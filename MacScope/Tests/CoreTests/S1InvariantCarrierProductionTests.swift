import Foundation
import XCTest
@testable import MacScope

/// New source-first cases for the bounded immutable physical-carrier proposal.
/// These are not execution results. Every refusal selector first requires a new
/// cyclic admission positive; a paired-positive failure alone is not evidence
/// that its negative was unsound. No production implementation is changed here.
@MainActor
final class S1InvariantCarrierProductionTests: XCTestCase {
    private let start: UInt64 = 0x1000
    private let header = """
        struct Ops { struct Ops *child; void (*run)(struct Ops *ops, int flag); void (*unknown)(); };
        void dispatch(struct Ops *ops, int flag, void *other);
        """
    // Save x19/x20 and LR, copy H1 root once, then repeat a fresh same-block
    // callable load. LR is restored before the terminal x19/x20 LDP + RET.
    private let loop: [UInt32] = [
        0xa9be53f3, 0xf9000bfe, 0xaa0003f3, 0xaa0103f4,
        0xaa1303e0, 0x2a1403e1, 0xf9400668, 0xd63f0100,
        0xf1000694, 0x54ffff61, 0xf9400bfe, 0xa8c253f3, 0xd65f03c0
    ]
    private let backward: [UInt32] = [
        0xa9be53f3, 0xf9000bfe, 0xaa0003f3, 0x14000008,
        0xf9400668, 0xd63f0100, 0xf9400bfe, 0xa8c253f3,
        0xd65f03c0, 0xd503201f, 0xd503201f, 0xd503201f, 0x17fffff8
    ]
    private func bytes(_ words: [UInt32]) -> Data {
        Data(words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) } })
    }
    private func conditionalBranch(from: Int, to: Int) -> UInt32 {
        0x54000001 | ((UInt32(truncatingIfNeeded: to - from) & 0x7ffff) << 5)
    }
    private func branch(from: Int, to: Int) -> UInt32 {
        0x14000000 | (UInt32(truncatingIfNeeded: to - from) & 0x03ffffff)
    }
    private func decode(_ words: [UInt32], file: StaticString = #filePath, line: UInt = #line) -> [DecodedInstruction] {
        let result = ARM64Decoder().decode(bytes(words), baseAddress: start, maxInstructionCount: words.count)
        XCTAssertEqual(result.count, words.count, file: file, line: line)
        for (index, instruction) in result.enumerated() {
            XCTAssertEqual(instruction.address, start + UInt64(index * 4), file: file, line: line)
            XCTAssertEqual(instruction.bytes, Array(bytes([words[index]])), file: file, line: line)
        }
        return result
    }
    private func render(_ words: [UInt32], file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let decoded = decode(words, file: file, line: line)
        let image = S1RecoveryMachOFixture.make(bodies: [start: ("dispatch", words)], exported: ["dispatch"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("s1-invariant-\(UUID().uuidString).dylib")
        try image.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var snapshot = try AnalysisEngine().analyze(url: url)
        let analysis = try XCTUnwrap(snapshot.analysis(in: .primary), file: file, line: line)
        XCTAssertEqual(analysis.imageBytes, image, file: file, line: line)
        XCTAssertTrue(analysis.functions.contains { $0.startAddress == start }, file: file, line: line)
        for instruction in decoded {
            let row = try XCTUnwrap(analysis.instructions.first { $0.address == instruction.address }, file: file, line: line)
            XCTAssertEqual(row.bytes, instruction.byteText, file: file, line: line)
            XCTAssertEqual(row.mnemonic, instruction.mnemonic, file: file, line: line)
            XCTAssertEqual(row.operands, instruction.operands, file: file, line: line)
        }
#if os(Linux)
        let imported = HeaderImportCore.prepare(source: header, typeDefinitions: snapshot.typeDefinitions,
            exports: analysis.exports, functions: analysis.functions, importedPrototypes: snapshot.importedPrototypes, slot: .primary)
        snapshot.typeDefinitions = imported.types
        snapshot.importedPrototypes = imported.prototypes
        snapshot.recordHeaderImportEvidence(imported.headerLayoutDefinitions)
#else
        let store = WorkspaceStore(workspaceName: "Invariant carrier proofs", snapshot: snapshot,
            engine: AnalysisEngine(), autosaveScheduler: nil)
        store.defineTypesFromCHeader(header)
        snapshot = store.snapshot
#endif
        XCTAssertNotNil(snapshot.functionSignatureOverrides(in: .primary)[start], file: file, line: line)
        _ = snapshot.imageWideIndirectCalls(in: .primary, compute: true)
        return DocumentExportService().pseudocodeText(
            for: snapshot.pseudocodeRenderInput(selectedAddress: start, in: .primary), options: .default)
    }
    private func typed(_ text: String) -> Bool {
        text.filter { !$0.isWhitespace }.contains("void(*)(structOps*,int32_t)")
    }
    private func positive(file: StaticString = #filePath, line: UInt = #line) throws {
        let decoded = decode(loop, file: file, line: line)
        XCTAssertEqual(decoded.map(\.mnemonic), ["stp", "str", "mov", "mov", "mov", "mov", "ldr", "blr", "subs", "b.ne", "ldr", "ldp", "ret"], file: file, line: line)
        XCTAssertEqual(decoded[9].branchTarget, start + 16, file: file, line: line)
        XCTAssertEqual(decoded[2].operands.replacingOccurrences(of: " ", with: ""), "x19,x0", file: file, line: line)
        XCTAssertEqual(decoded[6].operands.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "#0x8", with: "#8"), "x8,[x19,#8]", file: file, line: line)
        let text = try render(loop, file: file, line: line)
        XCTAssertTrue(typed(text), text, file: file, line: line)
    }
    func testInvariantLoopWithTerminalRestoreAdmits() throws { try positive() }

    func testInvariantBackwardLayoutAdmits() throws {
        try positive()
        let decoded = decode(backward)
        XCTAssertEqual(decoded[3].branchTarget, start + 44)
        XCTAssertEqual(decoded[12].branchTarget, start + 16)
        let text = try render(backward)
        XCTAssertTrue(typed(text), text)
    }
    func testEntryReexecutionRefuses() throws {
        try positive()
        var words = loop
        words[9] = conditionalBranch(from: 9, to: 0)
        XCTAssertEqual(decode(words)[9].branchTarget, start)
        XCTAssertFalse(typed(try render(words)))
    }
    func testSoleStaticDefinitionReexecutionRefuses() throws {
        try positive()
        var words = loop
        words[9] = conditionalBranch(from: 9, to: 2)
        XCTAssertEqual(decode(words)[9].branchTarget, start + 8)
        XCTAssertFalse(typed(try render(words)))
    }
    func testLoopCarriedXAndWOverwritesRefuse() throws {
        try positive()
        for overwrite: UInt32 in [0xaa0203f3, 0x2a0203f3] {
            var words = loop
            words.insert(overwrite, at: 8)
            words[10] = conditionalBranch(from: 10, to: 4)
            XCTAssertEqual(decode(words)[8].mnemonic, "mov")
            XCTAssertFalse(typed(try render(words)))
        }
    }
    func testBackwardLayoutInterveningOverwriteRefuses() throws {
        try positive()
        var words = backward
        words[11] = 0xaa0203f3
        XCTAssertEqual(decode(words)[11].operands.replacingOccurrences(of: " ", with: ""), "x19,x2")
        XCTAssertFalse(typed(try render(words)))
    }
    func testBypassJoinCannotInventInvariantDefinition() throws {
        try positive()
        var words = loop
        words[2] = 0xb4000042 // CBZ x2, index4 bypasses the sole root copy.
        words[3] = 0xaa0003f3
        XCTAssertEqual(decode(words)[2].branchTarget, start + 16)
        XCTAssertFalse(typed(try render(words)))
    }
    func testCallerSavedCarrierCannotSurviveLoopCall() throws {
        try positive()
        var words = loop
        words[2] = 0xaa0003e9 // MOV x9,x0.
        words[4] = 0xaa0903e0 // MOV x0,x9.
        words[6] = 0xf9400528 // LDR x8,[x9,#8].
        XCTAssertEqual(decode(words)[2].operands.replacingOccurrences(of: " ", with: ""), "x9,x0")
        XCTAssertFalse(typed(try render(words)))
    }
    func testUnknownPhysicalWriterFootprintRefuses() throws {
        try positive()
        var words = loop
        words.insert(0xd4000001, at: 8) // SVC #0 is decoded, but has no modeled write footprint.
        words[10] = conditionalBranch(from: 10, to: 4)
        XCTAssertEqual(decode(words)[8].mnemonic, "svc")
        XCTAssertFalse(typed(try render(words)))
    }
    func testNonterminalRestoreCannotBeExempted() throws {
        try positive()
        var words = loop
        words[12] = branch(from: 12, to: 4)
        XCTAssertEqual(decode(words)[12].branchTarget, start + 16)
        XCTAssertFalse(typed(try render(words)))
    }
    func testUnresolvedIndirectEdgeCannotCertifyTerminalRestore() throws {
        try positive()
        var words = loop
        words[12] = 0xd61f0040 // BR x2 is not a proven terminal return.
        XCTAssertEqual(decode(words)[12].mnemonic, "br")
        XCTAssertEqual(decode(words)[12].operands, "x2")
        XCTAssertFalse(typed(try render(words)))
    }
    func testLoadedAndChasedFactsAreNotInvariantSeeds() throws {
        try positive()
        let capturedBeforeBlock: [UInt32] = [
            0xa9be53f3, 0xf9000bfe, 0xaa0003f3, 0xf9400668,
            0x14000001, 0xd503201f, 0xd63f0100, 0x35ffffc1,
            0xf9400bfe, 0xa8c253f3, 0xd65f03c0
        ]
        var chasedBeforeBlock = capturedBeforeBlock
        chasedBeforeBlock[3] = 0xf9400275 // LDR x21,[x19] captures child outside loop block.
        chasedBeforeBlock[5] = 0xf94006a8 // LDR x8,[x21,#8].
        for words in [capturedBeforeBlock, chasedBeforeBlock] {
            XCTAssertEqual(decode(words)[7].branchTarget, start + 20)
            XCTAssertFalse(typed(try render(words)))
        }
    }
    func testMixedUnspecifiedCallStillRefusesWholeFunction() throws {
        try positive()
        var words = loop
        words.insert(contentsOf: [0xf9400a68, 0xd63f0100], at: 8) // LDR x8,[x19,#16]; BLR x8.
        words[11] = conditionalBranch(from: 11, to: 4)
        XCTAssertEqual(decode(words)[8].mnemonic, "ldr")
        XCTAssertFalse(typed(try render(words)))
    }

    // These additions use independent fresh images and inspect both the retained
    // physical proof and the final production call frame/render.
    private func certified(_ words: [UInt32], resultType: String = "void", admitted: Bool = true,
                           captureSelector: String? = nil,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        let declaration = "struct Ops { struct Ops *child; \(resultType) (*run)(struct Ops *ops, int flag); }; "
            + "void dispatch(struct Ops *ops, int flag, void *other);"
        let image = S1RecoveryMachOFixture.make(bodies: [
            start: ("dispatch", words), 0x2000: ("generic", [0xd63f0100, 0xd65f03c0])
        ], exported: ["dispatch"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-proof-\(UUID().uuidString).dylib")
        try image.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var snapshot = try AnalysisEngine().analyze(url: url)
        let analysis = try XCTUnwrap(snapshot.analysis(in: .primary), file: file, line: line)
#if os(Linux)
        let imported = HeaderImportCore.prepare(source: declaration, typeDefinitions: snapshot.typeDefinitions,
            exports: analysis.exports, functions: analysis.functions, importedPrototypes: snapshot.importedPrototypes, slot: .primary)
        snapshot.typeDefinitions = imported.types
        snapshot.importedPrototypes = imported.prototypes
        snapshot.recordHeaderImportEvidence(imported.headerLayoutDefinitions)
#else
        let store = WorkspaceStore(workspaceName: "Terminal restore proofs", snapshot: snapshot,
            engine: AnalysisEngine(), autosaveScheduler: nil)
        store.defineTypesFromCHeader(declaration)
        snapshot = store.snapshot
#endif
        XCTAssertEqual(analysis.imageBytes, image, file: file, line: line)
        XCTAssertNotNil(snapshot.importedPrototypes[.primary(start)], file: file, line: line)
        XCTAssertTrue(snapshot.addressOverrides.isEmpty, file: file, line: line)
        _ = snapshot.imageWideIndirectCalls(in: .primary, compute: true)
        let report = try XCTUnwrap(snapshot.slotTypedPrototypeReport(in: .primary, compute: false), file: file, line: line)
        let input = snapshot.pseudocodeRenderInput(selectedAddress: start, in: .primary)
        let text: String
        #if DEBUG
        if let captureSelector, let observer = F2J1CaptureRecorder.s1CaptureObserver {
            let capture = PseudocodePrinter.RenderCapture()
            var exporter = DocumentExportService()
            exporter.pseudocodeCapture = capture
            text = exporter.pseudocodeText(for: input, options: .default)
            if let output = capture.output { observer(captureSelector, output) }
        } else {
            text = DocumentExportService().pseudocodeText(for: input, options: .default)
        }
        #else
        text = DocumentExportService().pseudocodeText(for: input, options: .default)
        #endif
        let function = PseudocodePrinter().buildFunction(functionName: input.functionName,
            startAddress: input.startAddress, jumpTables: input.jumpTables,
            signatureOverrides: input.signatureOverrides, slotCallContracts: input.slotCallContracts,
            types: input.types, instructions: input.instructions)
        let site = start + UInt64(try XCTUnwrap(words.firstIndex(of: 0xd63f0100), file: file, line: line) * 4)
        let operation = try XCTUnwrap(function.instructions.first { $0.source.address == site }, file: file, line: line)
        guard case let .call(frame, result) = operation.operation else {
            return XCTFail("Expected original BLR call", file: file, line: line)
        }
        if admitted {
            let proof = try XCTUnwrap(report.callProofRows.first { $0.callAddress == site }, file: file, line: line)
            XCTAssertEqual(proof.rootFunctionStart, start, file: file, line: line)
            XCTAssertEqual(proof.rootParameterIndex, 0, file: file, line: line)
            XCTAssertEqual(proof.rootCopyAddresses, [start + 8], file: file, line: line)
            XCTAssertEqual(proof.loadAddress, site - 4, file: file, line: line)
            XCTAssertTrue(proof.physicalProof.contains("dominating immutable physical root carrier"), file: file, line: line)
            XCTAssertTrue(proof.physicalProof.contains("captured target retained"), file: file, line: line)
            let signature = try XCTUnwrap(frame.typedIndirectSignature, file: file, line: line)
            XCTAssertEqual(signature.source, "header-derived-slot", file: file, line: line)
            XCTAssertEqual(signature.parameters.count, 2, file: file, line: line)
            XCTAssertNotNil(frame.arguments.fixedArgument(at: 0), file: file, line: line)
            XCTAssertNotNil(frame.arguments.fixedArgument(at: 1), file: file, line: line)
            XCTAssertNil(frame.arguments.fixedArgument(at: 2), file: file, line: line)
            XCTAssertEqual(result == nil, resultType == "void", file: file, line: line)
            let load = try XCTUnwrap(function.instructions.first { $0.source.address == proof.loadAddress }, file: file, line: line)
            guard case let .load(capture, _) = load.operation else {
                return XCTFail("Expected original target load", file: file, line: line)
            }
            XCTAssertEqual(frame.controlInputs.indirectTarget?.value, capture, file: file, line: line)
            let rendered = try XCTUnwrap(text.components(separatedBy: .newlines).first { $0.contains("(*)") }, text, file: file, line: line)
            let statement = String(rendered.split(separator: ";", maxSplits: 1)[0])
            var depth = 0, commaCount = 0
            for character in statement.reversed() {
                if character == ")" { depth += 1 }
                if character == "(" { depth -= 1; if depth == 0 { break } }
                if character == "," && depth == 1 { commaCount += 1 }
            }
            XCTAssertEqual(commaCount + 1, 2, rendered, file: file, line: line)
            XCTAssertEqual(statement.contains("="), resultType != "void", rendered, file: file, line: line)
        } else {
            XCTAssertNil(report.callContracts[site], file: file, line: line)
            XCTAssertNil(frame.typedIndirectSignature, file: file, line: line)
            XCTAssertTrue(text.contains("(*"), text, file: file, line: line)
        }
        let generic = snapshot.pseudocodeRenderInput(selectedAddress: 0x2000, in: .primary)
        var withoutContracts = generic
        withoutContracts.slotCallContracts = [:]
        XCTAssertNil(report.callContracts[0x2000], file: file, line: line)
        XCTAssertEqual(DocumentExportService().pseudocodeText(for: generic, options: .default),
                       DocumentExportService().pseudocodeText(for: withoutContracts, options: .default), file: file, line: line)
    }
    private func terminalChain(_ restores: [UInt32]) -> [UInt32] {
        Array(loop.prefix(10)) + restores + [0xd65f03c0]
    }
    func testTwoRestoreChainHasExactVoidCallAndCapture() throws {
        try certified(terminalChain([0xa94053f3, 0xa8c27bfd]), captureSelector:
            "CoreTests/S1InvariantCarrierProductionTests/testTwoRestoreChainHasExactVoidCallAndCapture")
    }
    func testSixRestoreChainHasExactNonvoidCallAndCapture() throws {
        try certified(terminalChain([0xa94153f3, 0xa9425bf5, 0xa94363f7,
                                     0xa9446bf9, 0xa94573fb, 0xa8c67bfd]), resultType: "void *", captureSelector:
            "CoreTests/S1InvariantCarrierProductionTests/testSixRestoreChainHasExactNonvoidCallAndCapture")
    }
    func testTerminalFrameDeallocationHasExactCall() throws {
        try certified(terminalChain([0xa94053f3, 0xa9417bfd, 0x910083ff]), captureSelector:
            "CoreTests/S1InvariantCarrierProductionTests/testTerminalFrameDeallocationHasExactCall")
    }
    func testPureVectorAndScalarFootprintsPreserveInvariantRoot() throws {
        // Model the actual target families between the root copy and first use.
        var words = Array(loop.prefix(4)) + [UInt32](arrayLiteral:
            0x6f00e400, 0x6ea18c00, 0x6e205800, 0x6eb0a800,
            0x1e260008, 0xfc408520, 0xd37e7d08)
        words += Array(loop[4...8])
        words += [conditionalBranch(from: 16, to: 4), 0xa94053f3, 0xa8c27bfd, 0xd65f03c0]
        try certified(words, captureSelector:
            "CoreTests/S1InvariantCarrierProductionTests/testPureVectorAndScalarFootprintsPreserveInvariantRoot")
    }
    func testNarrowCarrierOverwriteBeforeRestoreChainRefuses() throws {
        var words = terminalChain([0xa94053f3, 0xa8c27bfd])
        words[8] = 0x2a0203f3
        try certified(words, admitted: false)
    }
    func testVectorToGPRCarrierClobbersRefuse() throws {
        for instruction: UInt32 in [0x1e260013, 0x4e083c13] {
            var words = terminalChain([0xa94053f3, 0xa8c27bfd])
            words[8] = instruction
            try certified(words, admitted: false)
        }
    }
    func testVectorStoreWritebackClobbersCarrierRefuses() throws {
        for instruction: UInt32 in [0xfc008660, 0x3c810e60] {
            var words = terminalChain([0xa94053f3, 0xa8c27bfd])
            words[8] = instruction
            try certified(words, admitted: false)
        }
    }
    func testUnknownFootprintWithRestoreChainRefuses() throws {
        var words = terminalChain([0xa94053f3, 0xa8c27bfd])
        words[8] = 0xd4000001
        try certified(words, admitted: false)
    }
    func testRestoreChainBackedgeRefuses() throws {
        var words = terminalChain([0xa94053f3, 0xa8c27bfd])
        words[12] = branch(from: 12, to: 4)
        try certified(words, admitted: false)
    }
    func testRestoreChainFollowedByCallRefuses() throws {
        try certified(terminalChain([0xa94053f3, 0xa8c27bfd, 0x94000400]), admitted: false)
    }
    func testRestoreChainAlternateSuccessorToBodyRefuses() throws {
        try certified(terminalChain([0xa94053f3, conditionalBranch(from: 11, to: 4), 0xa8c27bfd]), admitted: false)
    }
    func testFinalDirectCallConditionalExitRetainsRootButRejectsClobberedArgument() throws {
        let value = try FinalCallCarrierFixture.render()
        if value.function.ssaEnabled {
            try value.assertMissingSecondArgument()
        } else {
            try value.assertTyped(arity: 2)
        }
        XCTAssertEqual(value.decoded[6].branchTarget, 0x1020)
        XCTAssertEqual(value.decoded[7].mnemonic, "ret")
        XCTAssertEqual(value.decoded[8].mnemonic, "bl")
    }

    func testFinalDirectCallFallthroughExitRetainsRootButRejectsClobberedArgument() throws {
        var words = FinalCallCarrierFixture.words
        words[7] = 0xd503201f
        let value = try FinalCallCarrierFixture.render(words: words)
        if value.function.ssaEnabled {
            try value.assertMissingSecondArgument()
        } else {
            try value.assertTyped(arity: 2)
        }
    }

    func testFinalDirectCallWithoutFollowingFunctionStartRefuses() throws {
        try FinalCallCarrierFixture.render(followingFunction: false).assertUnresolved()
    }

    func testFinalDirectCallWithIndirectBranchRefuses() throws {
        var words = FinalCallCarrierFixture.words
        words[7] = 0xd61f0040 // BR x2 on the alternate exit path.
        try FinalCallCarrierFixture.render(words: words).assertUnresolved()
    }

    func testFinalDirectCallWithUnreachableIndirectBranchRefuses() throws {
        var words = FinalCallCarrierFixture.words
        words[6] = branch(from: 6, to: 8)
        words[7] = 0xd61f0040
        try FinalCallCarrierFixture.render(words: words).assertUnresolved()
    }

    func testFinalDirectCallWithConditionalEdgeToNextFunctionRefuses() throws {
        var words = FinalCallCarrierFixture.words
        words[6] = conditionalBranch(from: 6, to: 9)
        try FinalCallCarrierFixture.render(words: words).assertUnresolved()
    }

    func testDirectCallFollowedByInstructionInsideExtentRefuses() throws {
        try FinalCallCarrierFixture.render(words: FinalCallCarrierFixture.words + [0xd503201f]).assertUnresolved()
    }

    func testFinalIndirectCallRefuses() throws {
        var words = FinalCallCarrierFixture.words
        words[8] = 0xd63f0040 // BLR x2 does not certify an exit.
        try FinalCallCarrierFixture.render(words: words).assertUnresolved()
    }

}


/// Real-image fixture shared only by the added terminal-call regression cases.
@MainActor
enum FinalCallCarrierFixture {
    static let words: [UInt32] = [
        0xaa0003f3, // MOV x19,x0: unique invariant root.
        0xf9400269, 0xf9400128, 0xaa1303e0, 0xd63f0100,
        0x35ffff81, // CBNZ w1,0x1004 forces the invariant planner.
        0x54000041, // B.NE 0x1020 reaches the final BL.
        0xd65f03c0, // RET: no fall-through edge to the BL.
        0x97fffff8  // BL 0x1000: ordinary local callee, no noreturn authority.
    ]
    struct Rendered {
        let decoded: [DecodedInstruction]
        let text: String
        let function: MacIRFunction
        let report: SlotTypedPrototypeBinding.Report

        func assertMissingSecondArgument(
            file: StaticString = #filePath, line: UInt = #line
        ) throws {
            let proof = try XCTUnwrap(
                report.callProofRows.first { $0.callAddress == 0x1010 },
                file: file, line: line)
            XCTAssertEqual(proof.rootFunctionStart, 0x1000, file: file, line: line)
            XCTAssertEqual(proof.rootCopyAddresses, [0x1000], file: file, line: line)
            XCTAssertTrue(proof.physicalProof.contains("dominating immutable physical root carrier"),
                          file: file, line: line)
            let call = try XCTUnwrap(
                function.instructions.first { $0.source.address == 0x1010 },
                file: file, line: line)
            guard case let .call(frame, result) = call.operation else {
                return XCTFail("Expected original callback", file: file, line: line)
            }
            XCTAssertNil(frame.typedIndirectSignature, file: file, line: line)
            XCTAssertEqual(frame.arguments.canonicalPhysicalEntriesForAudit.count,
                           1, file: file, line: line)
            XCTAssertFalse(frame.arguments.canonicalPhysicalEntriesForAudit.contains {
                $0.location == .gpr(index: 1, carrierWidth: 64)
            }, file: file, line: line)
            XCTAssertNotNil(result, file: file, line: line)
        }

        func assertTyped(arity: Int, file: StaticString = #filePath, line: UInt = #line) throws {
            let proof = try XCTUnwrap(report.callProofRows.first { $0.callAddress == 0x1010 }, file: file, line: line)
            XCTAssertEqual(proof.rootFunctionStart, 0x1000, file: file, line: line)
            XCTAssertEqual(proof.rootCopyAddresses, [0x1000], file: file, line: line)
            XCTAssertTrue(proof.physicalProof.contains("dominating immutable physical root carrier"), file: file, line: line)
            let call = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1010 }, file: file, line: line)
            guard case let .call(frame, result) = call.operation else {
                return XCTFail("Expected original callback", file: file, line: line)
            }
            XCTAssertEqual(frame.typedIndirectSignature?.parameters.count, arity, file: file, line: line)
            XCTAssertEqual(frame.arguments.canonicalPhysicalEntriesForAudit.count, arity, file: file, line: line)
            XCTAssertEqual(frame.typedIndirectSignature?.returnType, "void", file: file, line: line)
            XCTAssertNil(result, file: file, line: line)
            let rendered = try XCTUnwrap(text.components(separatedBy: .newlines).first { $0.contains("(*)") }, text, file: file, line: line)
            let statement = String(rendered.split(separator: ";", maxSplits: 1)[0])
            XCTAssertFalse(statement.contains("="), rendered, file: file, line: line)
            var depth = 0, commas = 0
            for character in statement.reversed() {
                if character == ")" { depth += 1 }
                if character == "(" { depth -= 1; if depth == 0 { break } }
                if character == "," && depth == 1 { commas += 1 }
            }
            XCTAssertEqual(commas + 1, arity, rendered, file: file, line: line)
        }

        func assertUnresolved(file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertNil(report.callContracts[0x1010], file: file, line: line)
            XCTAssertFalse(report.callProofRows.contains { $0.functionStart == 0x1000 }, file: file, line: line)
            XCTAssertTrue(report.refusals.contains {
                $0.functionStart == 0x1000 && $0.reason == "unsupported_nonforward_or_incomplete_cfg"
            }, file: file, line: line)
            let call = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1010 }, file: file, line: line)
            guard case let .call(frame, _) = call.operation else {
                return XCTFail("Expected unresolved callback", file: file, line: line)
            }
            XCTAssertNil(frame.typedIndirectSignature, file: file, line: line)
            XCTAssertTrue(text.contains("(*"), text, file: file, line: line)
        }
    }

    static func render(words: [UInt32] = words, followingFunction: Bool = true,
                       declaration: String = """
                       struct FinalOps { void (*run)(void *root, int flag); };
                       struct FinalRoot { struct FinalOps *ops; };
                       void dispatch(struct FinalRoot *root, int flag, void *other);
                       """) throws -> Rendered {
        let end = UInt64(0x1000 + words.count * 4)
        var bodies: [UInt64: (String, [UInt32])] = [0x1000: ("dispatch", words)]
        if followingFunction { bodies[end] = ("following", [0xd65f03c0]) }
        let image = S1RecoveryMachOFixture.make(bodies: bodies, exported: ["dispatch"])
        let parsed = try MachOParser().parse(image)
        XCTAssertEqual(parsed.functionStarts.contains { $0.address == end }, followingFunction)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("final-call-\(UUID().uuidString).dylib")
        try image.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var snapshot = try AnalysisEngine().analyze(url: url)
        let analysis = try XCTUnwrap(snapshot.analysis(in: .primary))
        XCTAssertEqual(analysis.functions.contains { $0.startAddress == end }, followingFunction)
        let bytes = Data(words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) } })
        let decoded = ARM64Decoder().decode(bytes, baseAddress: 0x1000, maxInstructionCount: words.count)
        XCTAssertEqual(decoded.count, words.count)
        for instruction in decoded {
            let row = try XCTUnwrap(analysis.instructions.first { $0.address == instruction.address })
            XCTAssertEqual(row.bytes, instruction.byteText)
            XCTAssertEqual(row.mnemonic, instruction.mnemonic)
            XCTAssertEqual(row.operands, instruction.operands)
        }
