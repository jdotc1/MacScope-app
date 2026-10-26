import Foundation
import XCTest
@testable import MacScope

final class NoEvidenceReturnMarkerTests: XCTestCase {
    private typealias Operation = (String, String)
    private let marker = MacIRValue.unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker)

    private func rows(_ operations: [Operation], start: UInt64 = 0x1000) -> [InstructionRow] {
        operations.enumerated().map { index, operation in
            InstructionRow(address: start + UInt64(index * 4), bytes: "", mnemonic: operation.0,
                           operands: operation.1, hasBreakpoint: false, comment: nil)
        }
    }

    private func build(_ operations: [Operation]) -> MacIRFunction {
        MacIRBuilder().buildFunction(name: "return_fixture", startAddress: 0x1000,
                                     instructions: rows(operations))
    }

    private func assertReturns(_ function: MacIRFunction, admitted: Bool, count: Int = 1,
                               file: StaticString = #filePath, line: UInt = #line) {
        let returns: [MacIRValue?] = function.instructions.compactMap { instruction in
            guard case let .returnValue(value) = instruction.operation else { return nil }
            return .some(value)
        }
        XCTAssertEqual(returns.count, count, file: file, line: line)
        for value in returns {
            if admitted {
                XCTAssertNotNil(value, "producer evidence cannot establish void", file: file, line: line)
                XCTAssertNotEqual(value, marker, file: file, line: line)
            } else {
                XCTAssertEqual(value, marker, file: file, line: line)
            }
        }
    }

    func testAllPathsImmediateAndLoadKeepBothReturns() {
        assertReturns(build([
            ("cbz", "x2, 0x100c"), ("mov", "w0, #7"), ("ret", ""),
            ("ldr", "w0, [x1]"), ("ret", "")
        ]), admitted: true, count: 2)
    }

    func testAllPathsImmediateAndArithmeticKeepBothReturns() {
        assertReturns(build([
            ("cbz", "x2, 0x100c"), ("mov", "w0, #7"), ("ret", ""),
            ("add", "w0, w1, #1"), ("ret", "")
        ]), admitted: true, count: 2)
    }

    func testAllPathsZeroAndOneKeepJoinedReturn() {
        assertReturns(build([
            ("cbz", "x2, 0x100c"), ("mov", "w0, #1"), ("b", "0x1010"),
            ("mov", "w0, wzr"), ("ret", "")
        ]), admitted: true)
        for operand in ["#0", "#1", "wzr"] {
            assertReturns(build([("mov", "w0, \(operand)"), ("ret", "")]), admitted: true)
        }
    }

    func testExactCompareSetReturnDefinitionIsAdmittedInBothWidths() {
        for destination in ["w0", "x0"] {
            assertReturns(build([
                ("cmp", "x1, #0"), ("cset", "\(destination), ne"), ("ret", "")
            ]), admitted: true)
        }
    }

    func testCopiedBooleanDoesNotEstablishCompareSetReturnDefinition() {
        assertReturns(build([
            ("cmp", "x2, #0"), ("cset", "w1, ne"), ("mov", "w0, w1"), ("ret", "")
        ]), admitted: false)
        assertReturns(build([
            ("cmp", "x2, #0"), ("cset", "w0, ne"), ("mov", "w0, #7"), ("ret", "")
        ]), admitted: false)
    }

    func testCompareSetSelfCopyIsAnInterveningDefinition() {
        assertReturns(build([
            ("cmp", "x2, #0"), ("cset", "x0, ne"), ("mov", "x0, x0"), ("ret", "")
        ]), admitted: false)
    }

    func testAliasWritesReplaceThePriorConstantDefinition() {
        assertReturns(build([
            ("mov", "x0, #7"), ("mov", "w0, #1"), ("ret", "")
        ]), admitted: true)
        assertReturns(build([
            ("mov", "w0, #1"), ("mov", "x0, #7"), ("ret", "")
        ]), admitted: false)
    }

    func testIntegerProducerEvidenceCannotAdmitALaterScalarFPResult() {
        for move in ["d0, x1", "s0, w1"] {
            assertReturns(build([
                ("mov", "w0, #1"), ("fmov", move), ("ret", "")
            ]), admitted: false)
        }
        assertReturns(build([
            ("fmov", "d0, x1"), ("mov", "w0, #1"), ("ret", "")
        ]), admitted: true)
    }

    func testValidatedVectorOnlyWritesPreserveIntegerProducerEvidence() {
        assertReturns(build([
            ("movi", "v1.16b, #0"), ("mov", "w0, #1"), ("ret", "")
        ]), admitted: true)
        assertReturns(build([
            ("mov", "w0, #1"), ("movi", "x0, #0"), ("ret", "")
        ]), admitted: false)
    }

    func testLoadWritebackDistinguishesLoadedResultFromUpdatedBase() {
        assertReturns(build([
            ("cbz", "x2, 0x100c"), ("mov", "w0, #7"), ("ret", ""),
            ("ldr", "w0, [x1], #4"), ("ret", "")
        ]), admitted: true, count: 2)
        assertReturns(build([
            ("mov", "x0, #1"), ("ldr", "x1, [x0], #8"), ("ret", "")
        ]), admitted: false)
    }

    func testArgumentCopyAndImmediateOnPartialPathsAreRefused() {
        assertReturns(build([
            ("cbz", "x2, 0x100c"), ("mov", "w0, #1"), ("b", "0x1010"),
            ("mov", "w0, w1"), ("ret", "")
        ]), admitted: false)
    }

    func testImmediateWithUnwrittenPathIsRefused() {
        assertReturns(build([
            ("cbz", "x2, 0x1008"), ("mov", "w0, #1"), ("ret", "")
        ]), admitted: false)
    }

    func testConstantsOutsideBooleanSubsetAreRefused() {
        for constant in [2, 7] {
            assertReturns(build([("mov", "w0, #\(constant)"), ("ret", "")]), admitted: false)
        }
        assertReturns(build([
            ("cbz", "x2, 0x100c"), ("mov", "w0, #0"), ("ret", ""),
            ("mov", "w0, #2"), ("ret", "")
        ]), admitted: false, count: 2)
    }

    func testImmediateAndLoadWithAnUnwrittenPathAreRefused() {
        assertReturns(build([
            ("cbz", "x2, 0x1018"), ("cbz", "x3, 0x1010"),
            ("mov", "w0, #7"), ("b", "0x1018"), ("ldr", "w0, [x1]"),
            ("b", "0x1018"), ("ret", "")
        ]), admitted: false)
    }

    func testCallResultReachingReturnRequiresIndependentCallerEvidence() {
        for call in [("bl", "0x5000"), ("blr", "x8")] {
            assertReturns(build([call, ("ret", "")]), admitted: false)
        }
        assertReturns(build([
            ("cbz", "x2, 0x100c"), ("mov", "w0, #0"), ("ret", ""),
            ("bl", "0x5000"), ("ret", "")
        ]), admitted: false, count: 2)
    }

    func testCallClobberedRegisterCopyCannotRecoverEarlierConstant() {
        for call in [("bl", "0x5000"), ("blr", "x8")] {
            assertReturns(build([
                ("mov", "w1, #1"), call, ("mov", "w0, w1"), ("ret", "")
            ]), admitted: false)
        }
    }

    func testKnownNonReturningCalleeEndsOnlyItsOwnPath() {
        XCTAssertTrue(NoReturnCatalog.isNoReturn("__stack_chk_fail"))
        assertReturns(build([
            ("cbz", "x2, 0x100c"), ("mov", "w0, #1"), ("ret", ""),
            ("bl", "__stack_chk_fail")
        ]), admitted: true)
        assertReturns(build([
            ("cbz", "x2, 0x100c"), ("mov", "w0, #1"), ("ret", ""),
            ("bl", "unknown_callee")
        ]), admitted: false)
    }

    func testCallResultOverwrittenByBooleanConstantIsAdmitted() {
        assertReturns(build([
            ("bl", "0x5000"), ("mov", "w0, #1"), ("ret", "")
        ]), admitted: true)
    }

    func testAlternateUnresolvedIndirectTailAndTrapExitsRefuseReturnProof() {
        for exit: Operation in [("b", "0x5000"), ("b", "unresolved_target"),
                                ("br", "x8"), ("brk", "#0")] {
            assertReturns(build([
                ("cbz", "x2, 0x100c"), ("mov", "w0, #1"), ("ret", ""), exit
            ]), admitted: false)
        }
        assertReturns(build([
            ("cbz", "x2, 0x100c"), ("mov", "w0, #1"), ("ret", ""), ("nop", "")
        ]), admitted: false)
    }

    func testUnmodeledAliasAndMemoryReloadDoNotInheritBooleanEvidence() {
        assertReturns(build([
            ("mov", "w0, #1"), ("opaque", "x0, x1"), ("ret", "")
        ]), admitted: false)
        assertReturns(build([
            ("mov", "w0, #1"), ("str", "w0, [sp]"),
            ("ldr", "w0, [sp]"), ("ret", "")
        ]), admitted: false)
    }

    func testImmediateDirectCallerReadKeepsValueWithoutCallResultSSA() throws {
        var caller = MacIRBuilder().buildFunction(name: "caller", startAddress: 0x2000,
            instructions: rows([("bl", "0x1000"), ("cmp", "w0, #0"),
                                ("mov", "w0, #0"), ("ret", "")], start: 0x2000))
        guard case let .call(frame, _) = caller.instructions[0].operation else {
            return XCTFail("fixture must contain the direct call")
        }
        caller.instructions[0].operation = .call(frame: frame, result: nil)
        let target = MacIRFunction(name: "target", startAddress: 0x1000, instructions: [])
        let width = try XCTUnwrap(MacIRCallerReturnEvidence.collect(functions: [target, caller])[0x1000])
        let function = MacIRBuilder().buildFunction(name: "target", startAddress: 0x1000,
            callerReturnWidth: width, instructions: rows([("mov", "w0, #7"), ("ret", "")]))
        assertReturns(function, admitted: true)
    }

    func testImmediateCallerReadPreservesExistingNarrowing() throws {
        let caller = MacIRBuilder().buildFunction(name: "caller", startAddress: 0x2000,
            instructions: rows([("bl", "0x1000"), ("mov", "w9, w0"),
                                ("mov", "x0, #0"), ("ret", "")], start: 0x2000))
        let target = MacIRFunction(name: "target", startAddress: 0x1000, instructions: [])
        let width = try XCTUnwrap(MacIRCallerReturnEvidence.collect(functions: [target, caller])[0x1000])
        XCTAssertEqual(width, .w0)
        let function = MacIRBuilder().buildFunction(name: "target", startAddress: 0x1000,
            callerReturnWidth: width, instructions: rows([("add", "x9, x0, #1"), ("ret", "")]))
        assertReturns(function, admitted: true)
        XCTAssertEqual(function.returnType, "uint32_t")
    }

    private func callerEvidence(_ operations: [Operation], opaquePrefix: Operation? = nil,
                                targetDoesNotReturn: Bool = false) -> MacIRCallerReturnEvidence.Width? {
        let bodyStart: UInt64 = opaquePrefix.map { _ in 0x2004 } ?? 0x2000
        let body = MacIRBuilder().buildFunction(name: "caller", startAddress: bodyStart,
            instructions: rows(operations, start: bodyStart))
        let caller: MacIRFunction
        if let prefix = opaquePrefix {
            let instruction = MacIRInstruction(
                source: MacIRSourceSpan(address: 0x2000, byteText: "",
                    mnemonic: prefix.0, operands: prefix.1),
                operation: .unknown(mnemonic: prefix.0, operands: prefix.1))
            caller = MacIRFunction(name: "caller", startAddress: 0x2000,
                                   instructions: [instruction] + body.instructions)
        } else {
            caller = body
        }
        let target = MacIRFunction(name: "target", startAddress: 0x1000,
            isNoReturn: targetDoesNotReturn, instructions: [])
        return MacIRCallerReturnEvidence.collect(functions: [target, caller])[0x1000]
    }

    func testImmediateCallerReadCrossesPlainQStackAndPagePrologue() {
        for read: Operation in [("mov", "x20, x0"), ("cmp", "w0, #0")] {
            let width = callerEvidence([
                ("sub", "sp, sp, #0x40"), ("adrp", "x8, 0x4000"),
                ("bl", "0x1000"), read, ("mov", "x0, #0"),
                ("add", "sp, sp, #0x40"), ("ret", "")
            ], opaquePrefix: ("stp", "q0, q1, [sp, #0x30]"))
            XCTAssertEqual(width, .x0, "control-only reachability must not justify narrowing")
        }
    }

    func testImmediateCallerReadCrossesBoundedPlainQLoads() {
        for prefix: Operation in [("ldur", "q0, [x23, #0x28]"),
                                  ("ldr", "q31, [x30, #65520]"),
                                  ("ldp", "q0, q1, [sp, #-1024]")] {
            XCTAssertEqual(callerEvidence([
                ("bl", "0x1000"), ("cmp", "w0, #0"),
                ("mov", "x0, #0"), ("ret", "")
            ], opaquePrefix: prefix), .x0)
        }
    }

    func testControlOnlyReachabilityDoesNotCreateDelayedResultWitness() {
        XCTAssertNil(callerEvidence([
            ("sub", "sp, sp, #0x40"), ("bl", "0x1000"), ("nop", ""),
            ("mov", "x20, x0"), ("mov", "x0, #0"), ("ret", "")
        ]))
    }

    func testIndirectBranchBeforeCandidateCallPreventsWitness() {
        for prefix: [Operation] in [[], [("sub", "sp, sp, #0x40")]] {
            XCTAssertNil(callerEvidence(prefix + [
                ("br", "x8"), ("bl", "0x1000"), ("mov", "x20, x0"), ("ret", "")
            ]))
        }
    }

    func testKnownNonReturningCallBeforeCandidatePreventsWitness() {
        for nonReturningTarget in ["__stack_chk_fail", "_abort"] {
            for prefix: [Operation] in [[], [("sub", "sp, sp, #0x40")]] {
                XCTAssertNil(callerEvidence(prefix + [
                    ("bl", nonReturningTarget), ("bl", "0x1000"),
                    ("mov", "x9, x0"), ("ret", "")
                ]))
            }
        }
        XCTAssertNil(callerEvidence([
            ("sub", "sp, sp, #0x40"), ("bl", "0x1000"),
            ("mov", "x20, x0"), ("ret", "")
        ], targetDoesNotReturn: true))
    }

    func testAlwaysConditionalBranchesDoNotReachSkippedCall() {
        for mnemonic in ["b.al", "b.nv"] {
            XCTAssertNil(callerEvidence([
                (mnemonic, "0x2010"), ("bl", "0x1000"),
                ("mov", "x20, x0"), ("ret", ""), ("ret", "")
            ]))
        }
    }

    func testTrapBeforeCandidateCallPreventsWitness() {
        for trap: Operation in [("brk", "#0"), ("udf", "#0")] {
            XCTAssertNil(callerEvidence([
                ("sub", "sp, sp, #0x40"), trap,
                ("bl", "0x1000"), ("mov", "x20, x0"), ("ret", "")
            ]))
        }
    }

    func testUnsupportedPlainQPredecessorsCannotCreateWitness() {
        let refused: [Operation] = [
            ("ldr", "q32, [x1]"),
            ("ldr", "q00, [x1]"),
            ("ldr", "q0, [x1, x2]"),
            ("ldr", "q0, [x1, #16]!"),
            ("ldr", "q0, [x1, #--16]"),
            ("ldr", "q0, [x1, #65536]"),
            ("ldur", "q0, [x1, #256]"),
            ("stp", "q0, q1, [sp, #15]"),
            ("ldr", "q0, [x31]"),
            ("opaque", "x8")
        ]
        for prefix in refused {
            XCTAssertNil(callerEvidence([
                ("bl", "0x1000"), ("mov", "x20, x0"), ("ret", "")
            ], opaquePrefix: prefix), "\(prefix.0) \(prefix.1)")
        }
    }

    func testSymbolicOrAmbiguousCallerTargetCannotCreateEvidence() {
        let target = MacIRFunction(name: "target", startAddress: 0x1000, instructions: [])
        let symbolic = MacIRBuilder().buildFunction(name: "caller", startAddress: 0x2000,
            instructions: rows([("bl", "target"), ("cmp", "w0, #0"), ("ret", "")], start: 0x2000))
        XCTAssertNil(MacIRCallerReturnEvidence.collect(functions: [target, symbolic])[0x1000])
        let addressed = MacIRBuilder().buildFunction(name: "caller", startAddress: 0x2000,
            instructions: rows([("bl", "0x1000"), ("cmp", "w0, #0"), ("ret", "")], start: 0x2000))
        let duplicate = MacIRFunction(name: "other", startAddress: 0x1000, instructions: [])
        XCTAssertNil(MacIRCallerReturnEvidence.collect(functions: [target, duplicate, addressed])[0x1000])
    }

    func testUntypedSlotDoesNotAdmitStoredTargetReturn() {
        var analysis = ImageAnalysis()
        analysis.functions = [
            FunctionSummary(id: UUID(), name: "target", startAddress: 0x1000,
                            endAddress: 0x1008, confidence: 1),
            FunctionSummary(id: UUID(), name: "install", startAddress: 0x2000,
                            endAddress: 0x200c, confidence: 1)
        ]
        analysis.instructions = rows([("mov", "x0, #7"), ("ret", "")])
            + rows([("mov", "x8, #0x1000"), ("str", "x8, [x0]"), ("ret", "")], start: 0x2000)
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        snapshot.insertImage(binary: BinaryImage(id: UUID(), name: "slot-fixture", path: "/tmp/slot-fixture",
            kind: "executable", architecture: "arm64", slot: .primary), analysis: analysis)
        XCTAssertNotNil(snapshot.imageWideIndirectCalls(in: .primary, compute: true))
        let input = snapshot.pseudocodeRenderInput(selectedAddress: 0x1000, in: .primary)
        XCTAssertNil(input.signatureOverrides[0x1000])
        let text = PseudocodeView.document(for: input, options: .default).text
        XCTAssertTrue(text.contains("return unresolved_return_contract;"), text)
    }

    private var typedValueSlotHeader: String {
        """
        struct Slots { long (*value)(void); };
        void install(struct Slots *slots);
        """
    }

    private func typedValueSlotSnapshot(header: String) -> WorkspaceSnapshot {
        let parsed = CTypeHeaderParser.parse(header)
        var analysis = ImageAnalysis()
        analysis.functions = [
            FunctionSummary(id: UUID(), name: "target", startAddress: 0x1000,
                            endAddress: 0x1008, confidence: 1),
            FunctionSummary(id: UUID(), name: "install", startAddress: 0x2000,
                            endAddress: 0x200c, confidence: 1)
        ]
        analysis.instructions = rows([("mov", "x0, #7"), ("ret", "")])
            + rows([("mov", "x8, #0x1000"), ("str", "x8, [x0]"), ("ret", "")], start: 0x2000)
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        snapshot.insertImage(binary: BinaryImage(id: UUID(), name: "typed-slot-fixture", path: "/tmp/typed-slot-fixture",
            kind: "executable", architecture: "arm64", slot: .primary), analysis: analysis)
        snapshot.typeDefinitions = parsed.types
        for prototype in parsed.prototypes {
            if let function = analysis.functions.first(where: { $0.name == prototype.name }) {
                snapshot.importedPrototypes[.primary(function.startAddress)] = prototype.signature
            }
        }
        return snapshot
    }

    func testTypedValueSlotDoesNotDeclareWarmTargetReturn() {
        let snapshot = typedValueSlotSnapshot(header: typedValueSlotHeader)
        let coldInput = snapshot.pseudocodeRenderInput(selectedAddress: 0x1000, in: .primary)
        XCTAssertNil(coldInput.signatureOverrides[0x1000])
        let cold = PseudocodeView.document(for: coldInput, options: .default).text
        XCTAssertTrue(cold.contains("return unresolved_return_contract;"), cold)
        XCTAssertFalse(cold.contains("return 7;"), cold)
        XCTAssertFalse(cold.contains("return 0x7;"), cold)
        XCTAssertNotNil(snapshot.imageWideIndirectCalls(in: .primary, compute: true))
        let warmInput = snapshot.pseudocodeRenderInput(selectedAddress: 0x1000, in: .primary)
        XCTAssertNil(warmInput.signatureOverrides[0x1000])
        let warm = PseudocodeView.document(for: warmInput, options: .default).text
        XCTAssertTrue(warm.contains("return "), warm)
        XCTAssertTrue(warm.contains("return unresolved_return_contract;"), warm)
        XCTAssertFalse(warm.contains("return;"), warm)
        XCTAssertFalse(warm.contains("return 7;"), warm)
        XCTAssertFalse(warm.contains("return 0x7;"), warm)
    }

    func testIndependentTargetDeclarationKeepsTypedValueSlotTargetReturn() {
        let snapshot = typedValueSlotSnapshot(header: typedValueSlotHeader + "\nlong target(void);")
        XCTAssertEqual(snapshot.importedPrototypes[.primary(0x1000)]?.returnType, "int64_t")
        let coldInput = snapshot.pseudocodeRenderInput(selectedAddress: 0x1000, in: .primary)
        XCTAssertEqual(coldInput.signatureOverrides[0x1000]?.returnType, "int64_t")
        let cold = PseudocodeView.document(for: coldInput, options: .default).text
        XCTAssertTrue(cold.contains("return "), cold)
        XCTAssertFalse(cold.contains("unresolved_return_contract"), cold)
        XCTAssertFalse(cold.contains("return;"), cold)
        XCTAssertNotNil(snapshot.imageWideIndirectCalls(in: .primary, compute: true))
        let warmInput = snapshot.pseudocodeRenderInput(selectedAddress: 0x1000, in: .primary)
        XCTAssertEqual(warmInput.signatureOverrides[0x1000]?.returnType, "int64_t")
        XCTAssertEqual(warmInput.signatureOverrides[0x1000], snapshot.importedPrototypes[.primary(0x1000)])
        let warm = PseudocodeView.document(for: warmInput, options: .default).text
        XCTAssertTrue(warm.contains("return "), warm)
        XCTAssertFalse(warm.contains("unresolved_return_contract"), warm)
        XCTAssertFalse(warm.contains("return;"), warm)
        let function = PseudocodePrinter().buildFunction(functionName: warmInput.functionName,
            startAddress: warmInput.startAddress, signatureOverrides: warmInput.signatureOverrides,
            types: warmInput.types, instructions: warmInput.instructions)
        XCTAssertEqual(function.returnType, "int64_t")
        XCTAssertNotNil(function.returnValue)
        XCTAssertNotEqual(function.returnValue, marker)
    }

    func testRemovingIndependentTargetDeclarationRestoresSlotOnlyMarker() {
        let snapshot = typedValueSlotSnapshot(header: typedValueSlotHeader)
        XCTAssertNil(snapshot.importedPrototypes[.primary(0x1000)])
        let coldInput = snapshot.pseudocodeRenderInput(selectedAddress: 0x1000, in: .primary)
        XCTAssertNil(coldInput.signatureOverrides[0x1000])
        let cold = PseudocodeView.document(for: coldInput, options: .default).text
        XCTAssertTrue(cold.contains("return unresolved_return_contract;"), cold)
        XCTAssertFalse(cold.contains("return 7;"), cold)
        XCTAssertFalse(cold.contains("return 0x7;"), cold)
        XCTAssertNotNil(snapshot.imageWideIndirectCalls(in: .primary, compute: true))
        let warmInput = snapshot.pseudocodeRenderInput(selectedAddress: 0x1000, in: .primary)
        XCTAssertNil(warmInput.signatureOverrides[0x1000])
        let warm = PseudocodeView.document(for: warmInput, options: .default).text
        XCTAssertTrue(warm.contains("return unresolved_return_contract;"), warm)
        XCTAssertFalse(warm.contains("return;"), warm)
        XCTAssertFalse(warm.contains("return 7;"), warm)
        XCTAssertFalse(warm.contains("return 0x7;"), warm)
    }

    func testTypedValueSlotStoreStillTypesIndirectInvocation() throws {
        let parsed = CTypeHeaderParser.parse(typedValueSlotHeader)
        var analysis = ImageAnalysis()
        analysis.functions = [
            FunctionSummary(id: UUID(), name: "target", startAddress: 0x1000,
                            endAddress: 0x1008, confidence: 1),
            FunctionSummary(id: UUID(), name: "install", startAddress: 0x2000,
                            endAddress: 0x201c, confidence: 1)
        ]
        let literalRows: [(UInt64, String, String, String)] = [
            (0x1000, "e0 00 80 d2", "mov", "x0, #7"),
            (0x1004, "c0 03 5f d6", "ret", ""),
            (0x2000, "08 80 ff 10", "adr", "x8, 0x1000"),
            (0x2004, "fd 7b bf a9", "stp", "x29, x30, [sp, #-16]!"),
            (0x2008, "08 00 00 f9", "str", "x8, [x0]"),
            (0x200c, "08 00 40 f9", "ldr", "x8, [x0]"),
            (0x2010, "00 01 3f d6", "blr", "x8"),
            (0x2014, "fd 7b c1 a8", "ldp", "x29, x30, [sp], #16"),
            (0x2018, "c0 03 5f d6", "ret", "")
        ]
        analysis.instructions = literalRows.map { address, bytes, mnemonic, operands in
            InstructionRow(address: address, bytes: bytes, mnemonic: mnemonic,
                           operands: operands, hasBreakpoint: false, comment: nil)
        }
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        snapshot.insertImage(binary: BinaryImage(id: UUID(), name: "typed-slot-invocation", path: "/tmp/typed-slot-invocation",
            kind: "executable", architecture: "arm64", slot: .primary), analysis: analysis)
        snapshot.typeDefinitions = parsed.types
        for prototype in parsed.prototypes {
            if let function = analysis.functions.first(where: { $0.name == prototype.name }) {
                snapshot.importedPrototypes[.primary(function.startAddress)] = prototype.signature
            }
        }
        snapshot.recordHeaderImportEvidence(parsed.types)
        XCTAssertNotNil(snapshot.imageWideIndirectCalls(in: .primary, compute: true))
        let report = try XCTUnwrap(snapshot.slotTypedPrototypeReport(in: .primary, compute: false))
        XCTAssertEqual(report.census["literal_slot_store_candidates"], 1)
        XCTAssertEqual(Set(report.callContracts.keys), Set([UInt64(0x2010)]))
        XCTAssertEqual(report.callContracts[0x2010]?.returnType, "int64_t")
        XCTAssertEqual(report.callProofRows.count, 1)
        let proof = try XCTUnwrap(report.callProofRows.first)
        XCTAssertEqual(proof.functionStart, 0x2000)
        XCTAssertEqual(proof.rootFunctionStart, 0x2000)
        XCTAssertEqual(proof.rootParameterIndex, 0)
        XCTAssertEqual(proof.loadAddress, 0x200c)
        XCTAssertEqual(proof.callAddress, 0x2010)
        let input = snapshot.pseudocodeRenderInput(selectedAddress: 0x2000, in: .primary)
        XCTAssertNil(input.signatureOverrides[0x1000])
        XCTAssertEqual(input.slotCallContracts[0x2010]?.returnType, "int64_t")
        let function = PseudocodePrinter().buildFunction(functionName: input.functionName,
            startAddress: input.startAddress, signatureOverrides: input.signatureOverrides,
            authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
            slotCallContracts: input.slotCallContracts, types: input.types, instructions: input.instructions)
        let calls = function.instructions.filter { $0.source.address == 0x2010 }
        XCTAssertEqual(calls.count, 1)
        let call = try XCTUnwrap(calls.first)
        guard case let .call(frame, result) = call.operation else { return XCTFail("Missing same-slot indirect invocation") }
        XCTAssertNotNil(frame.controlInputs.indirectTarget)
        XCTAssertNil(frame.knownSignature)
        XCTAssertEqual(frame.typedIndirectSignature?.returnType, "int64_t")
        XCTAssertEqual(frame.typedIndirectSignature?.source, "header-derived-slot")
        XCTAssertNotNil(result)
        let targetInput = snapshot.pseudocodeRenderInput(selectedAddress: 0x1000, in: .primary)
        XCTAssertNil(targetInput.signatureOverrides[0x1000])
        let targetText = PseudocodeView.document(for: targetInput, options: .default).text
        XCTAssertTrue(targetText.contains("return unresolved_return_contract;"), targetText)
    }

    func testOwnVoidAuthorityRemainsVoidDespiteProducerRefusal() {
        let function = MacIRBuilder().buildFunction(name: "void_target", startAddress: 0x1000,
            authoritativeReturnLocation: .void,
            instructions: rows([("mov", "w0, #7"), ("ret", "")]))
        XCTAssertNil(function.returnValue)
        XCTAssertTrue(function.instructions.contains { $0.operation == .returnValue(nil) })
        let text = PseudocodePrinter().print(function: function).text
        XCTAssertTrue(text.contains("return;"), text)
        XCTAssertFalse(text.contains("unresolved_return_contract"), text)
    }
}

