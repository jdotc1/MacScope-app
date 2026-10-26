import Foundation
import XCTest
@testable import MacScope

// Source-authored qualification fixtures; execution requires the authorized local run.
// Literal bytes accompany each admitted row; every rendering case exercises both modes.
final class MachineCallUsageTests: XCTestCase {
    private let context = MacIRMachineUsageContext(snapshotID: UUID(), imageID: UUID(), imageSlotRawValue: 0)
    private typealias Literal = (String, String, String)

    private func rows(_ start: UInt64, _ literals: [Literal]) -> [InstructionRow] {
        literals.enumerated().map { index, value in
            InstructionRow(address: start + UInt64(index * 4), bytes: value.0,
                mnemonic: value.1, operands: value.2, hasBreakpoint: false, comment: nil)
        }
    }
    private func body(_ rows: [InstructionRow]) -> MacIRMachineUsageBody {
        MacIRMachineUsageBody(start: rows[0].address, end: rows.last!.address + 4,
            rows: rows.map { MacIRSourceSpan(address: $0.address, byteText: $0.bytes,
                mnemonic: $0.mnemonic, operands: $0.operands, comment: $0.comment,
                structuredOperands: $0.structuredOperands) })
    }
    private func built(_ rows: [InstructionRow], ssa: Bool,
                       usage: MacIRMachineCallUsage? = nil,
                       expected: MacIRMachineUsageContext? = nil) -> MacIRFunction {
        PseudocodePrinter().buildFunction(functionName: "caller", startAddress: rows[0].address,
            machineCallUsage: usage, machineUsageContext: expected,
            explicitCFGEnabled: true, ssaEnabled: ssa, instructions: rows)
    }
    private func call(_ function: MacIRFunction, at pc: UInt64) throws -> (MacIRCallFrame, MacIRValue?) {
        let instruction = try XCTUnwrap(function.instructions.first { $0.source.address == pc })
        guard case let .call(frame, result) = instruction.operation else {
            XCTFail("Expected exact call instruction"); throw NSError(domain: "fixture", code: 1)
        }
        return (frame, result)
    }
    private func renderedCall(_ function: MacIRFunction, at pc: UInt64) throws -> String {
        let instruction = try XCTUnwrap(function.instructions.first { $0.source.address == pc })
        // Stable user register labels avoid baking mode-specific SSA version IDs
        // into literal pseudocode. The operation and captured values are unchanged.
        let labels = Dictionary(uniqueKeysWithValues: (0..<8).flatMap { index in
            [("x\(index)", "captured_x\(index)"), ("w\(index)", "captured_x\(index)")]
        })
        return PseudocodePrinter().render(operation: instruction.operation,
            names: PseudocodeNameContext(function: function, registerNameOverrides: labels))
    }
    private func sparseCaller(_ write: Literal = ("22 01 80 d2", "mov", "x2, #9")) -> [InstructionRow] {
        rows(0x1000, [("e0 00 80 d2", "mov", "x0, #7"), write,
            ("fe 03 00 94", "bl", "target"), ("c0 03 5f d6", "ret", "")])
    }

    func testTwoWholeCellDefinitionsPromoteSparseInputInBothModes() throws {
        let callee = rows(0x2000, [("48 00 40 f9", "ldr", "x8, [x2]"),
                                  ("c0 03 5f d6", "ret", "")])
        let writes: [Literal] = [("22 01 80 d2", "mov", "x2, #9"),
                                 ("22 01 80 52", "mov", "w2, #9")]
        for write in writes {
            let caller = sparseCaller(write)
            let usage = try XCTUnwrap(MacIRMachineCallUsage.prove(context: context,
                caller: body(caller), callees: [body(callee)]))
            for ssa in [false, true] {
                let before = built(caller, ssa: ssa)
                let after = built(caller, ssa: ssa, usage: usage, expected: context)
                let old = try call(before, at: 0x1008), new = try call(after, at: 0x1008)
                XCTAssertEqual(old.0.unprovenArgumentRegisters, ["x2"])
                XCTAssertTrue(new.0.unprovenArgumentRegisters.isEmpty)
                XCTAssertEqual(old.0.arguments, new.0.arguments)
                XCTAssertEqual(old.1, new.1)
                XCTAssertTrue(try renderedCall(after, at: 0x1008).contains(
                    "target(/* machine inputs */ x0: captured_x0, x2: captured_x2)"))
            }
        }
    }

