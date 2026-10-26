import Foundation
import XCTest
@testable import MacScope

final class ClosedWorldDiscardExportTests: XCTestCase {
    private enum Scenario { case discardedInteger, declaredVoid, consumedValue }
    private let caller: UInt64 = 0x1000

    private struct Fixture {
        let snapshot: WorkspaceSnapshot
        let analysis: ImageAnalysis
        let leaf: UInt64
        let signatures: [UInt64: FunctionSignatureOverride]
    }

    private func fixture(_ scenario: Scenario) -> Fixture {
        let consumes = scenario == .consumedValue
        let leaf: UInt64 = consumes ? 0x1018 : 0x1014
        // Both BL immediates are relative to 0x1004. Every returning caller
        // writes X0=0 after the call; only the positive control first reads X0.
        let callerWords: [UInt32] = consumes
            ? [0xa9bf7bfd, 0x94000005, 0xf100001f, 0xd2800000, 0xa8c17bfd, 0xd65f03c0]
            : [0xa9bf7bfd, 0x94000004, 0xd2800000, 0xa8c17bfd, 0xd65f03c0]
        // Pure constants zero and one satisfy the existing return-producer
        // rule. Seven deliberately does not and is covered by the older test.
        let leafWords: [UInt32] = consumes ? [0xd2800000, 0xd65f03c0]
                                         : [0x52800020, 0xd65f03c0]
        let bodies: [UInt64: (String, [UInt32])] = [
            caller: ("caller", callerWords), leaf: ("leaf", leafWords)
        ]
        let bytes = S1RecoveryMachOFixture.make(bodies: bodies, exported: [])
        // The fixture helper places __text at file offset/address 0x1000.
        // The production closed-world audit independently validates the image,
        // all decoded rows, ownership and complete inventories before export.
        let raw = bytes.subdata(in: Int(caller)..<Int(leaf + 8))
        let decoded = ARM64Decoder().decode(raw, baseAddress: caller,
            maxInstructionCount: callerWords.count + leafWords.count)
        XCTAssertEqual(decoded.count, callerWords.count + leafWords.count)
        XCTAssertEqual(decoded.first { $0.address == caller + 4 }?.branchTarget, leaf)
        XCTAssertEqual(decoded.first { $0.address == leaf }?.byteText,
            consumes ? "00 00 80 d2" : "20 00 80 52")
        XCTAssertEqual(decoded.last?.address, leaf + 4)
        XCTAssertEqual(decoded.last?.byteText, "c0 03 5f d6")

        var analysis = ImageAnalysis()
        analysis.imageBytes = bytes
        analysis.instructions = decoded.map(InstructionRow.init(decoded:))
        analysis.functions = bodies.sorted { $0.key < $1.key }.map { address, body in
            FunctionSummary(id: UUID(), name: body.0, startAddress: address,
                endAddress: address + UInt64(body.1.count * 4), confidence: 1)
        }
        var snapshot = WorkspaceSnapshot(binaries: [], analysisBySlot: [:])
        snapshot.insertImage(binary: BinaryImage(id: UUID(), name: "authority", path: "/fixture/discard-export",
            kind: "executable", architecture: "arm64", slot: .primary), analysis: analysis)
        var signatures: [UInt64: FunctionSignatureOverride] = [
            caller: .init(returnType: "int32_t", args: [])
        ]
        if scenario == .declaredVoid { signatures[leaf] = .init(returnType: "void", args: []) }
        for (address, signature) in signatures {
            snapshot.addressOverrides[.primary(address)] = AddressOverride(signature: signature)
        }
        return Fixture(snapshot: snapshot, analysis: analysis, leaf: leaf, signatures: signatures)
    }