extension NoEvidenceReturnMarkerTests {
    // Byte-explicit rows, not decoder output. Width facts below are
    // machine facts only. Neither this fixture metadata nor source scoring is
    // passed to the builder as return authority.
    private typealias WidthAuthorityRow = (String, String, String)
    private func withWidthAuthorityModes(_ body: () -> Void) {
        for enabled in [false, true] {
            MacIRConfiguration.$ssaOverride.withValue(enabled) {
                MacIRConfiguration.$explicitCFGOverride.withValue(enabled) {
                    MacIRConfiguration.$returnContractOverride.withValue(enabled) { body() }
                }
            }
        }
    }
    private func buildWidthAuthorityFixture(_ fixture: [WidthAuthorityRow], width: Int? = nil,
                              declaredVoid: Bool = false) -> MacIRFunction {
        let instructions = fixture.enumerated().map { index, row in
            InstructionRow(address: 0x1000 + UInt64(index * 4), bytes: row.0,
                mnemonic: row.1, operands: row.2, hasBreakpoint: false, comment: nil)
        }
        let location: DarwinARM64RichReturnLocation? = declaredVoid ? .void
            : width.map { .single(.gpr(index: 0, carrierWidth: $0)) }
        return MacIRBuilder().buildFunction(name: "width_authority_fixture", startAddress: 0x1000,
            authoritativeReturnLocation: location,
            authoritativeReturnType: declaredVoid ? "void" : width.map { "uint\($0)_t" },
            instructions: instructions)
    }
    private func assertWidthAuthorityRefused(_ fixture: [WidthAuthorityRow], count: Int = 1,
                                file: StaticString = #filePath, line: UInt = #line) {
        withWidthAuthorityModes { assertReturns(buildWidthAuthorityFixture(fixture), admitted: false, count: count,
                                    file: file, line: line) }
    }