    func testTwoNoReadBodiesRemoveOnlyMarkerInBothModes() throws {
        let writes: [Literal] = [("00 00 80 d2", "mov", "x0, #0"),
                                 ("00 02 80 52", "mov", "w0, #16")]
        for literal in writes {
            let caller = sparseCaller()
            let callee = rows(0x2000, [literal, ("c0 03 5f d6", "ret", "")])
            let usage = try XCTUnwrap(MacIRMachineCallUsage.prove(context: context,
                caller: body(caller), callees: [body(callee)]))
            for ssa in [false, true] {
                let before = built(caller, ssa: ssa)
                let after = built(caller, ssa: ssa, usage: usage, expected: context)
                XCTAssertEqual(try call(before, at: 0x1008).0.unprovenArgumentRegisters, ["x2"])
                XCTAssertTrue(try call(after, at: 0x1008).0.unprovenArgumentRegisters.isEmpty)
                XCTAssertEqual(try renderedCall(after, at: 0x1008),
                    try renderedCall(before, at: 0x1008).replacingOccurrences(
                        of: " /* unproven args: x2 */", with: ""))
                XCTAssertTrue(try renderedCall(after, at: 0x1008).contains("target(captured_x0)"))
            }
        }
    }

    func testTwoUnresolvedBodiesKeepWholeCallInBothModes() throws {
        let caller = sparseCaller()
        let bodies: [[Literal]] = [
            [("00 04 00 94", "bl", "other"), ("c0 03 5f d6", "ret", "")],
            [("00 04 00 14", "b", "0x3000"), ("c0 03 5f d6", "ret", "")]
        ]
        for literals in bodies {
            let usage = MacIRMachineCallUsage.prove(context: context,
                caller: body(caller), callees: [body(rows(0x2000, literals))])
            XCTAssertNil(usage)
            for ssa in [false, true] {
                let before = built(caller, ssa: ssa), after = built(caller, ssa: ssa,
                    usage: usage, expected: context)
                XCTAssertEqual(before, after)
                XCTAssertTrue(try renderedCall(after, at: 0x1008).contains(
                    "target(captured_x0) /* unproven args: x2 */"))
            }
        }
    }

    func testConditionalX1ReadOnOnePathRequiresCallerDefinitionBothModes() throws {
        let caller = rows(0x1000, [("21 01 80 d2", "mov", "x1, #9"),
            ("ff 03 00 94", "bl", "target"), ("c0 03 5f d6", "ret", "")])
        for branch: Literal in [("40 00 00 b4", "cbz", "x0, 0x2008"),
                                ("40 00 00 b5", "cbnz", "x0, 0x2008")] {
        let callee = rows(0x2000, [branch,
            ("28 00 40 f9", "ldr", "x8, [x1]"), ("c0 03 5f d6", "ret", "")])
        let usage = try XCTUnwrap(MacIRMachineCallUsage.prove(context: context,
            caller: body(caller), callees: [body(callee)]))
        for ssa in [false, true] {
            let before = built(caller, ssa: ssa)
            let after = built(caller, ssa: ssa, usage: usage, expected: context)
            XCTAssertEqual(try call(before, at: 0x1004).0.unprovenArgumentRegisters, ["x1"])
            XCTAssertTrue(try renderedCall(after, at: 0x1004).contains(
                "target(/* machine inputs */ x1: captured_x1)"))
            XCTAssertEqual(try call(before, at: 0x1004).1, try call(after, at: 0x1004).1)
        }
        }
    }

    func testPartialWriteCannotCreateWholeCellProofBothModes() throws {
        let caller = sparseCaller(("22 01 80 f2", "movk", "x2, #9"))
        let callee = rows(0x2000, [("48 00 40 f9", "ldr", "x8, [x2]"),
                                  ("c0 03 5f d6", "ret", "")])
        let usage = try XCTUnwrap(MacIRMachineCallUsage.prove(context: context,
            caller: body(caller), callees: [body(callee)]))
        for ssa in [false, true] {
            let before = built(caller, ssa: ssa)
            let after = built(caller, ssa: ssa, usage: usage, expected: context)
            XCTAssertEqual(before, after)
            XCTAssertTrue(try renderedCall(after, at: 0x1008).contains(
                "target(captured_x0) /* unproven args: x2 */"))
        }
    }

    func testCallerCallClobberThenPartialWriteDoesNotReviveInputBothModes() throws {
        let caller = rows(0x1000, [("22 01 80 d2", "mov", "x2, #9"),
            ("ff 07 00 94", "bl", "other"), ("e0 00 80 d2", "mov", "x0, #7"),
            ("22 01 80 f2", "movk", "x2, #9"),
            ("fc 03 00 94", "bl", "target"), ("c0 03 5f d6", "ret", "")])
        let callee = rows(0x2000, [("48 00 40 f9", "ldr", "x8, [x2]"),
                                  ("c0 03 5f d6", "ret", "")])
        let usage = try XCTUnwrap(MacIRMachineCallUsage.prove(context: context,
            caller: body(caller), callees: [body(callee)]))
        for ssa in [false, true] {
            let before = built(caller, ssa: ssa)
            let after = built(caller, ssa: ssa, usage: usage, expected: context)
            XCTAssertEqual(before, after)
            XCTAssertFalse(try renderedCall(after, at: 0x1010).contains("/* machine inputs */"))
        }
    }

