import Foundation
import XCTest
@testable import MacScope

final class DirectVoidCallResultTests: XCTestCase {
    private typealias Operation = (String, String)
    private let void = FunctionSignatureOverride(returnType: "void")

    private func rows(_ start: UInt64, _ operations: [Operation]) -> [InstructionRow] {
        operations.enumerated().map { index, operation in
            InstructionRow(address: start + UInt64(index * 4), bytes: "", mnemonic: operation.0,
                           operands: operation.1, hasBreakpoint: false, comment: nil)
        }
    }

    private func callRows(_ target: String = "callback") -> [InstructionRow] {
        rows(0x3000, [("mov", "x0, #7"), ("mov", "x1, #9"), ("bl", target),
                      ("mov", "x0, #3"), ("bl", "other"), ("ret", "")])
    }

    private func render(_ target: String = "callback",
                        contracts: [String: FunctionSignatureOverride] = [:],
                        authored: [String: FunctionSignatureOverride] = [:]) -> String {
        PseudocodePrinter().print(functionName: "caller", startAddress: 0x3000,
            authoredCallSignaturesByTarget: authored, directCallVoidResultTargets: contracts,
            instructions: callRows(target)).text
    }

    func testReturnOnlyVoidDropsOnlyAssignmentAndPreservesArgumentsAndLaterNames() throws {
        let before = render()
        let after = render(contracts: ["callback": void])
        let pattern = #"\b[xw]0_[0-9]+ = (?=callback\()"#
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(before.startIndex..., in: before)
        XCTAssertEqual(expression.numberOfMatches(in: before, range: range), 1, before)
        XCTAssertEqual(after, expression.stringByReplacingMatches(in: before, range: range, withTemplate: ""))
        let baseline = PseudocodePrinter().buildFunction(functionName: "caller", startAddress: 0x3000,
            instructions: callRows())
        let changed = PseudocodePrinter().buildFunction(functionName: "caller", startAddress: 0x3000,
            directCallVoidResultTargets: ["callback": void], instructions: callRows())
        let old = try XCTUnwrap(baseline.instructions.first { $0.source.address == 0x3008 })
        let new = try XCTUnwrap(changed.instructions.first { $0.source.address == 0x3008 })
        guard case let .call(oldFrame, oldResult) = old.operation,
              case let .call(newFrame, newResult) = new.operation else {
            return XCTFail("Expected direct call operations")
        }
        XCTAssertEqual(oldFrame, newFrame)
        XCTAssertNotNil(oldResult)
        XCTAssertNil(newResult)
        if changed.ssaEnabled {
            let info = try XCTUnwrap(changed.ssaInfo)
            let row = try XCTUnwrap(info.sourceAddresses.firstIndex(of: 0x3008))
            let definition = try XCTUnwrap(info.plan.rowWriteBindings[row][0])
            XCTAssertEqual(info.plan.definitions[definition].origin, .callClobber(0x3008))
            XCTAssertEqual(info.values[definition], .unknown("unavailable_x0"),
                "Reserving a display name must not manufacture a call result or return authority")
        }
    }

    func testAuthoredParameterListKeepsResult() {
        let authored = ["callback": FunctionSignatureOverride(returnType: "long", args: [])]
        XCTAssertEqual(render(contracts: ["callback": void], authored: authored), render(authored: authored))
        XCTAssertTrue(render(authored: authored).contains("= callback("))
    }

    func testStaticKnownCallKeepsResult() {
        XCTAssertEqual(render("_malloc", contracts: ["_malloc": void]), render("_malloc"))
        XCTAssertTrue(render("_malloc").contains("= _malloc("))
    }

    func testUnknownAndNonReturnOnlyContractsKeepResult() {
        for contract in [FunctionSignatureOverride(returnType: "long"),
                         FunctionSignatureOverride(returnType: "void", args: []),
                         FunctionSignatureOverride(returnType: "void", variadicState: .fixed)] {
            XCTAssertEqual(render(contracts: ["callback": contract]), render())
        }
        XCTAssertEqual(render(contracts: ["unrelated": void]), render())
        XCTAssertTrue(render().contains("= callback("))
    }