#if os(Linux)
        let imported = HeaderImportCore.prepare(source: declaration, typeDefinitions: snapshot.typeDefinitions,
            exports: analysis.exports, functions: analysis.functions, importedPrototypes: snapshot.importedPrototypes, slot: .primary)
        snapshot.typeDefinitions = imported.types
        snapshot.importedPrototypes = imported.prototypes
        snapshot.recordHeaderImportEvidence(imported.headerLayoutDefinitions)
#else
        let store = WorkspaceStore(workspaceName: "Final call proofs", snapshot: snapshot,
            engine: AnalysisEngine(), autosaveScheduler: nil)
        store.defineTypesFromCHeader(declaration)
        snapshot = store.snapshot
#endif
        XCTAssertNotNil(snapshot.importedPrototypes[.primary(0x1000)])
        XCTAssertTrue(snapshot.addressOverrides.isEmpty)
        _ = snapshot.imageWideIndirectCalls(in: .primary, compute: true)
        let report = try XCTUnwrap(snapshot.slotTypedPrototypeReport(in: .primary, compute: false))
        let input = snapshot.pseudocodeRenderInput(selectedAddress: 0x1000, in: .primary)
        let function = PseudocodePrinter().buildFunction(functionName: input.functionName,
            startAddress: input.startAddress, jumpTables: input.jumpTables,
            signatureOverrides: input.signatureOverrides, slotCallContracts: input.slotCallContracts,
            types: input.types, instructions: input.instructions)
        return Rendered(decoded: decoded,
            text: DocumentExportService().pseudocodeText(for: input, options: .default), function: function, report: report)
    }
}