    func testIndependentContextAndOriginalCallerMismatchKeepBothModesUnchanged() throws {
        let caller = sparseCaller()
        let callee = rows(0x2000, [("48 00 40 f9", "ldr", "x8, [x2]"),
                                  ("c0 03 5f d6", "ret", "")])
        let usage = try XCTUnwrap(MacIRMachineCallUsage.prove(context: context,
            caller: body(caller), callees: [body(callee)]))
        let staleContexts = [
            MacIRMachineUsageContext(snapshotID: UUID(), imageID: context.imageID,
                imageSlotRawValue: context.imageSlotRawValue),
            MacIRMachineUsageContext(snapshotID: context.snapshotID, imageID: UUID(),
                imageSlotRawValue: context.imageSlotRawValue),
            MacIRMachineUsageContext(snapshotID: context.snapshotID, imageID: context.imageID,
                imageSlotRawValue: 1)
        ]
        var changed = caller
        changed[1].bytes = "42 01 80 d2"
        changed[1].operands = "x2, #10"
        for ssa in [false, true] {
            for stale in staleContexts {
                XCTAssertEqual(built(caller, ssa: ssa), built(caller, ssa: ssa, usage: usage, expected: stale))
            }
            XCTAssertEqual(built(changed, ssa: ssa), built(changed, ssa: ssa, usage: usage, expected: context))
            XCTAssertEqual(built(caller, ssa: ssa), built(caller, ssa: ssa, usage: usage))
        }
    }
    func testSpillVariadicAndUnfollowedAliasRefuseWholeSummaryBothModes() throws {
        let caller = sparseCaller()
        let attacks: [[Literal]] = [
            // A variadic-style save area is not proof of semantic parameters.
            [("e0 07 00 a9", "stp", "x0, x1, [sp]"),
             ("e2 0f 01 a9", "stp", "x2, x3, [sp, #16]"),
             ("e4 17 02 a9", "stp", "x4, x5, [sp, #32]"),
             ("e6 1f 03 a9", "stp", "x6, x7, [sp, #48]"),
             ("c0 03 5f d6", "ret", "")],
            [("f3 03 02 aa", "mov", "x19, x2"), ("c0 03 5f d6", "ret", "")],
            [("f3 03 00 91", "mov", "x19, sp"),
             ("62 02 00 f9", "str", "x2, [x19]"), ("c0 03 5f d6", "ret", "")],
            [("48 00 82 9a", "csel", "x8, x2, x2, eq"), ("c0 03 5f d6", "ret", "")]
        ]
        for attack in attacks {
            XCTAssertNil(MacIRMachineCallUsage.prove(context: context,
                caller: body(caller), callees: [body(rows(0x2000, attack))]))
            for ssa in [false, true] {
                let function = built(caller, ssa: ssa)
                XCTAssertTrue(try renderedCall(function, at: 0x1008).contains(
                    "target(captured_x0) /* unproven args: x2 */"))
                XCTAssertNil(try call(function, at: 0x1008).0.machineRenderArguments)
            }
        }
    }

    func testTailForwardingAndUnresolvedBranchDoNotEraseInputsBothModes() throws {
        let caller = sparseCaller()
        let attacks: [[Literal]] = [
            [("00 04 00 14", "b", "0x3000")], // forwards live x0, not a zero-read return
            [("00 01 1f d6", "br", "x8")],
            [("40 00 00 b4", "cbz", "x0, 0x2008"),
             ("28 00 40 f9", "ldr", "x8, [x1]"),
             ("fe 03 00 94", "bl", "unresolved"), ("c0 03 5f d6", "ret", "")]
        ]
        for attack in attacks {
            let proof = MacIRMachineCallUsage.prove(context: context,
                caller: body(caller), callees: [body(rows(0x2000, attack))])
            XCTAssertNil(proof, "Known prefix reads cannot survive an unresolved path")
            for ssa in [false, true] {
                let before = built(caller, ssa: ssa)
                let after = built(caller, ssa: ssa, usage: proof, expected: context)
                XCTAssertEqual(before, after)
                XCTAssertTrue(try renderedCall(after, at: 0x1008).contains(
                    "target(captured_x0) /* unproven args: x2 */"))
            }
        }
    }

    func testExactBLTargetRejectsRepeatedNamesAndContradictoryAddressBothModes() throws {
        let caller = sparseCaller()
        let good = body(rows(0x2000, [("48 00 40 f9", "ldr", "x8, [x2]"),
                                     ("c0 03 5f d6", "ret", "")]))
        let wrong = body(rows(0x3000, [("00 00 80 d2", "mov", "x0, #0"),
                                      ("c0 03 5f d6", "ret", "")]))
        XCTAssertNil(MacIRMachineCallUsage.prove(context: context, caller: body(caller), callees: [wrong]))
        XCTAssertNil(MacIRMachineCallUsage.prove(context: context, caller: body(caller), callees: [good, good]))
        var contradictory = caller
        contradictory[2].operands = "0x3000" // bytes still branch to 0x2000
        XCTAssertNil(MacIRMachineCallUsage.prove(context: context,
            caller: body(contradictory), callees: [good, wrong]))
        let proof = try XCTUnwrap(MacIRMachineCallUsage.prove(context: context,
            caller: body(caller), callees: [good, wrong]))
        for ssa in [false, true] {
            let function = built(caller, ssa: ssa, usage: proof, expected: context)
            XCTAssertTrue(try renderedCall(function, at: 0x1008).contains(
                "target(/* machine inputs */ x0: captured_x0, x2: captured_x2)"))
            XCTAssertTrue(try renderedCall(built(contradictory, ssa: ssa), at: 0x1008)
                .contains("/* unproven args: x2 */"))
        }
    }