    private func exercise(_ scenario: Scenario, returnContracts: Bool) throws {
        for requestedSSA in [false, true] {
            try MacIRConfiguration.$ssaOverride.withValue(requestedSSA) {
                try MacIRConfiguration.$explicitCFGOverride.withValue(requestedSSA) {
                    try MacIRConfiguration.$returnContractOverride.withValue(returnContracts) {
                        XCTAssertEqual(MacIRConfiguration.ssaEnabled, requestedSSA)
                        XCTAssertEqual(MacIRConfiguration.returnContractEnabled, returnContracts)
                        let value = fixture(scenario)
                        let snapshot = value.snapshot
                        var completed: [MacIRFunction] = []
                        XCTAssertNotNil(snapshot.imageWideIndirectCalls(in: .primary, compute: true,
                            inspectFunctions: { completed = $0 }))
                        XCTAssertEqual(completed.map(\.startAddress).sorted(), [caller, value.leaf])
                        XCTAssertTrue(completed.allSatisfy { $0.ssaEnabled == requestedSSA })
                        XCTAssertNotNil(snapshot.imageWideIndirectCalls(in: .primary, compute: false))
                        XCTAssertNotNil(snapshot.slotTypedPrototypeReport(in: .primary, compute: false))

                        // Reuse the exact completed lift, not another builder.
                        // Source operands are restored just as the snapshot's
                        // production caller/table copies restore numeric identity.
                        let originals = Dictionary(grouping: value.analysis.instructions, by: \.address)
                        XCTAssertTrue(originals.values.allSatisfy { $0.count == 1 })
                        let rawFunctions = completed.map { function in
                            var copy = function
                            copy.instructions = function.instructions.map { instruction in
                                var raw = instruction
                                raw.source.operands = originals[instruction.source.address]?.first?.operands ?? ""
                                return raw
                            }
                            return copy
                        }
                        let witness = MacIRCallerReturnEvidence.collectClosedWorld(analysis: value.analysis,
                            functions: rawFunctions, effectiveSignatures: value.signatures)
                        let conditions = try XCTUnwrap(witness.evidence[value.leaf])
                        XCTAssertEqual(conditions.map(\.condition), [1, 2, 3, 4, 5, 6])
                        XCTAssertTrue(conditions.filter { $0.condition < 6 }.allSatisfy(\.satisfied),
                            "The leaf must reach complete private-image evidence, not an inventory refusal")
                        let callerCondition = try XCTUnwrap(conditions.first { $0.condition == 6 })
                        if scenario == .discardedInteger {
                            XCTAssertTrue(callerCondition.satisfied)
                            XCTAssertEqual(callerCondition.detail,
                                "1 of 1 direct callers prove x0 discarded; no unresolved tail caller")
                        } else {
                            XCTAssertFalse(callerCondition.satisfied)
                            XCTAssertEqual(callerCondition.detail,
                                "0 of 1 direct callers prove x0 discarded; no unresolved tail caller")
                        }
                        let callerFunction = try XCTUnwrap(completed.first { $0.startAddress == caller })
                        let call = try XCTUnwrap(callerFunction.instructions.first { $0.source.address == caller + 4 })
                        guard case let .call(frame, result) = call.operation else {
                            XCTFail("The complete snapshot must contain the actual direct leaf call")
                            return
                        }
                        if scenario == .declaredVoid {
                            XCTAssertEqual(frame.knownSignature?.returnType, "void")
                            XCTAssertNil(result, "Independent callee declaration, not a discard certificate")
                        } else {
                            XCTAssertNil(frame.knownSignature)
                            XCTAssertNotNil(result, "An untyped result-bearing call must reach the discard/use proof")
                        }

                        let selected = try XCTUnwrap(snapshot.pseudocodeTarget(selectedAddress: value.leaf, in: .primary))
                        XCTAssertEqual(selected.function.startAddress, value.leaf)
                        XCTAssertEqual(selected.function.name, "leaf")
                        let input = snapshot.pseudocodeRenderInput(selectedAddress: value.leaf, in: .primary)
                        XCTAssertEqual(input.startAddress, value.leaf)
                        XCTAssertEqual(input.functionName, "leaf")
                        XCTAssertEqual(input.instructions.map(\.address), [value.leaf, value.leaf + 4])
                        XCTAssertNil(input.callerReturnType,
                            "Caller discard or an untyped table observation must not bind own void")
                        if scenario == .declaredVoid {
                            XCTAssertEqual(input.signatureOverrides[value.leaf]?.returnType, "void")
                        } else {
                            XCTAssertNil(input.signatureOverrides[value.leaf],
                                "The integer result must be justified by machine bytes, not a leaf declaration")
                        }
                        if scenario == .consumedValue {
                            XCTAssertEqual(input.callerReturnWidth, .x0)
                        } else {
                            XCTAssertNil(input.callerReturnWidth)
                        }
                        if returnContracts {
                            let table = try XCTUnwrap(snapshot.returnContractTable(in: .primary, compute: false))
                            XCTAssertEqual(table.entries.count, 2)
                            XCTAssertFalse(table.report.capExceeded)
                            if scenario == .discardedInteger {
                                XCTAssertEqual(table.entries[value.leaf]?.kind, .unresolved(.producerOnly))
                                XCTAssertNil(table.entries[value.leaf]?.tier)
                            } else if scenario == .declaredVoid {
                                XCTAssertEqual(table.entries[value.leaf]?.kind, .void)
                                XCTAssertEqual(table.entries[value.leaf]?.tier, .header)
                            } else {
                                XCTAssertEqual(table.entries[value.leaf]?.kind, .value(.gpr(width: 64, type: nil)))
                                XCTAssertEqual(table.entries[value.leaf]?.tier, .derived)
                            }
                        } else {
                            XCTAssertNil(snapshot.returnContractTable(in: .primary, compute: false))
                        }

                        let text = DocumentExportService().pseudocodeText(for: input, options: .default)
                        let lines = text.components(separatedBy: "\n")
                        if scenario == .declaredVoid {
                            XCTAssertEqual(lines.first, "void leaf(void) {")
                            XCTAssertTrue(lines.contains("    return; // return"), text)
                            XCTAssertFalse(lines.contains("    return w0_1; // return") || lines.contains("    return x0_1; // return"), text)
                        } else {
                            XCTAssertEqual(lines.first, "int64_t leaf(void) {")
                            XCTAssertTrue(lines.contains(scenario == .discardedInteger
                                ? "    w0_1 = 0x1;" : "    x0_1 = 0x0;"), text)
                            XCTAssertTrue(lines.contains(scenario == .discardedInteger ? "    return w0_1; // return" : "    return x0_1; // return"), text)
                            XCTAssertFalse(lines.contains("    return; // return"), text)
                            XCTAssertFalse(text.contains("void leaf("), text)
                        }
                        XCTAssertFalse(text.contains("unresolved_return_contract"), text)
                    }
                }
            }
        }
    }

    func testDiscardedIntegerLeafExportWithContractsOff() throws {
        try exercise(.discardedInteger, returnContracts: false)
    }

    func testDiscardedIntegerLeafExportWithContractsOn() throws {
        try exercise(.discardedInteger, returnContracts: true)
    }

    func testDeclaredVoidLeafExportWithContractsOff() throws {
        try exercise(.declaredVoid, returnContracts: false)
    }

    func testDeclaredVoidLeafExportWithContractsOn() throws {
        try exercise(.declaredVoid, returnContracts: true)
    }

    func testConsumedMachineValueExportWithContractsOff() throws {
        try exercise(.consumedValue, returnContracts: false)
    }

    func testConsumedMachineValueExportWithContractsOn() throws {
        try exercise(.consumedValue, returnContracts: true)
    }
}