    private func snapshot(duplicateName: Bool = false, usesResult: Bool = false) -> WorkspaceSnapshot {
        let parsed = CTypeHeaderParser.parse("""
            struct Slots { void (*run)(void); };
            void install(struct Slots *slots);
            """)
        var analysis = ImageAnalysis()
        var calls: [Operation] = [("mov", "x0, #7"), ("mov", "x1, #9"), ("bl", "0x1000")]
        if usesResult { calls.append(("str", "x0, [x19]")) }
        calls += [("mov", "x0, #0"), ("ret", "")]
        var bodies: [(UInt64, String, [Operation])] = [
            (0x1000, "callback", [("ldr", "x8, [x0]"), ("str", "x8, [x1]"), ("ret", "")]),
            (0x2000, "install", [("mov", "x8, #0x1000"), ("str", "x8, [x0]"), ("ret", "")]),
            (0x3000, "caller", calls)
        ]
        if duplicateName { bodies.append((0x4000, "callback", [("ret", "")])) }
        for (start, name, operations) in bodies {
            analysis.functions.append(FunctionSummary(id: UUID(), name: name, startAddress: start,
                endAddress: start + UInt64(operations.count * 4), confidence: 1))
            analysis.instructions += rows(start, operations)
        }
        var value = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        value.insertImage(binary: BinaryImage(id: UUID(), name: "direct-void", path: "/tmp/direct-void",
            kind: "executable", architecture: "arm64", slot: .primary), analysis: analysis)
        value.typeDefinitions = parsed.types
        value.importedPrototypes[.primary(0x2000)] = parsed.prototypes.first?.signature
        return value
    }

    func testWarmSlotAuthorityReachesExportWithoutChangingAuthoredPrototypes() throws {
        let value = snapshot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(value.authoredCallSignaturesByTarget(in: .primary))
        XCTAssertTrue(value.directCallVoidResultTargets(in: .primary).isEmpty)
        XCTAssertNotNil(value.imageWideIndirectCalls(in: .primary, compute: true))
        XCTAssertEqual(try encoder.encode(value.authoredCallSignaturesByTarget(in: .primary)), before)
        let contracts = value.directCallVoidResultTargets(in: .primary)
        XCTAssertEqual(contracts["callback"], void)
        XCTAssertEqual(contracts["0x1000"], void)
        let input = value.pseudocodeRenderInput(selectedAddress: 0x3000, in: .primary)
        XCTAssertEqual(input.directCallVoidResultTargets, contracts)
        let output = DocumentExportService().pseudocodeText(for: input, options: .default)
        XCTAssertTrue(output.contains("callback("), output)
        XCTAssertFalse(output.contains("= callback("), output)
        let exactID = try XCTUnwrap(value.functions.first { $0.startAddress == 0x3000 }?.id)
        let exact = try XCTUnwrap(value.pseudocodeRenderInput(exactFunctionID: exactID, in: .primary))
        let function = PseudocodePrinter().buildFunction(functionName: exact.functionName,
            startAddress: exact.startAddress, directCallVoidResultTargets: exact.directCallVoidResultTargets,
            instructions: exact.instructions)
        let call = try XCTUnwrap(function.instructions.first { $0.source.address == 0x3008 })
        guard case let .call(_, result) = call.operation else { return XCTFail("Expected a direct call") }
        XCTAssertNil(result)
    }

    func testPrototypeMutationInvalidatesMapWithoutInvalidatingUnchangedCopy() {
        let original = snapshot()
        XCTAssertNotNil(original.imageWideIndirectCalls(in: .primary, compute: true))
        var changed = original
        changed.importedPrototypes.removeAll()
        XCTAssertTrue(changed.authoredCallSignaturesByTarget(in: .primary).isEmpty)
        XCTAssertTrue(changed.directCallVoidResultTargets(in: .primary).isEmpty)
        XCTAssertEqual(original.directCallVoidResultTargets(in: .primary)["callback"], void)
    }