    func testCalleeEvidenceAndContextParticipateInCacheEqualityBothModes() throws {
        let caller = sparseCaller()
        let first = body(rows(0x2000, [("48 00 40 f9", "ldr", "x8, [x2]"),
                                      ("c0 03 5f d6", "ret", "")]))
        let second = body(rows(0x2000, [("00 00 80 d2", "mov", "x0, #0"),
                                       ("c0 03 5f d6", "ret", "")]))
        let a = try XCTUnwrap(MacIRMachineCallUsage.prove(context: context,
            caller: body(caller), callees: [first]))
        let b = try XCTUnwrap(MacIRMachineCallUsage.prove(context: context,
            caller: body(caller), callees: [second]))
        XCTAssertNotEqual(a, b, "Full callee spans, not caller PC alone, key the proof")
        for ssa in [false, true] {
            let function = built(caller, ssa: ssa, usage: a, expected: context)
            var key = SnapshotBuiltFunctionCache.Key(snapshotID: context.snapshotID,
                slot: .primary, startAddress: 0x1000, functionName: "caller", instructions: caller)
            key.machineCallUsage = a
            key.machineUsageContext = context
            let cache = SnapshotBuiltFunctionCache()
            cache.record(function, for: key, environment: [:], isCancelled: false)
            XCTAssertEqual(cache.function(for: key, environment: [:], isCancelled: false), function)
            var changed = key
            changed.machineCallUsage = b
            XCTAssertNotEqual(key, changed)
            XCTAssertNil(cache.function(for: changed, environment: [:], isCancelled: false))
            changed = key
            changed.machineUsageContext = MacIRMachineUsageContext(snapshotID: UUID(),
                imageID: context.imageID, imageSlotRawValue: context.imageSlotRawValue)
            XCTAssertNotEqual(key, changed)
            XCTAssertNil(cache.function(for: changed, environment: [:], isCancelled: false))
            XCTAssertTrue(try renderedCall(function, at: 0x1008).contains(
                "target(/* machine inputs */ x0: captured_x0, x2: captured_x2)"))
            XCTAssertTrue(try renderedCall(built(caller, ssa: ssa, usage: b, expected: context),
                at: 0x1008).contains("target(captured_x0)"))
        }
    }

    func testActualAuditAndLiteralRenderAgreeOnPhysicalKeysBothModes() throws {
        let caller = sparseCaller()
        let callee = rows(0x2000, [("48 00 40 f9", "ldr", "x8, [x2]"),
                                  ("c0 03 5f d6", "ret", "")])
        let proof = try XCTUnwrap(MacIRMachineCallUsage.prove(context: context,
            caller: body(caller), callees: [body(callee)]))
        for ssa in [false, true] {
            let before = built(caller, ssa: ssa)
            XCTAssertNil(WorkspaceScriptingAPI.machineCallArgumentAuditClassifications(
                frame: try call(before, at: 0x1008).0))
            let after = built(caller, ssa: ssa, usage: proof, expected: context)
            let frame = try call(after, at: 0x1008).0
            let audit = try XCTUnwrap(WorkspaceScriptingAPI.machineCallArgumentAuditClassifications(frame: frame))
            let physical = try XCTUnwrap(frame.machineRenderArguments)
            XCTAssertEqual(physical.count, 2)
            for argument in physical {
                let key = try XCTUnwrap(argument.location.physicalKey)
                XCTAssertEqual(audit[key]?.included, true)
                XCTAssertEqual(audit[key]?.reason, "machine-register-input")
                XCTAssertEqual(argument.role, .unknown)
                XCTAssertNil(argument.sourcePosition)
            }
            XCTAssertTrue(try renderedCall(after, at: 0x1008).contains(
                "target(/* machine inputs */ x0: captured_x0, x2: captured_x2)"))
        }
    }
    // Loop control is byte-backed; the taken backedge re-enters after the call
    // kill. A partial rewrite cannot restore x2, while a whole write can.
    func testCallerLoopKillAndRedefinitionInBothModes() throws {
        let callee = rows(0x2000, [("48 00 40 f9", "ldr", "x8, [x2]"),
                                  ("c0 03 5f d6", "ret", "")])
        let writes: [Literal] = [("22 01 80 f2", "movk", "x2, #9"),
                                 ("22 01 80 d2", "mov", "x2, #9")]
        for (index, rewrite) in writes.enumerated() {
            let caller = rows(0x1000, [("22 01 80 d2", "mov", "x2, #9"),
                ("e0 00 80 d2", "mov", "x0, #7"), rewrite,
                ("fd 03 00 94", "bl", "target"),
                ("b3 ff ff b5", "cbnz", "x19, 0x1004"), ("c0 03 5f d6", "ret", "")])
            let proof = try XCTUnwrap(MacIRMachineCallUsage.prove(context: context,
                caller: body(caller), callees: [body(callee)]))
            for ssa in [false, true] {
                let before = built(caller, ssa: ssa)
                let after = built(caller, ssa: ssa, usage: proof, expected: context)
                if index == 0 {
                    XCTAssertEqual(before, after)
                    XCTAssertFalse(try renderedCall(after, at: 0x100c).contains("/* machine inputs */"))
                } else {
                    XCTAssertTrue(try renderedCall(after, at: 0x100c).contains(
                        "target(/* machine inputs */ x0: captured_x0, x2: captured_x2)"))
                }
            }
        }
    }