    private func assertWidthAuthorityConstant(_ function: MacIRFunction, expected: Int64,
                                              file: StaticString = #filePath, line: UInt = #line) {
        guard let instruction = function.instructions.first(where: { $0.source.address == 0x1000 }),
              case let .assign(_, source) = instruction.operation else {
            return XCTFail("materialized constant must remain an explicit assignment", file: file, line: line)
        }
        XCTAssertEqual(source, .immediate(expected), file: file, line: line)
    }

    func testProducerWidth32IsNotAuthorityButBoundUInt32Works() {
        // Full W0 write: x0 = 0x0000000000000010; source signedness is unknown.
        let fixture: [WidthAuthorityRow] = [("00 02 80 52", "mov", "w0, #16"), ("c0 03 5f d6", "ret", "")]
        withWidthAuthorityModes {
            assertReturns(buildWidthAuthorityFixture(fixture), admitted: false)
            let bound = buildWidthAuthorityFixture(fixture, width: 32)
            assertWidthAuthorityConstant(bound, expected: 16)
            assertReturns(bound, admitted: true)
            XCTAssertEqual(ReturnContractTable.headerContract(type: "uint32_t").kind,
                           .value(.gpr(width: 32, type: "uint32_t")))
        }
    }
    func testProducerWidth64IsNotAuthorityButBoundUInt64Works() {
        // Full X0 write: x0 = 0x0000000100000000, not its low-word zero.
        let fixture: [WidthAuthorityRow] = [("20 00 c0 d2", "movz", "x0, #1, lsl #32"), ("c0 03 5f d6", "ret", "")]
        withWidthAuthorityModes {
            assertReturns(buildWidthAuthorityFixture(fixture), admitted: false)
            let bound = buildWidthAuthorityFixture(fixture, width: 64)
            assertWidthAuthorityConstant(bound, expected: 0x1_0000_0000)
            assertReturns(bound, admitted: true)
            XCTAssertEqual(ReturnContractTable.headerContract(type: "uint64_t").kind,
                           .value(.gpr(width: 64, type: "uint64_t")))
        }
    }
    func testProducerWidthOneDisagreeingReturnRefusesWholeFunction() {
        // One RET sees w0=7; the other x0=1<<32. No 32-bit agreement.
        assertWidthAuthorityRefused([("61 00 00 b4", "cbz", "x1, 0x100c"),
            ("e0 00 80 52", "mov", "w0, #7"), ("c0 03 5f d6", "ret", ""),
            ("20 00 c0 d2", "movz", "x0, #1, lsl #32"), ("c0 03 5f d6", "ret", "")], count: 2)
    }
    func testProducerWidthMixedWidthPathsToSharedReturnStayRefused() {
        // A single RET does not imply one producer width. High bits differ.
        assertWidthAuthorityRefused([("61 00 00 b4", "cbz", "x1, 0x100c"),
            ("e0 00 80 52", "mov", "w0, #7"), ("02 00 00 14", "b", "0x1010"),
            ("20 00 c0 d2", "movz", "x0, #1, lsl #32"), ("c0 03 5f d6", "ret", "")])
    }
    func testProducerWidthPartialMOVKDoesNotInitializeX0() {
        // Only bits 16...31 are replaced; the other 48 bits remain incoming.
        assertWidthAuthorityRefused([("20 00 a0 f2", "movk", "x0, #1, lsl #16"), ("c0 03 5f d6", "ret", "")])
    }
    func testProducerWidthUnwrittenEarlyReturnRefusesWholeFunction() {
        // One RET has no local x0 write; a different RET writes the full W0.
        assertWidthAuthorityRefused([("61 00 00 b4", "cbz", "x1, 0x100c"),
            ("e0 00 80 52", "mov", "w0, #7"), ("c0 03 5f d6", "ret", ""),
            ("c0 03 5f d6", "ret", "")], count: 2)
    }
    func testProducerWidthUnknownCallCarrierIsNotAProvenFullWrite() {
        assertWidthAuthorityRefused([("fd 7b bf a9", "stp", "x29, x30, [sp, #-16]!"),
            ("00 01 3f d6", "blr", "x8"), ("fd 7b c1 a8", "ldp", "x29, x30, [sp], #16"),
            ("c0 03 5f d6", "ret", "")])
    }
    func testProducerWidthLowWordZeroTestDoesNotProveCallHighBits() {
        // Taken edge w0=0 permits x0=0x100000000. No write occurs on that edge.
        assertWidthAuthorityRefused([("fd 7b bf a9", "stp", "x29, x30, [sp, #-16]!"),
            ("00 01 3f d6", "blr", "x8"), ("40 00 00 34", "cbz", "w0, 0x1010"),
            ("e0 00 80 52", "mov", "w0, #7"), ("fd 7b c1 a8", "ldp", "x29, x30, [sp], #16"),
            ("c0 03 5f d6", "ret", "")])
    }
    func testProducerWidthStoreWritebackDoesNotInventValueContract() {
        // quantize_float mechanism: full 64-bit x0+16 used as a store base.
        let fixture: [WidthAuthorityRow] = [("02 04 81 3c", "str", "q2, [x0], #16"), ("c0 03 5f d6", "ret", "")]
        withWidthAuthorityModes {
            assertReturns(buildWidthAuthorityFixture(fixture), admitted: false)
            let bound = buildWidthAuthorityFixture(fixture, declaredVoid: true)
            XCTAssertTrue(bound.instructions.contains { $0.operation == .returnValue(nil) })
        }
    }
    func testProducerWidthDeadArithmeticDoesNotInventValueContract() {
        // update_box mechanism: full W0 write of (w2 << 3) is compatible with void.
        let fixture: [WidthAuthorityRow] = [("40 70 1d 53", "lsl", "w0, w2, #3"), ("c0 03 5f d6", "ret", "")]
        withWidthAuthorityModes {
            assertReturns(buildWidthAuthorityFixture(fixture), admitted: false)
            let bound = buildWidthAuthorityFixture(fixture, declaredVoid: true)
            XCTAssertTrue(bound.instructions.contains { $0.operation == .returnValue(nil) })
        }
    }
    func testProducerWidthConstantAfterVoidCallDoesNotProvePurpose() {
        // A void callee can leave w0=7; an explicit local copy of that constant
        // after the call is also not this function's declaration.
        assertWidthAuthorityRefused([("fd 7b bf a9", "stp", "x29, x30, [sp, #-16]!"),
            ("00 01 3f d6", "blr", "x8"), ("e0 00 80 52", "mov", "w0, #7"),
            ("fd 7b c1 a8", "ldp", "x29, x30, [sp], #16"), ("c0 03 5f d6", "ret", "")])
    }
    func testProducerWidthConstantBeforeReturnWithoutAnyUseIsStillNotAuthority() {
        // x0=9, no intervening use; that syntactic shape supplies no purpose.
        assertWidthAuthorityRefused([("20 01 80 d2", "mov", "x0, #9"), ("c0 03 5f d6", "ret", "")])
    }
}