    func testAmbiguousNameAndPositiveResultUseRefuseAuthority() throws {
        for value in [snapshot(duplicateName: true), snapshot(usesResult: true)] {
            XCTAssertNotNil(value.imageWideIndirectCalls(in: .primary, compute: true))
            XCTAssertNil(value.directCallVoidResultTargets(in: .primary)["callback"])
            XCTAssertNil(value.directCallVoidResultTargets(in: .primary)["0x1000"])
            var input = value.pseudocodeRenderInput(selectedAddress: 0x3000, in: .primary)
            XCTAssertTrue(input.ownDirectCallAddresses.contains(0x3008))
            // Isolate refused void authority from the independent proof that an
            // own-image call's result is overwritten before any physical use.
            input.ownDirectCallAddresses = []
            XCTAssertTrue(input.ownDirectCallAddresses.isEmpty)
            let output = DocumentExportService().pseudocodeText(for: input, options: .default)
            let function = PseudocodePrinter().buildFunction(functionName: input.functionName,
                startAddress: input.startAddress,
                authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
                directCallVoidResultTargets: input.directCallVoidResultTargets,
                instructions: input.instructions)
            let call = try XCTUnwrap(function.instructions.first { $0.source.address == 0x3008 })
            guard case let .call(_, result) = call.operation else { return XCTFail("Expected direct call") }
            XCTAssertNotNil(result, "Refused void authority must retain the underlying IR result")
            XCTAssertTrue(output.contains("callback("), output)
            // With own-image lifetime authority excluded, both refusal cases must
            // retain the assignment in either lifter, even before an immediate MOV.
            XCTAssertTrue(output.contains("= callback("), output)
        }
    }

    func testIndirectMapCollisionCannotRemoveResultOrRenameLaterDefinitions() throws {
        let instructions = rows(0x3000, [("mov", "x0, #7"), ("blr", "x8"),
            ("mov", "x0, #3"), ("ret", "")])
        let before = PseudocodePrinter().buildFunction(functionName: "caller", startAddress: 0x3000,
            instructions: instructions)
        let after = PseudocodePrinter().buildFunction(functionName: "caller", startAddress: 0x3000,
            directCallVoidResultTargets: ["x8": void], instructions: instructions)
        XCTAssertEqual(after.instructions, before.instructions)
        XCTAssertEqual(after.ssaInfo, before.ssaInfo)
        let call = try XCTUnwrap(after.instructions.first { $0.source.address == 0x3004 })
        guard case let .call(_, result) = call.operation else { return XCTFail("Expected indirect call") }
        XCTAssertNotNil(result)
    }

    func testMalformedDirectCallCannotReserveAnOmittedResultName() throws {
        let instructions = rows(0x3000, [("mov", "x0, #7"), ("bl", "callback, x8"),
            ("mov", "x0, #3"), ("ret", "")])
        let before = PseudocodePrinter().buildFunction(functionName: "caller", startAddress: 0x3000,
            instructions: instructions)
        let after = PseudocodePrinter().buildFunction(functionName: "caller", startAddress: 0x3000,
            directCallVoidResultTargets: ["callback": void], instructions: instructions)
        XCTAssertEqual(after.instructions, before.instructions)
        XCTAssertEqual(after.ssaInfo, before.ssaInfo)
        let malformed = try XCTUnwrap(after.instructions.first { $0.source.address == 0x3004 })
        if case .call = malformed.operation { XCTFail("Malformed BL must not acquire call authority") }
    }

    func testImportedReturnOnlyContractPreventsPublication() {
        var value = snapshot()
        value.importedPrototypes[.primary(0x1000)] = void
        XCTAssertNotNil(value.imageWideIndirectCalls(in: .primary, compute: true))
        XCTAssertNil(value.directCallVoidResultTargets(in: .primary)["callback"])
        XCTAssertNil(value.directCallVoidResultTargets(in: .primary)["0x1000"])
    }