    func testMarkerFreeAndKnownCatalogCallsKeepExistingPresentationBothModes() throws {
        let callee = rows(0x2000, [("48 00 40 f9", "ldr", "x8, [x2]"),
                                  ("c0 03 5f d6", "ret", "")])
        let callers = [
            rows(0x1000, [("e0 00 80 d2", "mov", "x0, #7"),
                ("21 01 80 d2", "mov", "x1, #9"),
                ("fe 03 00 94", "bl", "target"), ("c0 03 5f d6", "ret", "")]),
            rows(0x1000, [("e0 00 80 d2", "mov", "x0, #7"),
                ("22 01 80 d2", "mov", "x2, #9"),
                ("fe 03 00 94", "bl", "_malloc"), ("c0 03 5f d6", "ret", "")])
        ]
        for caller in callers {
            let proof = try XCTUnwrap(MacIRMachineCallUsage.prove(context: context,
                caller: body(caller), callees: [body(callee)]))
            for ssa in [false, true] {
                let before = built(caller, ssa: ssa)
                let after = built(caller, ssa: ssa, usage: proof, expected: context)
                XCTAssertEqual(before, after)
                XCTAssertNil(try call(after, at: 0x1008).0.machineRenderArguments)
                XCTAssertFalse(try renderedCall(after, at: 0x1008).contains("/* machine inputs */"))
                let target = caller[2].operands
                XCTAssertTrue(try renderedCall(after, at: 0x1008).contains(
                    target == "target" ? "target(captured_x0, captured_x1)" : "_malloc(captured_x0)"))
            }
        }
    }

    func testAlgebraicCopiesAndFramePointerSaveAliasesRefuseBothModes() throws {
        let caller = sparseCaller()
        let attacks: [[Literal]] = [
            [("53 00 1f cb", "sub", "x19, x2, xzr"), ("c0 03 5f d6", "ret", "")],
            [("53 00 02 aa", "orr", "x19, x2, x2"), ("c0 03 5f d6", "ret", "")],
            [("53 04 1f aa", "orr", "x19, x2, xzr, lsl #1"), ("c0 03 5f d6", "ret", "")],
            [("53 04 1f cb", "sub", "x19, x2, xzr, lsl #1"), ("c0 03 5f d6", "ret", "")],
            [("53 20 df 9a", "lsl", "x19, x2, xzr"), ("c0 03 5f d6", "ret", "")],
            [("53 24 df 9a", "lsr", "x19, x2, xzr"), ("c0 03 5f d6", "ret", "")],
            [("53 28 df 9a", "asr", "x19, x2, xzr"), ("c0 03 5f d6", "ret", "")],
            [("53 2c df 9a", "ror", "x19, x2, xzr"), ("c0 03 5f d6", "ret", "")],
            [("b3 43 00 91", "add", "x19, x29, #16"),
             ("62 02 00 f9", "str", "x2, [x19]"), ("c0 03 5f d6", "ret", "")],
            [("f3 03 1d aa", "mov", "x19, x29"),
             ("62 02 00 f9", "str", "x2, [x19]"), ("c0 03 5f d6", "ret", "")]
        ]
        for literals in attacks {
            let proof = MacIRMachineCallUsage.prove(context: context,
                caller: body(caller), callees: [body(rows(0x2000, literals))])
            XCTAssertNil(proof)
            for ssa in [false, true] {
                let before = built(caller, ssa: ssa)
                let after = built(caller, ssa: ssa, usage: proof, expected: context)
                XCTAssertEqual(before, after)
                XCTAssertTrue(try renderedCall(after, at: 0x1008).contains(
                    "target(captured_x0) /* unproven args: x2 */"))
            }
        }
    }

    func testNonConventionalRetRegisterIsAnUnresolvedTransferBothModes() throws {
        let caller = sparseCaller()
        let transfers: [Literal] = [("00 01 5f d6", "ret", "x8"),
                                    ("40 00 5f d6", "ret", "x2")]
        for transfer in transfers {
            let proof = MacIRMachineCallUsage.prove(context: context,
                caller: body(caller), callees: [body(rows(0x2000, [transfer]))])
            XCTAssertNil(proof)
            for ssa in [false, true] {
                let before = built(caller, ssa: ssa)
                let after = built(caller, ssa: ssa, usage: proof, expected: context)
                XCTAssertEqual(before, after)
                XCTAssertTrue(try renderedCall(after, at: 0x1008).contains(
                    "target(captured_x0) /* unproven args: x2 */"))
            }
        }
    }

    func testPromotedAndUnresolvedPhysicalInputsKeepExactRemainingMarkerBothModes() throws {
        let caller = rows(0x1000, [("e0 00 80 d2", "mov", "x0, #7"),
            ("22 01 80 d2", "mov", "x2, #9"), ("23 01 80 f2", "movk", "x3, #9"),
            ("fd 03 00 94", "bl", "target"), ("c0 03 5f d6", "ret", "")])
        let callee = rows(0x2000, [("48 00 40 f9", "ldr", "x8, [x2]"),
            ("69 00 40 f9", "ldr", "x9, [x3]"), ("c0 03 5f d6", "ret", "")])
        let proof = try XCTUnwrap(MacIRMachineCallUsage.prove(context: context,
            caller: body(caller), callees: [body(callee)]))
        for ssa in [false, true] {
            let before = built(caller, ssa: ssa)
            XCTAssertEqual(try call(before, at: 0x100c).0.unprovenArgumentRegisters, ["x2", "x3"])
            let after = built(caller, ssa: ssa, usage: proof, expected: context)
            let frame = try call(after, at: 0x100c).0
            XCTAssertEqual(frame.unprovenArgumentRegisters, ["x3"])
            XCTAssertEqual(try call(before, at: 0x100c).0.arguments, frame.arguments)
            XCTAssertTrue(try renderedCall(after, at: 0x100c).contains(
                "target(/* machine inputs */ x0: captured_x0, x2: captured_x2) /* unproven args: x3 */"))
            let audit = try XCTUnwrap(WorkspaceScriptingAPI.machineCallArgumentAuditClassifications(frame: frame))
            let omitted = try XCTUnwrap(frame.arguments.argument(at: .gpr(index: 3)))
            let key = try XCTUnwrap(omitted.location.physicalKey)
            XCTAssertEqual(audit[key]?.included, false)
            XCTAssertEqual(audit[key]?.reason, "unknown-gap")
            XCTAssertNil(omitted.sourcePosition)
        }
    }

    func testSnapshotCalleeMutationInvalidatesIndependentExpectedContextBothModes() throws {
        let caller = sparseCaller()
        let callee = rows(0x2000, [("48 00 40 f9", "ldr", "x8, [x2]"),
                                  ("c0 03 5f d6", "ret", "")])
        let owner = FunctionSummary(id: UUID(), name: "caller", startAddress: 0x1000,
            endAddress: 0x1010, confidence: 1)
        let leaf = FunctionSummary(id: UUID(), name: "target", startAddress: 0x2000,
            endAddress: 0x2008, confidence: 1)
        var analysis = ImageAnalysis()
        analysis.functions = [owner, leaf]
        analysis.instructions = caller + callee
        var snapshot = WorkspaceSnapshot(binaries: [BinaryImage(id: UUID(), name: "fixture",
            path: "/fixture", kind: "Mach-O", architecture: "arm64")],
            analysisBySlot: [.primary: analysis])
        let original = try XCTUnwrap(snapshot.machineCallUsageHandoff(
            for: (function: owner, instructions: caller), in: .primary))
        analysis.instructions = caller + rows(0x2000, [("00 00 80 d2", "mov", "x0, #0"),
                                                       ("c0 03 5f d6", "ret", "")])
        snapshot.analysisBySlot[.primary] = analysis
        let current = try XCTUnwrap(snapshot.machineCallUsageHandoff(
            for: (function: owner, instructions: caller), in: .primary))
        XCTAssertNotEqual(original.context, current.context)
        XCTAssertNotEqual(original.usage, current.usage)
        for ssa in [false, true] {
            XCTAssertEqual(built(caller, ssa: ssa), built(caller, ssa: ssa,
                usage: original.usage, expected: current.context))
            let fresh = built(caller, ssa: ssa, usage: current.usage, expected: current.context)
            XCTAssertTrue(try call(fresh, at: 0x1008).0.unprovenArgumentRegisters.isEmpty)
            XCTAssertTrue(try renderedCall(fresh, at: 0x1008).contains("target(captured_x0)"))
            XCTAssertFalse(try renderedCall(fresh, at: 0x1008).contains("/* machine inputs */"))
        }
    }