    private func literalSlotVoidSnapshot() -> WorkspaceSnapshot {
        let parsed = CTypeHeaderParser.parse("""
            struct Slots { void (*run)(void); };
            void install(struct Slots *slots);
            """)
        let bodies: [(UInt64, String, [(String, String, String)])] = [
            (0x1000, "callback", [("08 00 40 f9", "ldr", "x8, [x0]"),
                                  ("28 00 00 f9", "str", "x8, [x1]"),
                                  ("c0 03 5f d6", "ret", "")]),
            (0x2000, "install", [("08 00 82 d2", "mov", "x8, #0x1000"),
                                 ("08 00 00 f9", "str", "x8, [x0]"),
                                 ("c0 03 5f d6", "ret", "")]),
            (0x3000, "caller", [("e0 00 80 d2", "mov", "x0, #7"),
                                ("21 01 80 d2", "mov", "x1, #9"),
                                ("fe f7 ff 97", "bl", "0x1000"),
                                ("00 00 80 d2", "mov", "x0, #0"),
                                ("c0 03 5f d6", "ret", "")])
        ]
        var analysis = ImageAnalysis()
        for (start, name, instructions) in bodies {
            analysis.functions.append(FunctionSummary(id: UUID(), name: name, startAddress: start,
                endAddress: start + UInt64(instructions.count * 4), confidence: 1))
            analysis.instructions += instructions.enumerated().map { offset, instruction in
                InstructionRow(address: start + UInt64(offset * 4), bytes: instruction.0,
                    mnemonic: instruction.1, operands: instruction.2, hasBreakpoint: false, comment: nil)
            }
        }
        var value = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        value.insertImage(binary: BinaryImage(id: UUID(), name: "caller-only-void", path: "/tmp/caller-only-void",
            kind: "executable", architecture: "arm64", slot: .primary), analysis: analysis)
        value.typeDefinitions = parsed.types
        value.importedPrototypes[.primary(0x2000)] = parsed.prototypes.first?.signature
        return value
    }

    func testCallerSideSlotVoidMapDoesNotDeclareCalleeOwnReturn() throws {
        for ssa in [false, true] {
            for returnContracts in [false, true] {
                try MacIRConfiguration.$ssaOverride.withValue(ssa) {
                    try MacIRConfiguration.$explicitCFGOverride.withValue(ssa) {
                        try MacIRConfiguration.$returnContractOverride.withValue(returnContracts) {
                            let value = literalSlotVoidSnapshot()
                            let before = value.pseudocodeRenderInput(selectedAddress: 0x1000, in: .primary)
                            let beforeText = DocumentExportService().pseudocodeText(for: before, options: .default)
                            XCTAssertTrue(beforeText.contains("int64_t callback("), beforeText)
                            XCTAssertTrue(beforeText.contains("return unresolved_return_contract;"), beforeText)
                            XCTAssertNotNil(value.imageWideIndirectCalls(in: .primary, compute: true))
                            let contracts = value.directCallVoidResultTargets(in: .primary)
                            XCTAssertEqual(contracts["callback"], void)
                            XCTAssertEqual(contracts["0x1000"], void)
                            let after = value.pseudocodeRenderInput(selectedAddress: 0x1000, in: .primary)
                            XCTAssertNil(after.signatureOverrides[0x1000])
                            XCTAssertNil(after.callerReturnType)
                            XCTAssertNil(after.callerReturnWidth)
                            XCTAssertNil(value.functionSignatureOverrides(in: .primary)[0x1000])
                            XCTAssertNil(value.authoredCallSignaturesByTarget(in: .primary)["callback"])
                            if returnContracts {
                                let table = try XCTUnwrap(value.returnContractTable(in: .primary, compute: false))
                                let own = try XCTUnwrap(table.contract(forFunctionAt: 0x1000))
                                switch own.kind {
                                case .unresolved: break
                                default: XCTFail("Caller-only slot permission must not establish an own contract")
                                }
                            }
                            let afterText = DocumentExportService().pseudocodeText(for: after, options: .default)
                            XCTAssertTrue(afterText.contains("int64_t callback("), afterText)
                            XCTAssertTrue(afterText.contains("return unresolved_return_contract;"), afterText)
                            XCTAssertEqual(afterText, beforeText)
                        }
                    }
                }
            }
        }
    }
}