    @MainActor
    func testCanonicalEditorExportAndCensusHandoffInBothModes() throws {
        let caller = sparseCaller()
        let callee = rows(0x2000, [("48 00 40 f9", "ldr", "x8, [x2]"),
                                  ("c0 03 5f d6", "ret", "")])
        let proof = try XCTUnwrap(MacIRMachineCallUsage.prove(context: context,
            caller: body(caller), callees: [body(callee)]))
        var input = PseudocodeRenderInput(imageSlot: .primary, functionName: "caller",
            startAddress: 0x1000, jumpTables: [:], objcSelectors: [:], nameOverrides: [:],
            signatureOverrides: [:], registerNameOverrides: ["x0": "captured_x0", "x2": "captured_x2"],
            types: [], instructions: caller)
        let absent = input
        input.machineCallUsage = proof
        input.machineUsageContext = context
        XCTAssertNotEqual(input, absent)
        for ssa in [false, true] {
            try MacIRConfiguration.$ssaOverride.withValue(ssa) {
                let exported = DocumentExportService().pseudocodeText(for: input, options: .default)
                XCTAssertEqual(PseudocodeView.document(for: input, options: .default).text, exported)
                XCTAssertTrue(exported.contains("target(/* machine inputs */ x0: captured_x0, x2: captured_x2)"))
                XCTAssertFalse(exported.contains("unproven args: x2"))
                let census = DecompilerC2DataflowCensusTests.buildFunction(printer: PseudocodePrinter(), input: input)
                XCTAssertEqual(census.ssaEnabled, ssa)
                XCTAssertTrue(try call(census, at: 0x1008).0.unprovenArgumentRegisters.isEmpty)
                XCTAssertTrue(try renderedCall(census, at: 0x1008).contains(
                    "target(/* machine inputs */ x0: captured_x0, x2: captured_x2)"))
                let baseline = DocumentExportService().pseudocodeText(for: absent, options: .default)
                XCTAssertFalse(baseline.contains("/* machine inputs */"))
                XCTAssertTrue(baseline.contains("unproven args: x2"))
            }
        }
    }

    func testRewrittenLinkRegisterCannotMasqueradeAsConventionalReturnBothModes() throws {
        let caller = sparseCaller()
        let rewrites: [Literal] = [("1e 00 86 d2", "mov", "x30, #0x3000"),
                                   ("fe 03 40 f9", "ldr", "x30, [sp]")]
        for rewrite in rewrites {
            let callee = rows(0x2000, [rewrite, ("c0 03 5f d6", "ret", "")])
            let proof = MacIRMachineCallUsage.prove(context: context,
                caller: body(caller), callees: [body(callee)])
            XCTAssertNil(proof, "A rewritten LR can tail-forward incoming x0 without reading it locally")
            for ssa in [false, true] {
                let before = built(caller, ssa: ssa)
                let after = built(caller, ssa: ssa, usage: proof, expected: context)
                XCTAssertEqual(before, after)
                XCTAssertTrue(try renderedCall(after, at: 0x1008).contains(
                    "target(captured_x0) /* unproven args: x2 */"))
            }
        }
    }
    func testZeroProductFusedCopiesRefuseBothModes() throws {
        let caller = sparseCaller()
        // MADD/MSUB X19,XZR,X8,X2: zero product leaves the incoming addend.
        for alias: Literal in [("f3 0b 08 9b", "madd", "x19, xzr, x8, x2"),
                               ("f3 8b 08 9b", "msub", "x19, xzr, x8, x2")] {
            let callee = rows(0x2000, [alias, ("c0 03 5f d6", "ret", "")])
            let proof = MacIRMachineCallUsage.prove(context: context,
                caller: body(caller), callees: [body(callee)])
            XCTAssertNil(proof)
            for ssa in [false, true] {
                let before = built(caller, ssa: ssa)
                let after = built(caller, ssa: ssa, usage: proof, expected: context)
                XCTAssertEqual(after, before)
                XCTAssertTrue(try renderedCall(after, at: 0x1008).contains(
                    "target(captured_x0) /* unproven args: x2 */"))
            }
        }
    }

    func testMacro12And16NamesCannotRebindTailThunkBothModes() throws {
        for symbol in ["_j12_shared_helper", "_j16_shared_helper"] {
            let caller = rows(0x1000, [("e0 00 80 d2", "mov", "x0, #7"),
                ("22 01 80 d2", "mov", "x2, #9"),
                ("fe 03 00 94", "bl", symbol), ("c0 03 5f d6", "ret", "")])
            // BL lands at the thunk, not the conveniently empty leaf. Names and
            // macro spellings cannot skip the unfollowed tail forwarding x0.
            let thunk = rows(0x2000, [("00 04 00 14", "b", "0x3000")])
            let leaf = rows(0x3000, [("00 00 80 d2", "mov", "x0, #0"),
                                    ("c0 03 5f d6", "ret", "")])
            let proof = MacIRMachineCallUsage.prove(context: context,
                caller: body(caller), callees: [body(thunk), body(leaf)])
            XCTAssertNil(proof)
            for ssa in [false, true] {
                let after = built(caller, ssa: ssa, usage: proof, expected: context)
                XCTAssertEqual(after, built(caller, ssa: ssa))
                XCTAssertTrue(try renderedCall(after, at: 0x1008).contains(
                    symbol + "(captured_x0) /* unproven args: x2 */"))
            }
        }
    }

    func testBodyBudgetsRefuseRatherThanPublishPartialProofBothModes() throws {
        let smallCaller = sparseCaller()
        let smallCallee = rows(0x2000, [("48 00 40 f9", "ldr", "x8, [x2]"),
                                      ("c0 03 5f d6", "ret", "")])
        let padding: Literal = ("1f 20 03 d5", "nop", "")
        let largeCallee = rows(0x2000, Array(repeating: padding, count: 4096)
            + [("c0 03 5f d6", "ret", "")])
        // An unreachable suffix still counts toward the complete-source budget.
        let largeCaller = smallCaller + rows(0x1010, Array(repeating: padding, count: 4093))
        for (caller, callee) in [(smallCaller, largeCallee), (largeCaller, smallCallee)] {
            let proof = MacIRMachineCallUsage.prove(context: context,
                caller: body(caller), callees: [body(callee)])
            XCTAssertNil(proof)
            for ssa in [false, true] {
                // Test fallback on the bounded original call; never build the
                // oversized source merely to exercise the provider's refusal.
                let after = built(smallCaller, ssa: ssa, usage: proof, expected: context)
                XCTAssertEqual(after, built(smallCaller, ssa: ssa))
                XCTAssertTrue(try renderedCall(after, at: 0x1008).contains(
                    "target(captured_x0) /* unproven args: x2 */"))
            }
        }
    }

    func testMalformedWriteShapesRefuseAgainstValidControlsBothModes() throws {
        let caller = sparseCaller()
        // Each malformed spelling deliberately contradicts its retained valid
        // control bytes. These are parser-refusal controls, not decoded examples.
        let pairs: [(Literal, Literal)] = [
            (("02 01 09 8b", "add", "x2, x8, x9"),
             ("02 01 09 8b", "add", "w2, x8, x9")),
            (("02 05 00 91", "add", "x2, x8, #1"),
             ("02 05 00 91", "add", "x2, x8, #1, ror #1")),
            (("e2 03 08 cb", "neg", "x2, x8"),
             ("e2 03 08 cb", "neg", "w2, x8")),
            (("02 01 40 f8", "ldur", "x2, [x8]"),
             ("02 01 40 f8", "ldur", "x2, [x8], #8")),
            (("02 79 69 f8", "ldr", "x2, [x8, x9, lsl #3]"),
             ("02 79 69 f8", "ldr", "x2, [x8, x9, ror #1]"))
        ]
        for (valid, malformed) in pairs {
            let suffix: [Literal] = [("48 00 40 f9", "ldr", "x8, [x2]"),
                                     ("c0 03 5f d6", "ret", "")]
            let positive = try XCTUnwrap(MacIRMachineCallUsage.prove(context: context,
                caller: body(caller), callees: [body(rows(0x2000, [valid] + suffix))]))
            let refused = MacIRMachineCallUsage.prove(context: context,
                caller: body(caller), callees: [body(rows(0x2000, [malformed] + suffix))])
            XCTAssertNil(refused, "Invalid write must not kill the incoming x2 bit")
            for ssa in [false, true] {
                let accepted = built(caller, ssa: ssa, usage: positive, expected: context)
                XCTAssertTrue(try call(accepted, at: 0x1008).0.unprovenArgumentRegisters.isEmpty)
                XCTAssertTrue(try renderedCall(accepted, at: 0x1008).contains("target(captured_x0)"))
                let unchanged = built(caller, ssa: ssa, usage: refused, expected: context)
                XCTAssertEqual(unchanged, built(caller, ssa: ssa))
                XCTAssertTrue(try renderedCall(unchanged, at: 0x1008).contains(
                    "target(captured_x0) /* unproven args: x2 */"))
            }
        }
    }

    func testWholeWOverwriteKillsIncomingXBeforeSubsequentReadBothModes() throws {
        let caller = sparseCaller()
        for write: Literal in [("02 00 80 52", "mov", "w2, #0"),
                               ("e2 00 80 52", "mov", "w2, #7")] {
            let callee = rows(0x2000, [write, ("48 00 40 f9", "ldr", "x8, [x2]"),
                                      ("c0 03 5f d6", "ret", "")])
            let proof = try XCTUnwrap(MacIRMachineCallUsage.prove(context: context,
                caller: body(caller), callees: [body(callee)]))
            for ssa in [false, true] {
                let after = built(caller, ssa: ssa, usage: proof, expected: context)
                XCTAssertTrue(try call(after, at: 0x1008).0.unprovenArgumentRegisters.isEmpty)
                XCTAssertNil(try call(after, at: 0x1008).0.machineRenderArguments)
                XCTAssertTrue(try renderedCall(after, at: 0x1008).contains("target(captured_x0)"))
            }
        }
    }

}
