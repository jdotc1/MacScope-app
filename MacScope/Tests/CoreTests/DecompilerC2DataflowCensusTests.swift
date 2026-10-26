import Foundation
import Darwin
import XCTest
@testable import MacScope

final class DecompilerC2DataflowCensusTests: XCTestCase {
    func testClobberOnlyCallCannotBorrowNextOrdinarySSAName() {
        var state = BuilderState()
        state.registerVersions["x0"] = 4
        state.unavailableRegisterValues = ["x0", "w0"]
        state.callUnavailableRegisterValues = ["x0", "w0"]
        state.constructedCallArgumentGPRs = [1]
        let unavailable = MacIRSSAState.Binding(value: .unknown("unavailable_x0"),
            bitWidth: 64, view: .integer, origin: .callClobber(0x9000))
        state.ssa = .init(current: [0: unavailable], writes: [:], clobbers: [0: unavailable])
        XCTAssertNil(state.writeCallResult(returnType: nil))
        XCTAssertEqual(state.registerVersions["x0"], 4)
        XCTAssertEqual(state.unavailableRegisterValues, ["x0", "w0"])
        XCTAssertEqual(state.callUnavailableRegisterValues, ["x0", "w0"])
        XCTAssertEqual(state.constructedCallArgumentGPRs, [1])
        XCTAssertEqual(state.readRegister("x0"), .unknown("unavailable_x0"))
        let next = MacIRSSAState.Binding(value: reg(0, 5), bitWidth: 64,
            view: .integer, origin: .instruction(0x9004))
        state.ssa = .init(current: [0: unavailable], writes: [0: next], clobbers: [:])
        XCTAssertEqual(state.writeRegister("x0"), reg(0, 5))
    }

    func testCallResultRejectsNonCallOrigins() {
        let origins: [MacIRSSA.DefinitionOrigin] = [
            .instruction(0x9004), .callClobber(0x9000), .refusal(.unknownEffects, 0x9000)]
        for origin in origins {
            var state = BuilderState()
            let binding = MacIRSSAState.Binding(value: reg(0, 5), bitWidth: 64,
                view: .integer, origin: origin)
            state.ssa = .init(current: [:], writes: [0: binding], clobbers: [:])
            XCTAssertNil(state.writeCallResult(returnType: "uint64_t"))
            XCTAssertNil(state.registerVersions["x0"])
            XCTAssertTrue(state.constructedCallArgumentGPRs.isEmpty)
        }
    }

    func testCallResultRejectsUnknownPlannedValue() {
        var state = BuilderState()
        state.ssa = .init(current: [:], writes: [0: .init(value: .unknown("unavailable_x0"),
            bitWidth: 64, view: .integer, origin: .callResult(target: nil))], clobbers: [:])
        XCTAssertNil(state.writeCallResult(returnType: nil))
        XCTAssertNil(state.registerVersions["x0"])
        XCTAssertTrue(state.constructedCallArgumentGPRs.isEmpty)
    }

    func testPlannedCallResultTargetPresencePreservesIdentity() {
        for target in [Optional("callee"), nil] {
            var state = BuilderState()
            let binding = MacIRSSAState.Binding(value: reg(0, 7), bitWidth: 64,
                view: .integer, origin: .callResult(target: target))
            state.ssa = .init(current: [:], writes: [0: binding], clobbers: [:])
            XCTAssertEqual(state.writeCallResult(returnType: "uint64_t"), reg(0, 7))
            XCTAssertEqual(state.readRegister("x0"), reg(0, 7))
        }
    }

    func testNoSSAPlanPreservesLegacyAllocation() {
        var state = BuilderState()
        XCTAssertNil(state.ssa)
        XCTAssertEqual(state.writeCallResult(returnType: nil), reg(0, 1))
        XCTAssertEqual(state.registerVersions["x0"], 1)
    }

    func testDuplicateDisplayedDefinitionsRemainRefusedInBothAccountingModes() {
        let function = MacIRFunction(name: "duplicate_definition", startAddress: 0x9000,
            returnType: "uint64_t", instructions: [
                instruction(0x9000, "mov", "x0, x1", .assign(destination: reg(0, 1), source: reg(1, 0))),
                instruction(0x9004, "mov", "x0, x2", .assign(destination: reg(0, 1), source: reg(2, 0))),
                instruction(0x9008, "ret", "", .returnValue(reg(0, 1)))])
        let printer = PseudocodePrinter(options: DecompilerOptions(structureControlFlow: false,
            deadCodeElimination: false, nopElision: false, functionSizeGate: 1024))
        let document = printer.print(function: function)
        let assignments = document.lines.filter {
            ($0.sourceAddress == 0x9000 || $0.sourceAddress == 0x9004)
                && $0.text.contains("x0_1 = ")
        }
        XCTAssertEqual(assignments.count, 2, "Both competing definitions must actually be displayed")
        XCTAssertTrue(document.lines.contains {
            $0.kind == .instruction && $0.sourceAddress == 0x9008 && $0.text.contains("x0_1")
        }, "The refused use must actually be displayed")
        let projected = MacIRFPEnvironmentPseudocodeProjection.project(function)
        var names = PseudocodeNameContext(function: projected)
        names.redundantCompareIndices = printer.redundantCompareIndices(function: projected, names: names)
        for accounting in [false, true] {
            let result = C2DataflowCensus.analyze(function: projected, document: document,
                machine: function.instructions.map(\.source), printer: printer, names: names,
                ssaAccountingEnabled: accounting)
            XCTAssertTrue(result.refusalDetails.contains {
                $0.reason == "ambiguous displayed definition: x0_1"
            }, "accounting=\(accounting)")
            XCTAssertTrue(result.rows.isEmpty)
        }
    }

    func testMissingEmittedPhiCopyRemainsRefusedInBothAccountingModes() {
        var function = join(merged: true)
        function.ssaEnabled = true
        let printer = PseudocodePrinter(options: DecompilerOptions(structureControlFlow: false,
            deadCodeElimination: false, nopElision: false, functionSizeGate: 1024))
        let original = printer.print(function: function)
        XCTAssertTrue(original.lines.contains { $0.syntheticPhiEdge != nil })
        var missing = original
        missing.lines.removeAll { $0.syntheticPhiEdge != nil }
        let projected = MacIRFPEnvironmentPseudocodeProjection.project(function)
        var names = PseudocodeNameContext(function: projected)
        names.redundantCompareIndices = printer.redundantCompareIndices(function: projected, names: names)
        let reason = "phi has no emitted predecessor edge copy"
        for accounting in [false, true] {
            let intact = C2DataflowCensus.analyze(function: projected, document: original,
                machine: function.instructions.map(\.source), printer: printer, names: names,
                ssaAccountingEnabled: accounting)
            XCTAssertNil(intact.skippedReason, "The intact phi fixture must be fully analyzable")
            XCTAssertTrue(intact.rows.isEmpty)
            XCTAssertFalse(intact.refusalDetails.contains { $0.reason == reason })
            let result = C2DataflowCensus.analyze(function: projected, document: missing,
                machine: function.instructions.map(\.source), printer: printer, names: names,
                ssaAccountingEnabled: accounting)
            XCTAssertTrue(result.refusalDetails.contains { $0.reason == reason },
                "accounting=\(accounting)")
            XCTAssertTrue(result.rows.isEmpty)
        }
    }

    // Source-only producer matrix. These authored fixtures are not execution evidence.
    // Census-only authored IR/machine fixtures; no product semantics are changed.
    func testGuardedSelectConditionalAvailabilityPredicateFamilies() {
        for width in [32, 64] {
            for (producer, suffix) in [("cmp", "eq"), ("cmp", "ne"),
                                       ("cmp", "lt"), ("cmp", "ge"),
                                       ("cmp", "lo"), ("cmp", "hs"),
                                       ("tst", "eq"), ("tst", "ne")] {
                let result = analyze(conditionalArmFixture(producer, suffix: suffix, width: width))
                XCTAssertNil(result.skippedReason, "\(producer) \(suffix) \(width)")
                XCTAssertTrue(result.rows.isEmpty)
            }
        }
    }

    func testGuardedSelectConditionalAvailabilityFalseArmAndComplement() {
        for mismatch in ["falseArm", "complement"] {
            for suffix in ["eq", "ne", "lt", "lo"] {
                let result = analyze(conditionalArmFixture("cmp", suffix: suffix, mismatch: mismatch))
                XCTAssertNil(result.skippedReason, "\(mismatch) \(suffix)")
                XCTAssertTrue(result.rows.isEmpty)
            }
        }
    }

    func testGuardedSelectConditionalAvailabilityRejectsWrongArmIdentity() {
        for suffix in ["eq", "ne", "lt", "lo"] {
            let result = analyze(conditionalArmFixture("cmp", suffix: suffix, mismatch: "wrongArm"))
            XCTAssertTrue(result.refusalDetails.contains {
                C2DataflowCensus.GuardedConjunct(reason: $0.reason) == .armDefinitionAmbiguous && $0.register == "x1"
            })
            XCTAssertNotNil(result.skippedReason)
        }
    }

    func testGuardedSelectConditionalAvailabilityRejectsUnrelatedPredicate() {
        for mismatch in ["unrelated", "flags", "cycle", "bothArms", "overwrite"] {
            let result = analyze(conditionalArmFixture("cmp", suffix: "eq", mismatch: mismatch))
            XCTAssertTrue(result.refusalDetails.contains {
                C2DataflowCensus.GuardedConjunct(reason: $0.reason) != nil && $0.register == "x1"
            }, mismatch)
            XCTAssertNotNil(result.skippedReason)
        }
    }

    func testGuardedSelectConditionalAvailabilityKeepsDisplayedNameRefusal() {
        let function = conditionalArmFixture("cmp", suffix: "eq")
        let printer = PseudocodePrinter(options: DecompilerOptions(structureControlFlow: false,
            deadCodeElimination: false, nopElision: false, functionSizeGate: 1024))
        let overrides = ["x1": "shared_arm"]
        let document = printer.print(function: function, registerNameOverrides: overrides)
        let names = PseudocodeNameContext(function: function, registerNameOverrides: overrides)
        XCTAssertEqual(printer.valueText(for: reg(1, 1), names: names),
                       printer.valueText(for: reg(1, 2), names: names))
        XCTAssertTrue(document.lines.contains {
            $0.sourceAddress == 0x7614 && $0.text.contains("shared_arm")
        })
        let result = C2DataflowCensus.analyze(function: function, document: document,
            machine: function.instructions.map(\.source), printer: printer, names: names)
        XCTAssertTrue(result.refusalDetails.contains {
            C2DataflowCensus.GuardedConjunct(reason: $0.reason) == .armDefinitionAmbiguous && $0.register == "x1"
        })
        XCTAssertNotNil(result.skippedReason)
    }

    private func conditionalArmFixture(_ producer: String, suffix: String, width: Int = 64,
                                       mismatch: String = "") -> MacIRFunction {
        let template = guardedProducerFixture(producer, immediate: true, width: width, suffix: suffix)
        let prefix = width == 32 ? "w" : "x"
        func value(_ number: Int, _ version: Int = 0) -> MacIRValue {
            .register(name: "\(prefix)\(number)", version: version)
        }
        guard case let .select(destination, condition, left, right, _, _) = template.instructions[1].operation else {
            preconditionFailure("guarded producer fixture must contain a select")
        }
        let first = template.instructions[0]
        let inverse = ["eq": "ne", "ne": "eq", "lt": "ge", "ge": "lt", "lo": "hs", "hs": "lo"]
        let branchSuffix = mismatch == "complement" ? inverse[suffix]! : suffix
        let branch = mismatch == "unrelated" ? "cbz" : "b.\(branchSuffix)"
        let branchCondition = mismatch == "complement"
            ? ["==": "!=", "!=": "==", "<": ">=", ">=": "<"][condition]! : condition
        let branchOperands = mismatch == "unrelated" ? "\(prefix)4, 0x7610" : "0x7610"
        var rows = [
            instruction(0x7600, first.source.mnemonic, first.source.operands, first.operation),
            instruction(0x7604, branch, branchOperands,
                .conditionalBranch(condition: branchCondition,
                    left: mismatch == "unrelated" ? value(4) : left,
                    right: mismatch == "unrelated" ? .immediate(0) : right,
                    target: .immediate(0x7610))),
            instruction(0x7608, "mov", "\(prefix)1, \(prefix)5", .assign(destination: value(1, 1), source: value(5))),
            instruction(0x760c, "b", "0x7614", .intrinsic(destination: nil, name: "branch", arguments: [.immediate(0x7614)])),
            instruction(0x7610, "mov", "\(prefix)1, \(prefix)6", .assign(destination: value(1, 2), source: value(6)))
        ]
        var address: UInt64 = 0x7614
        if mismatch == "flags" {
            rows.append(instruction(address, first.source.mnemonic, first.source.operands, first.operation))
            address += 4
        } else if mismatch == "overwrite" {
            rows.append(instruction(address, "mov", "\(prefix)1, \(prefix)7", .assign(destination: value(1, 3), source: value(7))))
            address += 4
        }
        let falseArm = mismatch == "falseArm"
        let yes = falseArm ? value(2) : value(1, ["wrongArm", "complement"].contains(mismatch) ? 1 : 2)
        let no = falseArm ? value(1, 1) : (mismatch == "bothArms" ? yes : value(2))
        rows.append(instruction(address, "csel", "\(prefix)0, \(prefix)\(falseArm ? 2 : 1), \(prefix)\(falseArm || mismatch == "bothArms" ? 1 : 2), \(suffix)",
            .select(destination: destination, condition: condition, left: left, right: right,
                    trueValue: yes, falseValue: no)))
        address += 4
        if mismatch == "cycle" {
            rows.append(instruction(address, "cbnz", "\(prefix)7, 0x7600",
                .conditionalBranch(condition: "!=", left: value(7), right: .immediate(0), target: .immediate(0x7600))))
            address += 4
        }
        rows.append(instruction(address, "ret", "", .returnValue(nil)))
        return MacIRFunction(name: "conditional_arm", startAddress: 0x7600, returnType: "void", instructions: rows)
    }

    func testGuardedProducerFormsWidthsAndConditions() {
        for form in guardedProducerForms {
            for width in [32, 64] {
                let conditions = form.0 == "cmp" || form.0 == "subs"
                    ? ["eq", "ne", "lt", "le", "gt", "ge", "lo", "hs", "hi", "ls", "cc", "cs"]
                    : ["eq", "ne", "lt", "le", "gt", "ge"]
                for suffix in conditions {
                    let function = guardedProducerFixture(form.0, immediate: form.1, width: width, suffix: suffix)
                    let result = analyze(function)
                    XCTAssertNil(result.skippedReason, "\(form) \(width) \(suffix)")
                    XCTAssertTrue(result.rows.isEmpty)
                    // The same form must not acquire proof from a different SSA input.
                    assertGuardedProducerRefusal(guardedProducerFixture(form.0, immediate: form.1,
                        width: width, suffix: suffix, mismatch: "predicate"))
                }
            }
        }
    }

    func testGuardedProducerFamilyArmWidthsAndAliasPolarity() {
        for form in guardedProducerForms {
            for width in [32, 64] {
                let conditions = form.0 == "cmp" || form.0 == "subs"
                    ? ["eq", "ne", "lt", "le", "gt", "ge", "lo", "hs", "hi", "ls", "cc", "cs"]
                    : ["eq", "ne", "lt", "le", "gt", "ge"]
                for mnemonic in ["csinc", "csinv", "csneg", "cinc", "cneg"] {
                    for suffix in conditions {
                        let function = guardedProducerFixture(form.0, immediate: form.1,
                            width: width, suffix: suffix, selection: mnemonic)
                        let result = analyze(function)
                        XCTAssertNil(result.skippedReason, "\(form) \(width) \(mnemonic) \(suffix)")
                        XCTAssertTrue(result.rows.isEmpty)
                        assertGuardedProducerRefusal(guardedProducerFixture(form.0, immediate: form.1,
                            width: width, suffix: suffix, selection: mnemonic, mismatch: "polarity"))
                    }
                }
            }
        }
    }

    func testGuardedProducerRejectsWidthMismatchForEveryForm() {
        for form in guardedProducerForms {
            for width in [32, 64] {
                assertGuardedProducerRefusal(guardedProducerFixture(form.0, immediate: form.1,
                    width: width, mismatch: "width"))
            }
        }
    }

    func testGuardedProducerRejectsCompetingAndMissingFlags() {
        for form in guardedProducerForms {
            for width in [32, 64] {
                for mismatch in ["competing", "missing", "ccmp", "armOverwrite"] {
                    assertGuardedProducerRefusal(guardedProducerFixture(form.0, immediate: form.1,
                        width: width, mismatch: mismatch))
                }
            }
        }
    }

    func testGuardedProducerRejectsSignednessAndLogicalShapeMismatch() {
        for form in guardedProducerForms {
            for width in [32, 64] {
                for suffix in ["lt", "ge"] {
                    for mismatch in ["signedness", "projectionWidth", "unprojected"] {
                        assertGuardedProducerRefusal(guardedProducerFixture(form.0, immediate: form.1,
                            width: width, suffix: suffix, mismatch: mismatch))
                    }
                }
                if form.0 == "cmp" || form.0 == "subs" {
                    for suffix in ["lo", "hs"] {
                        assertGuardedProducerRefusal(guardedProducerFixture(form.0, immediate: form.1,
                            width: width, suffix: suffix, mismatch: "signedness"))
                    }
                } else {
                    assertGuardedProducerRefusal(guardedProducerFixture(form.0, immediate: form.1,
                        width: width, mismatch: "logicalShape"))
                    for suffix in ["lo", "hs", "hi", "ls"] {
                        assertGuardedProducerRefusal(guardedProducerFixture(form.0, immediate: form.1,
                            width: width, suffix: suffix))
                    }
                }
            }
        }
    }

    func testGuardedProducerSingleBitTestAndInvalidBICSImmediate() {
        for width in [32, 64] {
            for suffix in ["eq", "ne"] {
                let result = analyze(guardedProducerFixture("tst", immediate: true,
                    width: width, suffix: suffix, singleBit: true))
                XCTAssertNil(result.skippedReason)
                XCTAssertTrue(result.rows.isEmpty)
                assertGuardedProducerRefusal(guardedProducerFixture("tst", immediate: true,
                    width: width, suffix: suffix, mismatch: "bitIndex", singleBit: true))
            }
            assertGuardedProducerRefusal(guardedProducerFixture("tst", immediate: true,
                width: width, suffix: "lt", singleBit: true))
            assertGuardedProducerRefusal(guardedProducerFixture("bics", immediate: true, width: width))
        }
    }

    // Authored byte-backed fixtures. No results were measured while preparing this patch.
    func testHalfwordLaneNoOffsetPreservesBothHalves() throws {
        try halfwordModes {
            try assertHalfwordPayload(word: 0x0d404990, text: "{v16.h}[1], [x12]",
                low: 0x11223344beef7788, high: 0x99aabbccddeeff00, base: 0x1000,
                reads: ["v16", "x12"], writes: ["v16"])
            try assertHalfwordPayload(word: 0x4d405990, text: "{v16.h}[7], [x12]",
                low: 0x1122334455667788, high: 0xbeefbbccddeeff00, base: 0x1000,
                reads: ["v16", "x12"], writes: ["v16"])
        }
    }

    func testHalfwordLaneNoOffsetReadsUpdatedCarrier() throws {
        try halfwordModes {
            let rows = [halfwordRow(0x0d404990, "{v16.h}[1], [x12]"),
                        halfwordRow(0x4d405990, "{v16.h}[7], [x12]", at: 0x7a04)]
            let function = MacIRBuilder().buildFunction(name: "lane_chain", instructions: rows)
            let frames = function.instructions.compactMap { instruction -> MacIRNEONStructureLaneMemory? in
                guard let step = instruction.neonStructureLaneMemory, step.ordinal == 0 else { return nil }
                return step.frame
            }
            XCTAssertEqual(frames.count, 2)
            guard frames.count == 2 else { return }
            XCTAssertEqual(frames[1].oldVectors, frames[0].destinations)
            let flow = C2MachineFlow(rows: rows.map(halfwordSource))
            XCTAssertNil(flow.error)
            XCTAssertEqual(flow.before[1]["v16"], [0x7a00])
            XCTAssertEqual(flow.reads[1], ["v16", "x12"])
            var evaluator = try halfwordEvaluator(function)
            try evaluator.executeNEONStructureLaneMemory(frames[0])
            try evaluator.executeNEONStructureLaneMemory(frames[1])
            XCTAssertEqual(evaluator.state.v[16].low, 0x11223344beef7788)
            XCTAssertEqual(evaluator.state.v[16].high, 0xbeefbbccddeeff00)
            XCTAssertEqual(evaluator.state.x[12], 0x1000)
        }
    }

    func testHalfwordLaneNoOffsetMalformedAndByteMismatchStayRefused() throws {
        try halfwordModes {
            for text in ["{v16.h}[8], [x12]", "{v16.s}[1], [x12]",
                         "{v16.h, v17.h}[1], [x12]", "{v16.h}[1], [sp]",
                         "{v16.h}[1], [x12, #2]", "{v1 6.h}[1], [x12]",
                         "{v16.h}[1], [x1 2]"] {
                assertHalfwordRefusal(0x0d404990, text)
            }
            try assertHalfwordByteMismatch(0x0d404991, "{v16.h}[1], [x12]")
        }
    }

    func testHalfwordLaneImmediatePostPreservesBothHalves() throws {
        try halfwordModes {
            try assertHalfwordPayload(word: 0x0ddf4990, text: "{v16.h}[1], [x12], #2",
                low: 0x11223344beef7788, high: 0x99aabbccddeeff00, base: 0x1002,
                reads: ["v16", "x12"], writes: ["v16", "x12"])
        }
    }

    func testHalfwordLaneImmediatePostUsesOldAddress() throws {
        try halfwordModes {
            try assertHalfwordPayload(word: 0x4ddf5990, text: "{v16.h}[7], [x12], #2",
                low: 0x1122334455667788, high: 0xbeefbbccddeeff00, base: 0x1002,
                reads: ["v16", "x12"], writes: ["v16", "x12"])
            // The memory at the updated address is 0x1234, not the 0xbeef loaded above.
            let flow = C2MachineFlow(rows: [halfwordSource(halfwordRow(0x0ddf4990,
                "{v16.h}[1], [x12], #2")),
                halfwordSource(halfwordRow(0x0d404990, "{v16.h}[1], [x12]", at: 0x7a04))])
            XCTAssertEqual(flow.before[1]["x12"], [0x7a00])
            XCTAssertEqual(flow.before[1]["v16"], [0x7a00])
        }
    }

    func testHalfwordLaneImmediatePostMalformedAndByteMismatchStayRefused() throws {
        try halfwordModes {
            for text in ["{v16.h}[1], [x12], #4", "{v16.h}[1], [x12], #-2",
                         "{v16.h}[1], [x12]!, #2", "{v16.h}[1], [x12], #2, x0"] {
                assertHalfwordRefusal(0x0ddf4990, text)
            }
            try assertHalfwordByteMismatch(0x0d404990, "{v16.h}[1], [x12], #2")
        }
    }

    func testHalfwordLaneRegisterPostPreservesBothHalves() throws {
        try halfwordModes {
            try assertHalfwordPayload(word: 0x0dcd4990, text: "{v16.h}[1], [x12], x13",
                low: 0x11223344beef7788, high: 0x99aabbccddeeff00, base: 0x1006,
                reads: ["v16", "x12", "x13"], writes: ["v16", "x12"])
        }
    }

    func testHalfwordLaneRegisterPostAliasesBaseSnapshot() throws {
        try halfwordModes {
            try assertHalfwordPayload(word: 0x4dcc5990, text: "{v16.h}[7], [x12], x12",
                low: 0x1122334455667788, high: 0xbeefbbccddeeff00, base: 0x2000,
                reads: ["v16", "x12"], writes: ["v16", "x12"])
            let row = halfwordRow(0x4dcc5990, "{v16.h}[7], [x12], x12")
            let function = MacIRBuilder().buildFunction(name: "lane_same_base", instructions: [row])
            let frame = try XCTUnwrap(function.instructions.first?.neonStructureLaneMemory?.frame)
            XCTAssertEqual(frame.registerPost?.oldIncrement, frame.oldBase)
            XCTAssertEqual(frame.fixedPostDelta, 0)
            XCTAssertEqual(frame.byteCount, 2)
        }
    }

    func testHalfwordLaneRegisterPostMalformedAndByteMismatchStayRefused() throws {
        try halfwordModes {
            for text in ["{v16.h}[1], [x12], w13", "{v16.h}[1], [x12], xzr",
                         "{v16.h}[1], [x12], x31", "{v16.h}[1], [x12], sp",
                         "{v16.h}[1], [x12], x1 3"] {
                assertHalfwordRefusal(0x0dcd4990, text)
            }
            try assertHalfwordByteMismatch(0x0dce4990, "{v16.h}[1], [x12], x13")
        }
    }

    private func halfwordModes(_ body: () throws -> Void) rethrows {
        for enabled in [false, true] {
            try MacIRConfiguration.$ssaOverride.withValue(enabled) {
                XCTAssertEqual(MacIRBuilder().ssaEnabled, enabled)
                try body()
            }
        }
    }

    private func halfwordRow(_ word: UInt32, _ operands: String, at address: UInt64 = 0x7a00) -> InstructionRow {
        let bytes = (0..<4).map { String(format: "%02x", (word >> ($0 * 8)) & 255) }.joined(separator: " ")
        return .init(address: address, bytes: bytes, mnemonic: "ld1", operands: operands,
                     hasBreakpoint: false, comment: nil)
    }

    private func halfwordSource(_ row: InstructionRow) -> MacIRSourceSpan {
        .init(address: row.address, byteText: row.bytes, mnemonic: row.mnemonic, operands: row.operands)
    }

    private func halfwordEvaluator(_ function: MacIRFunction) throws -> MacIRConcreteEvaluator {
        var input = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self,
            from: Data("{}".utf8)))
        input.x[12] = 0x1000
        input.x[13] = 6
        input.v[16] = .init(low: 0x1122334455667788, high: 0x99aabbccddeeff00)
        input.setByte(0xef, at: 0x1000); input.setByte(0xbe, at: 0x1001)
        input.setByte(0x34, at: 0x1002); input.setByte(0x12, at: 0x1003)
        return MacIRConcreteEvaluator(function: function, state: input)
    }

    private func assertHalfwordPayload(word: UInt32, text: String, low: UInt64, high: UInt64,
                                      base: UInt64, reads: Set<String>, writes: Set<String>) throws {
        let row = halfwordRow(word, text)
        let flow = C2MachineFlow(rows: [halfwordSource(row)])
        XCTAssertNil(flow.error)
        XCTAssertEqual(flow.reads, [reads]); XCTAssertEqual(flow.writes, [writes])
        let parsed = try XCTUnwrap(MacIRBuilder.neonStructureLaneMemory(row))
        XCTAssertEqual(parsed.elementBytes, 2); XCTAssertEqual(parsed.structureCount, 1)
        let function = MacIRBuilder().buildFunction(name: "halfword_lane", instructions: [row])
        let frame = try XCTUnwrap(function.instructions.first?.neonStructureLaneMemory?.frame)
        XCTAssertEqual(frame.elementBytes, 2); XCTAssertEqual(frame.byteCount, 2)
        XCTAssertEqual(frame.orderedBytes.map(\.offset), [0, 1])
        XCTAssertEqual(frame.orderedBytes.map(\.vector), [0, 0])
        if frame.laneIndex == 1 {
            XCTAssertEqual(frame.orderedBytes.map(\.lane), [2, 3])
            XCTAssertEqual(frame.preservedVectorBytes, [0, 1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15])
        } else {
            XCTAssertEqual(frame.laneIndex, 7)
            XCTAssertEqual(frame.orderedBytes.map(\.lane), [14, 15])
            XCTAssertEqual(frame.preservedVectorBytes, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13])
        }
        XCTAssertEqual(function.instructions.count, writes.contains("x12") ? 2 : 1)
        for instruction in function.instructions {
            XCTAssertNotNil(instruction.neonStructureLaneMemory)
            if case .unknown = instruction.operation { XCTFail("admitted LD1 cannot remain unknown") }
        }
        let printer = PseudocodePrinter(options: DecompilerOptions(structureControlFlow: false,
            deadCodeElimination: false, nopElision: false, functionSizeGate: 1024))
        let printed = printer.print(function: function).text
        XCTAssertFalse(printed.contains("__unknown("), printed)
        XCTAssertTrue(printed.contains("uint16_t"), printed)
        var evaluator = try halfwordEvaluator(function)
        try evaluator.executeNEONStructureLaneMemory(frame)
        XCTAssertEqual(evaluator.state.v[16].low, low)
        XCTAssertEqual(evaluator.state.v[16].high, high)
        XCTAssertEqual(evaluator.state.x[12], base)
        XCTAssertEqual(evaluator.state.x[13], 6)
        XCTAssertEqual([evaluator.state.byte(at: 0x1000), evaluator.state.byte(at: 0x1001),
                        evaluator.state.byte(at: 0x1002), evaluator.state.byte(at: 0x1003)],
                       [0xef, 0xbe, 0x34, 0x12])
    }

    private func assertHalfwordRefusal(_ word: UInt32, _ text: String) {
        let row = halfwordRow(word, text)
        XCTAssertNil(MacIRBuilder.neonStructureLaneMemory(row))
        XCTAssertEqual(C2MachineFlow(rows: [halfwordSource(row)]).error,
                       "0x7a00: partial vector lane load")
    }

    private func assertHalfwordByteMismatch(_ word: UInt32, _ text: String) throws {
        let row = halfwordRow(word, text)
        XCTAssertNil(MacIRBuilder.neonStructureLaneMemory(row))
        // C2 consumes decoded text, not bytes. Its independent operand effect
        // does not override a product refusal; force the poisoned Vd to print.
        let store = InstructionRow(address: 0x7a04, bytes: "10 00 80 3d", mnemonic: "str",
            operands: "q16, [x0]", hasBreakpoint: false, comment: nil)
        let function = MacIRBuilder().buildFunction(name: "lane_mismatch", instructions: [row, store])
        XCTAssertTrue(function.instructions.contains { instruction in
            if case .unknown = instruction.operation { return instruction.source.address == 0x7a00 }
            return false
        })
        let result = analyze(function, ssaAccountingEnabled: MacIRConfiguration.ssaEnabled,
                             machine: [halfwordSource(row), halfwordSource(store)])
        XCTAssertTrue(result.refusalDetails.contains { $0.reason == "unknown-use: unavailable_v16" })
        XCTAssertNotNil(result.skippedReason)
    }

    private var guardedProducerForms: [(String, Bool)] {
        [("cmp", false), ("cmp", true), ("subs", false), ("subs", true),
         ("tst", false), ("tst", true), ("ands", false), ("ands", true), ("bics", false)]
    }

    private func assertGuardedProducerRefusal(_ function: MacIRFunction,
                                              file: StaticString = #filePath, line: UInt = #line) {
        let result = analyze(function)
        XCTAssertTrue(result.refusalDetails.contains {
            C2DataflowCensus.GuardedConjunct(reason: $0.reason) != nil
        }, file: file, line: line)
    }

    private func guardedProducerFixture(_ producer: String, immediate: Bool, width: Int,
                                        suffix: String = "eq", selection: String = "csel",
                                        mismatch: String = "", singleBit: Bool = false) -> MacIRFunction {
        let prefix = width == 32 ? "w" : "x"
        func input(_ number: Int) -> MacIRValue { .register(name: "\(prefix)\(number)", version: 0) }
        let lhs = input(3)
        let rhs: MacIRValue = immediate ? .immediate(singleBit ? 8 : 3) : input(4)
        let sourceRight = immediate ? (singleBit ? "#8" : "#3") : "\(prefix)4"
        let logical = ["tst", "ands", "bics"].contains(producer)
        let logicalValue: MacIRValue
        if singleBit {
            logicalValue = .bitTest(value: lhs, bit: 3)
        } else {
            logicalValue = .binaryExpression(op: "&", left: lhs,
                right: producer == "bics" ? .unary(op: "~", value: rhs) : rhs)
        }
        var predicateLeft: MacIRValue = logical ? logicalValue : lhs
        var predicateRight: MacIRValue = logical ? .immediate(0) : rhs
        if mismatch == "predicate" {
            predicateLeft = logical
                ? .binaryExpression(op: "&", left: input(5), right: producer == "bics" ? .unary(op: "~", value: rhs) : rhs)
                : input(5)
        }
        if mismatch == "logicalShape" {
            predicateLeft = .binaryExpression(op: "|", left: lhs, right: rhs)
        }
        if mismatch == "bitIndex" { predicateLeft = .bitTest(value: lhs, bit: 2) }
        let isSigned = ["lt", "le", "gt", "ge"].contains(suffix)
        let isUnsigned = ["lo", "hs", "hi", "ls", "cc", "cs"].contains(suffix)
        if (isSigned || isUnsigned) && mismatch != "unprojected" {
            let castWidth = mismatch == "projectionWidth" ? (width == 32 ? 64 : 32) : width
            let useSigned = mismatch == "signedness" ? !isSigned : isSigned
            let cast = "(\(useSigned ? "int" : "uint")\(castWidth)_t)"
            predicateLeft = .unary(op: cast, value: predicateLeft)
            predicateRight = .unary(op: cast, value: predicateRight)
        }
        let relation: String
        switch suffix {
        case "eq": relation = "=="
        case "ne": relation = "!="
        case "lt", "lo", "cc": relation = "<"
        case "le", "ls": relation = "<="
        case "gt", "hi": relation = ">"
        default: relation = ">="
        }
        let inverse = ["eq": "ne", "ne": "eq", "lt": "ge", "ge": "lt", "le": "gt", "gt": "le",
                       "lo": "hs", "hs": "lo", "hi": "ls", "ls": "hi", "cc": "cs", "cs": "cc"]
        let alias = selection == "cinc" || selection == "cneg"
        var machineCondition = alias ? inverse[suffix]! : suffix
        if mismatch == "polarity" { machineCondition = inverse[machineCondition]! }
        let selectPrefix = mismatch == "width" ? (prefix == "w" ? "x" : "w") : prefix
        let yes = MacIRValue.register(name: "\(selectPrefix)1", version: 0)
        let noLeaf = alias ? yes : MacIRValue.register(name: "\(selectPrefix)2", version: 0)
        let no: MacIRValue
        switch selection {
        case "csinc", "cinc": no = .binaryExpression(op: "+", left: noLeaf, right: .immediate(1))
        case "csinv": no = .unary(op: "~", value: noLeaf)
        case "csneg", "cneg": no = .unary(op: "-", value: noLeaf)
        default: no = noLeaf
        }
        let producerOperands = ["cmp", "tst"].contains(producer)
            ? "\(prefix)3, \(sourceRight)" : "\(prefix)6, \(prefix)3, \(sourceRight)"
        let producerOperation: MacIROperation
        if producer == "subs" {
            producerOperation = .binary(destination: .register(name: "\(prefix)6", version: 1), op: "-", left: lhs, right: rhs)
        } else if producer == "ands" || producer == "bics" {
            producerOperation = .assign(destination: .register(name: "\(prefix)6", version: 1), source: logicalValue)
        } else {
            producerOperation = .intrinsic(destination: nil, name: "compare",
                arguments: logical ? [logicalValue, .immediate(0)] : [lhs, rhs])
        }
        var rows: [MacIRInstruction] = []
        if mismatch != "missing" {
            rows.append(instruction(0x7600, producer, producerOperands, producerOperation))
        }
        if mismatch == "competing" {
            rows.append(instruction(0x7604, "cmp", "\(prefix)5, #3",
                .intrinsic(destination: nil, name: "compare", arguments: [input(5), .immediate(3)])))
        }
        if mismatch == "ccmp" {
            rows.append(instruction(0x7604, "ccmp", "\(prefix)3, #3, #0, eq",
                .intrinsic(destination: nil, name: "compare", arguments: [lhs, .immediate(3)])))
        }
        if mismatch == "armOverwrite" {
            rows.append(instruction(0x7604, "mov", "\(selectPrefix)1, \(selectPrefix)7",
                .assign(destination: .register(name: "\(selectPrefix)1", version: 1),
                    source: .register(name: "\(selectPrefix)7", version: 0))))
        }
        let selectOperands = alias
            ? "\(selectPrefix)0, \(selectPrefix)1, \(machineCondition)"
            : "\(selectPrefix)0, \(selectPrefix)1, \(selectPrefix)2, \(machineCondition)"
        rows.append(instruction(0x7608, selection, selectOperands,
            .select(destination: .register(name: "\(selectPrefix)0", version: 1), condition: relation,
                left: predicateLeft, right: predicateRight, trueValue: yes, falseValue: no)))
        rows.append(instruction(0x760c, "ret", "", .returnValue(nil)))
        rows = rows.enumerated().map { offset, row in
            instruction(0x7600 + UInt64(offset * 4), row.source.mnemonic, row.source.operands, row.operation)
        }
        return MacIRFunction(name: "guarded_producer_matrix", startAddress: 0x7600,
            returnType: "void", instructions: rows)
    }

    // Authored source fixtures; execution is intentionally separate qualification.
    func testGuardedSelectFamilyCanonicalArmProof() {
        for mnemonic in ["csel", "csinc", "csinv", "csneg", "cinc", "cneg"] {
            for condition in ["==", "!="] {
                let result = analyze(guardedFamily(mnemonic, condition: condition))
                XCTAssertNil(result.skippedReason, "\(mnemonic) \(condition)")
                XCTAssertTrue(result.rows.isEmpty)
            }
        }
    }

    func testGuardedSelectFamilyCompetingPredicateAndOverwrite() {
        for mnemonic in ["csinc", "csinv", "csneg", "cinc", "cneg"] {
            for flags in [true, false] {
                var function = guardedFamily(mnemonic)
                function.instructions.insert(flags
                    ? instruction(0x7108, "cmp", "x4, #0", .intrinsic(destination: nil, name: "compare", arguments: [reg(4, 0), .immediate(0)]))
                    : instruction(0x7108, "mov", "x1, x4", .assign(destination: reg(1, 2), source: reg(4, 0))), at: 2)
                renumberGuardedSelect(&function)
                let alias = mnemonic == "cinc" || mnemonic == "cneg"
                assertGuardedRefusal(function, registers: flags && !alias ? ["x1", "x2"] : ["x1"])
            }
        }
    }

    func testGuardedSelectFamilyRejectsWidthAndPolarityMismatch() {
        for mnemonic in ["csinc", "csinv", "csneg", "cinc", "cneg"] {
            for mismatch in ["width", "polarity", "transform"] {
                let alias = mnemonic == "cinc" || mnemonic == "cneg"
                assertGuardedRefusal(guardedFamily(mnemonic, mismatch: mismatch),
                    registers: alias ? ["x1"] : ["x1", "x2"])
            }
        }
    }

    func testGuardedSelectFamilyRejectsDiamondAvailability() {
        for mnemonic in ["csinc", "csinv", "csneg", "cinc", "cneg"] {
            let select = guardedFamily(mnemonic).instructions[2]
            let function = MacIRFunction(name: "guarded_family_diamond", startAddress: 0x7200, returnType: "void", instructions: [
                instruction(0x7200, "cmp", "x3, #0", .intrinsic(destination: nil, name: "compare", arguments: [reg(3, 0), .immediate(0)])),
                instruction(0x7204, "cbz", "x4, 0x7210", .conditionalBranch(condition: "==", left: reg(4, 0), right: .immediate(0), target: .immediate(0x7210))),
                instruction(0x7208, "mov", "x1, x5", .assign(destination: reg(1, 1), source: reg(5, 0))),
                instruction(0x720c, "b", "0x7214", .intrinsic(destination: nil, name: "branch", arguments: [.immediate(0x7214)])),
                instruction(0x7210, "mov", "x1, x6", .assign(destination: reg(1, 2), source: reg(6, 0))),
                instruction(0x7214, select.source.mnemonic, select.source.operands, select.operation),
                instruction(0x7218, "ret", "", .returnValue(nil))
            ])
            assertGuardedRefusal(function, registers: ["x1"])
        }
    }

    private func guardedFamily(_ mnemonic: String, condition: String = "==", mismatch: String = "") -> MacIRFunction {
        var function = guardedSelect(condition: condition)
        let alias = mnemonic == "cinc" || mnemonic == "cneg"
        let canonical = mnemonic == "cinc" ? "csinc" : (mnemonic == "cneg" ? "csneg" : mnemonic)
        let source = alias ? reg(1, 1) : reg(2, 0)
        let falseValue: MacIRValue
        switch canonical {
        case "csinc": falseValue = .binaryExpression(op: "+", left: source, right: .immediate(mismatch == "transform" ? 2 : 1))
        case "csinv": falseValue = .unary(op: mismatch == "transform" ? "-" : "~", value: source)
        case "csneg": falseValue = .unary(op: mismatch == "transform" ? "~" : "-", value: source)
        default: falseValue = source
        }
        let expected = condition == "==" ? "eq" : "ne"
        var spelling = alias ? (expected == "eq" ? "ne" : "eq") : expected
        if mismatch == "polarity" { spelling = spelling == "eq" ? "ne" : "eq" }
        let destination = mismatch == "width" ? "w0" : "x0"
        let operands = alias ? "\(destination), x1, \(spelling)" : "\(destination), x1, x2, \(spelling)"
        function.instructions[2] = instruction(0x7108, mnemonic, operands,
            .select(destination: reg(0, 1), condition: condition, left: reg(3, 0), right: .immediate(0), trueValue: reg(1, 1), falseValue: falseValue))
        return function
    }

    func testDOnlyCallProjectionPreservesOnlyLow64Candidate() {
        let function = partialBankFixture(displayed: .register(name: "d8", version: 0))
        let rows = function.instructions.map(\.source)
        XCTAssertEqual(C2MachineFlow(rows: rows).error,
            "call with v8-v15 use requires partial-register reaching definitions")
        let projected = C2MachineFlow(rows: rows, permitDOnlyCallProjection: true)
        XCTAssertNil(projected.error)
        XCTAssertEqual(projected.before[1]["v8"], Set([UInt64(0)]))
        XCTAssertNil(analyze(function).skippedReason)
    }

    func testDOnlyCallProjectionRejectsEveryOtherMachineAlias() {
        for alias in ["q8", "v8", "s8", "h8", "b8", "q15", "v15"] {
            var rows = partialBankFixture(displayed: .register(name: "d8", version: 0)).instructions.map(\.source)
            rows[1] = .init(address: 0x7804, byteText: "00 00 00 00", mnemonic: "str", operands: "\(alias), [x0]")
            XCTAssertEqual(C2MachineFlow(rows: rows, permitDOnlyCallProjection: true).error,
                "call with v8-v15 use requires partial-register reaching definitions")
        }
    }

    func testDOnlyMachineCannotCertifyUpperDisplayedOrProjectedValue() {
        let values: [MacIRValue] = [.register(name: "q8", version: 0),
                                 .register(name: "v8", version: 0),
                                 .unary(op: "__ssa_high64", value: .register(name: "d8", version: 0))]
        for value in values {
            XCTAssertEqual(analyze(partialBankFixture(displayed: value)).detectorSkippedReason,
                "call with v8-v15 use requires partial-register reaching definitions")
        }
    }

    func testExplicitLow64SaveProjectionIsNotWholeVectorPreservation() {
        for low in ["__low64", "__ssa_low64"] {
            let saved = MacIRValue.unary(op: "__ssa_bitcast_f64",
                value: .unary(op: low, value: .register(name: "v8", version: 0)))
            XCTAssertNil(analyze(partialBankFixture(displayed: saved)).detectorSkippedReason)
        }
        for op in ["__high64", "__ssa_high64", "unknown_wrapper", "__bitcast_f32"] {
            let value = MacIRValue.unary(op: op, value: .register(name: "v8", version: 0))
            XCTAssertEqual(analyze(partialBankFixture(displayed: value)).detectorSkippedReason,
                "call with v8-v15 use requires partial-register reaching definitions")
        }
        let arbitraryBitcast = MacIRValue.unary(op: "__bitcast_f64", value: .register(name: "v8", version: 0))
        XCTAssertEqual(analyze(partialBankFixture(displayed: arbitraryBitcast)).detectorSkippedReason,
            "call with v8-v15 use requires partial-register reaching definitions")
    }

    func testLow64ProjectionRejectsHiddenWidePhiAndHighAssignment() {
        for width in [64, 128] {
            var function = partialBankFixture(displayed: .register(name: "d8", version: 0))
            function.phis = [MacIRPhi(blockAddress: 0x7804,
                destination: .register(name: width == 64 ? "q8" : "d8", version: 1), bitWidth: width,
                incoming: [.init(predecessorAddress: 0x7800, value: .register(name: "d8", version: 0))])]
            XCTAssertEqual(analyze(function).detectorSkippedReason,
                "call with v8-v15 use requires partial-register reaching definitions")
        }
        var function = partialBankFixture(displayed: .register(name: "d8", version: 0))
        function.instructions[1] = instruction(0x7804, "str", "d8, [sp]",
            .assign(destination: .register(name: "d9", version: 1),
                source: .unary(op: "__ssa_high64", value: .register(name: "v8", version: 0))))
        XCTAssertEqual(analyze(function).detectorSkippedReason,
            "call with v8-v15 use requires partial-register reaching definitions")
    }

    func testPartialLaneLoadKeepsPriorLaneRefusal() {
        // H lanes now have an exact RMW rule. A real B-lane encoding remains
        // outside that rule; do not retain a supported H form as a negative.
        let row = MacIRSourceSpan(address: 0x7900, byteText: "81 01 40 0d",
            mnemonic: "ld1", operands: "{v1.b}[0], [x12]")
        XCTAssertEqual(C2MachineFlow(rows: [row], permitDOnlyCallProjection: true).error,
            "0x7900: partial vector lane load")
    }

    func testCFGRefusalClassesRemainCountedWithoutInventedReachability() {
        let reasons: [MacIRRefusal.Reason] = [.unreachableBlock, .irreducibleLoop]
        for reason in reasons {
            var function = join(merged: true)
            function.ssaEnabled = true
            function.refusals = [.init(reason: reason, scope: .block(1), detail: "retained refusal fixture")]
            let result = analyze(function, ssaAccountingEnabled: true)
            XCTAssertTrue(result.lifterRefusals.contains { $0.reason == reason })
            XCTAssertTrue(result.skippedReason?.contains("lifter " + reason.rawValue) == true)
        }
    }

    private func partialBankFixture(displayed: MacIRValue) -> MacIRFunction {
        MacIRFunction(name: "low_bank", startAddress: 0x7800, returnType: "void", instructions: [
            instruction(0x7800, "bl", "0x9000", .intrinsic(destination: nil, name: "nop", arguments: [])),
            instruction(0x7804, "str", "d8, [sp]", .store(source: displayed, address: .register(name: "sp", version: 0))),
            instruction(0x7808, "ret", "", .returnValue(nil))
        ])
    }

    func testGuardedSelectAllPathCompareZeroProof() {
        for condition in ["==", "!="] {
            let result = analyze(guardedSelect(condition: condition))
            XCTAssertNil(result.skippedReason)
            XCTAssertTrue(result.rows.isEmpty)
        }
    }

    func testGuardedSelectRetainsUnsupportedPredicateAndPolarity() {
        for condition in ["<", "!="] {
            let result = analyze(guardedSelect(condition: condition, machineCondition: "eq"))
            XCTAssertTrue(result.refusalDetails.contains { C2DataflowCensus.GuardedConjunct(reason: $0.reason) != nil })
        }
    }

    func testGuardedSelectRetainsFlagOverwrite() {
        var function = guardedSelect()
        // The overwritten flags test a different input from the printed predicate.
        function.instructions.insert(instruction(0x7106, "cmp", "x4, #0",
            .intrinsic(destination: nil, name: "compare", arguments: [reg(4, 0), .immediate(0)])), at: 2)
        // Keep machine addresses contiguous; the select now follows the overwrite.
        function.instructions = function.instructions.enumerated().map { offset, row in
            instruction(0x7100 + UInt64(offset * 4), row.source.mnemonic, row.source.operands, row.operation)
        }
        let result = analyze(function)
        XCTAssertTrue(result.refusalDetails.contains { C2DataflowCensus.GuardedConjunct(reason: $0.reason) != nil })
    }

    func testGuardedSelectRetainsSiblingDefinitionAndFlagJoin() {
        for overwriteFlags in [false, true] {
            let function = MacIRFunction(name: "guarded_join", startAddress: 0x7200, returnType: "void", instructions: [
                instruction(0x7200, "cmp", "x3, #0", .intrinsic(destination: nil, name: "compare", arguments: [reg(3, 0), .immediate(0)])),
                instruction(0x7204, "cbz", "x4, 0x7210", .conditionalBranch(condition: "==", left: reg(4, 0), right: .immediate(0), target: .immediate(0x7210))),
                instruction(0x7208, "mov", "x1, x5", .assign(destination: reg(1, 1), source: reg(5, 0))),
                instruction(0x720c, "b", "0x7214", .intrinsic(destination: nil, name: "branch", arguments: [.immediate(0x7214)])),
                overwriteFlags
                    ? instruction(0x7210, "cmp", "x3, #0", .intrinsic(destination: nil, name: "compare", arguments: [reg(3, 0), .immediate(0)]))
                    : instruction(0x7210, "mov", "x1, x6", .assign(destination: reg(1, 2), source: reg(6, 0))),
                instruction(0x7214, "csel", "x0, x1, x2, eq", .select(destination: reg(0, 1), condition: "==", left: reg(3, 0), right: .immediate(0), trueValue: reg(1, 1), falseValue: reg(2, 0))),
                instruction(0x7218, "ret", "", .returnValue(nil))
            ])
            let result = analyze(function)
            XCTAssertTrue(result.refusalDetails.contains { C2DataflowCensus.GuardedConjunct(reason: $0.reason) != nil })
        }
    }

    func testGuardedSelectRetainsAmbiguousDefinition() {
        var function = guardedSelect()
        function.instructions.insert(instruction(0x7100, "mov", "x1, x5",
            .assign(destination: reg(1, 1), source: reg(5, 0))), at: 0)
        function.instructions = function.instructions.enumerated().map { offset, row in
            instruction(0x7100 + UInt64(offset * 4), row.source.mnemonic, row.source.operands, row.operation)
        }
        let result = analyze(function)
        XCTAssertTrue(result.refusalDetails.contains { C2DataflowCensus.GuardedConjunct(reason: $0.reason) != nil })
    }

    func testGuardedSelectRetainsPhiIdentity() {
        var function = guardedSelect()
        function.instructions.insert(instruction(0x7108, "b", "0x710c",
            .intrinsic(destination: nil, name: "branch", arguments: [.immediate(0x710c)])), at: 2)
        function.instructions[3] = instruction(0x710c, "csel", "x0, x1, x2, eq",
            .select(destination: reg(0, 1), condition: "==", left: reg(3, 0), right: .immediate(0),
                trueValue: reg(1, 2), falseValue: reg(2, 0)))
        renumberGuardedSelect(&function)
        function.phis = [MacIRPhi(blockAddress: 0x710c, destination: reg(1, 2), bitWidth: 64,
            incoming: [.init(predecessorAddress: 0x7108, value: reg(1, 1))])]
        let result = analyze(function, expectedPrintedValue: reg(1, 2), expectedUseAddress: 0x710c)
        XCTAssertTrue(result.refusalDetails.contains { C2DataflowCensus.GuardedConjunct(reason: $0.reason) != nil })
    }

    func testGuardedSelectRetainsNarrowRegisterView() {
        var function = guardedSelect()
        function.instructions[2] = instruction(0x7108, "csel", "x0, x1, x2, eq",
            .select(destination: reg(0, 1), condition: "==", left: reg(3, 0), right: .immediate(0),
                trueValue: .register(name: "w1", version: 1), falseValue: reg(2, 0)))
        let result = analyze(function)
        XCTAssertTrue(result.refusalDetails.contains { C2DataflowCensus.GuardedConjunct(reason: $0.reason) != nil })
    }

    func testGuardedSelectPredicateSnapshotSurvivesLaterRegisterWrite() {
        var function = guardedSelect()
        function.instructions.insert(instruction(0x7108, "mov", "x3, x4",
            .assign(destination: reg(3, 1), source: reg(4, 0))), at: 2)
        renumberGuardedSelect(&function)
        let result = analyze(function)
        XCTAssertNil(result.skippedReason, "NZCV still tests the displayed entry x3 snapshot")
        XCTAssertTrue(result.rows.isEmpty)
    }

    func testGuardedSelectRejectsStalePredicateRegisterAsArm() {
        var function = guardedSelect()
        function.instructions.insert(instruction(0x7108, "mov", "x3, x4",
            .assign(destination: reg(3, 1), source: reg(4, 0))), at: 2)
        function.instructions[3] = instruction(0x710c, "csel", "x0, x3, x2, eq",
            .select(destination: reg(0, 1), condition: "==", left: reg(3, 0), right: .immediate(0),
                trueValue: reg(3, 0), falseValue: reg(2, 0)))
        renumberGuardedSelect(&function)
        assertGuardedRefusal(function, registers: ["x3"])
    }

    func testGuardedSelectProofDoesNotTransferBetweenArms() {
        for staleTrueArm in [true, false] {
            var function = guardedSelect()
            function.instructions[2] = instruction(0x7108, "csel", "x0, x1, x2, eq",
                .select(destination: reg(0, 1), condition: "==", left: reg(3, 0), right: .immediate(0),
                    trueValue: reg(1, staleTrueArm ? 0 : 1), falseValue: reg(2, staleTrueArm ? 0 : 1)))
            assertGuardedRefusal(function, registers: [staleTrueArm ? "x1" : "x2"])
        }
    }

    func testGuardedSelectSameRegisterArmsNeedIndependentIdentities() {
        for staleFalseArm in [false, true] {
            var function = guardedSelect()
            function.instructions[2] = instruction(0x7108, "csel", "x0, x1, x1, eq",
                .select(destination: reg(0, 1), condition: "==", left: reg(3, 0), right: .immediate(0),
                    trueValue: reg(1, 1), falseValue: reg(1, staleFalseArm ? 0 : 1)))
            if staleFalseArm {
                assertGuardedRefusal(function, registers: ["x1"])
            } else {
                let result = analyze(function)
                XCTAssertNil(result.skippedReason)
                XCTAssertTrue(result.rows.isEmpty)
            }
        }
    }

    func testGuardedSelectDestinationAliasReadsPriorDefinition() {
        for selfReference in [false, true] {
            var function = guardedSelect()
            function.instructions[2] = instruction(0x7108, "csel", "x1, x1, x2, eq",
                .select(destination: reg(1, 2), condition: "==", left: reg(3, 0), right: .immediate(0),
                    trueValue: reg(1, selfReference ? 2 : 1), falseValue: reg(2, 0)))
            if selfReference {
                assertGuardedRefusal(function, registers: ["x1"])
            } else {
                let result = analyze(function)
                XCTAssertNil(result.skippedReason)
                XCTAssertTrue(result.rows.isEmpty)
            }
        }
    }

    func testGuardedSelectRejectsZeroRegisterArms() {
        for zero in ["xzr", "wzr"] {
            var function = guardedSelect()
            function.instructions[2] = instruction(0x7108, "csel", "x0, x1, \(zero), eq",
                .select(destination: reg(0, 1), condition: "==", left: reg(3, 0), right: .immediate(0),
                    trueValue: reg(1, 1), falseValue: .register(name: zero, version: 0)))
            assertGuardedRefusal(function, registers: ["x1"])
        }
    }

    func testGuardedSelectRejectsUnsupportedOrMismatchedFlagProducers() {
        // SUBS is now supported, but mismatching its RHS still cannot prove
        // the unchanged printed comparison against zero. CMN stays unsupported.
        for opcode in ["cmn", "subs"] {
            var function = guardedSelect()
            function.instructions[1] = instruction(0x7104, opcode,
                opcode == "cmn" ? "x3, #0" : "x4, x3, #1",
                .intrinsic(destination: nil, name: "compare", arguments: [reg(3, 0), .immediate(0)]))
            assertGuardedRefusal(function, registers: ["x1", "x2"])
        }
    }

    func testGuardedSelectRejectsNonzeroCompareAndSwappedSources() {
        for swapped in [false, true] {
            var function = guardedSelect()
            if swapped {
                function.instructions[2].source.operands = "x0, x2, x1, eq"
            } else {
                function.instructions[1].source.operands = "x3, #1"
            }
            assertGuardedRefusal(function, registers: ["x1", "x2"])
        }
    }

    func testGuardedSelectRejectsLoopBackedgeArmDefinition() {
        let function = MacIRFunction(name: "guarded_loop", startAddress: 0x7300, returnType: "void", instructions: [
            instruction(0x7300, "mov", "x1, x5", .assign(destination: reg(1, 1), source: reg(5, 0))),
            instruction(0x7304, "cmp", "x3, #0", .intrinsic(destination: nil, name: "compare", arguments: [reg(3, 0), .immediate(0)])),
            instruction(0x7308, "csel", "x0, x1, x2, eq", .select(destination: reg(0, 1), condition: "==",
                left: reg(3, 0), right: .immediate(0), trueValue: reg(1, 2), falseValue: reg(2, 0))),
            instruction(0x730c, "mov", "x1, x6", .assign(destination: reg(1, 2), source: reg(6, 0))),
            instruction(0x7310, "cbnz", "x4, 0x7304", .conditionalBranch(condition: "!=", left: reg(4, 0), right: .immediate(0), target: .immediate(0x7304))),
            instruction(0x7314, "ret", "", .returnValue(nil))
        ])
        let flow = C2MachineFlow(rows: function.instructions.map(\.source))
        XCTAssertNil(flow.error)
        XCTAssertEqual(flow.before[2]["nzcv"], [0x7304])
        XCTAssertTrue(flow.dominates(1, 2))
        XCTAssertEqual(flow.before[2]["x1"], [0x7300, 0x730c])
        assertGuardedRefusal(function, registers: ["x1"])
    }

    private func renumberGuardedSelect(_ function: inout MacIRFunction) {
        function.instructions = function.instructions.enumerated().map { offset, row in
            instruction(0x7100 + UInt64(offset * 4), row.source.mnemonic, row.source.operands, row.operation)
        }
    }

    private func assertGuardedRefusal(_ function: MacIRFunction, registers: Set<String>,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let result = analyze(function)
        let refusals = result.refusalDetails.filter { C2DataflowCensus.GuardedConjunct(reason: $0.reason) != nil }
        XCTAssertEqual(Set(refusals.compactMap(\.register)), registers, file: file, line: line)
    }

    private func guardedSelect(condition: String = "==", machineCondition: String? = nil) -> MacIRFunction {
        MacIRFunction(name: "guarded_all_paths", startAddress: 0x7100, returnType: "void", instructions: [
            instruction(0x7100, "mov", "x1, x5", .assign(destination: reg(1, 1), source: reg(5, 0))),
            instruction(0x7104, "cmp", "x3, #0", .intrinsic(destination: nil, name: "compare", arguments: [reg(3, 0), .immediate(0)])),
            instruction(0x7108, "csel", "x0, x1, x2, \(machineCondition ?? (condition == "==" ? "eq" : "ne"))",
                .select(destination: reg(0, 1), condition: condition, left: reg(3, 0), right: .immediate(0), trueValue: reg(1, 1), falseValue: reg(2, 0))),
            instruction(0x710c, "ret", "", .returnValue(nil))
        ])
    }

    func testConditionalCompareIncomingFlagOperandProvenance() {
        for condition in ["eq", "ge", "lt"] {
            let function = conditionalFlagFunction(condition: condition)
            let result = analyze(function, expectedPrintedValue: reg(9, 1), expectedUseAddress: 0x800c)
            XCTAssertFalse(result.refusalDetails.contains {
                $0.reason == "predicate operand provenance is not a direct flag-producer input"
            })
            XCTAssertTrue(result.rows.isEmpty)
        }
    }

    func testUnconditionalCompareDoesNotReadIncomingFlagOperand() {
        for condition in ["al", "nv"] {
            let result = analyze(conditionalFlagFunction(condition: condition))
            XCTAssertTrue(result.refusalDetails.contains {
                $0.reason == "predicate operand provenance is not a direct flag-producer input"
            })
        }
    }

    func testUnrelatedPredicateRegisterIsNotAnIncomingFlagOperand() {
        let result = analyze(conditionalFlagFunction(condition: "eq", predicate: reg(11, 0)))
        XCTAssertTrue(result.refusalDetails.contains {
            $0.reason == "predicate operand provenance is not a direct flag-producer input"
        })
    }

    func testDifferentRegisterWidthIsNotAnIncomingFlagOperand() {
        let result = analyze(conditionalFlagFunction(condition: "eq",
            predicate: .register(name: "w9", version: 1)))
        XCTAssertTrue(result.refusalDetails.contains {
            $0.reason == "predicate operand provenance is not a direct flag-producer input"
        })
    }

    func testIncomingFlagDiamondRemainsRefused() {
        let function = MacIRFunction(name: "conditional_flag_diamond", startAddress: 0x8100,
            returnType: "void", instructions: [
                instruction(0x8100, "cbz", "x0, 0x810c", .conditionalBranch(condition: "==",
                    left: reg(0, 0), right: .immediate(0), target: .immediate(0x810c))),
                instruction(0x8104, "cmp", "x9, #0", .intrinsic(destination: nil,
                    name: "compare", arguments: [reg(9, 0), .immediate(0)])),
                instruction(0x8108, "b", "0x8110", .intrinsic(destination: nil,
                    name: "branch", arguments: [.immediate(0x8110)])),
                instruction(0x810c, "cmp", "x9, #1", .intrinsic(destination: nil,
                    name: "compare", arguments: [reg(9, 0), .immediate(1)])),
                instruction(0x8110, "ccmp", "x10, #3, #2, eq", .intrinsic(destination: nil,
                    name: "conditional_compare_eq", arguments: [reg(10, 0), .immediate(3), .immediate(2)])),
                instruction(0x8114, "b.eq", "0x811c", .conditionalBranch(condition: "==",
                    left: reg(9, 0), right: .immediate(0), target: .immediate(0x811c))),
                instruction(0x8118, "ret", "", .returnValue(nil)),
                instruction(0x811c, "ret", "", .returnValue(nil))
            ])
        let result = analyze(function)
        XCTAssertTrue(result.refusalDetails.contains {
            $0.reason == "predicate operand provenance is not a direct flag-producer input"
        })
    }

    func testMalformedConditionalCompareRolesRemainRefused() {
        for (name, arguments) in [
            ("conditional_compare_ge", [reg(10, 0), .immediate(3), .immediate(2)]),
            ("conditional_compare_eq", [reg(10, 0), .immediate(3)]),
            ("conditional_compare_eq", [reg(10, 0), .immediate(3), .immediate(16)])
        ] {
            let function = MacIRFunction(name: "malformed_conditional_roles", startAddress: 0x8200,
                returnType: "void", instructions: [
                    instruction(0x8200, "ccmp", "x10, #3, #2, eq", .intrinsic(
                        destination: nil, name: name, arguments: arguments)),
                    instruction(0x8204, "ret", "", .returnValue(nil))
                ])
            let result = analyze(function)
            XCTAssertTrue(result.refusalDetails.contains {
                $0.reason.hasPrefix("unsupported intrinsic operand roles:")
            })
        }
    }

    func testConditionalRoleDeclarationDoesNotGrantUnrelatedMachineRead() {
        let function = MacIRFunction(name: "unrelated_conditional_input", startAddress: 0x8300,
            returnType: "void", instructions: [
                instruction(0x8300, "ccmp", "x10, #3, #2, eq", .intrinsic(destination: nil,
                    name: "conditional_compare_eq", arguments: [reg(11, 0), .immediate(3), .immediate(2)])),
                instruction(0x8304, "ret", "", .returnValue(nil))
            ])
        let result = analyze(function)
        XCTAssertTrue(result.refusalDetails.contains {
            $0.reason == "printed operand is not a direct machine read"
        })
    }

    // Authored byte-backed fixtures; all execution outcomes remain unmeasured.
    func testStructureLaneST1BNoIndexLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d000184, mnemonic: "st1",
                text: "{v4.b}[0], [x12]", elements: 1, elementBytes: 1, lane: 0,
                vectors: [4], oldBase: 0x1000, newBase: 0x1000, expected: [0x04])
            try assertStructureStore(word: 0x4d001d9e, mnemonic: "st1",
                text: "{v30.b}[15], [x12]", elements: 1, elementBytes: 1, lane: 15,
                vectors: [30], oldBase: 0x1001, newBase: 0x1001, expected: [0x2d])
        }
    }

    func testStructureLaneST1BFixedPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d9f0184, mnemonic: "st1",
                text: "{v4.b}[0], [x12], #1", elements: 1, elementBytes: 1, lane: 0,
                vectors: [4], oldBase: 0x1000, newBase: 0x1001, expected: [0x04])
            try assertStructureStore(word: 0x4d9f1d9e, mnemonic: "st1",
                text: "{v30.b}[15], [x12], #1", elements: 1, elementBytes: 1, lane: 15,
                vectors: [30], oldBase: 0x1001, newBase: 0x1002, expected: [0x2d])
        }
    }

    func testStructureLaneST1HNoIndexLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d004184, mnemonic: "st1",
                text: "{v4.h}[0], [x12]", elements: 1, elementBytes: 2, lane: 0,
                vectors: [4], oldBase: 0x1000, newBase: 0x1000, expected: [0x04, 0x05])
            try assertStructureStore(word: 0x4d00599e, mnemonic: "st1",
                text: "{v30.h}[7], [x12]", elements: 1, elementBytes: 2, lane: 7,
                vectors: [30], oldBase: 0x1001, newBase: 0x1001, expected: [0x2c, 0x2d])
        }
    }

    func testStructureLaneST1HFixedPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d9f4184, mnemonic: "st1",
                text: "{v4.h}[0], [x12], #2", elements: 1, elementBytes: 2, lane: 0,
                vectors: [4], oldBase: 0x1000, newBase: 0x1002, expected: [0x04, 0x05])
            try assertStructureStore(word: 0x4d9f599e, mnemonic: "st1",
                text: "{v30.h}[7], [x12], #2", elements: 1, elementBytes: 2, lane: 7,
                vectors: [30], oldBase: 0x1001, newBase: 0x1003, expected: [0x2c, 0x2d])
        }
    }

    func testStructureLaneST1SNoIndexLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d008184, mnemonic: "st1",
                text: "{v4.s}[0], [x12]", elements: 1, elementBytes: 4, lane: 0,
                vectors: [4], oldBase: 0x1000, newBase: 0x1000, expected: [0x04, 0x05, 0x06, 0x07])
            try assertStructureStore(word: 0x4d00919e, mnemonic: "st1",
                text: "{v30.s}[3], [x12]", elements: 1, elementBytes: 4, lane: 3,
                vectors: [30], oldBase: 0x1001, newBase: 0x1001, expected: [0x2a, 0x2b, 0x2c, 0x2d])
        }
    }

    func testStructureLaneST1SFixedPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d9f8184, mnemonic: "st1",
                text: "{v4.s}[0], [x12], #4", elements: 1, elementBytes: 4, lane: 0,
                vectors: [4], oldBase: 0x1000, newBase: 0x1004, expected: [0x04, 0x05, 0x06, 0x07])
            try assertStructureStore(word: 0x4d9f919e, mnemonic: "st1",
                text: "{v30.s}[3], [x12], #4", elements: 1, elementBytes: 4, lane: 3,
                vectors: [30], oldBase: 0x1001, newBase: 0x1005, expected: [0x2a, 0x2b, 0x2c, 0x2d])
        }
    }

    func testStructureLaneST1DNoIndexLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d008584, mnemonic: "st1",
                text: "{v4.d}[0], [x12]", elements: 1, elementBytes: 8, lane: 0,
                vectors: [4], oldBase: 0x1000, newBase: 0x1000, expected: [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b])
            try assertStructureStore(word: 0x4d00859e, mnemonic: "st1",
                text: "{v30.d}[1], [x12]", elements: 1, elementBytes: 8, lane: 1,
                vectors: [30], oldBase: 0x1001, newBase: 0x1001, expected: [0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d])
        }
    }

    func testStructureLaneST1DFixedPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d9f8584, mnemonic: "st1",
                text: "{v4.d}[0], [x12], #8", elements: 1, elementBytes: 8, lane: 0,
                vectors: [4], oldBase: 0x1000, newBase: 0x1008, expected: [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b])
            try assertStructureStore(word: 0x4d9f859e, mnemonic: "st1",
                text: "{v30.d}[1], [x12], #8", elements: 1, elementBytes: 8, lane: 1,
                vectors: [30], oldBase: 0x1001, newBase: 0x1009, expected: [0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d])
        }
    }

    func testStructureLaneST2BNoIndexLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d200184, mnemonic: "st2",
                text: "{v4.b, v5.b}[0], [x12]", elements: 2, elementBytes: 1, lane: 0,
                vectors: [4, 5], oldBase: 0x1000, newBase: 0x1000, expected: [0x04, 0x05])
            try assertStructureStore(word: 0x4d201d9e, mnemonic: "st2",
                text: "{v30.b, v31.b}[15], [x12]", elements: 2, elementBytes: 1, lane: 15,
                vectors: [30, 31], oldBase: 0x1001, newBase: 0x1001, expected: [0x2d, 0x2e])
        }
    }

    func testStructureLaneST2BFixedPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0dbf0184, mnemonic: "st2",
                text: "{v4.b, v5.b}[0], [x12], #2", elements: 2, elementBytes: 1, lane: 0,
                vectors: [4, 5], oldBase: 0x1000, newBase: 0x1002, expected: [0x04, 0x05])
            try assertStructureStore(word: 0x4dbf1d9e, mnemonic: "st2",
                text: "{v30.b, v31.b}[15], [x12], #2", elements: 2, elementBytes: 1, lane: 15,
                vectors: [30, 31], oldBase: 0x1001, newBase: 0x1003, expected: [0x2d, 0x2e])
        }
    }

    func testStructureLaneST2HNoIndexLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d204184, mnemonic: "st2",
                text: "{v4.h, v5.h}[0], [x12]", elements: 2, elementBytes: 2, lane: 0,
                vectors: [4, 5], oldBase: 0x1000, newBase: 0x1000, expected: [0x04, 0x05, 0x05, 0x06])
            try assertStructureStore(word: 0x4d20599e, mnemonic: "st2",
                text: "{v30.h, v31.h}[7], [x12]", elements: 2, elementBytes: 2, lane: 7,
                vectors: [30, 31], oldBase: 0x1001, newBase: 0x1001, expected: [0x2c, 0x2d, 0x2d, 0x2e])
        }
    }

    func testStructureLaneST2HFixedPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0dbf4184, mnemonic: "st2",
                text: "{v4.h, v5.h}[0], [x12], #4", elements: 2, elementBytes: 2, lane: 0,
                vectors: [4, 5], oldBase: 0x1000, newBase: 0x1004, expected: [0x04, 0x05, 0x05, 0x06])
            try assertStructureStore(word: 0x4dbf599e, mnemonic: "st2",
                text: "{v30.h, v31.h}[7], [x12], #4", elements: 2, elementBytes: 2, lane: 7,
                vectors: [30, 31], oldBase: 0x1001, newBase: 0x1005, expected: [0x2c, 0x2d, 0x2d, 0x2e])
        }
    }

    func testStructureLaneST2SNoIndexLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d208184, mnemonic: "st2",
                text: "{v4.s, v5.s}[0], [x12]", elements: 2, elementBytes: 4, lane: 0,
                vectors: [4, 5], oldBase: 0x1000, newBase: 0x1000, expected: [0x04, 0x05, 0x06, 0x07, 0x05, 0x06, 0x07, 0x08])
            try assertStructureStore(word: 0x4d20919e, mnemonic: "st2",
                text: "{v30.s, v31.s}[3], [x12]", elements: 2, elementBytes: 4, lane: 3,
                vectors: [30, 31], oldBase: 0x1001, newBase: 0x1001, expected: [0x2a, 0x2b, 0x2c, 0x2d, 0x2b, 0x2c, 0x2d, 0x2e])
        }
    }

    func testStructureLaneST2SFixedPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0dbf8184, mnemonic: "st2",
                text: "{v4.s, v5.s}[0], [x12], #8", elements: 2, elementBytes: 4, lane: 0,
                vectors: [4, 5], oldBase: 0x1000, newBase: 0x1008, expected: [0x04, 0x05, 0x06, 0x07, 0x05, 0x06, 0x07, 0x08])
            try assertStructureStore(word: 0x4dbf919e, mnemonic: "st2",
                text: "{v30.s, v31.s}[3], [x12], #8", elements: 2, elementBytes: 4, lane: 3,
                vectors: [30, 31], oldBase: 0x1001, newBase: 0x1009, expected: [0x2a, 0x2b, 0x2c, 0x2d, 0x2b, 0x2c, 0x2d, 0x2e])
        }
    }

    func testStructureLaneST2DNoIndexLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d208584, mnemonic: "st2",
                text: "{v4.d, v5.d}[0], [x12]", elements: 2, elementBytes: 8, lane: 0,
                vectors: [4, 5], oldBase: 0x1000, newBase: 0x1000, expected: [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c])
            try assertStructureStore(word: 0x4d20859e, mnemonic: "st2",
                text: "{v30.d, v31.d}[1], [x12]", elements: 2, elementBytes: 8, lane: 1,
                vectors: [30, 31], oldBase: 0x1001, newBase: 0x1001, expected: [0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e])
        }
    }

    func testStructureLaneST2DFixedPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0dbf8584, mnemonic: "st2",
                text: "{v4.d, v5.d}[0], [x12], #16", elements: 2, elementBytes: 8, lane: 0,
                vectors: [4, 5], oldBase: 0x1000, newBase: 0x1010, expected: [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c])
            try assertStructureStore(word: 0x4dbf859e, mnemonic: "st2",
                text: "{v30.d, v31.d}[1], [x12], #16", elements: 2, elementBytes: 8, lane: 1,
                vectors: [30, 31], oldBase: 0x1001, newBase: 0x1011, expected: [0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e])
        }
    }

    func testStructureLaneST3BNoIndexLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d002184, mnemonic: "st3",
                text: "{v4.b, v5.b, v6.b}[0], [x12]", elements: 3, elementBytes: 1, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x1000, expected: [0x04, 0x05, 0x06])
            try assertStructureStore(word: 0x4d003d9e, mnemonic: "st3",
                text: "{v30.b, v31.b, v0.b}[15], [x12]", elements: 3, elementBytes: 1, lane: 15,
                vectors: [30, 31, 0], oldBase: 0x1001, newBase: 0x1001, expected: [0x2d, 0x2e, 0x0f])
        }
    }

    func testStructureLaneST3BFixedPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d9f2184, mnemonic: "st3",
                text: "{v4.b, v5.b, v6.b}[0], [x12], #3", elements: 3, elementBytes: 1, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x1003, expected: [0x04, 0x05, 0x06])
            try assertStructureStore(word: 0x4d9f3d9e, mnemonic: "st3",
                text: "{v30.b, v31.b, v0.b}[15], [x12], #3", elements: 3, elementBytes: 1, lane: 15,
                vectors: [30, 31, 0], oldBase: 0x1001, newBase: 0x1004, expected: [0x2d, 0x2e, 0x0f])
        }
    }

    func testStructureLaneST3BRegisterPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d8d2184, mnemonic: "st3",
                text: "{v4.b, v5.b, v6.b}[0], [x12], x13", elements: 3, elementBytes: 1, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x1006, expected: [0x04, 0x05, 0x06])
            try assertStructureStore(word: 0x4d8c3d9e, mnemonic: "st3",
                text: "{v30.b, v31.b, v0.b}[15], [x12], x12", elements: 3, elementBytes: 1, lane: 15,
                vectors: [30, 31, 0], oldBase: 0x1001, newBase: 0x2002, expected: [0x2d, 0x2e, 0x0f])
        }
    }

    func testStructureLaneST3HNoIndexLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d006184, mnemonic: "st3",
                text: "{v4.h, v5.h, v6.h}[0], [x12]", elements: 3, elementBytes: 2, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x1000, expected: [0x04, 0x05, 0x05, 0x06, 0x06, 0x07])
            try assertStructureStore(word: 0x4d00799e, mnemonic: "st3",
                text: "{v30.h, v31.h, v0.h}[7], [x12]", elements: 3, elementBytes: 2, lane: 7,
                vectors: [30, 31, 0], oldBase: 0x1001, newBase: 0x1001, expected: [0x2c, 0x2d, 0x2d, 0x2e, 0x0e, 0x0f])
        }
    }

    func testStructureLaneST3HFixedPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d9f6184, mnemonic: "st3",
                text: "{v4.h, v5.h, v6.h}[0], [x12], #6", elements: 3, elementBytes: 2, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x1006, expected: [0x04, 0x05, 0x05, 0x06, 0x06, 0x07])
            try assertStructureStore(word: 0x4d9f799e, mnemonic: "st3",
                text: "{v30.h, v31.h, v0.h}[7], [x12], #6", elements: 3, elementBytes: 2, lane: 7,
                vectors: [30, 31, 0], oldBase: 0x1001, newBase: 0x1007, expected: [0x2c, 0x2d, 0x2d, 0x2e, 0x0e, 0x0f])
        }
    }

    func testStructureLaneST3HRegisterPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d8d6184, mnemonic: "st3",
                text: "{v4.h, v5.h, v6.h}[0], [x12], x13", elements: 3, elementBytes: 2, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x1006, expected: [0x04, 0x05, 0x05, 0x06, 0x06, 0x07])
            try assertStructureStore(word: 0x4d8c799e, mnemonic: "st3",
                text: "{v30.h, v31.h, v0.h}[7], [x12], x12", elements: 3, elementBytes: 2, lane: 7,
                vectors: [30, 31, 0], oldBase: 0x1001, newBase: 0x2002, expected: [0x2c, 0x2d, 0x2d, 0x2e, 0x0e, 0x0f])
        }
    }

    func testStructureLaneST3SNoIndexLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d00a184, mnemonic: "st3",
                text: "{v4.s, v5.s, v6.s}[0], [x12]", elements: 3, elementBytes: 4, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x1000, expected: [0x04, 0x05, 0x06, 0x07, 0x05, 0x06, 0x07, 0x08, 0x06, 0x07, 0x08, 0x09])
            try assertStructureStore(word: 0x4d00b19e, mnemonic: "st3",
                text: "{v30.s, v31.s, v0.s}[3], [x12]", elements: 3, elementBytes: 4, lane: 3,
                vectors: [30, 31, 0], oldBase: 0x1001, newBase: 0x1001, expected: [0x2a, 0x2b, 0x2c, 0x2d, 0x2b, 0x2c, 0x2d, 0x2e, 0x0c, 0x0d, 0x0e, 0x0f])
        }
    }

    func testStructureLaneST3SFixedPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d9fa184, mnemonic: "st3",
                text: "{v4.s, v5.s, v6.s}[0], [x12], #12", elements: 3, elementBytes: 4, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x100c, expected: [0x04, 0x05, 0x06, 0x07, 0x05, 0x06, 0x07, 0x08, 0x06, 0x07, 0x08, 0x09])
            try assertStructureStore(word: 0x4d9fb19e, mnemonic: "st3",
                text: "{v30.s, v31.s, v0.s}[3], [x12], #12", elements: 3, elementBytes: 4, lane: 3,
                vectors: [30, 31, 0], oldBase: 0x1001, newBase: 0x100d, expected: [0x2a, 0x2b, 0x2c, 0x2d, 0x2b, 0x2c, 0x2d, 0x2e, 0x0c, 0x0d, 0x0e, 0x0f])
        }
    }

    func testStructureLaneST3SRegisterPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d8da184, mnemonic: "st3",
                text: "{v4.s, v5.s, v6.s}[0], [x12], x13", elements: 3, elementBytes: 4, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x1006, expected: [0x04, 0x05, 0x06, 0x07, 0x05, 0x06, 0x07, 0x08, 0x06, 0x07, 0x08, 0x09])
            try assertStructureStore(word: 0x4d8cb19e, mnemonic: "st3",
                text: "{v30.s, v31.s, v0.s}[3], [x12], x12", elements: 3, elementBytes: 4, lane: 3,
                vectors: [30, 31, 0], oldBase: 0x1001, newBase: 0x2002, expected: [0x2a, 0x2b, 0x2c, 0x2d, 0x2b, 0x2c, 0x2d, 0x2e, 0x0c, 0x0d, 0x0e, 0x0f])
        }
    }

    func testStructureLaneST3DNoIndexLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d00a584, mnemonic: "st3",
                text: "{v4.d, v5.d, v6.d}[0], [x12]", elements: 3, elementBytes: 8, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x1000, expected: [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d])
            try assertStructureStore(word: 0x4d00a59e, mnemonic: "st3",
                text: "{v30.d, v31.d, v0.d}[1], [x12]", elements: 3, elementBytes: 8, lane: 1,
                vectors: [30, 31, 0], oldBase: 0x1001, newBase: 0x1001, expected: [0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f])
        }
    }

    func testStructureLaneST3DFixedPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d9fa584, mnemonic: "st3",
                text: "{v4.d, v5.d, v6.d}[0], [x12], #24", elements: 3, elementBytes: 8, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x1018, expected: [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d])
            try assertStructureStore(word: 0x4d9fa59e, mnemonic: "st3",
                text: "{v30.d, v31.d, v0.d}[1], [x12], #24", elements: 3, elementBytes: 8, lane: 1,
                vectors: [30, 31, 0], oldBase: 0x1001, newBase: 0x1019, expected: [0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f])
        }
    }

    func testStructureLaneST3DRegisterPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d8da584, mnemonic: "st3",
                text: "{v4.d, v5.d, v6.d}[0], [x12], x13", elements: 3, elementBytes: 8, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x1006, expected: [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d])
            try assertStructureStore(word: 0x4d8ca59e, mnemonic: "st3",
                text: "{v30.d, v31.d, v0.d}[1], [x12], x12", elements: 3, elementBytes: 8, lane: 1,
                vectors: [30, 31, 0], oldBase: 0x1001, newBase: 0x2002, expected: [0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f])
        }
    }

    func testStructureLaneST4BNoIndexLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d202184, mnemonic: "st4",
                text: "{v4.b, v5.b, v6.b, v7.b}[0], [x12]", elements: 4, elementBytes: 1, lane: 0,
                vectors: [4, 5, 6, 7], oldBase: 0x1000, newBase: 0x1000, expected: [0x04, 0x05, 0x06, 0x07])
            try assertStructureStore(word: 0x4d203d9e, mnemonic: "st4",
                text: "{v30.b, v31.b, v0.b, v1.b}[15], [x12]", elements: 4, elementBytes: 1, lane: 15,
                vectors: [30, 31, 0, 1], oldBase: 0x1001, newBase: 0x1001, expected: [0x2d, 0x2e, 0x0f, 0x10])
        }
    }

    func testStructureLaneST4BFixedPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0dbf2184, mnemonic: "st4",
                text: "{v4.b, v5.b, v6.b, v7.b}[0], [x12], #4", elements: 4, elementBytes: 1, lane: 0,
                vectors: [4, 5, 6, 7], oldBase: 0x1000, newBase: 0x1004, expected: [0x04, 0x05, 0x06, 0x07])
            try assertStructureStore(word: 0x4dbf3d9e, mnemonic: "st4",
                text: "{v30.b, v31.b, v0.b, v1.b}[15], [x12], #4", elements: 4, elementBytes: 1, lane: 15,
                vectors: [30, 31, 0, 1], oldBase: 0x1001, newBase: 0x1005, expected: [0x2d, 0x2e, 0x0f, 0x10])
        }
    }

    func testStructureLaneST4HNoIndexLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d206184, mnemonic: "st4",
                text: "{v4.h, v5.h, v6.h, v7.h}[0], [x12]", elements: 4, elementBytes: 2, lane: 0,
                vectors: [4, 5, 6, 7], oldBase: 0x1000, newBase: 0x1000, expected: [0x04, 0x05, 0x05, 0x06, 0x06, 0x07, 0x07, 0x08])
            try assertStructureStore(word: 0x4d20799e, mnemonic: "st4",
                text: "{v30.h, v31.h, v0.h, v1.h}[7], [x12]", elements: 4, elementBytes: 2, lane: 7,
                vectors: [30, 31, 0, 1], oldBase: 0x1001, newBase: 0x1001, expected: [0x2c, 0x2d, 0x2d, 0x2e, 0x0e, 0x0f, 0x0f, 0x10])
        }
    }

    func testStructureLaneST4HFixedPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0dbf6184, mnemonic: "st4",
                text: "{v4.h, v5.h, v6.h, v7.h}[0], [x12], #8", elements: 4, elementBytes: 2, lane: 0,
                vectors: [4, 5, 6, 7], oldBase: 0x1000, newBase: 0x1008, expected: [0x04, 0x05, 0x05, 0x06, 0x06, 0x07, 0x07, 0x08])
            try assertStructureStore(word: 0x4dbf799e, mnemonic: "st4",
                text: "{v30.h, v31.h, v0.h, v1.h}[7], [x12], #8", elements: 4, elementBytes: 2, lane: 7,
                vectors: [30, 31, 0, 1], oldBase: 0x1001, newBase: 0x1009, expected: [0x2c, 0x2d, 0x2d, 0x2e, 0x0e, 0x0f, 0x0f, 0x10])
        }
    }

    func testStructureLaneST4SNoIndexLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d20a184, mnemonic: "st4",
                text: "{v4.s, v5.s, v6.s, v7.s}[0], [x12]", elements: 4, elementBytes: 4, lane: 0,
                vectors: [4, 5, 6, 7], oldBase: 0x1000, newBase: 0x1000, expected: [0x04, 0x05, 0x06, 0x07, 0x05, 0x06, 0x07, 0x08, 0x06, 0x07, 0x08, 0x09, 0x07, 0x08, 0x09, 0x0a])
            try assertStructureStore(word: 0x4d20b19e, mnemonic: "st4",
                text: "{v30.s, v31.s, v0.s, v1.s}[3], [x12]", elements: 4, elementBytes: 4, lane: 3,
                vectors: [30, 31, 0, 1], oldBase: 0x1001, newBase: 0x1001, expected: [0x2a, 0x2b, 0x2c, 0x2d, 0x2b, 0x2c, 0x2d, 0x2e, 0x0c, 0x0d, 0x0e, 0x0f, 0x0d, 0x0e, 0x0f, 0x10])
        }
    }

    func testStructureLaneST4SFixedPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0dbfa184, mnemonic: "st4",
                text: "{v4.s, v5.s, v6.s, v7.s}[0], [x12], #16", elements: 4, elementBytes: 4, lane: 0,
                vectors: [4, 5, 6, 7], oldBase: 0x1000, newBase: 0x1010, expected: [0x04, 0x05, 0x06, 0x07, 0x05, 0x06, 0x07, 0x08, 0x06, 0x07, 0x08, 0x09, 0x07, 0x08, 0x09, 0x0a])
            try assertStructureStore(word: 0x4dbfb19e, mnemonic: "st4",
                text: "{v30.s, v31.s, v0.s, v1.s}[3], [x12], #16", elements: 4, elementBytes: 4, lane: 3,
                vectors: [30, 31, 0, 1], oldBase: 0x1001, newBase: 0x1011, expected: [0x2a, 0x2b, 0x2c, 0x2d, 0x2b, 0x2c, 0x2d, 0x2e, 0x0c, 0x0d, 0x0e, 0x0f, 0x0d, 0x0e, 0x0f, 0x10])
        }
    }

    func testStructureLaneST4DNoIndexLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d20a584, mnemonic: "st4",
                text: "{v4.d, v5.d, v6.d, v7.d}[0], [x12]", elements: 4, elementBytes: 8, lane: 0,
                vectors: [4, 5, 6, 7], oldBase: 0x1000, newBase: 0x1000, expected: [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e])
            try assertStructureStore(word: 0x4d20a59e, mnemonic: "st4",
                text: "{v30.d, v31.d, v0.d, v1.d}[1], [x12]", elements: 4, elementBytes: 8, lane: 1,
                vectors: [30, 31, 0, 1], oldBase: 0x1001, newBase: 0x1001, expected: [0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10])
        }
    }

    func testStructureLaneST4DFixedPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0dbfa584, mnemonic: "st4",
                text: "{v4.d, v5.d, v6.d, v7.d}[0], [x12], #32", elements: 4, elementBytes: 8, lane: 0,
                vectors: [4, 5, 6, 7], oldBase: 0x1000, newBase: 0x1020, expected: [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e])
            try assertStructureStore(word: 0x4dbfa59e, mnemonic: "st4",
                text: "{v30.d, v31.d, v0.d, v1.d}[1], [x12], #32", elements: 4, elementBytes: 8, lane: 1,
                vectors: [30, 31, 0, 1], oldBase: 0x1001, newBase: 0x1021, expected: [0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0x10])
        }
    }

    func testStructureLaneST3SPBNoIndexLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d0023e4, mnemonic: "st3",
                text: "{v4.b, v5.b, v6.b}[0], [sp]", elements: 3, elementBytes: 1, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x1000, expected: [0x04, 0x05, 0x06], baseRegister: "sp")
            try assertStructureStore(word: 0x4d003ffe, mnemonic: "st3",
                text: "{v30.b, v31.b, v0.b}[15], [sp]", elements: 3, elementBytes: 1, lane: 15,
                vectors: [30, 31, 0], oldBase: 0x2000, newBase: 0x2000, expected: [0x2d, 0x2e, 0x0f], baseRegister: "sp")
        }
    }

    func testStructureLaneST3SPBFixedPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d9f23e4, mnemonic: "st3",
                text: "{v4.b, v5.b, v6.b}[0], [sp], #3", elements: 3, elementBytes: 1, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x1003, expected: [0x04, 0x05, 0x06], baseRegister: "sp")
            try assertStructureStore(word: 0x4d9f3ffe, mnemonic: "st3",
                text: "{v30.b, v31.b, v0.b}[15], [sp], #3", elements: 3, elementBytes: 1, lane: 15,
                vectors: [30, 31, 0], oldBase: 0x2000, newBase: 0x2003, expected: [0x2d, 0x2e, 0x0f], baseRegister: "sp")
        }
    }

    func testStructureLaneST3SPBRegisterPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d8d23e4, mnemonic: "st3",
                text: "{v4.b, v5.b, v6.b}[0], [sp], x13", elements: 3, elementBytes: 1, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x1006, expected: [0x04, 0x05, 0x06], baseRegister: "sp")
            try assertStructureStore(word: 0x4d8c3ffe, mnemonic: "st3",
                text: "{v30.b, v31.b, v0.b}[15], [sp], x12", elements: 3, elementBytes: 1, lane: 15,
                vectors: [30, 31, 0], oldBase: 0x2000, newBase: 0x2040, expected: [0x2d, 0x2e, 0x0f], baseRegister: "sp")
        }
    }

    func testStructureLaneST3SPHNoIndexLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d0063e4, mnemonic: "st3",
                text: "{v4.h, v5.h, v6.h}[0], [sp]", elements: 3, elementBytes: 2, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x1000, expected: [0x04, 0x05, 0x05, 0x06, 0x06, 0x07], baseRegister: "sp")
            try assertStructureStore(word: 0x4d007bfe, mnemonic: "st3",
                text: "{v30.h, v31.h, v0.h}[7], [sp]", elements: 3, elementBytes: 2, lane: 7,
                vectors: [30, 31, 0], oldBase: 0x2000, newBase: 0x2000, expected: [0x2c, 0x2d, 0x2d, 0x2e, 0x0e, 0x0f], baseRegister: "sp")
        }
    }

    func testStructureLaneST3SPHFixedPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d9f63e4, mnemonic: "st3",
                text: "{v4.h, v5.h, v6.h}[0], [sp], #6", elements: 3, elementBytes: 2, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x1006, expected: [0x04, 0x05, 0x05, 0x06, 0x06, 0x07], baseRegister: "sp")
            try assertStructureStore(word: 0x4d9f7bfe, mnemonic: "st3",
                text: "{v30.h, v31.h, v0.h}[7], [sp], #6", elements: 3, elementBytes: 2, lane: 7,
                vectors: [30, 31, 0], oldBase: 0x2000, newBase: 0x2006, expected: [0x2c, 0x2d, 0x2d, 0x2e, 0x0e, 0x0f], baseRegister: "sp")
        }
    }

    func testStructureLaneST3SPHRegisterPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d8d63e4, mnemonic: "st3",
                text: "{v4.h, v5.h, v6.h}[0], [sp], x13", elements: 3, elementBytes: 2, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x1006, expected: [0x04, 0x05, 0x05, 0x06, 0x06, 0x07], baseRegister: "sp")
            try assertStructureStore(word: 0x4d8c7bfe, mnemonic: "st3",
                text: "{v30.h, v31.h, v0.h}[7], [sp], x12", elements: 3, elementBytes: 2, lane: 7,
                vectors: [30, 31, 0], oldBase: 0x2000, newBase: 0x2040, expected: [0x2c, 0x2d, 0x2d, 0x2e, 0x0e, 0x0f], baseRegister: "sp")
        }
    }

    func testStructureLaneST3SPSNoIndexLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d00a3e4, mnemonic: "st3",
                text: "{v4.s, v5.s, v6.s}[0], [sp]", elements: 3, elementBytes: 4, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x1000, expected: [0x04, 0x05, 0x06, 0x07, 0x05, 0x06, 0x07, 0x08, 0x06, 0x07, 0x08, 0x09], baseRegister: "sp")
            try assertStructureStore(word: 0x4d00b3fe, mnemonic: "st3",
                text: "{v30.s, v31.s, v0.s}[3], [sp]", elements: 3, elementBytes: 4, lane: 3,
                vectors: [30, 31, 0], oldBase: 0x2000, newBase: 0x2000, expected: [0x2a, 0x2b, 0x2c, 0x2d, 0x2b, 0x2c, 0x2d, 0x2e, 0x0c, 0x0d, 0x0e, 0x0f], baseRegister: "sp")
        }
    }

    func testStructureLaneST3SPSFixedPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d9fa3e4, mnemonic: "st3",
                text: "{v4.s, v5.s, v6.s}[0], [sp], #12", elements: 3, elementBytes: 4, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x100c, expected: [0x04, 0x05, 0x06, 0x07, 0x05, 0x06, 0x07, 0x08, 0x06, 0x07, 0x08, 0x09], baseRegister: "sp")
            try assertStructureStore(word: 0x4d9fb3fe, mnemonic: "st3",
                text: "{v30.s, v31.s, v0.s}[3], [sp], #12", elements: 3, elementBytes: 4, lane: 3,
                vectors: [30, 31, 0], oldBase: 0x2000, newBase: 0x200c, expected: [0x2a, 0x2b, 0x2c, 0x2d, 0x2b, 0x2c, 0x2d, 0x2e, 0x0c, 0x0d, 0x0e, 0x0f], baseRegister: "sp")
        }
    }

    func testStructureLaneST3SPSRegisterPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d8da3e4, mnemonic: "st3",
                text: "{v4.s, v5.s, v6.s}[0], [sp], x13", elements: 3, elementBytes: 4, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x1006, expected: [0x04, 0x05, 0x06, 0x07, 0x05, 0x06, 0x07, 0x08, 0x06, 0x07, 0x08, 0x09], baseRegister: "sp")
            try assertStructureStore(word: 0x4d8cb3fe, mnemonic: "st3",
                text: "{v30.s, v31.s, v0.s}[3], [sp], x12", elements: 3, elementBytes: 4, lane: 3,
                vectors: [30, 31, 0], oldBase: 0x2000, newBase: 0x2040, expected: [0x2a, 0x2b, 0x2c, 0x2d, 0x2b, 0x2c, 0x2d, 0x2e, 0x0c, 0x0d, 0x0e, 0x0f], baseRegister: "sp")
        }
    }

    func testStructureLaneST3SPDNoIndexLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d00a7e4, mnemonic: "st3",
                text: "{v4.d, v5.d, v6.d}[0], [sp]", elements: 3, elementBytes: 8, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x1000, expected: [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d], baseRegister: "sp")
            try assertStructureStore(word: 0x4d00a7fe, mnemonic: "st3",
                text: "{v30.d, v31.d, v0.d}[1], [sp]", elements: 3, elementBytes: 8, lane: 1,
                vectors: [30, 31, 0], oldBase: 0x2000, newBase: 0x2000, expected: [0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f], baseRegister: "sp")
        }
    }

    func testStructureLaneST3SPDFixedPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d9fa7e4, mnemonic: "st3",
                text: "{v4.d, v5.d, v6.d}[0], [sp], #24", elements: 3, elementBytes: 8, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x1018, expected: [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d], baseRegister: "sp")
            try assertStructureStore(word: 0x4d9fa7fe, mnemonic: "st3",
                text: "{v30.d, v31.d, v0.d}[1], [sp], #24", elements: 3, elementBytes: 8, lane: 1,
                vectors: [30, 31, 0], oldBase: 0x2000, newBase: 0x2018, expected: [0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f], baseRegister: "sp")
        }
    }

    func testStructureLaneST3SPDRegisterPostLiteralBytes() throws {
        try structureStoreModes {
            try assertStructureStore(word: 0x0d8da7e4, mnemonic: "st3",
                text: "{v4.d, v5.d, v6.d}[0], [sp], x13", elements: 3, elementBytes: 8, lane: 0,
                vectors: [4, 5, 6], oldBase: 0x1000, newBase: 0x1006, expected: [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d], baseRegister: "sp")
            try assertStructureStore(word: 0x4d8ca7fe, mnemonic: "st3",
                text: "{v30.d, v31.d, v0.d}[1], [sp], x12", elements: 3, elementBytes: 8, lane: 1,
                vectors: [30, 31, 0], oldBase: 0x2000, newBase: 0x2040, expected: [0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f], baseRegister: "sp")
        }
    }

    func testStructureLaneRolesRejectUntypedAndMismatchedOperations() throws {
        try structureStoreModes {
            let row = structureStoreRow(0x0d9f2184, "st3", "{v4.b, v5.b, v6.b}[0], [x12], #3")
            let original = MacIRBuilder().buildFunction(name: "typed_store", instructions: [row])
            let frame = try XCTUnwrap(original.instructions.first?.neonStructureLaneMemory?.frame)
            let name = "neon_structure_lane_store"
            for arguments in [[frame.oldVectors[0], frame.oldBase], [frame.oldBase],
                              [frame.oldBase, frame.oldVectors[0], frame.oldVectors[1]]] {
                var bad = original
                bad.instructions[0].operation = .intrinsic(destination: nil, name: name, arguments: arguments)
                XCTAssertFalse(frame.matches(bad.instructions[0].operation, ordinal: 0))
                XCTAssertTrue(analyze(bad, machine: [structureStoreSource(row)]).refusalDetails.contains {
                    $0.reason == "unsupported intrinsic operand roles: neon_structure_lane_store"
                })
            }
            XCTAssertFalse(frame.matches(.intrinsic(destination: frame.oldVectors[0], name: name,
                arguments: [frame.oldBase, frame.oldVectors[0]]), ordinal: 0))
            var untyped = original
            untyped.instructions[0].neonStructureLaneMemory = nil
            XCTAssertTrue(analyze(untyped, machine: [structureStoreSource(row)]).refusalDetails.contains {
                $0.reason == "unsupported intrinsic operand roles: neon_structure_lane_store"
            })
            var wrongCount = original
            wrongCount.instructions[0].source.mnemonic = "st2"
            XCTAssertTrue(analyze(wrongCount, machine: [structureStoreSource(row)]).refusalDetails.contains {
                $0.reason == "unsupported intrinsic operand roles: neon_structure_lane_store"
            })
            var baseOrdinal = original
            baseOrdinal.instructions[0].neonStructureLaneMemory = .init(frame: frame, ordinal: frame.structureCount)
            XCTAssertTrue(analyze(baseOrdinal, machine: [structureStoreSource(row)]).refusalDetails.contains {
                $0.reason == "unsupported intrinsic operand roles: neon_structure_lane_store"
            })
        }
    }

    func testStructureLaneByteTextDisagreementStaysProductRefused() throws {
        try structureStoreModes {
            for row in [
                structureStoreRow(0x0d000185, "st1", "{v4.b}[0], [x12]"),
                structureStoreRow(0x0d202184, "st2", "{v4.b, v5.b}[1], [x12]"),
                structureStoreRow(0x0d002184, "st3", "{v4.b, v5.b, v6.b}[0], [x12], #3"),
                structureStoreRow(0x0d202185, "st4", "{v4.b, v5.b, v6.b, v7.b}[0], [x12]")
            ] {
                XCTAssertNil(MacIRBuilder.neonStructureLaneMemory(row))
                let function = MacIRBuilder().buildFunction(name: "store_mismatch", instructions: [row])
                XCTAssertFalse(function.instructions.contains { $0.neonStructureLaneMemory != nil })
                XCTAssertTrue(function.instructions.contains {
                    if case .unknown = $0.operation { return $0.source.address == row.address }
                    return false
                })
            }
        }
    }

    func testStructureLaneUnsupportedOverlappingSPStoreStaysRefused() throws {
        try structureStoreModes {
            // Both machine stores target entry SP. The H lane overlaps bytes0–1
            // of the preceding16-byte spill. Overlap is architecturally valid;
            // ST1-on-SP remains outside this pin's admitted lane-store model.
            let spill = InstructionRow(address: 0x7b00, bytes: "e4 03 80 3d", mnemonic: "str",
                operands: "q4, [sp]", hasBreakpoint: false, comment: nil)
            let overlap = structureStoreRow(0x0d0043e4, "st1", "{v4.h}[0], [sp]", at: 0x7b04)
            XCTAssertNil(MacIRBuilder.neonStructureLaneMemory(overlap))
            let function = MacIRBuilder().buildFunction(name: "overlapping_sp_lane", instructions: [spill, overlap])
            XCTAssertTrue(function.instructions.contains {
                if case .unknown = $0.operation { return $0.source.address == 0x7b04 }
                return false
            })
            XCTAssertFalse(function.instructions.contains { $0.source.address == 0x7b04 && $0.neonStructureLaneMemory != nil })
            // Register-post ST2 is another architectural form deliberately not
            // admitted by the product parser. No role declaration widens it.
            XCTAssertNil(MacIRBuilder.neonStructureLaneMemory(structureStoreRow(0x0dad0184,
                "st2", "{v4.b, v5.b}[0], [x12], x13")))
        }
    }

    func testStructureLaneWrappingSpanRefusesBeforeAnyWrite() throws {
        try structureStoreModes {
            let row = structureStoreRow(0x0d20a584, "st4", "{v4.d, v5.d, v6.d, v7.d}[0], [x12]")
            let function = MacIRBuilder().buildFunction(name: "span_refusal", instructions: [row])
            let frame = try XCTUnwrap(function.instructions.first?.neonStructureLaneMemory?.frame)
            var input = try structureStoreState()
            input.x[12] = 0xfffffffffffffff0
            input.setByte(0xa5, at: 0xfffffffffffffff0)
            var evaluator = MacIRConcreteEvaluator(function: function, state: input)
            XCTAssertThrowsError(try evaluator.executeNEONStructureLaneMemory(frame)) { error in
                XCTAssertEqual(error as? MacIRConcreteEvaluator.Failure,
                    .unsupported("NEON structure-lane span/base"))
            }
            XCTAssertEqual(evaluator.state, input)
            // The evaluator cannot represent a wrapping span. This is not a
            // claim that the architecture makes every wrapping access invalid.
        }
    }

    func testStructureLaneAdmittedOverlappingStoresKeepProgramOrder() throws {
        try structureStoreModes {
            let rows = [structureStoreRow(0x0d002184, "st3", "{v4.b, v5.b, v6.b}[0], [x12]"),
                        structureStoreRow(0x0d00219e, "st3", "{v30.b, v31.b, v0.b}[0], [x12]", at: 0x7b04)]
            let function = MacIRBuilder().buildFunction(name: "overlapping_x_lane", instructions: rows)
            let frames = function.instructions.compactMap { instruction -> MacIRNEONStructureLaneMemory? in
                guard let step = instruction.neonStructureLaneMemory, step.ordinal == 0 else { return nil }
                return step.frame
            }
            XCTAssertEqual(frames.count, 2)
            guard frames.count == 2 else { return }
            var input = try structureStoreState()
            input.x[12] = 0x1000
            input.setByte(0xa5, at: 0x1003)
            var evaluator = MacIRConcreteEvaluator(function: function, state: input)
            try evaluator.validateNEONStructureLaneMemory(function.instructions)
            try evaluator.executeNEONStructureLaneMemory(frames[0])
            XCTAssertEqual((0..<3).map { evaluator.state.byte(at: 0x1000 + UInt64($0)) }, [0x04, 0x05, 0x06])
            try evaluator.executeNEONStructureLaneMemory(frames[1])
            XCTAssertEqual((0..<4).map { evaluator.state.byte(at: 0x1000 + UInt64($0)) }, [0x1e, 0x1f, 0x00, 0xa5])
            XCTAssertEqual(evaluator.state.x[12], 0x1000)
            XCTAssertEqual(evaluator.state.v, input.v)
            XCTAssertNil(analyze(function, machine: rows.map(structureStoreSource)).skippedReason)
        }
    }

    private func structureStoreModes(_ body: () throws -> Void) rethrows {
        for enabled in [false, true] {
            try MacIRConfiguration.$ssaOverride.withValue(enabled) {
                XCTAssertEqual(MacIRBuilder().ssaEnabled, enabled)
                try body()
            }
        }
    }

    private func structureStoreRow(_ word: UInt32, _ mnemonic: String, _ operands: String,
                                   at address: UInt64 = 0x7b00) -> InstructionRow {
        let bytes = (0..<4).map { String(format: "%02x", (word >> ($0 * 8)) & 255) }.joined(separator: " ")
        return .init(address: address, bytes: bytes, mnemonic: mnemonic, operands: operands,
                     hasBreakpoint: false, comment: nil)
    }

    private func structureStoreSource(_ row: InstructionRow) -> MacIRSourceSpan {
        .init(address: row.address, byteText: row.bytes, mnemonic: row.mnemonic, operands: row.operands)
    }

    private func structureStoreState() throws -> A64MachineState {
        var input = try A64MachineState(seeding: JSONDecoder().decode(A64OracleVector.State.self,
            from: Data("{}".utf8)))
        input.x[13] = 6
        for index in 0..<32 {
            let offset = UInt64(index) * 0x0101010101010101
            input.v[index] = .init(low: 0x0706050403020100 + offset, high: 0x0f0e0d0c0b0a0908 + offset)
        }
        return input
    }

    private func assertStructureStore(word: UInt32, mnemonic: String, text: String,
                                      elements: Int, elementBytes: Int, lane: Int, vectors: [Int],
                                      oldBase: UInt64, newBase: UInt64, expected: [UInt8], baseRegister: String = "x12") throws {
        let row = structureStoreRow(word, mnemonic, text)
        let parsed = try XCTUnwrap(MacIRBuilder.neonStructureLaneMemory(row))
        XCTAssertEqual(parsed.effect, .store)
        XCTAssertEqual(parsed.structureCount, elements)
        XCTAssertEqual(parsed.elementBytes, elementBytes)
        XCTAssertEqual(parsed.laneIndex, lane)
        XCTAssertEqual(parsed.vectors, vectors.map { "v\($0)" })
        let function = MacIRBuilder().buildFunction(name: "literal_lane_store", instructions: [row])
        let frame = try XCTUnwrap(function.instructions.first?.neonStructureLaneMemory?.frame)
        XCTAssertEqual(frame.effect, .store)
        XCTAssertEqual(frame.structureCount, elements)
        XCTAssertEqual(frame.elementBytes, elementBytes)
        XCTAssertEqual(frame.laneIndex, lane)
        XCTAssertEqual(frame.byteCount, expected.count)
        XCTAssertEqual(frame.oldBase, .register(name: baseRegister, version: 0))
        XCTAssertEqual(frame.oldVectors, vectors.map { .register(name: "v\($0)", version: 0) })
        XCTAssertTrue(frame.destinations.isEmpty)
        XCTAssertEqual(function.instructions.count, elements + (newBase == oldBase ? 0 : 1))
        for (ordinal, instruction) in function.instructions.enumerated() {
            XCTAssertEqual(instruction.neonStructureLaneMemory, .init(frame: frame, ordinal: ordinal))
            XCTAssertTrue(frame.matches(instruction.operation, ordinal: ordinal))
            XCTAssertEqual(instruction.id.sourceAddress, row.address)
            XCTAssertEqual(instruction.id.effectOrdinal, ordinal)
        }
        let flow = C2MachineFlow(rows: [structureStoreSource(row)])
        XCTAssertNil(flow.error)
        let reads = Set(vectors.map { "v\($0)" } + [baseRegister] + (text.hasSuffix("x13") ? ["x13"] : text.hasSuffix("x12") ? ["x12"] : []))
        XCTAssertEqual(flow.reads, [reads])
        XCTAssertEqual(flow.writes, [newBase == oldBase ? Set<String>() : Set([baseRegister])])
        var input = try structureStoreState()
        if baseRegister == "sp" { input.sp = oldBase; input.x[12] = 0x40 } else { input.x[12] = oldBase }
        for offset in -1...expected.count { input.setByte(0xa5, at: oldBase + UInt64(offset + 1) - 1) }
        var expectedMemory = input.memory
        for (offset, byte) in expected.enumerated() {
            let address = oldBase + UInt64(offset)
            if byte == 0 { expectedMemory.removeValue(forKey: address) } else { expectedMemory[address] = byte }
        }
        var evaluator = MacIRConcreteEvaluator(function: function, state: input)
        try evaluator.validateNEONStructureLaneMemory(function.instructions)
        try evaluator.executeNEONStructureLaneMemory(frame)
        XCTAssertEqual(expected.indices.map { evaluator.state.byte(at: oldBase + UInt64($0)) }, expected)
        XCTAssertEqual(evaluator.state.memory, expectedMemory)
        XCTAssertEqual(evaluator.state.v, input.v)
        XCTAssertEqual(evaluator.state.x[12], baseRegister == "sp" ? 0x40 : newBase)
        XCTAssertEqual(evaluator.state.x[13], 6)
        XCTAssertEqual(evaluator.state.sp, baseRegister == "sp" ? newBase : input.sp)
        if baseRegister == "x12", text.hasSuffix("x12") {
            XCTAssertEqual(frame.registerPost?.oldIncrement, frame.oldBase)
        }
        // Exact roles are only the entry point: independent direct-read and
        // reaching-definition checks still run on the same product effects.
        XCTAssertNil(analyze(function, machine: [structureStoreSource(row)]).skippedReason)
    }

    func testStructureStoreWithoutTypedFrameRemainsRefused() {
        let function = MacIRFunction(name: "untyped_structure_store", startAddress: 0x8400,
            returnType: "void", instructions: [
                instruction(0x8400, "st2", "{v0.16b, v1.16b}, [x1]", .intrinsic(destination: nil,
                    name: "neon_structure_store", arguments: [reg(1, 0), .register(name: "q0", version: 0)])),
                instruction(0x8404, "ret", "", .returnValue(nil))
            ])
        let result = analyze(function)
        XCTAssertTrue(result.refusalDetails.contains {
            $0.reason == "unsupported intrinsic operand roles: neon_structure_store"
        })
    }

    func testWrongSnapshotIsNotAnIncomingFlagOperand() {
        let result = analyze(conditionalFlagFunction(condition: "eq", predicate: reg(9, 0)))
        XCTAssertTrue(result.refusalDetails.contains {
            $0.reason == "predicate operand provenance is not a direct flag-producer input"
        })
    }

    private func conditionalFlagFunction(condition: String, predicate: MacIRValue? = nil) -> MacIRFunction {
        MacIRFunction(name: "conditional_flag_origin", startAddress: 0x8000, returnType: "void",
            instructions: [
                instruction(0x8000, "mov", "x9, x0", .assign(destination: reg(9, 1), source: reg(0, 0))),
                instruction(0x8004, "cmp", "x9, #0", .intrinsic(destination: nil,
                    name: "compare", arguments: [reg(9, 1), .immediate(0)])),
                instruction(0x8008, "ccmp", "x10, #3, #2, \(condition)", .intrinsic(destination: nil,
                    name: "conditional_compare_\(condition)", arguments: [reg(10, 0), .immediate(3), .immediate(2)])),
                instruction(0x800c, "b.eq", "0x8014", .conditionalBranch(condition: "==",
                    left: predicate ?? reg(9, 1), right: .immediate(0), target: .immediate(0x8014))),
                instruction(0x8010, "ret", "", .returnValue(nil)),
                instruction(0x8014, "ret", "", .returnValue(nil))
            ])
    }

    func testLoopCarriedDrop() {
        let result = analyze(loop(merged: false))
        XCTAssertNil(result.skippedReason)
        XCTAssertTrue(result.rows.contains {
            $0.kind == "L" && $0.variable == "x1_1" && $0.useAddress == 0x1004
                && $0.definitionAddress == 0x1000 && $0.reachingDefinitions.contains(0x1008)
        }, "The printed loop reads the entry x1 definition after the machine backedge replaces x1")
    }

    func testWrongPathJoin() {
        let result = analyze(join(merged: false))
        XCTAssertNil(result.skippedReason)
        XCTAssertTrue(result.rows.contains {
            $0.kind == "J" && $0.variable == "x1_1" && $0.useAddress == 0x2010
                && $0.definitionAddress == 0x2004 && $0.reachingDefinitions.contains(0x200c)
        }, "The join must not use a definition supplied only by one sibling")
    }

    func testCorrectPhiLoop() {
        let result = analyze(loop(merged: true))
        XCTAssertNil(result.skippedReason)
        XCTAssertTrue(result.rows.isEmpty, "The printer emits the loop phi's entry and backedge copies")
    }

    func testCorrectJoin() {
        let result = analyze(join(merged: true))
        XCTAssertNil(result.skippedReason)
        XCTAssertTrue(result.rows.isEmpty, "Both predecessors supply the printed join phi")
    }

    func testParallelAssignment() {
        let function = MacIRFunction(name: "parallel_writeback", startAddress: 0x3000,
            instructions: [
                instruction(0x3000, "mov", "x1, x20", .assign(destination: reg(1, 1), source: reg(20, 0))),
                instruction(0x3004, "ldr", "x0, [x1], #8", .loadWriteback(
                    destination: reg(0, 1), baseDestination: reg(1, 2), baseSource: reg(1, 1),
                    delta: 8, preIndex: false)),
                instruction(0x3008, "str", "x0, [x1], #8", .storeWriteback(
                    source: reg(0, 1), baseDestination: reg(1, 3), baseSource: reg(1, 2),
                    delta: 8, preIndex: false)),
                instruction(0x300c, "ret", "", .returnValue(reg(0, 1)))
            ])
        let result = analyze(function)
        XCTAssertNil(result.skippedReason)
        XCTAssertTrue(result.rows.isEmpty, "Simultaneous load/store writeback reads the old base before defining its new version")
    }

    func testSameInstructionVectorDestinationProjectionsHaveNoJoinFinding() {
        for name in ["__low64", "__high64", "__ssa_low64", "__ssa_high64"] {
            for readsDestination in [true, false] {
                let prior = MacIRValue.register(name: "q6", version: 1)
                let destination = MacIRValue.register(name: "q6", version: 2)
                let producer = instruction(0x3104, readsDestination ? "and" : "mul",
                    readsDestination ? "v6.16b, v6.16b, v18.16b" : "v6.4s, v1.4s, v2.4s",
                    .binary(destination: destination, op: readsDestination ? "&" : "*",
                        left: readsDestination ? prior : .register(name: "q1", version: 0),
                        right: .register(name: readsDestination ? "q18" : "q2", version: 0)))
                let machineInstructions = [
                    instruction(0x3100, "movi", "v6.4s, #0", .assign(destination: prior, source: .immediate(0))),
                    producer,
                    instruction(0x3108, "ret", "", .returnValue(nil))
                ]
                let projection = MacIRInstruction(source: producer.source, operation: .assign(
                    destination: .register(name: name.contains("high") ? "vh6" : "v6", version: 2),
                    source: .unary(op: name, value: destination)))
                let function = MacIRFunction(name: "destination_projection", startAddress: 0x3100,
                    returnType: "void", instructions: [machineInstructions[0], producer, projection, machineInstructions[2]])
                let result = analyze(function, expectedPrintedValue: .unary(op: name, value: destination),
                    expectedUseAddress: 0x3104,
                    machine: machineInstructions.map(\.source))
                XCTAssertNil(result.skippedReason, name)
                XCTAssertTrue(result.rows.isEmpty, "\(name) projects the new destination after its defining instruction")
                XCTAssertTrue(result.refusalDetails.isEmpty, name)
            }
        }
    }

    func testWrongPathVectorProjectionStillHasJoinFinding() {
        for name in ["__low64", "__high64", "__ssa_low64", "__ssa_high64"] {
            let wrongPath = MacIRValue.register(name: "q6", version: 1)
            let function = MacIRFunction(name: "wrong_path_projection", startAddress: 0x3200,
                returnType: "void", instructions: [
                    instruction(0x3200, "cbz", "x3, 0x320c", .conditionalBranch(condition: "==",
                        left: reg(3, 0), right: .immediate(0), target: .immediate(0x320c))),
                    instruction(0x3204, "movi", "v6.4s, #1", .assign(destination: wrongPath, source: .immediate(1))),
                    instruction(0x3208, "b", "0x3210", .intrinsic(destination: nil, name: "branch",
                        arguments: [.immediate(0x3210)])),
                    instruction(0x320c, "movi", "v6.4s, #2", .assign(
                        destination: .register(name: "q6", version: 2), source: .immediate(2))),
                    instruction(0x3210, "and", "v6.16b, v6.16b, v18.16b", .assign(
                        destination: .register(name: name.contains("high") ? "vh6" : "v6", version: 3),
                        source: .unary(op: name, value: wrongPath))),
                    instruction(0x3214, "ret", "", .returnValue(nil))
                ])
            let result = analyze(function, expectedPrintedValue: .unary(op: name, value: wrongPath),
                expectedUseAddress: 0x3210)
            XCTAssertNil(result.skippedReason, name)
            XCTAssertEqual(result.rows.count, 1, name)
            XCTAssertTrue(result.rows.contains {
                $0.kind == "J" && $0.variable == "q6_1" && $0.useAddress == 0x3210
                    && $0.definitionAddress == 0x3204 && $0.reachingDefinitions == [0x3204, 0x320c]
            }, "A projection must not exempt a q value supplied by only one predecessor")
        }
    }

    func testOtherInstructionVectorProjectionUsesOrdinaryDominance() {
        for name in ["__low64", "__high64", "__ssa_low64", "__ssa_high64"] {
            for definitionBeforeUse in [true, false] {
                let source = MacIRValue.register(name: "q6", version: 1)
                let definition = instruction(definitionBeforeUse ? 0x3300 : 0x3304,
                    "movi", "v6.4s, #1", .assign(destination: source, source: .immediate(1)))
                let projection = instruction(definitionBeforeUse ? 0x3304 : 0x3300,
                    "str", "q6, [x2]", .assign(
                        destination: .register(name: name.contains("high") ? "vh6" : "v6", version: 2),
                        source: .unary(op: name, value: source)))
                let function = MacIRFunction(name: "prior_projection", startAddress: 0x3300,
                    returnType: "void", instructions: (definitionBeforeUse
                        ? [definition, projection] : [projection, definition]) + [
                            instruction(0x3308, "ret", "", .returnValue(nil))
                        ])
                let result = analyze(function, expectedPrintedValue: .unary(op: name, value: source),
                    expectedUseAddress: projection.source.address)
                XCTAssertNil(result.skippedReason, name)
                if definitionBeforeUse {
                    XCTAssertTrue(result.rows.isEmpty, "A prior dominating q definition remains a valid projection source")
                } else {
                    XCTAssertEqual(result.rows.count, 1, name)
                    XCTAssertTrue(result.rows.contains {
                        $0.kind == "J" && $0.variable == "q6_1" && $0.useAddress == 0x3300
                            && $0.definitionAddress == 0x3304 && $0.reachingDefinitions == [0]
                    }, "A q definition after the use must still fail ordinary dominance")
                }
            }
        }
    }

    func testNonDirectReadKeepsEachUseCoordinate() throws {
        let function = MacIRFunction(name: "non_direct_reads", startAddress: 0x5000,
            returnType: "void", instructions: [
                instruction(0x5000, "str", "x8, [x2]", .store(source: reg(9, 0), address: reg(2, 0))),
                instruction(0x5004, "str", "x8, [x2]", .store(source: reg(9, 0), address: reg(2, 0))),
                instruction(0x5008, "ret", "", .returnValue(nil))
            ])
        let result = analyze(function)
        let reason = "printed operand is not a direct machine read"
        XCTAssertEqual(result.skippedReason, reason)
        XCTAssertEqual(Self.reasonSet(result.skippedReason ?? ""), [reason])
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(result.refusalDetails.map(\.reason), [reason, reason])
        XCTAssertEqual(result.refusalDetails.map(\.instructionAddress), [0x5000, 0x5004])
        XCTAssertEqual(result.refusalDetails.map(\.mnemonic), ["str", "str"])
        XCTAssertEqual(result.refusalDetails.map(\.register), ["x9", "x9"])
        XCTAssertEqual(result.refusalDetails.map(\.valueName), ["x9_0", "x9_0"])
        XCTAssertTrue(result.refusalDetails.allSatisfy { $0.displayedLineNumber != nil })
        XCTAssertTrue(result.indirectBranchSites.isEmpty)
        let decoded = try JSONDecoder().decode([C2DataflowCensus.RefusalDetail].self,
            from: JSONEncoder().encode(result.refusalDetails))
        XCTAssertEqual(decoded, result.refusalDetails)
    }

    func testIndirectBranchInventoryKeepsFirstError() throws {
        let function = MacIRFunction(name: "indirect_branches", startAddress: 0x6008,
            returnType: "void", instructions: [
                instruction(0x6008, "br", "x8", .intrinsic(destination: nil, name: "branch", arguments: [reg(8, 0)])),
                instruction(0x6000, "br", "x9", .intrinsic(destination: nil, name: "branch", arguments: [reg(9, 0)]))
            ])
        let flow = C2MachineFlow(rows: function.instructions.map(\.source))
        XCTAssertEqual(flow.indirectBranchSites, [0x6000, 0x6008])
        XCTAssertEqual(flow.error, "unresolved indirect branch at 0x6008")
        let result = analyze(function)
        XCTAssertEqual(result.indirectBranchSites, flow.indirectBranchSites)
        XCTAssertEqual(result.skippedReason, flow.error)
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(result.refusalDetails.count, 1)
        let detail = try XCTUnwrap(result.refusalDetails.first)
        XCTAssertEqual(detail.reason, flow.error)
        XCTAssertNil(detail.instructionAddress)
        XCTAssertNil(detail.mnemonic)
        XCTAssertNil(detail.register)
        XCTAssertNil(detail.valueName)
        XCTAssertNil(detail.displayedLineNumber)
    }

    func testTypedReturnRegistersHaveNoRefusalDetail() {
        for register in ["x0", "v0"] {
            let function = MacIRFunction(name: "typed_return", startAddress: 0x7000,
                returnType: register == "x0" ? "uint64_t" : "double", instructions: [
                    instruction(0x7000, "ret", "", .returnValue(.register(name: register, version: 0)))
                ])
            let result = analyze(function)
            XCTAssertNil(result.skippedReason, register)
            XCTAssertTrue(result.rows.isEmpty, register)
            XCTAssertTrue(result.refusalDetails.isEmpty, register)
            XCTAssertTrue(result.indirectBranchSites.isEmpty, register)
        }
    }

    func testUnknownRefusalDetailPreservesReasons() throws {
        let value = MacIRValue.unknown("unavailable_x8")
        let result = analyze(printedLeaf(value), expectedPrintedValue: value)
        XCTAssertEqual(Self.reasonSet(result.skippedReason ?? ""), ["unknown-use: unavailable_x8"])
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(result.refusalDetails.count, 1)
        let detail = try XCTUnwrap(result.refusalDetails.first)
        XCTAssertEqual(detail.reason, "unknown-use: unavailable_x8")
        XCTAssertEqual(detail.instructionAddress, 0x4008)
        XCTAssertEqual(detail.mnemonic, "str")
        XCTAssertNil(detail.register)
        XCTAssertEqual(detail.valueName, "unavailable_x8")
        XCTAssertNotNil(detail.displayedLineNumber)
    }

    func testMissingPhiPredecessorDoesNotInventCoordinate() throws {
        let function = MacIRFunction(name: "missing_predecessor", startAddress: 0x8000,
            returnType: "void", instructions: [
                instruction(0x8000, "ret", "", .returnValue(nil))
            ], phis: [
                MacIRPhi(blockAddress: 0x8000, destination: reg(1, 1), bitWidth: 64,
                    incoming: [.init(predecessorAddress: 0x9000, value: reg(1, 0))])
            ])
        let result = analyze(function)
        XCTAssertEqual(result.skippedReason, "phi predecessor is not a machine edge to its join")
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(result.refusalDetails.count, 1)
        let detail = try XCTUnwrap(result.refusalDetails.first)
        XCTAssertEqual(detail.reason, result.skippedReason)
        XCTAssertNil(detail.instructionAddress)
        XCTAssertNil(detail.mnemonic)
        XCTAssertEqual(detail.register, "x1")
        XCTAssertEqual(detail.valueName, "x1_0")
        XCTAssertNil(detail.displayedLineNumber)
    }

    func testUpperHalfEffectsKeepUnmodelledSiblingRefused() {
        let pairs = ["ushll", "sshll", "smull", "umull", "uaddw", "saddl", "uxtl", "sxtl",
            "umlal", "smlal", "usubl", "ssubl", "uaddl", "usubw", "ssubw", "saddw"]
        for base in pairs {
            let operands = ["ushll", "sshll"].contains(base) ? "v0.8h, v1.16b, #0"
                : ["uxtl", "sxtl"].contains(base) ? "v0.8h, v1.16b" : "v0.8h, v1.8h, v2.16b"
            let rows = [instruction(0xa000, base, operands, .returnValue(nil)).source]
            let upper = [instruction(0xa000, base + "2", operands, .returnValue(nil)).source]
            let original = C2MachineFlow(rows: rows), extended = C2MachineFlow(rows: upper)
            XCTAssertNil(original.error, base)
            XCTAssertNil(extended.error, base)
            XCTAssertEqual(extended.reads, original.reads, base)
            XCTAssertEqual(extended.writes, original.writes, base)
        }
        let source = MacIRValue.register(name: "v1", version: 0)
        for mnemonic in ["ushll2", "shrn2"] {
            let function = MacIRFunction(name: "upper_half", startAddress: 0xa000,
                returnType: "void", instructions: [
                    instruction(0xa000, mnemonic, "v0.8h, v1.16b, #0", .intrinsic(
                        destination: .register(name: "v0", version: 1), name: mnemonic, arguments: [source])),
                    instruction(0xa004, "ret", "", .returnValue(nil))
                ])
            let result = analyze(function, expectedPrintedValue: source, expectedUseAddress: 0xa000)
            XCTAssertTrue(result.rows.isEmpty)
            if mnemonic == "ushll2" {
                XCTAssertNil(result.skippedReason)
                XCTAssertTrue(result.refusalDetails.isEmpty)
            } else {
                // SHRN2 is known. This retained negative reverses its narrowing
                // arrangements and uses invalid shift #0; operand validation
                // must refuse it rather than classify the mnemonic as unknown.
                XCTAssertEqual(result.skippedReason, "0xa000: invalid narrow or wide vector operands")
                XCTAssertEqual(result.refusalDetails.map(\.reason),
                    ["0xa000: invalid narrow or wide vector operands"])
            }
        }
    }

    func testKnownSHRN2ShapePreservesLowHalfAndPassesCensusInBothModes() throws {
        for enabled in [false, true] {
            try MacIRConfiguration.$ssaOverride.withValue(enabled) {
                XCTAssertEqual(MacIRBuilder().ssaEnabled, enabled)
                let row = MacIRSourceSpan(address: 0xa000, byteText: "20 84 0d 4f",
                    mnemonic: "shrn2", operands: "v0.16b, v1.8h, #3")
                let flow = C2MachineFlow(rows: [row])
                XCTAssertNil(flow.error)
                XCTAssertEqual(flow.reads, [Set(["v0", "v1"])])
                XCTAssertEqual(flow.writes, [Set(["v0"])])
                let parsed = try XCTUnwrap(MacIRBuilder.neonLaneOperation(
                    mnemonic: row.mnemonic, operandText: row.operands))
                let lane = parsed.semantics
                XCTAssertEqual(parsed.destination, "v0")
                XCTAssertEqual(parsed.sources, ["v1"])
                XCTAssertTrue(lane.highHalf)
                XCTAssertTrue(lane.readsDestination)
                XCTAssertEqual(lane.shift, 3)
                XCTAssertEqual(lane.arity, 2)
                // Halfwords [0,7,8,15,0x7ff,0x800,0xffff,0xfff8]
                // truncate after >>3, not rounding; the old low64 survives.
                let value = lane.evaluate(n: (0x000f000800070000, 0xfff8ffff080007ff),
                    oldDestination: (0x0123456789abcdef, 0xfedcba9876543210))
                XCTAssertEqual(value.low, 0x0123456789abcdef)
                XCTAssertEqual(value.high, 0xffff00ff01010000)
                let source = MacIRValue.register(name: "v1", version: 0)
                let oldDestination = MacIRValue.register(name: "v0", version: 0)
                let destination = MacIRValue.register(name: "v0", version: 1)
                let operation = MacIROperation.intrinsic(destination: destination,
                    name: lane.intrinsicName, arguments: [source, oldDestination])
                var function = MacIRFunction(name: "known_shrn2_control", startAddress: 0xa000,
                    returnType: "void", instructions: [
                        MacIRInstruction(source: row, operation: operation, neonLaneOp: lane),
                        MacIRInstruction(source: MacIRSourceSpan(address: 0xa004,
                            byteText: "c0 03 5f d6", mnemonic: "ret", operands: ""),
                            operation: .returnValue(nil))
                    ])
                function.ssaEnabled = enabled
                // Both inputs are explicit version-zero entry snapshots. The
                // nonnil destination is separate, and this linear fixture has
                // no phi, call or loop that could supply competing provenance.
                let result = analyze(function, expectedPrintedValue: source,
                    expectedUseAddress: 0xa000, ssaAccountingEnabled: enabled)
                XCTAssertNil(result.skippedReason)
                XCTAssertTrue(result.rows.isEmpty)
                XCTAssertTrue(result.refusalDetails.isEmpty)
                XCTAssertTrue(result.indirectBranchSites.isEmpty)
            }
        }
    }

    func testDotProductRequiresAccumulatorDefinition() {
        for mnemonic in ["udot", "sdot"] {
            for version in [1, 99] {
                let accumulator = MacIRValue.register(name: "v0", version: version)
                let function = MacIRFunction(name: "dot_product", startAddress: 0xb000,
                    returnType: "void", instructions: [
                        instruction(0xb000, "movi", "v0.4s, #0", .assign(
                            destination: .register(name: "v0", version: 1), source: .immediate(0))),
                        instruction(0xb004, mnemonic, "v0.4s, v1.16b, v2.16b", .intrinsic(
                            destination: .register(name: "v0", version: 2), name: mnemonic,
                            arguments: [accumulator, .register(name: "v1", version: 0),
                                .register(name: "v2", version: 0)])),
                        instruction(0xb008, "ret", "", .returnValue(nil))
                    ])
                let flow = C2MachineFlow(rows: function.instructions.map(\.source))
                XCTAssertNil(flow.error)
                XCTAssertEqual(flow.reads[1], ["v0", "v1", "v2"])
                XCTAssertEqual(flow.writes[1], ["v0"])
                XCTAssertEqual(flow.before[1]["v0"], [0xb000])
                let result = analyze(function, expectedPrintedValue: accumulator, expectedUseAddress: 0xb004)
                XCTAssertTrue(result.rows.isEmpty)
                if version == 1 {
                    XCTAssertNil(result.skippedReason)
                    XCTAssertTrue(result.refusalDetails.isEmpty)
                } else {
                    XCTAssertEqual(result.skippedReason, "missing SSA definition: v0_99")
                    XCTAssertEqual(result.refusalDetails.map(\.instructionAddress), [0xb004])
                    XCTAssertEqual(result.refusalDetails.map(\.register), ["v0"])
                }
            }
        }
    }

    func testInsertKeepsOtherPartialWritesRefused() {
        let accumulator = MacIRValue.register(name: "v0", version: 1)
        for sourceName in ["v1", "w1"] {
            let source = MacIRValue.register(name: sourceName, version: 0)
            let operands = "v0.s[1], " + (sourceName == "v1" ? "v1.s[2]" : "w1")
            for mnemonic in ["ins", "mov"] {
                let function = MacIRFunction(name: "lane_insert", startAddress: 0xc000,
                    returnType: "void", instructions: [
                        instruction(0xc000, "movi", "v0.4s, #0", .assign(destination: accumulator, source: .immediate(0))),
                        instruction(0xc004, mnemonic, operands, .intrinsic(
                            destination: .register(name: "v0", version: 2), name: "insert_lane",
                            arguments: [accumulator, source])),
                        instruction(0xc008, "ret", "", .returnValue(nil))
                    ])
                let result = analyze(function, expectedPrintedValue: accumulator, expectedUseAddress: 0xc004)
                XCTAssertTrue(result.rows.isEmpty)
                if mnemonic == "ins" {
                    let flow = C2MachineFlow(rows: function.instructions.map(\.source))
                    XCTAssertNil(result.skippedReason)
                    XCTAssertTrue(result.refusalDetails.isEmpty)
                    XCTAssertEqual(flow.reads[1], ["v0", sourceName == "v1" ? "v1" : "x1"])
                    XCTAssertEqual(flow.writes[1], ["v0"])
                } else {
                    XCTAssertEqual(result.skippedReason, "0xc004: partial vector destination")
                }
            }
        }
        for mnemonic in ["addhn", "addhn2"] {
            let row = instruction(0xc000, mnemonic, "v0.16b, v1.8h, v2.8h", .returnValue(nil)).source
            let flow = C2MachineFlow(rows: [row])
            XCTAssertNil(flow.error)
            XCTAssertEqual(flow.reads[0], mnemonic == "addhn" ? ["v1", "v2"] : ["v0", "v1", "v2"])
            XCTAssertEqual(flow.writes[0], ["v0"])
        }
    }

    func testCallArgumentsRequireDefinitionsAndABICarriers() throws {
        for mnemonic in ["bl", "blr"] {
            for name in ["x0", "w0", "x7", "w7", "x8", "w8", "v0", "s0", "d0", "q0", "v7", "s7", "d7", "q7", "x9", "v8"] {
                let value = MacIRValue.register(name: name, version: 1)
                let operation = try callOperation(value, indirect: mnemonic == "blr")
                let function = MacIRFunction(name: "call_argument", startAddress: 0xd000,
                    returnType: "void", instructions: [
                        instruction(0xd000, "mov", "\(name), #0", .assign(destination: value, source: .immediate(0))),
                        instruction(0xd004, mnemonic, mnemonic == "blr" ? "x9" : "0xe000", operation),
                        instruction(0xd008, "ret", "", .returnValue(nil))
                    ])
                let result = analyze(function, expectedPrintedValue: value, expectedUseAddress: 0xd004)
                XCTAssertTrue(result.rows.isEmpty, "\(mnemonic) \(name)")
                if ["x9", "v8"].contains(name) {
                    XCTAssertEqual(result.skippedReason, "printed operand is not a direct machine read", name)
                    XCTAssertEqual(result.refusalDetails.map(\.register), [name])
                } else {
                    XCTAssertNil(result.skippedReason, "\(mnemonic) \(name)")
                    XCTAssertTrue(result.refusalDetails.isEmpty)
                }
            }
            let missing = reg(0, 99)
            let function = MacIRFunction(name: "missing_call_argument", startAddress: 0xd000,
                returnType: "void", instructions: [
                    instruction(0xd000, mnemonic, mnemonic == "blr" ? "x9" : "0xe000",
                        try callOperation(missing, indirect: mnemonic == "blr")),
                    instruction(0xd004, "ret", "", .returnValue(nil))
                ])
            let result = analyze(function, expectedPrintedValue: missing, expectedUseAddress: 0xd000)
            XCTAssertEqual(result.skippedReason, "missing SSA definition: x0_99")
            XCTAssertEqual(result.refusalDetails.map(\.instructionAddress), [0xd000])
            XCTAssertTrue(result.rows.isEmpty)
        }
    }

    func testCallArgumentStillChecksDominance() throws {
        let function = MacIRFunction(name: "call_join", startAddress: 0xe000,
            returnType: "void", instructions: [
                instruction(0xe000, "cbz", "x3, 0xe00c", .conditionalBranch(condition: "==",
                    left: reg(3, 0), right: .immediate(0), target: .immediate(0xe00c))),
                instruction(0xe004, "mov", "x0, #1", .assign(destination: reg(0, 1), source: .immediate(1))),
                instruction(0xe008, "b", "0xe010", .intrinsic(destination: nil, name: "branch", arguments: [.immediate(0xe010)])),
                instruction(0xe00c, "mov", "x0, #2", .assign(destination: reg(0, 2), source: .immediate(2))),
                instruction(0xe010, "bl", "0xf000", try callOperation(reg(0, 1))),
                instruction(0xe014, "ret", "", .returnValue(nil))
            ])
        let result = analyze(function, expectedPrintedValue: reg(0, 1), expectedUseAddress: 0xe010)
        XCTAssertNil(result.skippedReason)
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertTrue(result.rows.contains {
            $0.kind == "J" && $0.variable == "x0_1" && $0.useAddress == 0xe010
                && $0.definitionAddress == 0xe004 && $0.reachingDefinitions == [0xe004, 0xe00c]
        })
    }

    private func callOperation(_ value: MacIRValue, indirect: Bool = false) throws -> MacIROperation {
        let scope = try XCTUnwrap(MacIRCallArgumentObservationScope(gprIndices: [0]))
        let arguments = try XCTUnwrap(MacIRCallArguments([
            MacIRCallArgument(location: .gpr(index: 0, carrierWidth: 64), role: .unknown, value: value)
        ], observationScope: scope))
        let controls = indirect ? try XCTUnwrap(MacIRCallControlInputs([
            MacIRCallControlInput(role: .indirectTarget, register: .gpr(index: 9), value: reg(9, 0))
        ])) : .none
        let frame = try XCTUnwrap(MacIRCallFrame(target: indirect ? "(*x9)" : "callee",
            knownSignature: nil, controlInputs: controls, arguments: arguments))
        return .call(frame: frame, result: nil)
    }

    @MainActor
    func testLibjpegDataflowCensus() throws {
        guard ProcessInfo.processInfo.environment["MACSCOPE_LIBJPEG_WITNESS"] == "1" else {
            throw XCTSkip("Set MACSCOPE_LIBJPEG_WITNESS=1 for the explicitly authorized libjpeg census")
        }
        let path = "/opt/homebrew/lib/libjpeg.8.dylib"
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("libjpeg witness input is absent")
        }
        let destination = ProcessInfo.processInfo.environment["MACSCOPE_C2_OUT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory.appendingPathComponent("c2-census-\(UUID().uuidString)", isDirectory: true)
        // Explicit test-only capture; no product option, environment toggle or second run.
        let capturesProofFacts = true
        let artifacts = ["c2-census.csv", "c2-summary.json", "pseudocode-all.txt"]
        for name in artifacts {
            guard !FileManager.default.fileExists(atPath: destination.appendingPathComponent(name).path) else {
                throw NSError(domain: "C2Census", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "Census artifact already exists: \(name); do not repeat unchanged input"])
            }
        }
        let began = Date()
        let initial = try AnalysisEngine().analyze(url: URL(fileURLWithPath: path))
        let headers = try CalleeWitnessHeaders.load(into: initial)
        let snapshot = headers.snapshot
        let slot = snapshot.primarySlot
        let analysis = try XCTUnwrap(snapshot.analysis(in: slot))
        // Warm the identical image-wide report before capturing any per-function input.
        let report = try XCTUnwrap(snapshot.imageWideIndirectCalls(in: slot, compute: true),
            "A complete, uncancelled report within the 4096-function cap is required")
        let options = DecompilerOptions(userDefaults: .standard)
        let printer = PseudocodePrinter(options: options)
        var rows: [C2DataflowCensus.Finding] = []
        var skipped: [[String: Any]] = []
        var skipReasons: [String: Int] = [:]
        var refusalsByReason: [String: Int] = [:]
        var outputRows: [CalleeWitnessOutputMetrics.Row] = []
        var allPseudocode = ""
        var analyzed = 0
        var partiallyAnalyzed = 0
        var analysisReasons: [String?] = []
        var lifterRefusalFunctions: [[String: Any]] = []
        var ssaMetrics: [[String: Any]] = []
        var jumpTableEscapes: [[String: Any]] = []
        var resolvedTableCount = 0
        var totalPhis = 0
        var totalJoinBlocks = 0
        let ssaAccountingEnabled = MacIRConfiguration.ssaEnabled
        // Stream diagnostics per function; never retain a second whole-image dump.
        let proofWriter = C2ProofDiagnostics.Writer()
        var proofFactsOutput: FileHandle?
        var proofCoverageOutput: FileHandle?
        if capturesProofFacts {
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                proofFactsOutput = try Self.openProofOutput(destination.appendingPathComponent("c2-proof-facts.jsonl"))
                proofCoverageOutput = try Self.openProofOutput(destination.appendingPathComponent("c2-proof-coverage.jsonl"))
            } catch { proofWriter.recordFailure(error) }
        }
        defer { try? proofFactsOutput?.close(); try? proofCoverageOutput?.close() }
        for identity in analysis.functions {
            let input = snapshot.pseudocodeRenderInput(selectedAddress: identity.startAddress, in: slot)
            XCTAssertEqual(input.startAddress, identity.startAddress)
            // Scope passive copies around each original call, never rerun it.
            let proofCollector = capturesProofFacts && proofWriter.failureReason == nil ? C2ProofDiagnostics.Collector() : nil
            let function = C2ProofDiagnostics.withCollector(proofCollector, phase: "build") {
                Self.buildFunction(printer: printer, input: input)
            }
            let document = C2ProofDiagnostics.withCollector(proofCollector, phase: "render") {
                printer.print(function: function, types: input.types,
                    nameOverrides: input.nameOverrides, registerNameOverrides: input.registerNameOverrides,
                    stackLocalOverrides: input.stackLocalOverrides, resolvedIndirectCalls: input.resolvedIndirectCalls)
            }
            let projected = PseudocodePrinter.applyingStackLocalOverrides(input.stackLocalOverrides,
                to: MacIRFPEnvironmentPseudocodeProjection.project(function))
            var names = PseudocodeNameContext(function: projected, types: input.types,
                callTargetRenames: input.nameOverrides, registerNameOverrides: input.registerNameOverrides)
            names.redundantCompareIndices = printer.redundantCompareIndices(function: projected, names: names)
            names.resolvedIndirectCalls = input.resolvedIndirectCalls
            let machine = input.instructions.map {
                MacIRSourceSpan(address: $0.address, byteText: $0.bytes, mnemonic: $0.mnemonic,
                    operands: $0.operands, comment: $0.comment, structuredOperands: $0.structuredOperands)
            }
            if machine.count > 1024 {
                print("C2_CENSUS_FUNCTION \(identity.name) 0x\(String(identity.startAddress, radix: 16)) instructions=\(machine.count)")
            }
            let result = C2ProofDiagnostics.withCollector(proofCollector, phase: "census") {
                C2DataflowCensus.analyze(function: projected, document: document,
                    machine: machine, printer: printer, names: names,
                    ssaAccountingEnabled: ssaAccountingEnabled)
            }
            // Copy the unchanged verdict only after the original analysis has returned.
            if let proofCollector, proofWriter.failureReason == nil {
              do {
                let exported = try C2ProofDiagnostics.export(function: projected, machine: machine,
                    result: result, collector: proofCollector,
                    sourceHead: ProcessInfo.processInfo.environment["MACSCOPE_WITNESS_SOURCE_HEAD"] ?? "unrecorded",
                    flags: ["ssaAccountingEnabled": ssaAccountingEnabled, "functionSSAEnabled": function.ssaEnabled,
                        "captureEnabled": true, "explicitCFGEnabled": MacIRConfiguration.explicitCFGEnabled,
                        "returnContractEnabled": MacIRConfiguration.returnContractEnabled,
                        "structureControlFlow": options.structureControlFlow, "deadCodeElimination": options.deadCodeElimination,
                        "nopElision": options.nopElision, "functionSizeGate": options.functionSizeGate,
                        "recoverSharedTails": options.recoverSharedTails, "recoverLoopExits": options.recoverLoopExits,
                        "recoverGuardRegions": options.recoverGuardRegions, "sharedTailInstructionLimit": options.sharedTailInstructionLimit,
                        "recoveryMaxTransferRatioPercent": options.recoveryMaxTransferRatioPercent,
                        "recoveryMaxAdditionalNesting": options.recoveryMaxAdditionalNesting], functionOrdinal: analysisReasons.count)
                // The ledger is emitted once; use records carry exact sequence references.
                proofWriter.emit(exported,
                    writeCoverage: { data in
                        guard let output = proofCoverageOutput else { throw POSIXError(.EBADF) }
                        try output.write(contentsOf: data)
                    }, writeRecord: { data in
                        guard let output = proofFactsOutput else { throw POSIXError(.EBADF) }
                        try output.write(contentsOf: data)
                    })
              } catch { proofWriter.recordFailure(error) }
            }
            rows.append(contentsOf: result.rows)
            analysisReasons.append(result.skippedReason)
            if ssaAccountingEnabled {
                if !result.lifterRefusals.isEmpty {
                    lifterRefusalFunctions.append(["function": identity.name, "start": identity.startAddress,
                        "refusals": result.lifterRefusals.map(Self.refusalRecord)])
                    let refusalGroups = Dictionary(grouping: result.lifterRefusals,
                        by: C2DataflowCensus.lifterRefusalClass)
                    for reason in refusalGroups.keys.sorted() {
                        print("C2_REFUSAL function=\(identity.name) start=0x\(String(identity.startAddress, radix: 16)) reason=\(reason) scopes=\(refusalGroups[reason]?.count ?? 0)")
                    }
                }
                let phiCount = function.ssaInfo?.plan.phis.count ?? function.phis.count
                let joinCount = function.cfg?.blocks.filter { $0.predecessors.count > 1 }.count ?? 0
                totalPhis += phiCount
                totalJoinBlocks += joinCount
                ssaMetrics.append(["function": identity.name, "start": identity.startAddress,
                    "ssaEnabled": function.ssaEnabled, "hasDefinitionMetadata": function.ssaInfo != nil,
                    "phis": phiCount, "renderablePhis": function.phis.count, "joinBlocks": joinCount])
                let machineAddresses = Set(machine.map(\.address))
                let owningTables = input.jumpTables.filter { machineAddresses.contains($0.key) }
                resolvedTableCount += owningTables.count
                jumpTableEscapes.append(contentsOf: Self.jumpTableEscapeRecords(function: identity.name,
                    start: identity.startAddress, end: identity.endAddress, tables: owningTables))
            }
            if let reason = result.skippedReason {
                let details = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result.refusalDetails))
                var skippedRecord: [String: Any] = ["function": identity.name, "start": identity.startAddress,
                    "reason": reason, "provenRows": result.rows.count,
                    "refusalDetails": details, "indirectBranchSites": result.indirectBranchSites]
                if ssaAccountingEnabled {
                    skippedRecord["detectorReason"] = result.detectorSkippedReason.map { $0 as Any } ?? NSNull()
                    skippedRecord["lifterRefusalClasses"] = Array(Set(result.lifterRefusals.map(C2DataflowCensus.lifterRefusalClass))).sorted()
                }
                skipped.append(skippedRecord)
                skipReasons[reason, default: 0] += 1
                Self.countRefusals(reason, into: &refusalsByReason)
                if !result.rows.isEmpty { partiallyAnalyzed += 1 }
            } else {
                analyzed += 1
            }
            let text = document.text
            outputRows.append(CalleeWitnessOutputMetrics.extract(name: identity.name,
                start: identity.startAddress, text: text))
            let headerName = identity.name.replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            allPseudocode += "// FUNCTION name=\(headerName) start=0x\(String(identity.startAddress, radix: 16))\n" + text + "\n\n"
        }
        let counts = Dictionary(grouping: rows, by: \.kind).mapValues(\.count)
        let functionsAffected = Set(rows.map(\.start)).count
        let cancelled = Task.isCancelled
        let validity = Self.summaryValidityForTesting(ssaAccountingEnabled: ssaAccountingEnabled,
            partiallyAnalyzed: partiallyAnalyzed, affected: functionsAffected,
            skipped: skipped.count, analysisReasons: analysisReasons,
            refusalsByReason: refusalsByReason, cancelled: cancelled)

        var summary: [String: Any] = [
            "schemaVersion": 1, "input": path,
            "sourceHead": ProcessInfo.processInfo.environment["MACSCOPE_WITNESS_SOURCE_HEAD"] ?? "unrecorded",
            "functions": analysis.functions.count, "functionsAnalyzed": analyzed,
            "functionsVisited": analysis.functions.count, "functionsPartiallyAnalyzed": partiallyAnalyzed,
            "functionsSkipped": skipped.count, "skippedFunctions": skipped, "skipReasons": skipReasons,
            "refusalsByReason": refusalsByReason,
            "valid": validity.valid, "invalidReason": validity.invalidReason.map { $0 as Any } ?? NSNull(),
            "coverageCounting": "functionsAnalyzed means no explicit refusal within the detector's supported model, not semantic certification. functionsSkipped includes partially analyzed functions; flagged rows are retained when a coverage reason is present.",
            "method": "J: a displayed SSA definition fails machine dominance and an alternative register definition reaches the use. L: a displayed natural-loop use retains an outside definition while an in-loop definition reaches it, without an emitted phi destination. Predicate operands are checked at their NZCV producer; phi inputs at predecessor exit. Guarded selects, non-direct machine reads and unsupported machine semantics report coverage limits. Calls use conservative ABI clobbers.",
            "defectsByKind": ["L": counts["L", default: 0], "J": counts["J", default: 0]],
            "functionsAffected": functionsAffected,
            "functionsAffectedByKind": ["L": Set(rows.filter { $0.kind == "L" }.map(\.start)).count,
                "J": Set(rows.filter { $0.kind == "J" }.map(\.start)).count],
            "outputMetrics": CalleeWitnessOutputMetrics.aggregate(outputRows),
            "importedHeaders": headers.headerNames,
            "importedPrototypeCount": headers.summary.importedPrototypeCount,
            "completeWarmImageReport": true,
            "typedResolvedCallSites": report.resolutions.filter { if case .type = $0.scope { return true }; return false }.count,
            "renderedTypedNotes": allPseudocode.components(separatedBy: "/* via struct ").count - 1,
            "renderPath": "DocumentExportService.pseudocodeText printer build/print seams; one render per function",
            "options": String(describing: options), "nativeSleighExport": false,
            "cancelled": cancelled, "seconds": Date().timeIntervalSince(began)
        ]
        summary = Self.assemblingSummaryForTesting(base: summary, ssaAccountingEnabled: ssaAccountingEnabled) {
            var usage = rusage()
            let resourceUsageAvailable = getrusage(RUSAGE_SELF, &usage) == 0
            var additions: [String: Any] = [
            "entryBackedgeRefusalFunctions": refusalsByReason[C2DataflowCensus.entryBackedgeReason, default: 0],
            "lifterRefusalFunctions": lifterRefusalFunctions,
            "ssaMetricsByFunction": ssaMetrics, "totalPhis": totalPhis, "totalJoinBlocks": totalJoinBlocks,
            "phiBoundSatisfied": totalPhis <= 3 * totalJoinBlocks,
            "resolvedJumpTables": resolvedTableCount, "jumpTableEscapes": jumpTableEscapes,
            "jumpTableAddressCoverage": "Resolved render inputs retain BR addresses and ordered case targets, but not table storage addresses; tableAddress is null.",
            "peakRSSBytes": resourceUsageAvailable ? usage.ru_maxrss as Any : NSNull(),
            "peakRSSScope": "test host process lifetime high-water mark sampled at census completion",
            ]
            additions["coverageCounting"] = "functionsAnalyzed means no detector coverage reason or SSA lifter refusal, not semantic certification. functionsSkipped includes partially analyzed functions; flagged rows are retained when a coverage reason is present. refusalsByReason counts each class once per function, including unprinted entry-backedge refusals. Detector and lifter reasons remain separately recorded."
            return additions
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        // Exclusive creation also protects another process's receipt appearing during analysis.
        try Data(([C2DataflowCensus.csvHeader] + rows.map(\.csvRow)).joined(separator: "\n").appending("\n").utf8)
            .write(to: destination.appendingPathComponent("c2-census.csv"), options: .withoutOverwriting)
        try Data(allPseudocode.utf8).write(to: destination.appendingPathComponent("pseudocode-all.txt"), options: .withoutOverwriting)
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathComponent("c2-summary.json"), options: .withoutOverwriting)
        // Diagnose export qualification only after original census artifacts are saved.
        do {
            try proofFactsOutput?.close(); proofFactsOutput = nil
            try proofCoverageOutput?.close(); proofCoverageOutput = nil
        } catch { proofWriter.recordFailure(error) }
        if let reason = proofWriter.failureReason {
            print("C2_PROOF_EXPORT_INCOMPLETE \(reason)")
            XCTFail("Proof diagnostics export incomplete: \(reason)")
        }
        print("C2_CENSUS_RECEIPT \(destination.path)")
        if let reason = validity.invalidReason {
            print("C2_CENSUS_INVALID \(reason)")
            XCTFail("Invalid census: \(reason)")
        }
        XCTAssertEqual(skipped.count, analysisReasons.compactMap { $0 }.count,
            "functionsSkipped must count every analysis with a non-nil skippedReason")
    }

    func testUnknownUseIsCoverageNotZeroDefects() {
        let value = MacIRValue.unknown("unavailable_x8")
        let result = analyze(printedLeaf(value), expectedPrintedValue: value)
        XCTAssertTrue(result.rows.isEmpty)
        XCTAssertEqual(result.skippedReason, "unknown-use: unavailable_x8")
    }

    func testEveryPrintedRefusalLeafHasReason() {
        let values: [MacIRValue] = [.unknown("unavailable_x8"), .temporary(1),
            .argumentFragment(rowID: .init(rawValue: "fragment"), byteOffset: 0, size: 8)]
        for value in values {
            let result = analyze(printedLeaf(value), expectedPrintedValue: value)
            XCTAssertTrue(result.rows.isEmpty, "\(value)")
            XCTAssertNotNil(result.skippedReason, "\(value)")
            if case .unknown = value {
                XCTAssertEqual(result.skippedReason, "unknown-use: unavailable_x8")
            } else {
                XCTAssertEqual(result.skippedReason,
                    "printed temporary or argument fragment has no physical-register mapping")
            }
        }
    }

    func testPrintedLiteralLeavesHaveNoReason() {
        let values: [MacIRValue] = [.immediate(7), .symbol("literal_symbol"), .stackSlot(offset: -8),
            .argument(bindingID: .entryStack(byteOffset: 0)), .register(name: "xzr", version: 0)]
        for value in values {
            let result = analyze(printedLeaf(value), expectedPrintedValue: value)
            XCTAssertNil(result.skippedReason, "\(value)")
            XCTAssertTrue(result.rows.isEmpty, "\(value)")
        }
    }

    func testRefusalsByReasonClasses() {
        var counts: [String: Int] = [:]
        Self.countRefusals("unknown-use: unavailable_x8; unknown-use: unavailable_x19; "
            + "unknown-use: unavailable_join_result", into: &counts)
        XCTAssertEqual(counts, ["unavailable_x": 1, "unavailable_join_result": 1])
        Self.countRefusals("unknown-use: unavailable_x8; unknown-use: unbound_x0; "
            + "unknown-use: clobbered_x19; unknown-use: refusal: missing value; "
            + "unknown-use: unavailable_0x4000; missing SSA definition: x1_1; "
            + "missing SSA definition: x2_1", into: &counts)
        XCTAssertEqual(counts, ["unavailable_x": 2, "unavailable_join_result": 1,
            "unbound_": 1, "clobbered_": 1, "refusal:": 1,
            "unavailable_": 1, "missing SSA definition": 1])
    }

    func testRefusalClassesDropAddresses() {
        var counts: [String: Int] = [:]
        Self.countRefusals("0x19c80: unsupported machine mnemonic sdot; "
            + "unresolved indirect branch at 0x1180; unresolved indirect branch at 0x118c; "
            + "unknown-use: #0xffffffff00000000", into: &counts)
        XCTAssertEqual(counts, ["unsupported machine mnemonic sdot": 1,
            "unresolved indirect branch": 1, "unknown-use: immediate": 1])
    }

    func testSummaryValidityRejectsBlindShape() {
        let blind = Self.summaryValidity(partiallyAnalyzed: 0, affected: 0, skipped: 1,
            analysisReasons: [""], refusalsByReason: [:], cancelled: false)
        XCTAssertFalse(blind.valid)
        XCTAssertEqual(blind.invalidReason, "blind census has skipped functions without explicit refusal coverage")
        let covered = Self.summaryValidity(partiallyAnalyzed: 0, affected: 0, skipped: 1,
            analysisReasons: ["unknown-use: unavailable_x8"],
            refusalsByReason: ["unavailable_x": 1], cancelled: false)
        XCTAssertTrue(covered.valid)
        XCTAssertNil(covered.invalidReason)
        let emptyFunctionReason = Self.summaryValidity(partiallyAnalyzed: 0, affected: 0, skipped: 2,
            analysisReasons: ["unknown-use: unavailable_x8", " ; "],
            refusalsByReason: ["unavailable_x": 1], cancelled: false)
        XCTAssertFalse(emptyFunctionReason.valid)
        let emptyClasses = Self.summaryValidity(partiallyAnalyzed: 0, affected: 0, skipped: 1,
            analysisReasons: ["unknown-use: unavailable_x8"], refusalsByReason: [:], cancelled: false)
        XCTAssertFalse(emptyClasses.valid)
        let cancelled = Self.summaryValidity(partiallyAnalyzed: 1, affected: 1, skipped: 1,
            analysisReasons: ["unknown-use: unavailable_x8"],
            refusalsByReason: ["unavailable_x": 1], cancelled: true)
        XCTAssertFalse(cancelled.valid)
        XCTAssertEqual(cancelled.invalidReason, "census cancelled")
        let mismatched = Self.summaryValidity(partiallyAnalyzed: 0, affected: 0, skipped: 0,
            analysisReasons: [nil, "unknown-use: unavailable_x8"],
            refusalsByReason: ["unavailable_x": 1], cancelled: false)
        XCTAssertFalse(mismatched.valid)
        XCTAssertEqual(mismatched.invalidReason, "functionsSkipped does not match analyses with skippedReason")
        let complete = Self.summaryValidity(partiallyAnalyzed: 0, affected: 0, skipped: 0,
            analysisReasons: [nil], refusalsByReason: [:], cancelled: false)
        XCTAssertTrue(complete.valid)
        XCTAssertNil(complete.invalidReason)
    }

    func testUnprintedEntryBackedgeRefusalIsCountedWithoutHidingDefects() {
        var function = join(merged: false)
        function.refusals = [.init(reason: .unknownEffects, scope: .function,
            detail: C2DataflowCensus.entryBackedgeReason)]
        let result = analyze(function, ssaAccountingEnabled: true)
        XCTAssertEqual(result.skippedReason, C2DataflowCensus.entryBackedgeReason)
        XCTAssertNil(result.detectorSkippedReason, "Independent machine coverage is unchanged")
        XCTAssertEqual(result.lifterRefusals, function.refusals)
        XCTAssertTrue(result.rows.contains { $0.kind == "J" && $0.useAddress == 0x2010 },
            "A producer refusal must not suppress an independently proven wrong-path join")
        var classes: [String: Int] = [:]
        Self.countRefusals(result.skippedReason ?? "", into: &classes)
        XCTAssertEqual(classes[C2DataflowCensus.entryBackedgeReason], 1)
    }

    func testSyntheticPhiEdgeSourcesKeepIndependentIncomingChecks() {
        var function = join(merged: true)
        function.ssaEnabled = true
        let correct = analyze(function)
        XCTAssertNil(correct.skippedReason, "Synthetic copies retain exact predecessor identity")
        XCTAssertTrue(correct.rows.isEmpty)
        function.phis[0].incoming[0].value = reg(1, 2)
        let wrong = analyze(function)
        XCTAssertNil(wrong.skippedReason)
        XCTAssertTrue(wrong.rows.contains {
            $0.kind == "J" && $0.useAddress == 0x2008 && $0.definitionAddress == 0x200c
                && $0.controlAddresses == [0x2010]
        }, "An incoming supplied only by the sibling arm is still checked at its named predecessor exit")
    }

    func testSSAOriginRefusalIsReportedFromDefinitionMetadata() {
        var function = loop(merged: true)
        function.ssaEnabled = true
        let definition = MacIRSSA.Definition(id: 0, cell: 1, bitWidth: 64, view: .integer,
            origin: .refusal(.unknownEffects, 0x1008))
        let plan = MacIRSSA.Plan(definitions: [definition], phis: [], rowReadBindings: [],
            rowWriteBindings: [], blockEntryBindings: [], blockExitBindings: [], liveIn: [],
            liveOut: [], aliases: [:], refusals: [])
        function.ssaInfo = .init(plan: plan, values: [0: reg(1, 2)],
            sourceAddresses: function.instructions.map { $0.source.address })
        let refusals = C2DataflowCensus.lifterRefusals(in: function)
        XCTAssertEqual(refusals, [.init(reason: .unknownEffects, scope: .cell(1, 0x1008), detail: nil)],
            "Definition-origin refusals must remain accountable even without a row annotation")
    }

    func testFlagOffDoesNotAcquireSSARefusalAccounting() {
        var function = join(merged: false)
        function.refusals = [.init(reason: .unknownEffects, scope: .row(0x2004), detail: "unknown row")]
        let result = analyze(function, ssaAccountingEnabled: false)
        XCTAssertNil(result.skippedReason, "Retained-path accounting stays unchanged")
        XCTAssertTrue(result.lifterRefusals.isEmpty)
        XCTAssertTrue(result.rows.contains { $0.kind == "J" && $0.useAddress == 0x2010 })
    }

    func testSSARefusalSurvivesIndependentMachineGraphRefusal() {
        var function = MacIRFunction(name: "unresolved_transfer", startAddress: 0x5000,
            returnType: "void", instructions: [instruction(0x5000, "br", "x8",
                .intrinsic(destination: nil, name: "branch", arguments: [reg(8, 0)]))])
        function.ssaEnabled = true
        function.refusals = [.init(reason: .unresolvedIndirectBranch, scope: .block(0), detail: nil)]
        let result = analyze(function, ssaAccountingEnabled: true)
        XCTAssertEqual(result.detectorSkippedReason, "unresolved indirect branch at 0x5000")
        XCTAssertTrue(result.skippedReason?.contains("lifter unresolvedIndirectBranch") == true)
        XCTAssertEqual(result.lifterRefusals, function.refusals)
        XCTAssertTrue(result.rows.isEmpty, "Unavailable independent control flow cannot certify a defect")
    }

    func testSummaryValidityRejectsUnaccountedPartialRefusalsAndWrongClassCounts() {
        let partial = Self.ssaSummaryValidity(partiallyAnalyzed: 1, affected: 1, skipped: 1,
            analysisReasons: [" ; "], refusalsByReason: ["unknown": 1], cancelled: false)
        XCTAssertFalse(partial.valid)
        XCTAssertEqual(partial.invalidReason, "skipped function has no explicit refusal coverage")
        let wrongCounts = Self.ssaSummaryValidity(partiallyAnalyzed: 0, affected: 0, skipped: 1,
            analysisReasons: [C2DataflowCensus.entryBackedgeReason],
            refusalsByReason: [C2DataflowCensus.entryBackedgeReason: 2], cancelled: false)
        XCTAssertFalse(wrongCounts.valid)
        XCTAssertEqual(wrongCounts.invalidReason, "refusalsByReason does not match per-function refusal classes")
        let covered = Self.ssaSummaryValidity(partiallyAnalyzed: 1, affected: 1, skipped: 1,
            analysisReasons: [C2DataflowCensus.entryBackedgeReason, nil],
            refusalsByReason: [C2DataflowCensus.entryBackedgeReason: 1], cancelled: false)
        XCTAssertTrue(covered.valid, "One partial, one analyzed and no fully skipped functions account for both visits")
    }

    func testJumpTableEscapeEvidenceUsesOwningBoundsAndOrderedCases() {
        let records = Self.jumpTableEscapeRecords(function: "bounded_dispatch", start: 0x6000,
            end: 0x6020, tables: [0x6004: [0x6000, 0x6020, 0x5ffc, 0x601c, 0x6020]])
        XCTAssertEqual(records.compactMap { $0["caseIndex"] as? Int }, [1, 2, 4],
            "The end is exclusive and repeated targets retain their distinct case indices")
        XCTAssertEqual(records.compactMap { $0["target"] as? UInt64 }, [0x6020, 0x5ffc, 0x6020])
        XCTAssertTrue(records.allSatisfy { ($0["brAddress"] as? UInt64) == 0x6004 })
        XCTAssertTrue(records.allSatisfy { $0["tableAddress"] is NSNull },
            "Missing table storage provenance must be explicit rather than inferred from the BR")
    }

    static func assemblingSummaryForTesting(base: [String: Any], ssaAccountingEnabled: Bool,
                                           additions: () -> [String: Any]) -> [String: Any] {
        guard ssaAccountingEnabled else { return base }
        var summary = base
        for (key, value) in additions() { summary[key] = value }
        return summary
    }

    static func summaryValidityForTesting(ssaAccountingEnabled: Bool,
                                         partiallyAnalyzed: Int, affected: Int, skipped: Int,
                                         analysisReasons: [String?], refusalsByReason: [String: Int],
                                         cancelled: Bool) -> (valid: Bool, invalidReason: String?) {
        if ssaAccountingEnabled {
            return ssaSummaryValidity(partiallyAnalyzed: partiallyAnalyzed, affected: affected,
                skipped: skipped, analysisReasons: analysisReasons, refusalsByReason: refusalsByReason,
                cancelled: cancelled)
        }
        return summaryValidity(partiallyAnalyzed: partiallyAnalyzed, affected: affected,
            skipped: skipped, analysisReasons: analysisReasons, refusalsByReason: refusalsByReason,
            cancelled: cancelled)
    }

    private static func ssaSummaryValidity(partiallyAnalyzed: Int, affected: Int, skipped: Int,
                                        analysisReasons: [String?], refusalsByReason: [String: Int],
                                        cancelled: Bool) -> (valid: Bool, invalidReason: String?) {
        let base = summaryValidity(partiallyAnalyzed: partiallyAnalyzed, affected: affected,
            skipped: skipped, analysisReasons: analysisReasons, refusalsByReason: refusalsByReason,
            cancelled: cancelled)
        guard base.valid else { return base }
        let reasons = analysisReasons.compactMap { $0 }
        guard !reasons.contains(where: { reasonSet($0).isEmpty }) else {
            return (false, "skipped function has no explicit refusal coverage")
        }
        var expectedClasses: [String: Int] = [:]
        for reason in reasons { countRefusals(reason, into: &expectedClasses) }
        guard refusalsByReason == expectedClasses else {
            return (false, "refusalsByReason does not match per-function refusal classes")
        }
        guard partiallyAnalyzed >= 0, partiallyAnalyzed <= skipped,
              partiallyAnalyzed <= affected, affected <= analysisReasons.count else {
            return (false, "inconsistent analyzed, skipped or affected function counts")
        }
        return (true, nil)
    }

    private static func refusalRecord(_ refusal: MacIRRefusal) -> [String: Any] {
        ["reason": refusal.reason.rawValue, "class": C2DataflowCensus.lifterRefusalClass(refusal),
         "scope": String(describing: refusal.scope), "detail": refusal.detail.map { $0 as Any } ?? NSNull()]
    }

    private static func jumpTableEscapeRecords(function: String, start: UInt64, end: UInt64,
                                               tables: [UInt64: [UInt64]]) -> [[String: Any]] {
        tables.keys.sorted().flatMap { branch -> [[String: Any]] in
            (tables[branch] ?? []).enumerated().compactMap { index, target in
                guard target < start || target >= end else { return nil }
                return ["function": function, "brAddress": branch, "tableAddress": NSNull(),
                    "caseIndex": index, "target": target, "functionStart": start, "functionEnd": end]
            }
        }
    }

    private static func summaryValidity(partiallyAnalyzed: Int, affected: Int, skipped: Int,
                                        analysisReasons: [String?], refusalsByReason: [String: Int],
                                        cancelled: Bool) -> (valid: Bool, invalidReason: String?) {
        let reasons = analysisReasons.compactMap { $0 }
        if cancelled { return (false, "census cancelled") }
        guard skipped == reasons.count else {
            return (false, "functionsSkipped does not match analyses with skippedReason")
        }
        if partiallyAnalyzed == 0 && affected == 0 && skipped > 0,
           reasons.contains(where: { reasonSet($0).isEmpty }) || refusalsByReason.isEmpty {
            return (false, "blind census has skipped functions without explicit refusal coverage")
        }
        return (true, nil)
    }

    private static func reasonSet(_ reason: String) -> Set<String> {
        Set(reason.components(separatedBy: "; ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    private static func countRefusals(_ reason: String, into counts: inout [String: Int]) {
        let classes = Set(reasonSet(reason).map { reason -> String in
            let marker = "unknown-use: "
            guard reason.hasPrefix(marker) else {
                let normalized = reason.replacingOccurrences(of: #"^0[xX][0-9a-fA-F]+: "#,
                    with: "", options: .regularExpression)
                    .replacingOccurrences(of: #" at 0[xX][0-9a-fA-F]+$"#,
                        with: "", options: .regularExpression)
                return String(normalized.prefix { $0 != ":" })
            }
            let name = String(reason.dropFirst(marker.count))
            if name.hasPrefix("#") { return "unknown-use: immediate" }
            for prefix in ["unavailable_join_result", "unbound_", "clobbered_", "refusal:"] {
                if name.hasPrefix(prefix) { return prefix }
            }
            // Keep the register bank but discard its index, or discard an address suffix.
            if let suffix = name.range(of: #"0[xX][0-9a-fA-F]+|(?<=[xwvqbdhs])[0-9]+"#,
                                       options: .regularExpression) {
                return String(name[..<suffix.lowerBound])
            }
            return name
        }.filter { !$0.isEmpty })
        for reasonClass in classes { counts[reasonClass, default: 0] += 1 }
    }

    private func printedLeaf(_ value: MacIRValue) -> MacIRFunction {
        MacIRFunction(name: "printed_leaf", startAddress: 0x4000, returnType: "void", instructions: [
            instruction(0x4000, "b", "0x4008", .intrinsic(destination: nil, name: "branch",
                arguments: [.immediate(0x4008)])),
            instruction(0x4008, "str", "x8, [x2]", .store(source: value, address: reg(2, 0))),
            instruction(0x400c, "ret", "", .returnValue(nil))
        ])
    }

    /// The census artifact's build seam: the canonical overload split at its existing build
    /// seam, passing every argument DocumentExportService.pseudocodeText passes, so the dump
    /// matches the shipping export. Focused contract tests call it to prove that address-keyed
    /// authority present in the render input reaches the built function.
    static func buildFunction(printer: PseudocodePrinter, input: PseudocodeRenderInput) -> MacIRFunction {
        printer.buildFunction(functionName: input.functionName,
            startAddress: input.startAddress, jumpTables: input.jumpTables,
            objcSelectors: input.objcSelectors, constantStrings: input.constantStrings,
            signatureOverrides: input.signatureOverrides,
            authoredCallSignaturesByTarget: input.authoredCallSignaturesByTarget,
            directCallVoidResultTargets: input.directCallVoidResultTargets,
            machineCallUsage: input.machineCallUsage,
            machineUsageContext: input.machineUsageContext,
            knownTailCallTargets: input.knownTailCallTargets,
            slotCallContracts: input.slotCallContracts,
            callerReturnWidth: input.callerReturnWidth, callerReturnType: input.callerReturnType,
            types: input.types, instructions: input.instructions)
    }

    private func tailBoundaryFixture(ssa: Bool, start: UInt64 = 0x21294,
                                     target: UInt64 = 0x21038, bytes: String = "69 ff ff 17",
                                     callerType: String? = "uint32_t", calleeType: String? = "uint64_t")
        -> (MacIRFunction, [MacIRSourceSpan]) {
        let row = InstructionRow(address: start, bytes: bytes, mnemonic: "b",
            operands: "0x" + String(target, radix: 16), hasBreakpoint: false, comment: nil)
        let signature = callerType.map { FunctionSignatureOverride(returnType: $0, args: []) }
        let callee = calleeType.map { FunctionSignatureOverride(returnType: $0, args: []) }
        let function = PseudocodePrinter().buildFunction(functionName: "tail_boundary", startAddress: start,
            signatureOverrides: signature.map { [start: $0] } ?? [:],
            authoredCallSignaturesByTarget: callee.map { ["_boundary_callee": $0] } ?? [:],
            knownTailCallTargets: [target: "_boundary_callee"], explicitCFGEnabled: true,
            ssaEnabled: ssa, instructions: [row])
        if callerType == "uint32_t", calleeType == "uint64_t" {
            // Match the narrowing caller contract: equal call/return values fold
            // into return callee(), hiding the leaf from the printed-use census.
            if let first = function.instructions.first, case let .call(_, value?) = first.operation {
                XCTAssertEqual(function.instructions.last?.operation,
                    .returnValue(.unary(op: "(uint32_t)", value: value)))
                XCTAssertNotEqual(function.instructions.last?.operation, .returnValue(value))
                let printer = PseudocodePrinter(options: DecompilerOptions(structureControlFlow: false,
                    deadCodeElimination: false, nopElision: false, functionSizeGate: 1024))
                let document = printer.print(function: function)
                let projected = MacIRFPEnvironmentPseudocodeProjection.project(function)
                var names = PseudocodeNameContext(function: projected)
                names.redundantCompareIndices = printer.redundantCompareIndices(function: projected, names: names)
                let text = printer.valueText(for: value, names: names)
                XCTAssertEqual(document.lines.filter {
                    $0.kind == .instruction && $0.sourceAddress == start && $0.text.contains(text)
                }.count, 2, "The fixture must retain both printed result and return uses")
            } else {
                XCTFail("tail call fixture must define a result")
            }
        }
        return (function, [MacIRSourceSpan(address: start, byteText: bytes, mnemonic: "b", operands: row.operands)])
    }

    func testProvenTailResultDefinesAtBranchBeforeSyntheticReturnBothLifters() throws {
        for ssa in [false, true] {
            let (function, machine) = tailBoundaryFixture(ssa: ssa)
            let definitions = C2DataflowCensus.postTailCallResultDefinitions(function: function, machine: machine)
            let resultValue = try XCTUnwrap(definitions[0x21294])
            XCTAssertEqual(function.instructions.map { $0.source.tailCallEffect?.phase }, [.call, .returnAfterCall])
            XCTAssertFalse(C2MachineFlow(rows: machine).writes[0].contains("x0"), "raw B remains control-only")
            let result = analyze(function, expectedPrintedValue: resultValue,
                expectedUseAddress: 0x21294, ssaAccountingEnabled: ssa, machine: machine)
            XCTAssertTrue(result.rows.isEmpty)
            XCTAssertNil(result.detectorSkippedReason)
            XCTAssertFalse(function.refusals.contains { $0.reason == .targetOutsideFunction })
        }
    }

    func testOtherSingleBranchVoidAndUnresolvedThunksDoNotInventResult() {
        let voidVectors: [(UInt64, UInt64, String)] = [
            (0xe3c, 0x1b588, "d3 69 00 14"), (0xe40, 0x1b530, "bc 69 00 14"),
            (0x213e0, 0x1b588, "6a e8 ff 17"), (0x213e4, 0x1b530, "53 e8 ff 17")
        ]
        for ssa in [false, true] {
            for (start, target, bytes) in voidVectors {
                let (function, machine) = tailBoundaryFixture(ssa: ssa, start: start,
                    target: target, bytes: bytes, callerType: "void", calleeType: "void")
                XCTAssertTrue(C2DataflowCensus.postTailCallResultDefinitions(function: function, machine: machine).isEmpty)
                XCTAssertTrue(analyze(function, ssaAccountingEnabled: ssa, machine: machine).rows.isEmpty)
                XCTAssertEqual(function.instructions.last?.operation, .returnValue(nil))
            }
            // This retained local wrapper has no independent contract supplied here.
            let (unknown, machine) = tailBoundaryFixture(ssa: ssa, start: 0x1a094,
                target: 0x1a098, bytes: "01 00 00 14", callerType: nil, calleeType: nil)
            XCTAssertTrue(C2DataflowCensus.postTailCallResultDefinitions(function: unknown, machine: machine).isEmpty)
            let result = analyze(unknown, ssaAccountingEnabled: ssa, machine: machine)
            XCTAssertTrue(result.rows.isEmpty)
            XCTAssertTrue(result.detectorSkippedReason?.contains("unresolved_return_contract") == true)
        }
    }

    func testTailBoundaryMetadataCannotAuthorizeWrongMachineOrMissingProof() throws {
        for ssa in [false, true] {
            let (original, machine) = tailBoundaryFixture(ssa: ssa)
            var missing = original
            for index in missing.instructions.indices { missing.instructions[index].source.tailCallEffect = nil }
            XCTAssertTrue(C2DataflowCensus.postTailCallResultDefinitions(function: missing, machine: machine).isEmpty)
            XCTAssertEqual(analyze(missing, ssaAccountingEnabled: ssa, machine: machine).rows.filter { $0.kind == "J" }.count, 2)
            var mismatch = machine
            mismatch[0].operands = "0x2103c"
            XCTAssertTrue(C2DataflowCensus.postTailCallResultDefinitions(function: original, machine: mismatch).isEmpty)
            XCTAssertEqual(analyze(original, ssaAccountingEnabled: ssa, machine: mismatch).rows.filter { $0.kind == "J" }.count, 2)
            var ordinaryCall = machine
            ordinaryCall[0].mnemonic = "bl"
            XCTAssertTrue(C2DataflowCensus.postTailCallResultDefinitions(function: original, machine: ordinaryCall).isEmpty)
            XCTAssertEqual(analyze(original, ssaAccountingEnabled: ssa, machine: ordinaryCall).rows.filter { $0.kind == "J" }.count, 2)
            var reversed = original
            reversed.instructions.reverse()
            XCTAssertTrue(C2DataflowCensus.postTailCallResultDefinitions(function: reversed, machine: machine).isEmpty)
            var duplicate = original
            duplicate.instructions.append(original.instructions[0])
            XCTAssertTrue(C2DataflowCensus.postTailCallResultDefinitions(function: duplicate, machine: machine).isEmpty)
            guard case let .call(originalFrame, originalValue) = original.instructions[0].operation else {
                return XCTFail("tail call fixture")
            }
            var wrongTarget = original
            let wrongFrame = try XCTUnwrap(MacIRCallFrame(target: "_different", knownSignature: nil,
                controlInputs: .none, arguments: originalFrame.arguments))
            wrongTarget.instructions[0].operation = .call(frame: wrongFrame, result: originalValue)
            XCTAssertTrue(C2DataflowCensus.postTailCallResultDefinitions(function: wrongTarget, machine: machine).isEmpty)
            var indirectFrame = original
            guard case let .call(indirect, _) = try callOperation(reg(0, 0), indirect: true) else {
                return XCTFail("indirect fixture")
            }
            indirectFrame.instructions[0].operation = .call(frame: indirect, result: originalValue)
            XCTAssertTrue(C2DataflowCensus.postTailCallResultDefinitions(function: indirectFrame, machine: machine).isEmpty)
            var wrongValue = original
            wrongValue.instructions[1].operation = .returnValue(.register(name: "x0", version: 99))
            XCTAssertTrue(C2DataflowCensus.postTailCallResultDefinitions(function: wrongValue, machine: machine).isEmpty)
            XCTAssertTrue(analyze(wrongValue, ssaAccountingEnabled: ssa, machine: machine)
                .detectorSkippedReason?.contains("missing SSA definition") == true)
            var unbalanced = original
            unbalanced.startAddress = 0x21290
            let badMachine = [MacIRSourceSpan(address: 0x21290, byteText: "ff 43 00 d1",
                mnemonic: "sub", operands: "sp, sp, #16")] + machine
            XCTAssertTrue(C2DataflowCensus.postTailCallResultDefinitions(function: unbalanced, machine: badMachine).isEmpty)
        }
    }

    func testTailCallArgumentIsBeforeResultDefinitionNotAfter() throws {
        for ssa in [false, true] {
            var (function, machine) = tailBoundaryFixture(ssa: ssa)
            let value = try XCTUnwrap(C2DataflowCensus.postTailCallResultDefinitions(function: function, machine: machine)[0x21294])
            guard case let .call(frame, _) = try callOperation(value) else { return XCTFail("call fixture") }
            let matchingFrame = try XCTUnwrap(MacIRCallFrame(target: "_boundary_callee", knownSignature: nil,
                controlInputs: frame.controlInputs, arguments: frame.arguments))
            function.instructions[0].operation = .call(frame: matchingFrame, result: value)
            let result = analyze(function, ssaAccountingEnabled: ssa, machine: machine)
            XCTAssertTrue(result.rows.contains { $0.kind == "J" && $0.useAddress == 0x21294
                && $0.definitionAddress == 0x21294 && $0.reachingDefinitions == [0] })
        }
    }

    func testPathCompleteTailPhaseReplayUsesProducerConfiguration() throws {
        let vectors: [(UInt64, String, String, String)] = [
            (0x1000, "60 00 00 b4", "cbz", "x0, 0x100c"),
            (0x1004, "1f 20 03 d5", "nop", ""),
            (0x1008, "02 00 00 14", "b", "0x1010"),
            (0x100c, "1f 20 03 d5", "nop", ""),
            (0x1010, "fc 03 00 14", "b", "0x2000")
        ]
        let rows = vectors.map { InstructionRow(address: $0.0, bytes: $0.1,
            mnemonic: $0.2, operands: $0.3, hasBreakpoint: false, comment: nil) }
        let machine = rows.map { MacIRSourceSpan(address: $0.address, byteText: $0.bytes,
            mnemonic: $0.mnemonic, operands: $0.operands, comment: $0.comment,
            structuredOperands: $0.structuredOperands) }
        let caller = FunctionSignatureOverride(returnType: "uint32_t",
            args: [ArgOverride(index: 0, name: "value", type: "uint64_t")])
        let callee = FunctionSignatureOverride(returnType: "uint64_t", args: [])
        for requestedSSA in [false, true] {
            for contracts in [false, true] {
                try MacIRConfiguration.$returnContractOverride.withValue(contracts) {
                    let function = PseudocodePrinter().buildFunction(functionName: "path_tail",
                        startAddress: 0x1000, signatureOverrides: [0x1000: caller],
                        authoredCallSignaturesByTarget: ["_path_callee": callee],
                        knownTailCallTargets: [0x2000: "_path_callee"],
                        explicitCFGEnabled: true, ssaEnabled: requestedSSA, instructions: rows)
                    XCTAssertEqual(function.ssaEnabled, requestedSSA)
                    let definitions = C2DataflowCensus.postTailCallResultDefinitions(
                        function: function, machine: machine)
                    XCTAssertEqual(definitions[0x1010] != nil, requestedSSA && contracts)
                    if requestedSSA && contracts {
                        let result = try XCTUnwrap(definitions[0x1010])
                        let effects = function.instructions.filter { $0.source.address == 0x1010 }
                        XCTAssertEqual(effects.map { $0.source.tailCallEffect?.phase }, [.call, .returnAfterCall])
                        XCTAssertEqual(effects.last?.operation,
                            .returnValue(.unary(op: "(uint32_t)", value: result)))
                        MacIRConfiguration.$returnContractOverride.withValue(false) {
                            XCTAssertTrue(C2DataflowCensus.postTailCallResultDefinitions(
                                function: function, machine: machine).isEmpty)
                        }
                    }
                }
            }
        }
    }

    private func reg(_ number: Int, _ version: Int) -> MacIRValue {
        .register(name: "x\(number)", version: version)
    }

    private func instruction(_ address: UInt64, _ mnemonic: String, _ operands: String,
                             _ operation: MacIROperation) -> MacIRInstruction {
        MacIRInstruction(source: MacIRSourceSpan(address: address, byteText: "00 00 00 00",
            mnemonic: mnemonic, operands: operands), operation: operation)
    }

    private func analyze(_ function: MacIRFunction,
                         expectedPrintedValue: MacIRValue? = nil,
                         expectedUseAddress: UInt64 = 0x4008,
                         ssaAccountingEnabled: Bool = false,
                         machine: [MacIRSourceSpan]? = nil) -> C2DataflowCensus.Analysis {
        let printer = PseudocodePrinter(options: DecompilerOptions(structureControlFlow: false,
            deadCodeElimination: false, nopElision: false, functionSizeGate: 1024))
        let document = printer.print(function: function)
        let projected = MacIRFPEnvironmentPseudocodeProjection.project(function)
        var names = PseudocodeNameContext(function: projected)
        names.redundantCompareIndices = printer.redundantCompareIndices(function: projected, names: names)
        if let value = expectedPrintedValue {
            let text = printer.valueText(for: value, names: names)
            XCTAssertTrue(document.lines.contains {
                $0.kind == .instruction && $0.sourceAddress == expectedUseAddress && $0.text.contains(text)
            }, "The fixture must print \(text) at its use")
        }
        return C2DataflowCensus.analyze(function: projected, document: document,
            machine: machine ?? function.instructions.map(\.source), printer: printer, names: names,
            ssaAccountingEnabled: ssaAccountingEnabled)
    }

    private func loop(merged: Bool) -> MacIRFunction {
        let bodyValue = reg(1, merged ? 3 : 1)
        return MacIRFunction(name: merged ? "correct_loop" : "stale_loop", startAddress: 0x1000,
            returnType: "void", instructions: [
                instruction(0x1000, "mov", "x1, x20", .assign(destination: reg(1, 1), source: reg(20, 0))),
                instruction(0x1004, "str", "x1, [x2]", .store(source: bodyValue, address: reg(2, 0))),
                instruction(0x1008, "add", "x1, x1, #1", .binary(destination: reg(1, 2),
                    op: "+", left: bodyValue, right: .immediate(1))),
                instruction(0x100c, "cbnz", "x3, 0x1004", .conditionalBranch(condition: "!=",
                    left: reg(3, 0), right: .immediate(0), target: .immediate(0x1004))),
                instruction(0x1010, "ret", "", .returnValue(nil))
            ], phis: merged ? [MacIRPhi(blockAddress: 0x1004, destination: bodyValue, bitWidth: 64,
                incoming: [.init(predecessorAddress: 0x1000, value: reg(1, 1)),
                    .init(predecessorAddress: 0x100c, value: reg(1, 2))])] : [])
    }

    private func join(merged: Bool) -> MacIRFunction {
        let joinedValue = reg(1, merged ? 3 : 1)
        return MacIRFunction(name: merged ? "correct_join" : "wrong_join", startAddress: 0x2000,
            returnType: "void", instructions: [
                instruction(0x2000, "cbz", "x3, 0x200c", .conditionalBranch(condition: "==",
                    left: reg(3, 0), right: .immediate(0), target: .immediate(0x200c))),
                instruction(0x2004, "mov", "x1, x20", .assign(destination: reg(1, 1), source: reg(20, 0))),
                instruction(0x2008, "b", "0x2010", .intrinsic(destination: nil, name: "branch",
                    arguments: [.immediate(0x2010)])),
                instruction(0x200c, "mov", "x1, x21", .assign(destination: reg(1, 2), source: reg(21, 0))),
                instruction(0x2010, "str", "x1, [x2]", .store(source: joinedValue, address: reg(2, 0))),
                instruction(0x2014, "ret", "", .returnValue(nil))
            ], phis: merged ? [MacIRPhi(blockAddress: 0x2010, destination: joinedValue, bitWidth: 64,
                incoming: [.init(predecessorAddress: 0x2008, value: reg(1, 1)),
                    .init(predecessorAddress: 0x200c, value: reg(1, 2))])] : [])
    }
    // Exact ordered W predicate projection, with independently authored bytes.
    func testGuardedWPredicateUnsignedXLeavesIgnoreHighBits() {
        XCTAssertEqual(UInt32(truncatingIfNeeded: UInt64(0x100000000)), 0)
        XCTAssertEqual(UInt32(truncatingIfNeeded: UInt64(0x100000000)) < UInt32(1), true)
        assertGuardedWPredicate(mode: "unsigned", expectedRefusals: 0)
    }

    func testGuardedWPredicateSignedXLeavesIgnoreHighBits() {
        XCTAssertEqual(Int32(bitPattern: UInt32(0xffffffff)), -1)
        XCTAssertEqual(Int32(bitPattern: UInt32(0xffffffff)) < Int32(0), true)
        XCTAssertEqual(Int32(bitPattern: UInt32(0x80000000)) < Int32(1), true)
        assertGuardedWPredicate(mode: "signed", expectedRefusals: 0)
    }

    func testGuardedWPredicateSubsXLeavesIgnoreHighBits() {
        XCTAssertEqual(UInt32(truncatingIfNeeded: UInt64(0x100000000)), 0)
        assertGuardedWPredicate(mode: "subs", expectedRefusals: 0)
    }

    func testGuardedWPredicateRefusesRawEqualityXLeaves() {
        XCTAssertEqual(UInt64(0x100000000) == UInt64(0), false)
        XCTAssertEqual(UInt32(truncatingIfNeeded: UInt64(0x100000000)) == UInt32(0), true)
        assertGuardedWPredicate(mode: "equality", expectedRefusals: 2)
    }

    func testGuardedWPredicateRefusesRawHighBitSensitiveXLeaves() {
        // On the high-bit input path raw X and native W predicates disagree.
        XCTAssertEqual(UInt64(0x100000000) < UInt64(1), false)
        XCTAssertEqual(UInt32(truncatingIfNeeded: UInt64(0x100000000)) < UInt32(1), true)
        assertGuardedWPredicate(mode: "raw", expectedRefusals: 2)
    }

    func testGuardedWPredicateRefusesWrongSignedCast() {
        XCTAssertEqual(Int32(bitPattern: UInt32(0xffffffff)) < Int32(0), true)
        XCTAssertEqual(UInt32(0xffffffff) < UInt32(0), false)
        assertGuardedWPredicate(mode: "wrongSignedness", expectedRefusals: 2)
    }

    func testGuardedWPredicateRefusesNestedExpression() {
        // Even low32-safe expressions must not bypass exact direct-input binding.
        XCTAssertEqual(UInt32(3) + UInt32(1), 4)
        assertGuardedWPredicate(mode: "nested", expectedRefusals: 2)
    }

    func testGuardedWPredicateRefusesStaleProducerInput() {
        assertGuardedWPredicate(mode: "stale", expectedRefusals: 2)
    }

    private func assertGuardedWPredicate(mode: String, expectedRefusals: Int,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let function = guardedWPredicateFixture(mode: mode)
        for accounting in [false, true] {
            let result = analyze(function, ssaAccountingEnabled: accounting)
            XCTAssertEqual(result.refusalDetails.filter {
                C2DataflowCensus.GuardedConjunct(reason: $0.reason) != nil
            }.count, expectedRefusals, file: file, line: line)
            XCTAssertEqual(result.rows.count, 0, file: file, line: line)
        }
    }

    private func guardedWPredicateFixture(mode: String) -> MacIRFunction {
        func row(_ address: UInt64, _ bytes: String, _ mnemonic: String,
                 _ operands: String, _ operation: MacIROperation) -> MacIRInstruction {
            MacIRInstruction(source: MacIRSourceSpan(address: address, byteText: bytes,
                mnemonic: mnemonic, operands: operands), operation: operation)
        }
        let signed = mode == "signed" || mode == "wrongSignedness"
        let cast = signed && mode != "wrongSignedness" ? "(int32_t)" : "(uint32_t)"
        var left = reg(3, 0)
        if mode == "nested" { left = .binaryExpression(op: "+", left: left, right: .immediate(1)) }
        var right = reg(4, 0)
        if mode != "raw" && mode != "equality" {
            left = .unary(op: cast, value: left)
            right = .unary(op: cast, value: right)
        }
        var rows: [MacIRInstruction] = []
        if mode == "stale" {
            // MOV X3,X5 precedes CMP: printed entry X3 no longer names its input.
            rows.append(row(0x7900, "e3 03 05 aa", "mov", "x3, x5",
                .assign(destination: reg(3, 1), source: reg(5, 0))))
        }
        let start: UInt64 = mode == "stale" ? 0x7904 : 0x7900
        if mode == "subs" {
            rows.append(row(start, "66 00 04 6b", "subs", "w6, w3, w4",
                .binary(destination: .register(name: "w6", version: 1), op: "-", left: reg(3, 0), right: reg(4, 0))))
        } else {
            rows.append(row(start, "7f 00 04 6b", "cmp", "w3, w4",
                .intrinsic(destination: nil, name: "compare", arguments: [reg(3, mode == "stale" ? 1 : 0), reg(4, 0)])))
        }
        let equality = mode == "equality"
        rows.append(row(start + 4, equality ? "20 00 82 1a" : (signed ? "20 b0 82 1a" : "20 30 82 1a"), "csel",
            equality ? "w0, w1, w2, eq" : (signed ? "w0, w1, w2, lt" : "w0, w1, w2, lo"),
            .select(destination: .register(name: "w0", version: 1), condition: equality ? "==" : "<",
                left: left, right: right,
                trueValue: .unary(op: "(uint32_t)", value: reg(1, 0)),
                falseValue: .unary(op: "(uint32_t)", value: reg(2, 0)))))
        rows.append(row(start + 8, "c0 03 5f d6", "ret", "", .returnValue(nil)))
        return MacIRFunction(name: "guarded_w_predicate_\(mode)", startAddress: 0x7900,
            returnType: "void", instructions: rows)
    }

    // Passive diagnostics only: authored IR fixtures reuse the original machine
    // rows. These tests do not decode bytes or make diagnostic evidence a proof.
    func testGuardedDiagnosticVocabularyRejectsUnknownReasons() {
        XCTAssertEqual(C2DataflowCensus.GuardedConjunct.allCases.count, 7)
        for conjunct in C2DataflowCensus.GuardedConjunct.allCases {
            XCTAssertEqual(C2DataflowCensus.GuardedConjunct(reason: conjunct.reason), conjunct)
        }
        XCTAssertNil(C2DataflowCensus.GuardedConjunct(reason: "guarded select arm needs path-predicate proof"))
        XCTAssertNil(C2DataflowCensus.GuardedConjunct(reason: "guarded select arm needs path-predicate proof: invented"))
        XCTAssertNil(C2DataflowCensus.GuardedConjunct(reason: "guarded select arm needs path-predicate proof: cyclic-graph trailing"))
    }

    func testGuardedDiagnosticOldGateIsTerminalBeforeExtension() {
        for mode in [false, true] {
            let result = analyze(guardedSelect(condition: "<", machineCondition: "eq"),
                                 ssaAccountingEnabled: mode)
            let details = result.refusalDetails
            XCTAssertEqual(details.count, 2)
            XCTAssertEqual(details.map(\.instructionAddress), [0x7108, 0x7108])
            XCTAssertEqual(Set(details.compactMap(\.register)), ["x1", "x2"])
            XCTAssertEqual(details.map(\.reason), Array(repeating: C2DataflowCensus.GuardedConjunct.oldGateFailed.reason, count: 2))
            XCTAssertEqual(details.compactMap { $0.guardedFailure?.guardID }, ["old.condition-relation", "old.condition-relation"])
            XCTAssertEqual(details.compactMap { $0.guardedFailure?.conjunct }, [.oldGateFailed, .oldGateFailed])
            XCTAssertEqual(details.compactMap { $0.guardedFailure?.sourceFile },
                           ["CoreTests/C2DataflowCensus.swift", "CoreTests/C2DataflowCensus.swift"])
            // Literal source anchor: old.condition-relation return in the candidate.
            XCTAssertEqual(details.compactMap { $0.guardedFailure?.sourceLine }, [692, 692])
            XCTAssertTrue(result.skippedReason?.contains("guarded select arm needs path-predicate proof") == true)
            XCTAssertFalse(result.skippedReason?.contains(": old-gate-failed") == true)
            XCTAssertTrue(result.rows.isEmpty)
        }
    }

    func testGuardedDiagnosticExtensionReportsOnlyTerminalFailure() {
        let cases: [(String, C2DataflowCensus.GuardedConjunct, String, [UInt64], Int)] = [
            ("wrongArm", .armDefinitionAmbiguous, "extension.true-arm-definition", [0x7614], 837),
            ("unrelated", .armDefinitionAmbiguous, "extension.true-arm-definition", [0x7614], 837),
            ("bothArms", .armDefinitionAmbiguous, "extension.false-arm-definition", [0x7614, 0x7614], 837),
            ("overwrite", .armDefinitionAmbiguous, "extension.true-arm-definition", [0x7618], 837),
            ("cycle", .cyclicGraph, "extension.acyclic-order", [0x7614], 805)]
        for mode in [false, true] {
            for (mismatch, conjunct, guardID, addresses, sourceLine) in cases {
                let result = analyze(conditionalArmFixture("cmp", suffix: "eq", mismatch: mismatch),
                                     ssaAccountingEnabled: mode)
                let details = result.refusalDetails
                XCTAssertEqual(details.count, addresses.count, mismatch)
                XCTAssertEqual(details.compactMap(\.instructionAddress), addresses, mismatch)
                XCTAssertEqual(details.compactMap(\.register), Array(repeating: "x1", count: addresses.count), mismatch)
                XCTAssertEqual(details.map(\.reason), Array(repeating: conjunct.reason, count: addresses.count), mismatch)
                XCTAssertEqual(details.compactMap { $0.guardedFailure?.conjunct }, Array(repeating: conjunct, count: addresses.count), mismatch)
                XCTAssertEqual(details.compactMap { $0.guardedFailure?.guardID }, Array(repeating: guardID, count: addresses.count), mismatch)
                XCTAssertEqual(details.compactMap { $0.guardedFailure?.sourceFile }, Array(repeating: "CoreTests/C2DataflowCensus.swift", count: addresses.count), mismatch)
                XCTAssertEqual(details.compactMap { $0.guardedFailure?.sourceLine }, Array(repeating: sourceLine, count: addresses.count), mismatch)
                XCTAssertEqual(result.skippedReason, "guarded select arm needs path-predicate proof", mismatch)
                XCTAssertTrue(result.rows.isEmpty, mismatch)
            }
        }
    }

    func testGuardedDiagnosticSuccessfulProofHasNoRefusalMetadata() {
        for mode in [false, true] {
            let fixtures: [(MacIRFunction, MacIRValue, UInt64)] = [
                (guardedSelect(), reg(1, 1), 0x7108),
                (conditionalArmFixture("cmp", suffix: "eq"), reg(1, 2), 0x7614)]
            for (function, value, address) in fixtures {
                let result = analyze(function, expectedPrintedValue: value,
                                     expectedUseAddress: address, ssaAccountingEnabled: mode)
                XCTAssertNil(result.skippedReason)
                XCTAssertTrue(result.refusalDetails.isEmpty)
                XCTAssertTrue(result.rows.isEmpty)
            }
        }
    }

    func testGuardedDiagnosticMetadataSurvivesSummaryEncoding() throws {
        let result = analyze(guardedSelect(condition: "<", machineCondition: "eq"))
        let encoded = try JSONEncoder().encode(result.refusalDetails)
        let decoded = try JSONDecoder().decode([C2DataflowCensus.RefusalDetail].self, from: encoded)
        XCTAssertEqual(decoded, result.refusalDetails)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded.first?.guardedFailure?.guardID, "old.condition-relation")
        // The real census uses JSONEncoder then JSONSerialization for the envelope.
        let object = try JSONSerialization.jsonObject(with: encoded)
        let envelope = try JSONSerialization.data(withJSONObject: ["refusalDetails": object])
        let restored = try JSONSerialization.jsonObject(with: envelope) as? [String: Any]
        let detailObjects = restored?["refusalDetails"] as? [[String: Any]]
        XCTAssertEqual(detailObjects?.count, 2)
        XCTAssertEqual((detailObjects?.first?["guardedFailure"] as? [String: Any])?["guardID"] as? String,
                       "old.condition-relation")
        let legacy = Data("[{\"reason\":\"legacy refusal\"}]".utf8)
        let legacyDecoded = try JSONDecoder().decode([C2DataflowCensus.RefusalDetail].self, from: legacy)
        XCTAssertEqual(legacyDecoded.count, 1)
        XCTAssertEqual(legacyDecoded.first?.reason, "legacy refusal")
        XCTAssertNil(legacyDecoded.first?.guardedFailure)
        let ordinaryEncoded = try JSONEncoder().encode(legacyDecoded)
        let ordinaryObjects = try JSONSerialization.jsonObject(with: ordinaryEncoded) as? [[String: Any]]
        XCTAssertEqual(ordinaryObjects?.count, 1)
        XCTAssertNil(ordinaryObjects?.first?["guardedFailure"])
    }

    // Literal authored machine rows; no decoder is used by these fixtures.
    func testGuardedZeroExtendedWLeafSmallConstants() {
        XCTAssertEqual(UInt64(UInt32(0x38)), 56)
        XCTAssertEqual(UInt64(UInt32(0x48)), 72)
        assertGuardedZeroExtendedMov(leafWidth: 32, high: false)
    }

    func testGuardedZeroExtendedWLeafHighConstants() {
        XCTAssertEqual(UInt64(UInt32(0xffffffff)), 4294967295)
        XCTAssertEqual(UInt64(UInt32(0x80000000)), 2147483648)
        assertGuardedZeroExtendedMov(leafWidth: 32, high: true)
    }

    func testGuardedZeroExtendedXLeafSmallConstants() {
        XCTAssertEqual(UInt64(UInt32(0x38)), 56)
        XCTAssertEqual(UInt64(UInt32(0x48)), 72)
        assertGuardedZeroExtendedMov(leafWidth: 64, high: false)
    }

    func testGuardedZeroExtendedXLeafHighConstants() {
        XCTAssertEqual(UInt64(UInt32(0xffffffff)), 4294967295)
        XCTAssertEqual(UInt64(UInt32(0x80000000)), 2147483648)
        assertGuardedZeroExtendedMov(leafWidth: 64, high: true)
    }

    private func assertGuardedZeroExtendedMov(leafWidth: Int, high: Bool,
                                             file: StaticString = #filePath, line: UInt = #line) {
        for mode in [false, true] {
            let function = guardedZeroExtendedMovFixture(leafWidth: leafWidth, high: high)
            let leaf = MacIRValue.register(name: leafWidth == 32 ? "w1" : "x1", version: 1)
            let result = analyze(function, expectedPrintedValue: leaf, expectedUseAddress: 0x7a0c,
                                 ssaAccountingEnabled: mode)
            XCTAssertNil(result.skippedReason, file: file, line: line)
            XCTAssertTrue(result.rows.isEmpty, file: file, line: line)
            XCTAssertTrue(result.refusalDetails.isEmpty, file: file, line: line)
        }
    }

    func testGuardedZeroExtendedMovRejectsWrongMachineArmRegister() {
        // W4 is genuinely zero-extended, but the machine arm reads X1, not X4.
        for width in [32, 64] {
            for mode in [false, true] {
                let function = guardedZeroExtendedMovFixture(leafWidth: width, mismatch: "wrongRegister")
                let result = analyze(function,
                    expectedPrintedValue: .register(name: width == 32 ? "w4" : "x4", version: 1),
                    expectedUseAddress: 0x7a0c, ssaAccountingEnabled: mode)
                XCTAssertEqual(result.refusalDetails.count, 2)
                XCTAssertEqual(result.refusalDetails.compactMap(\.instructionAddress), [0x7a0c, 0x7a0c])
                XCTAssertEqual(result.refusalDetails.compactMap(\.register), ["x4", "x2"])
                XCTAssertEqual(result.refusalDetails.compactMap { $0.guardedFailure?.guardID },
                    ["old.arm-binding.yes-leaf", "old.arm-binding.yes-leaf"])
                XCTAssertEqual(result.skippedReason, "guarded select arm needs path-predicate proof")
            }
        }
    }

    func testGuardedZeroExtendedMovRejectsXWriteAndEntryValue() {
        XCTAssertNotEqual(UInt64(0x100000000), UInt64(UInt32(truncatingIfNeeded: UInt64(0x100000000))))
        for mismatch in ["xWrite", "entry"] {
            for mode in [false, true] {
                let function = guardedZeroExtendedMovFixture(leafWidth: 64, mismatch: mismatch)
                let result = analyze(function, expectedPrintedValue: reg(1, mismatch == "entry" ? 0 : 1),
                                     expectedUseAddress: 0x7a0c, ssaAccountingEnabled: mode)
                XCTAssertEqual(result.refusalDetails.count, 2)
                XCTAssertEqual(result.refusalDetails.compactMap(\.instructionAddress), [0x7a0c, 0x7a0c])
                XCTAssertEqual(result.refusalDetails.compactMap(\.register), ["x1", "x2"])
                XCTAssertEqual(result.refusalDetails.compactMap { $0.guardedFailure?.guardID },
                    ["old.arm-binding.yes-leaf", "old.arm-binding.yes-leaf"])
                XCTAssertEqual(result.skippedReason, "guarded select arm needs path-predicate proof")
            }
        }
    }

    func testGuardedZeroExtendedMovRetainsOverwritePathFailure() {
        for mode in [false, true] {
            let result = analyze(guardedZeroExtendedMovFixture(leafWidth: 64, mismatch: "overwrite"),
                                 expectedPrintedValue: reg(1, 1), expectedUseAddress: 0x7a10,
                                 ssaAccountingEnabled: mode)
            XCTAssertEqual(result.refusalDetails.count, 1)
            XCTAssertEqual(result.refusalDetails.compactMap(\.instructionAddress), [0x7a10])
            XCTAssertEqual(result.refusalDetails.compactMap(\.register), ["x1"])
            XCTAssertEqual(result.refusalDetails.map(\.reason), [C2DataflowCensus.GuardedConjunct.armDefinitionAmbiguous.reason])
            XCTAssertEqual(result.refusalDetails.compactMap { $0.guardedFailure?.guardID }, ["extension.true-arm-definition"])
            XCTAssertEqual(result.skippedReason, "guarded select arm needs path-predicate proof")
        }
    }

    func testGuardedArmBindingNoLeafDoesNotRelabelYesLeaf() {
        for mode in [false, true] {
            let result = analyze(guardedZeroExtendedMovFixture(leafWidth: 64, mismatch: "noLeaf"),
                                 expectedPrintedValue: reg(2, 1), expectedUseAddress: 0x7a0c,
                                 ssaAccountingEnabled: mode)
            XCTAssertEqual(result.refusalDetails.count, 2)
            XCTAssertEqual(result.refusalDetails.compactMap(\.instructionAddress), [0x7a0c, 0x7a0c])
            XCTAssertEqual(result.refusalDetails.compactMap { $0.guardedFailure?.guardID },
                ["old.arm-binding.no-leaf", "old.arm-binding.no-leaf"])
            XCTAssertEqual(result.skippedReason, "guarded select arm needs path-predicate proof")
        }
    }

    private func guardedZeroExtendedMovFixture(leafWidth: Int, high: Bool = false,
                                              mismatch: String = "") -> MacIRFunction {
        let prefix = leafWidth == 32 ? "w" : "x"
        let number = mismatch == "wrongRegister" ? 4 : 1
        let yesLeaf = MacIRValue.register(name: "\(prefix)\(number)", version: mismatch == "entry" ? 0 : 1)
        let noLeaf = MacIRValue.register(name: "\(prefix)2", version: 1)
        func extended(_ value: MacIRValue) -> MacIRValue {
            .unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: value))
        }
        func row(_ address: UInt64, _ bytes: String, _ mnemonic: String, _ operands: String,
                 _ operation: MacIROperation) -> MacIRInstruction {
            MacIRInstruction(source: MacIRSourceSpan(address: address, byteText: bytes,
                mnemonic: mnemonic, operands: operands), operation: operation)
        }
        let firstValue: Int64 = mismatch == "xWrite" ? 0x100000000 : (high ? 0xffffffff : 0x38)
        let secondValue: Int64 = mismatch == "noLeaf" ? 0x100000000 : (high ? 0x80000000 : 0x48)
        let firstBytes = mismatch == "xWrite" ? "21 00 c0 d2" : (number == 4 ? "04 07 80 52" : (high ? "01 00 80 12" : "01 07 80 52"))
        let secondBytes = mismatch == "noLeaf" ? "22 00 c0 d2" : (high ? "02 00 b0 52" : "02 09 80 52")
        let firstOperands = mismatch == "xWrite" ? "x1, #0x100000000" : (number == 4 ? "w4, #0x38" : (high ? "w1, #0xffffffff" : "w1, #0x38"))
        let secondOperands = mismatch == "noLeaf" ? "x2, #0x100000000" : (high ? "w2, #0x80000000" : "w2, #0x48")
        var rows = [
            mismatch == "entry"
                ? row(0x7a00, "1f 20 03 d5", "nop", "", .intrinsic(destination: nil, name: "nop", arguments: []))
                : row(0x7a00, firstBytes, "mov", firstOperands, .assign(destination: yesLeaf, source: .immediate(firstValue))),
            row(0x7a04, secondBytes, "mov", secondOperands, .assign(destination: noLeaf, source: .immediate(secondValue))),
            row(0x7a08, "7f 00 00 f1", "cmp", "x3, #0", .intrinsic(destination: nil, name: "compare", arguments: [reg(3, 0), .immediate(0)]))]
        if mismatch == "overwrite" {
            rows.append(row(0x7a0c, "21 00 c0 d2", "mov", "x1, #0x100000000", .assign(destination: reg(1, 2), source: .immediate(0x100000000))))
        }
        let address: UInt64 = mismatch == "overwrite" ? 0x7a10 : 0x7a0c
        rows.append(row(address, "20 00 82 9a", "csel", "x0, x1, x2, eq", .select(destination: reg(0, 1), condition: "==",
            left: reg(3, 0), right: .immediate(0), trueValue: mismatch == "noLeaf" ? yesLeaf : extended(yesLeaf), falseValue: extended(noLeaf))))
        rows.append(row(address + 4, "c0 03 5f d6", "ret", "", .returnValue(nil)))
        return MacIRFunction(name: "guarded_zero_extended_mov", startAddress: 0x7a00, returnType: "void", instructions: rows)
    }

    func testGuardedArmBindingAliasEqualityIsItsOwnTerminal() {
        for mode in [false, true] {
            var function = guardedZeroExtendedMovFixture(leafWidth: 64)
            function.instructions[1] = MacIRInstruction(source: MacIRSourceSpan(address: 0x7a04,
                byteText: "01 09 80 d2", mnemonic: "mov", operands: "x1, #0x48"),
                operation: .assign(destination: reg(1, 2), source: .immediate(0x48)))
            function.instructions[3] = MacIRInstruction(source: MacIRSourceSpan(address: 0x7a0c,
                byteText: "20 04 81 9a", mnemonic: "cinc", operands: "x0, x1, ne"),
                operation: .select(destination: reg(0, 1), condition: "==", left: reg(3, 0), right: .immediate(0),
                    trueValue: reg(1, 1), falseValue: .binaryExpression(op: "+", left: reg(1, 2), right: .immediate(1))))
            let result = analyze(function, expectedPrintedValue: reg(1, 1), expectedUseAddress: 0x7a0c,
                                 ssaAccountingEnabled: mode)
            XCTAssertEqual(result.refusalDetails.count, 2)
            XCTAssertEqual(result.refusalDetails.compactMap(\.instructionAddress), [0x7a0c, 0x7a0c])
            XCTAssertEqual(result.refusalDetails.compactMap(\.register), ["x1", "x1"])
            XCTAssertEqual(result.refusalDetails.compactMap { $0.guardedFailure?.guardID },
                ["old.arm-binding.alias-equal", "old.arm-binding.alias-equal"])
            XCTAssertEqual(result.skippedReason, "guarded select arm needs path-predicate proof")
        }
    }

    func testGuardedZeroExtendedMovDoesNotRelaxWArmViews() {
        for mode in [false, true] {
            var function = guardedZeroExtendedMovFixture(leafWidth: 64)
            let yes = MacIRValue.unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: reg(1, 1)))
            let no = MacIRValue.unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)", value: reg(2, 1)))
            function.instructions[3] = MacIRInstruction(source: MacIRSourceSpan(address: 0x7a0c,
                byteText: "20 00 82 1a", mnemonic: "csel", operands: "w0, w1, w2, eq"),
                operation: .select(destination: .register(name: "w0", version: 1), condition: "==",
                    left: reg(3, 0), right: .immediate(0), trueValue: yes, falseValue: no))
            let result = analyze(function, expectedPrintedValue: reg(1, 1), expectedUseAddress: 0x7a0c,
                                 ssaAccountingEnabled: mode)
            XCTAssertEqual(result.refusalDetails.count, 2)
            XCTAssertEqual(result.refusalDetails.compactMap(\.instructionAddress), [0x7a0c, 0x7a0c])
            XCTAssertEqual(result.refusalDetails.compactMap { $0.guardedFailure?.guardID },
                ["old.arm-binding.yes-leaf", "old.arm-binding.yes-leaf"])
            XCTAssertEqual(result.skippedReason, "guarded select arm needs path-predicate proof")
        }
    }

}

// Authored expectations only: these fixtures have not been executed for this hand-back.
extension DecompilerC2DataflowCensusTests {
    private var proofID: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000286")! }
    private var nestedProofID: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000287")! }
    private typealias ProofObject = C2ProofDiagnostics.Object

    /// Literal fixture has one ordinary return. Event injection checks the test
    /// serializer, while the separate builder smoke test checks original hooks.
    private func proofFixture(_ events: [RejectedCFGDiagnostics.Event],
                              check: ([ProofObject]) throws -> Void) throws {
        let function = MacIRFunction(name: "proof_fixture", startAddress: 0x1000,
            returnType: "void", instructions: [instruction(0x1000, "ret", "", .returnValue(nil))])
        var offText: String?
        var offVerdict: C2DataflowCensus.Analysis?
        for enabled in [false, true] {
            let collector = enabled ? C2ProofDiagnostics.Collector() : nil
            let printer = PseudocodePrinter(options: DecompilerOptions(structureControlFlow: false,
                deadCodeElimination: false, nopElision: false, functionSizeGate: 1024))
            let document = C2ProofDiagnostics.withCollector(collector, phase: "fixture") {
                for event in events { RejectedCFGDiagnostics.sink?(event) }
                return printer.print(function: function)
            }
            let result = C2ProofDiagnostics.withCollector(collector, phase: "census") {
                C2DataflowCensus.analyze(function: function, document: document,
                    machine: function.instructions.map(\.source), printer: printer,
                    names: PseudocodeNameContext(function: function))
            }
            XCTAssertEqual(function.instructions.map(\.operation), [.returnValue(nil)])
            // Literal code lines exclude metadata and unchanged source comments.
            let code = document.lines.filter { $0.kind != .metadata }.map {
                $0.text.components(separatedBy: " // ").first!.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            XCTAssertEqual(code, ["void proof_fixture(void) {", "return;", "}"])
            XCTAssertNil(result.skippedReason)
            XCTAssertEqual(result.rows, [])
            XCTAssertEqual(result.refusalDetails, [])
            if enabled {
                XCTAssertEqual(document.text, offText)
                XCTAssertEqual(result.rows, offVerdict?.rows)
                XCTAssertEqual(result.skippedReason, offVerdict?.skippedReason)
                XCTAssertEqual(result.refusalDetails, offVerdict?.refusalDetails)
                let ledger = try XCTUnwrap(collector).ledger()
                try check(ledger)
                // Every event must actually serialize as a JSON object without
                // stringifying value identities or dropping null observations.
                for record in ledger {
                    let data = try C2ProofDiagnostics.jsonLine(record)
                    XCTAssertEqual(data.last, 0x0a)
                    XCTAssertTrue(try JSONSerialization.jsonObject(with: data) is ProofObject)
                }
            } else {
                XCTAssertNil(collector)
                offText = document.text
                offVerdict = result
            }
        }
    }
    private func proofObject(_ value: Any?, file: StaticString = #filePath, line: UInt = #line) throws -> ProofObject {
        try XCTUnwrap(value as? ProofObject, file: file, line: line)
    }
    private func proofArray(_ value: Any?, file: StaticString = #filePath, line: UInt = #line) throws -> [ProofObject] {
        try XCTUnwrap(value as? [ProofObject], file: file, line: line)
    }
    private func literalPlan(producer: Int, unavailable: Set<Int>, nonlexical: Bool) -> RejectedCFGDiagnostics.Event {
        .plan(id: proofID, addresses: [0x1000, 0x1004], ranges: [0..<1, 1..<2],
            successors: [[1], []], predecessors: [[], [0]], precedingRows: [[], [0]],
            effects: [[3], []], entries: [1: .init(unavailable: unavailable, nonlexical: nonlexical, producers: [3: producer])],
            incoming: [nil, [producer]], callRows: [], hasUnenumeratedTransfer: false)
    }
    func testProofEntryProducersExactPositiveRowBothModes() throws {
        try proofFixture([literalPlan(producer: 0, unavailable: [], nonlexical: true)]) { ledger in
            let entries = try proofArray(ledger[0]["entryProducers"])
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries[0]["row"] as? Int, 1)
            XCTAssertEqual(entries[0]["nonlexical"] as? Bool, true)
            XCTAssertEqual(entries[0]["unavailable"] as? [Int], [])
            let producer = try proofArray(entries[0]["producers"])[0]
            XCTAssertEqual(producer["cell"] as? Int, 3)
            XCTAssertEqual(producer["producer"] as? Int, 0)
            XCTAssertEqual(ledger[0]["addresses"] as? [String], ["0x1000", "0x1004"])
        }
    }
    func testProofEntryProducersMixedAndEntrySentinelsBothModes() throws {
        try proofFixture([literalPlan(producer: -2, unavailable: [3], nonlexical: false),
                          literalPlan(producer: -1, unavailable: [], nonlexical: true)]) { ledger in
            let mixed = try proofArray(ledger[0]["entryProducers"])[0]
            XCTAssertEqual(mixed["unavailable"] as? [Int], [3])
            XCTAssertEqual(try proofArray(mixed["producers"])[0]["producer"] as? Int, -2)
            let entry = try proofArray(ledger[1]["entryProducers"])[0]
            XCTAssertEqual(try proofArray(entry["producers"])[0]["producer"] as? Int, -1)
            XCTAssertEqual(ledger[1]["sequence"] as? Int, 1)
        }
    }
    func testProofProducerSnapshotVersionWidthBothModes() throws {
        try proofFixture([.snapshot(id: proofID, row: 2, cell: 3,
            definition: .init(value: .register(name: "w3", version: 7), width: 32))]) { ledger in
            XCTAssertEqual(ledger[0]["producerRow"] as? Int, 2)
            let snap = try proofObject(ledger[0]["definition"])
            XCTAssertEqual(snap["width"] as? Int, 32)
            let value = try proofObject(snap["value"])
            XCTAssertEqual(value["name"] as? String, "w3")
            XCTAssertEqual(value["version"] as? Int, 7)
        }
    }
    func testProofProducerSnapshotMissingAndComparisonBothModes() throws {
        try proofFixture([.missingSnapshot(id: proofID, row: 4, cell: 3, producer: 2),
            .comparison(id: proofID, row: 4, cell: 3, producer: 2,
                snapshot: .init(value: .register(name: "x3", version: 9), width: 64),
                current: .init(value: .unknown("unavailable_x3"), width: 64), needsRepair: true)]) { ledger in
            XCTAssertEqual(ledger[0]["kind"] as? String, "missingSnapshot")
            XCTAssertEqual(ledger[0]["producer"] as? Int, 2)
            XCTAssertEqual(ledger[1]["needsRepair"] as? Bool, true)
            let current = try proofObject(ledger[1]["current"])
            XCTAssertEqual(try proofObject(current["value"])["text"] as? String, "unavailable_x3")
            let snap = try proofObject(ledger[1]["snapshot"])
            XCTAssertEqual(try proofObject(snap["value"])["version"] as? Int, 9)
        }
    }
    func testProofPreservationExactPredecessorsBothModes() throws {
        try proofFixture([.preservationVisit(id: proofID, row: 4, cell: 3, producer: 0,
            prior: 2, outcome: "preserved", modeled: true, writesCell: false, predecessors: [0, 1]),
            .preservationResult(id: proofID, row: 4, cell: 3, producer: 0, preserved: true)]) { ledger in
            XCTAssertEqual(ledger[0]["prior"] as? Int, 2)
            XCTAssertEqual(ledger[0]["predecessors"] as? [Int], [0, 1])
            XCTAssertEqual(ledger[0]["alreadyModeled"] as? Bool, true)
            XCTAssertEqual(ledger[0]["writesCell"] as? Bool, false)
            XCTAssertEqual(ledger[1]["preserved"] as? Bool, true)
        }
    }
    func testProofPreservationShortCircuitIsNotEmptyEvidenceBothModes() throws {
        try proofFixture([.preservationVisit(id: proofID, row: 4, cell: 3, producer: 0,
            prior: 2, outcome: "unmodeled", modeled: false, writesCell: nil, predecessors: nil),
            .preservationResult(id: proofID, row: 4, cell: 3, producer: 0, preserved: false)]) { ledger in
            XCTAssertEqual(ledger[0]["alreadyModeled"] as? Bool, false)
            XCTAssertTrue(ledger[0]["writesCell"] is NSNull)
            XCTAssertTrue(ledger[0]["predecessors"] is NSNull)
            XCTAssertEqual(ledger[1]["preserved"] as? Bool, false)
        }
    }
    private func literalOrdinary(completed: Bool, loop: Bool) -> RejectedCFGDiagnostics.Event {
        typealias ID = RegionalOrdinaryValuePlan.DefinitionID
        let source = ID.source(row: 0, slot: 0)
        let join = ID.join(block: 1, register: 3)
        return .ordinaryFacts(id: proofID, plannerCompleted: completed,
            definitions: [source: .init(value: .register(name: "x3", version: 2), width: 64, type: "uint64_t", zeroHigh: false)],
            uses: [.init(row: 2, ordinal: 1, register: .init(index: 3, width: 32),
                definition: source, value: .unary(op: "(uint32_t)", value: .register(name: "x3", version: 2)))],
            edges: [.init(edge: CFGEdge(0, 1), register: 3, source: source, destination: join)],
            phiInputs: loop ? [join: [CFGEdge(0, 1): source, CFGEdge(2, 1): .source(row: 3, slot: 0)]] : [:],
            before: [[source], [join]], after: [[source], [source]], replacements: [:])
    }
    func testProofRowBindingsPreserveOriginalOrdinalAndProjectionBothModes() throws {
        try proofFixture([literalOrdinary(completed: true, loop: false)]) { ledger in
            let use = try proofArray(ledger[0]["uses"])[0]
            XCTAssertEqual(use["row"] as? Int, 2)
            XCTAssertEqual(use["ordinal"] as? Int, 1)
            XCTAssertEqual(try proofObject(use["register"])["width"] as? Int, 32)
            let v = try proofObject(use["value"])
            XCTAssertEqual(v["op"] as? String, "(uint32_t)")
            XCTAssertEqual(try proofObject(v["value"])["version"] as? Int, 2)
            XCTAssertEqual(ledger[0]["plannerCompleted"] as? Bool, true)
        }
    }
    func testProofRowBindingsPartialPlannerDoesNotClaimProofBothModes() throws {
        try proofFixture([literalOrdinary(completed: false, loop: false)]) { ledger in
            XCTAssertEqual(ledger[0]["plannerCompleted"] as? Bool, false)
            XCTAssertNil(ledger[0]["succeeded"])
            let edge = try proofArray(ledger[0]["edges"])[0]
            XCTAssertEqual(try proofObject(edge["edge"])["from"] as? Int, 0)
            XCTAssertEqual(try proofObject(edge["edge"])["to"] as? Int, 1)
            XCTAssertEqual(try proofObject(edge["destination"])["tag"] as? String, "join")
            let fact = try proofArray(ledger[0]["definitions"])[0]
            XCTAssertEqual(fact["width"] as? Int, 64)
            XCTAssertEqual(fact["zeroHigh"] as? Bool, false)
        }
    }
    func testProofLoopEdgesRetainForwardAndBackedgeInputsBothModes() throws {
        try proofFixture([literalOrdinary(completed: true, loop: true)]) { ledger in
            let phi = try proofArray(ledger[0]["phiInputs"])[0]
            let inputs = try proofArray(phi["inputs"])
            XCTAssertEqual(inputs.count, 2)
            XCTAssertEqual(try proofObject(inputs[0]["edge"])["from"] as? Int, 0)
            XCTAssertEqual(try proofObject(inputs[1]["edge"])["from"] as? Int, 2)
            XCTAssertEqual(try proofObject(inputs[1]["definition"])["row"] as? Int, 3)
            XCTAssertEqual(try proofObject(phi["join"])["block"] as? Int, 1)
        }
    }
    func testProofLoopEdgesNoInputsIsLiteralNotInventedBothModes() throws {
        try proofFixture([literalOrdinary(completed: false, loop: false)]) { ledger in
            XCTAssertEqual(try proofArray(ledger[0]["phiInputs"]).count, 0)
            let before = try XCTUnwrap(ledger[0]["before"] as? [[Any]])
            let after = try XCTUnwrap(ledger[0]["after"] as? [[Any]])
            XCTAssertEqual(try proofObject(before[1][0])["tag"] as? String, "join")
            XCTAssertEqual(try proofObject(after[1][0])["tag"] as? String, "source")
        }
    }
    private func literalPhysical() -> RejectedCFGDiagnostics.Event {
        .physicalAttempt(id: proofID, start: 0x1000, addresses: [0x1000, 0x1004],
            ranges: [0..<1, 1..<2], predecessors: [[], [0, 1]], successors: [[1], [1]],
            backEdges: [CFGEdge(1, 1)], file: "PhysicalFixture.swift", line: 40)
    }
    func testProofRejectedCertificateKeepsDecodedRowsAndOptionalRefusalBothModes() throws {
        try proofFixture([literalPhysical(), .physicalRows(id: proofID, rows: [
            .move(.init(index: 3, width: 32), .immediate(7)), .jump(0x1004)]),
            .physicalEnd(id: proofID, succeeded: false)]) { ledger in
            XCTAssertEqual(ledger[0]["file"] as? String, "PhysicalFixture.swift")
            XCTAssertEqual(ledger[0]["line"] as? Int, 40)
            let rows = try proofArray(ledger[1]["rows"])
            XCTAssertEqual(rows[0]["tag"] as? String, "move")
            XCTAssertEqual(try proofObject(rows[0]["destination"])["width"] as? Int, 32)
            XCTAssertEqual(try proofObject(rows[0]["operand"])["value"] as? String, "7")
            XCTAssertEqual(rows[1]["target"] as? String, "0x1004")
            XCTAssertEqual(ledger[2]["succeeded"] as? Bool, false)
            XCTAssertEqual(ledger[2]["regionalRefusalStatus"] as? String, "not-produced-by-optional-return")
        }
    }
    func testProofRejectedCertificateClassifiedCaseAndGuardLocationBothModes() throws {
        try proofFixture([.classificationBegin(id: proofID, file: "Caller.swift", line: 8),
            .guardObserved(kind: "contradiction", name: "wrong-edge", recorded: true, file: "Proof.swift", line: 91),
            .classificationEnd(id: proofID, refusal: .contradiction(guard: "wrong-edge"))]) { ledger in
            XCTAssertEqual(ledger[1]["file"] as? String, "Proof.swift")
            XCTAssertEqual(ledger[1]["line"] as? Int, 91)
            XCTAssertEqual(ledger[1]["owningClassificationID"] as? String, proofID.uuidString)
            let refusal = try proofObject(ledger[2]["refusal"])
            XCTAssertEqual(refusal["case"] as? String, "contradiction")
            XCTAssertEqual(refusal["guard"] as? String, "wrong-edge")
        }
    }
    private func literalParameter() throws -> MacIRFunctionParameter {
        try XCTUnwrap(MacIRFunctionParameter(id: .init(rawValue: "fixture:arg4"), bindingID: .gpr(4),
            sourcePosition: 0, abiLocation: .gpr(index: 4, carrierWidth: 64), type: "uint64_t",
            name: "input", evidence: .authoritativeUser))
    }
    func testProofEntryBindingExactReadProjectionBothModes() throws {
        let parameter = try literalParameter()
        try proofFixture([.buildBegin(id: proofID, name: "proof_fixture", start: 0x1000),
            .rowBegin(buildID: proofID, row: 1, address: 0x1004),
            .entryRead(register: "w4", parameter: parameter, sourceWidth: 64, requestedWidth: 32,
                projectedValue: .unary(op: "(uint32_t)", value: .argument(bindingID: .gpr(4))), file: "State.swift", line: 370),
            .rowEnd(buildID: proofID, row: 1), .buildEnd(id: proofID)]) { ledger in
            XCTAssertEqual(ledger[2]["sourceWidth"] as? Int, 64)
            XCTAssertEqual(ledger[2]["requestedWidth"] as? Int, 32)
            XCTAssertEqual(ledger[2]["register"] as? String, "w4")
            XCTAssertEqual(try proofObject(ledger[2]["owningRow"])["address"] as? String, "0x1004")
            let p = try proofObject(ledger[2]["parameter"])
            XCTAssertEqual(try proofObject(p["binding"])["value"] as? Int, 4)
            XCTAssertEqual(try proofObject(ledger[2]["projectedValue"])["op"] as? String, "(uint32_t)")
        }
    }
    func testProofEntryBindingUnknownWidthsDoNotInventSelectionBothModes() throws {
        let parameter = try literalParameter()
        try proofFixture([.entryRead(register: "x4", parameter: parameter, sourceWidth: nil, requestedWidth: nil,
            projectedValue: .argument(bindingID: .gpr(4)), file: "State.swift", line: 374)]) { ledger in
            XCTAssertTrue(ledger[0]["sourceWidth"] is NSNull)
            XCTAssertTrue(ledger[0]["requestedWidth"] is NSNull)
            XCTAssertEqual(ledger[0]["contextStatus"] as? String, "no-build-context")
            XCTAssertEqual(try proofObject(ledger[0]["projectedValue"])["tag"] as? String, "argument")
            XCTAssertEqual(ledger[0]["line"] as? Int, 374)
        }
    }
}

extension DecompilerC2DataflowCensusTests {
    func testProofNestedBuildAndPlannerContextsRemainDistinctBothModes() throws {
        let outer = proofID, inner = nestedProofID
        try proofFixture([.buildBegin(id: outer, name: "outer", start: 0x1000),
            .rowBegin(buildID: outer, row: 2, address: 0x1008),
            .buildBegin(id: inner, name: "lexical", start: 0x1000),
            .rowBegin(buildID: inner, row: 2, address: 0x1008),
            .buildEnd(id: inner), .snapshot(id: outer, row: 2, cell: 3,
                definition: .init(value: .register(name: "x3", version: 5), width: 64,
                    isJoinedDefinition: true, isSyntheticReturnPhi: true)),
            .rowEnd(buildID: outer, row: 2), .buildEnd(id: outer)]) { ledger in
            XCTAssertEqual(ledger[4]["owningBuildID"] as? String, inner.uuidString)
            XCTAssertEqual(ledger[5]["owningBuildID"] as? String, outer.uuidString)
            XCTAssertEqual(try proofObject(ledger[5]["owningRow"])["row"] as? Int, 2)
            XCTAssertEqual(ledger[7]["owningBuildID"] as? String, outer.uuidString)
            let snapshot = try proofObject(ledger[5]["definition"])
            XCTAssertEqual(snapshot["isJoinedDefinition"] as? Bool, true)
            XCTAssertEqual(snapshot["isSyntheticReturnPhi"] as? Bool, true)
        }
    }
    func testProofNestedClassificationsAndOuterRefusalDoNotLeakBothModes() throws {
        let outer = proofID, inner = nestedProofID
        try proofFixture([.classificationBegin(id: outer, file: "outer.swift", line: 1),
            .classificationBegin(id: inner, file: "inner.swift", line: 2),
            .guardObserved(kind: "inapplicable", name: "inner", recorded: true, file: "inner.swift", line: 3),
            .classificationEnd(id: inner, refusal: .inapplicable(guard: "inner")),
            .guardObserved(kind: "contradiction", name: "outer", recorded: true, file: "outer.swift", line: 4),
            .classificationEnd(id: outer, refusal: .contradiction(guard: "outer"))]) { ledger in
            XCTAssertEqual(ledger[2]["owningClassificationID"] as? String, inner.uuidString)
            XCTAssertEqual(ledger[3]["owningClassificationID"] as? String, inner.uuidString)
            XCTAssertEqual(ledger[4]["owningClassificationID"] as? String, outer.uuidString)
            XCTAssertEqual(try proofObject(ledger[3]["refusal"])["case"] as? String, "inapplicable")
            XCTAssertEqual(try proofObject(ledger[5]["refusal"])["case"] as? String, "contradiction")
        }
    }
    func testProofOuterOrdinaryRefusalOverridesPlannerCompletionBothModes() throws {
        try proofFixture([.ordinaryProofBegin(id: nestedProofID, start: 0x1000, file: "Caller.swift", line: 9),
            .ordinaryAttempt(id: proofID, start: 0x1000, addresses: [0x1000], parameters: [], file: "Planner.swift", line: 10),
            literalOrdinary(completed: true, loop: true),
            .ordinaryProofEnd(id: nestedProofID, succeeded: false)]) { ledger in
            XCTAssertEqual(ledger[2]["plannerCompleted"] as? Bool, true)
            XCTAssertEqual(ledger[2]["owningOrdinaryProofID"] as? String, nestedProofID.uuidString)
            XCTAssertEqual(ledger[2]["owningOrdinaryPlannerID"] as? String, proofID.uuidString)
            XCTAssertEqual(ledger[3]["succeeded"] as? Bool, false)
            XCTAssertEqual(ledger[3]["owningOrdinaryProofID"] as? String, nestedProofID.uuidString)
        }
    }
    func testProofUnavailableDuplicateLeavesAndSamePCStayDistinct() throws {
        let missing = MacIRValue.unknown("unavailable_w4")
        let function = MacIRFunction(name: "duplicate_uses", startAddress: 0x2000, returnType: "void", instructions: [
            instruction(0x2000, "add", "w0, w4, w4", .binary(destination: .register(name: "w0", version: 1), op: "+", left: missing, right: missing)),
            instruction(0x2000, "str", "w4, [x2]", .store(source: missing, address: .register(name: "x2", version: 0)))])
        let verdict = C2DataflowCensus.Analysis(rows: [], skippedReason: "fixture-refusal",
            refusalDetails: [], indirectBranchSites: [])
        let collector = C2ProofDiagnostics.Collector()
        let export = try C2ProofDiagnostics.export(function: function, machine: [function.instructions[0].source],
            result: verdict, collector: collector, sourceHead: "fixture", flags: ["captureEnabled": true])
        XCTAssertEqual(export.records.count, 3)
        XCTAssertEqual(export.records.map { $0["occurrenceID"] as? Int }, [0, 1, 2])
        XCTAssertEqual(try proofObject(export.records[0]["row"])["irIndex"] as? Int, 0)
        XCTAssertEqual(try proofObject(export.records[2]["row"])["irIndex"] as? Int, 1)
        XCTAssertEqual(try proofObject(export.records[0]["operand"])["operandPath"] as? [String], ["left"])
        XCTAssertEqual(try proofObject(export.records[1]["operand"])["operandPath"] as? [String], ["right"])
        XCTAssertEqual(try proofObject(export.records[2]["operand"])["operandPath"] as? [String], ["source"])
        XCTAssertEqual(try proofObject(export.coverage["originalCensus"])["skippedReason"] as? String, "fixture-refusal")
        XCTAssertEqual(try proofObject(export.coverage["groups"])["rowBindings"] as? String, "not-produced")
    }
    func testProofGuardedRefusalOccurrencesAndEmptyCoverageAreExplicit() throws {
        let function = MacIRFunction(name: "empty", startAddress: 0x3000, returnType: "void", instructions: [])
        let verdict = C2DataflowCensus.Analysis(rows: [], skippedReason: nil, refusalDetails: [], indirectBranchSites: [])
        let collector = C2ProofDiagnostics.Collector()
        let empty = try C2ProofDiagnostics.export(function: function, machine: [], result: verdict,
            collector: collector, sourceHead: "fixture", flags: ["captureEnabled": true])
        XCTAssertEqual(empty.records.count, 0)
        XCTAssertEqual(empty.coverage["recordCount"] as? Int, 0)
        XCTAssertEqual(try proofObject(empty.coverage["groups"])["entryBinding"] as? String, "not-produced")
        C2ProofDiagnostics.withCollector(collector, phase: "census") {
            for _ in 0..<2 {
                C2ProofDiagnostics.guardedSink?(.init(sourceRow: 4, address: 0x3010, mnemonic: "csel", operands: "x0, x1, x2, eq",
                    value: .register(name: "x1", version: 3), file: "Census.swift", line: 595))
            }
        }
        let observed = try C2ProofDiagnostics.export(function: function, machine: [], result: verdict,
            collector: collector, sourceHead: "fixture", flags: ["captureEnabled": true])
        XCTAssertEqual(observed.records.count, 2)
        XCTAssertEqual(observed.records.map { $0["occurrenceID"] as? Int }, [0, 1])
        XCTAssertEqual(try proofObject(observed.records[0]["row"])["sourceRow"] as? Int, 4)
        XCTAssertEqual(try proofObject(observed.records[0]["refusal"])["regionalRefusalStatus"] as? String, "not-produced-by-census")
        XCTAssertEqual(observed.coverage["guardedSelectRefusalCount"] as? Int, 2)
    }
    func testProofActualEntryReadBranchesBothModes() throws {
        let parameter = try literalParameter()
        for requested in ["w4", "x4"] {
            var off: MacIRValue?
            for enabled in [false, true] {
                let collector = enabled ? C2ProofDiagnostics.Collector() : nil
                var state = BuilderState()
                state.parameters = [parameter]
                let read = C2ProofDiagnostics.withCollector(collector, phase: "actual-entry-read") {
                    state.readRegister(requested)
                }
                let expected: MacIRValue = requested == "w4"
                    ? .unary(op: "(uint32_t)", value: .argument(bindingID: .gpr(4))) : .argument(bindingID: .gpr(4))
                XCTAssertEqual(read, expected)
                if enabled {
                    XCTAssertEqual(read, off)
                    let events = try XCTUnwrap(collector).ledger()
                    XCTAssertEqual(events.count, 1)
                    XCTAssertEqual(events[0]["kind"] as? String, "entryRead")
                    XCTAssertEqual(events[0]["register"] as? String, requested)
                    XCTAssertEqual(events[0]["sourceWidth"] as? Int, 64)
                    XCTAssertEqual(events[0]["requestedWidth"] as? Int, requested == "w4" ? 32 : 64)
                } else { off = read }
            }
        }
    }
    private struct ProofSourceRow: DecompilerInstructionRow {
        let address: UInt64
        let bytes: String
        let mnemonic: String
        let operands: String
        var comment: String? { nil }
    }
    func testProofActualBuilderCaptureDoesNotChangeOperationsOrPseudocode() throws {
        let rows = [ProofSourceRow(address: 0x1000, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "")]
        var offFunction: MacIRFunction?
        var offText: String?
        for enabled in [false, true] {
            let collector = enabled ? C2ProofDiagnostics.Collector() : nil
            let function = C2ProofDiagnostics.withCollector(collector, phase: "build") {
                MacIRBuilder(explicitCFGEnabled: false, ssaEnabled: false).buildFunction(name: "proof_fixture",
                    startAddress: 0x1000, authoritativeReturnLocation: .void, authoritativeReturnType: "void", instructions: rows)
            }
            let printer = PseudocodePrinter(options: DecompilerOptions(structureControlFlow: false,
                deadCodeElimination: false, nopElision: false, functionSizeGate: 1024))
            let document = C2ProofDiagnostics.withCollector(collector, phase: "render") { printer.print(function: function) }
            XCTAssertEqual(function.instructions.map(\.operation), [.returnValue(nil)])
            let code = document.lines.filter { $0.kind != .metadata }.map {
                $0.text.components(separatedBy: " // ").first!.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            XCTAssertEqual(code, ["int64_t proof_fixture(void) {", "return;", "}"])
            if enabled {
                XCTAssertEqual(function, offFunction)
                XCTAssertEqual(document.text, offText)
                let ledger = try XCTUnwrap(collector).ledger()
                XCTAssertEqual(ledger.filter { $0["kind"] as? String == "buildBegin" }.count, 1)
                XCTAssertEqual(ledger.filter { $0["kind"] as? String == "rowBegin" }.count, 1)
                XCTAssertEqual(ledger.filter { $0["kind"] as? String == "buildEnd" }.count, 1)
                let first = try XCTUnwrap(ledger.first)
                XCTAssertEqual(first["start"] as? String, "0x1000")
            } else { offFunction = function; offText = document.text }
        }
    }
    func testProofCaptureScopeRestoresAfterThrowAndNestedOff() throws {
        enum Expected: Error { case stop }
        let collector = C2ProofDiagnostics.Collector()
        try C2ProofDiagnostics.withCollector(collector, phase: "outer") {
            XCTAssertNotNil(RejectedCFGDiagnostics.sink)
            C2ProofDiagnostics.withCollector(nil, phase: "disabled") {
                XCTAssertNil(RejectedCFGDiagnostics.sink)
                XCTAssertNil(C2ProofDiagnostics.guardedSink)
            }
            XCTAssertNotNil(RejectedCFGDiagnostics.sink)
            do {
                try C2ProofDiagnostics.withCollector(nil, phase: "throw") { throw Expected.stop }
                XCTFail("Expected throw")
            } catch Expected.stop {}
            XCTAssertNotNil(RejectedCFGDiagnostics.sink)
        }
        XCTAssertNil(RejectedCFGDiagnostics.sink)
        XCTAssertNil(C2ProofDiagnostics.guardedSink)
    }
}

extension DecompilerC2DataflowCensusTests {
    func testProofActualClassifiedPhysicalRefusalBothModes() throws {
        let function = MacIRFunction(name: "proof_fixture", startAddress: 0x1000, returnType: "void",
            instructions: [instruction(0x1000, "ret", "", .returnValue(nil))])
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        var offText: String?
        for enabled in [false, true] {
            let collector = enabled ? C2ProofDiagnostics.Collector() : nil
            let outcome = C2ProofDiagnostics.withCollector(collector, phase: "actual-classified-proof") {
                RegionalPhysicalStatePlan.proveClassified(function: function, cfg: cfg, attemptLexical: false)
            }
            // Boundary prefix/suffix gate refuses this one-row shape before
            // any byte decoding; no RegionalRefusal guard was produced there.
            switch outcome {
            case .success: XCTFail("One-row fixture has no non-exterior body")
            case let .failure(reason): XCTAssertEqual(reason, .inapplicable(guard: "unmodeled-shape"))
            }
            let printer = PseudocodePrinter(options: DecompilerOptions(structureControlFlow: false,
                deadCodeElimination: false, nopElision: false, functionSizeGate: 1024))
            let document = C2ProofDiagnostics.withCollector(collector, phase: "render") { printer.print(function: function) }
            XCTAssertEqual(function.instructions.map(\.operation), [.returnValue(nil)])
            let code = document.lines.filter { $0.kind != .metadata }.map {
                $0.text.components(separatedBy: " // ").first!.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            XCTAssertEqual(code, ["void proof_fixture(void) {", "return;", "}"])
            if enabled {
                XCTAssertEqual(document.text, offText)
                let ledger = try XCTUnwrap(collector).ledger()
                let physical = ledger.filter { $0["kind"] as? String == "physicalAttempt" }
                let ends = ledger.filter { $0["kind"] as? String == "physicalEnd" }
                XCTAssertEqual(physical.count, 1)
                XCTAssertEqual(ends.count, 1)
                XCTAssertEqual(ends[0]["succeeded"] as? Bool, false)
                XCTAssertEqual(physical[0]["addresses"] as? [String], ["0x1000"])
                XCTAssertEqual(ledger.filter { $0["kind"] as? String == "guardObserved" }.count, 0)
                let classified = try XCTUnwrap(ledger.first { $0["kind"] as? String == "classificationEnd" })
                XCTAssertEqual(try proofObject(classified["refusal"])["guard"] as? String, "unmodeled-shape")
            } else { offText = document.text }
        }
    }
}

extension DecompilerC2DataflowCensusTests {
    private func literalOpaqueCallFunction() throws -> MacIRFunction {
        let scope = try XCTUnwrap(MacIRCallArgumentObservationScope(gprIndices: Set(0..<8)))
        let arguments = try XCTUnwrap(MacIRCallArguments([], observationScope: scope))
        let frame = try XCTUnwrap(MacIRCallFrame(target: "callee", knownSignature: nil,
            controlInputs: .none, arguments: arguments))
        // Literal envelope mirrors the pinned BL decoder constructor, not a
        // test-time decoder result. BL at 0x1000 carries displacement 0x1000.
        let callEnvelope = InstructionOperands(coverage: .complete, opcodeClass: "bl",
            operands: [.pcRelative(.init(baseAddress: 0x1000, displacement: 0x1000))],
            presentation: .init(mnemonic: "bl"))
        let call = MacIRInstruction(source: .init(address: 0x1000, byteText: "00 04 00 94",
            mnemonic: "bl", operands: "callee", structuredOperands: callEnvelope),
            operation: .call(frame: frame, result: nil))
        let returned = MacIRInstruction(source: .init(address: 0x1004, byteText: "c0 03 5f d6",
            mnemonic: "ret", operands: "", structuredOperands: .unavailable(mnemonic: "ret", operands: "")),
            operation: .returnValue(nil))
        var function = MacIRFunction(name: "proof_call", startAddress: 0x1000, returnType: "void", instructions: [call, returned])
        // Hand-built original SSA records satisfy the existing equality gate;
        // this fixture does not request a replay build or repair authority.
        function.ssaEnabled = true
        function.ssaOriginalInstructions = function.instructions
        function.ssaOriginalPhis = []
        return function
    }
    private func actualOrdinaryProofFixture(mismatch: Bool) throws {
        let function = try literalOpaqueCallFunction()
        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
        var offText: String?
        for enabled in [false, true] {
            let collector = enabled ? C2ProofDiagnostics.Collector() : nil
            // Standalone unit-fixture invocations. Production census adds none.
            let physical = try XCTUnwrap(C2ProofDiagnostics.withCollector(collector, phase: "actual-physical") {
                RegionalPhysicalStatePlan.prove(function: function, cfg: cfg, attemptLexical: false)
            })
            var candidate = function
            if mismatch { candidate.name = "not_the_certified_function" }
            let ordinary = C2ProofDiagnostics.withCollector(collector, phase: "actual-ordinary") {
                RegionalOrdinaryValuePlan.prove(function: candidate, cfg: cfg, certifiedBy: physical)
            }
            if mismatch { XCTAssertNil(ordinary) } else { XCTAssertNotNil(ordinary) }
            let printer = PseudocodePrinter(options: DecompilerOptions(structureControlFlow: false,
                deadCodeElimination: false, nopElision: false, functionSizeGate: 1024))
            let document = C2ProofDiagnostics.withCollector(collector, phase: "render") { printer.print(function: function) }
            guard case let .call(frame, nil) = function.instructions[0].operation else { return XCTFail("Literal original call changed") }
            XCTAssertEqual(frame.target, "callee")
            XCTAssertEqual(frame.bindingValues, [])
            XCTAssertEqual(function.instructions[1].operation, .returnValue(nil))
            let code = document.lines.filter { $0.kind != .metadata }.map {
                $0.text.components(separatedBy: " // ").first!.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            XCTAssertEqual(code, ["void proof_call(void) {", "callee();", "return;", "}"])
            if enabled {
                XCTAssertEqual(document.text, offText)
                let ledger = try XCTUnwrap(collector).ledger()
                let certificate = try XCTUnwrap(ledger.first { $0["kind"] as? String == "physicalCertificate" })
                XCTAssertEqual(try proofArray(certificate["provedPositions"]).count, 0)
                let decoded = try XCTUnwrap(ledger.first { $0["kind"] as? String == "physicalRows" })
                let decodedRows = try proofArray(decoded["rows"])
                XCTAssertEqual(decodedRows.map { $0["tag"] as? String }, ["call", "original"])
                XCTAssertEqual(decodedRows[0]["hasResult"] as? Bool, false)
                let ended = try XCTUnwrap(ledger.first { $0["kind"] as? String == "ordinaryProofEnd" })
                XCTAssertEqual(ended["succeeded"] as? Bool, !mismatch)
                let facts = ledger.filter { $0["kind"] as? String == "ordinaryFacts" }
                XCTAssertEqual(facts.count, mismatch ? 0 : 1)
                if !mismatch {
                    XCTAssertEqual(facts[0]["plannerCompleted"] as? Bool, true)
                    XCTAssertEqual(try proofArray(facts[0]["uses"]).count, 0)
                    XCTAssertEqual(try proofArray(facts[0]["phiInputs"]).count, 0)
                    XCTAssertEqual(facts[0]["owningOrdinaryProofID"] as? String, ended["attemptID"] as? String)
                }
                XCTAssertEqual(C2ProofDiagnostics.captureStatus(ledger), "complete")
            } else { offText = document.text }
        }
    }
    func testProofActualOrdinarySuccessCopiesOriginalLedgerBothModes() throws {
        try actualOrdinaryProofFixture(mismatch: false)
    }
    func testProofActualOrdinaryEarlyRefusalIsNotMissingCaptureBothModes() throws {
        try actualOrdinaryProofFixture(mismatch: true)
    }
    func testProofNestedPhaseRestoresAndTruncatedLedgerIsIncomplete() throws {
        let collector = C2ProofDiagnostics.Collector()
        C2ProofDiagnostics.withCollector(collector, phase: "outer") {
            RejectedCFGDiagnostics.sink?(.buildBegin(id: proofID, name: "fixture", start: 0x1000))
            C2ProofDiagnostics.withCollector(collector, phase: "inner") {
                RejectedCFGDiagnostics.sink?(.modeled(id: proofID, row: 1))
            }
            RejectedCFGDiagnostics.sink?(.modeled(id: proofID, row: 2))
        }
        let ledger = collector.ledger()
        XCTAssertEqual(ledger.map { $0["phase"] as? String }, ["outer", "inner", "outer"])
        XCTAssertEqual(C2ProofDiagnostics.captureStatus(ledger), "incomplete")
        XCTAssertEqual(C2ProofDiagnostics.phase, "unscoped")
    }
}

extension DecompilerC2DataflowCensusTests {
    // O_EXCL creates the exact stream exclusively; no create-then-reopen race.
    private static func openProofOutput(_ url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    func testProofNormalizedReferencesPreserveEveryOccurrence() throws {
        let collector = C2ProofDiagnostics.Collector()
        C2ProofDiagnostics.withCollector(collector, phase: "fixture") {
            RejectedCFGDiagnostics.sink?(.modeled(id: proofID, row: 0))
            RejectedCFGDiagnostics.sink?(.modeled(id: proofID, row: 1))
            RejectedCFGDiagnostics.sink?(.modeled(id: proofID, row: 2))
            C2ProofDiagnostics.guardedSink?(.init(sourceRow: 0, address: 0x1000, mnemonic: "csel", operands: "x0, x1, x2, eq",
                value: .register(name: "x1", version: 1), file: "Fixture.swift", line: 3))
        }
        let function = MacIRFunction(name: "referenced", startAddress: 0x1000, returnType: "void", instructions: [
            instruction(0x1000, "str", "w4, [x2]", .store(source: .unknown("unavailable_w4"), address: .register(name: "x2", version: 0)))])
        let verdict = C2DataflowCensus.Analysis(rows: [], skippedReason: "original-refusal", refusalDetails: [], indirectBranchSites: [])
        let exported = try C2ProofDiagnostics.export(function: function, machine: function.instructions.map(\.source), result: verdict,
            collector: collector, sourceHead: "fixture", flags: [:], functionOrdinal: 7)
        XCTAssertEqual(exported.coverage["captureStatus"] as? String, "complete")
        XCTAssertEqual(exported.records.count, 2)
        XCTAssertEqual(exported.coverage["unavailableUseCount"] as? Int, 1)
        XCTAssertEqual(exported.coverage["guardedSelectRefusalCount"] as? Int, 1)
        for record in exported.records {
            XCTAssertNil(record["facts"])
            let reference = try proofObject(record["factsRef"])
            XCTAssertEqual(reference["file"] as? String, "c2-proof-coverage.jsonl")
            XCTAssertEqual(reference["functionOrdinal"] as? Int, 7)
            XCTAssertEqual(reference["function"] as? String, "referenced")
            XCTAssertEqual(reference["start"] as? String, "0x1000")
            XCTAssertEqual(reference["firstSequence"] as? Int, 0)
            XCTAssertEqual(reference["sequenceCount"] as? Int, 3)
        }
        XCTAssertEqual(try proofArray(exported.coverage["facts"]).count, 3)
        XCTAssertEqual(try proofObject(exported.coverage["originalCensus"])["skippedReason"] as? String, "original-refusal")
    }
    func testProofPhiOccurrencesKeepVirtualEntryDistinctFromMachineEdgesBothModes() throws {
        for ssa in [false, true] {
            var function = MacIRFunction(name: "proof_phi_predecessors", startAddress: 0x1000,
                returnType: "void", instructions: [], phis: [
                    .init(blockAddress: 0x1000, destination: .register(name: "x3", version: 2), bitWidth: 64,
                        incoming: [
                            .init(predecessor: .functionEntry, value: .unknown("unavailable_x3")),
                            .init(predecessorAddress: 0x1004, value: .unknown("unavailable_x3"))])])
            function.ssaEnabled = ssa
            let verdict = C2DataflowCensus.Analysis(rows: [], skippedReason: "original-refusal",
                refusalDetails: [], indirectBranchSites: [])
            let exported = try C2ProofDiagnostics.export(function: function, machine: [], result: verdict,
                collector: .init(), sourceHead: "fixture", flags: [:])
            XCTAssertEqual(exported.records.count, 2)
            XCTAssertEqual(exported.records.compactMap { $0["occurrenceID"] as? Int }, [0, 1])
            let entry = try proofObject(exported.records[0]["row"])
            let machine = try proofObject(exported.records[1]["row"])
            XCTAssertEqual(entry["status"] as? String, "function-entry")
            XCTAssertEqual(entry["joinAddress"] as? String, "0x1000")
            XCTAssertTrue(entry["predecessorAddress"] is NSNull)
            XCTAssertEqual(machine["status"] as? String, "phi-edge")
            XCTAssertEqual(machine["joinAddress"] as? String, "0x1000")
            XCTAssertEqual(machine["predecessorAddress"] as? String, "0x1004")
        }
    }

    func testProofValueDepthFailureCannotProducePartialExport() throws {
        let collector = C2ProofDiagnostics.Collector()
        var deep = MacIRValue.register(name: "x3", version: 1)
        for _ in 0..<130 { deep = .unary(op: "(uint64_t)", value: deep) }
        collector.append(.snapshot(id: proofID, row: 0, cell: 3, definition: .init(value: deep, width: 64)))
        let function = MacIRFunction(name: "deep", startAddress: 0x1000, instructions: [])
        let verdict = C2DataflowCensus.Analysis(rows: [], skippedReason: nil, refusalDetails: [], indirectBranchSites: [])
        XCTAssertThrowsError(try C2ProofDiagnostics.export(function: function, machine: [], result: verdict,
            collector: collector, sourceHead: "fixture", flags: [:])) { error in
            guard case C2ProofDiagnostics.ExportError.valueDepthLimit = error else {
                return XCTFail("Unexpected failure: \(error)")
            }
        }
    }

}

extension DecompilerC2DataflowCensusTests {
    func testProofWriterFailureDoesNotChangeOriginalVerdictOrRetry() throws {
        enum Injected: Error { case failed }
        let original = C2DataflowCensus.Analysis(rows: [], skippedReason: "original-refusal",
            refusalDetails: [], indirectBranchSites: [])
        let function = MacIRFunction(name: "failure", startAddress: 0x1000, instructions: [])
        let exported = try C2ProofDiagnostics.export(function: function, machine: [], result: original,
            collector: .init(), sourceHead: "fixture", flags: [:])
        let writer = C2ProofDiagnostics.Writer()
        var attempts = 0
        writer.emit(exported, writeCoverage: { _ in attempts += 1; throw Injected.failed },
            writeRecord: { _ in XCTFail("No record after coverage failure") })
        writer.emit(exported, writeCoverage: { _ in XCTFail("No retry after first failure") },
            writeRecord: { _ in XCTFail("No retry after first failure") })
        XCTAssertEqual(attempts, 1)
        XCTAssertNotNil(writer.failureReason)
        XCTAssertEqual(original.skippedReason, "original-refusal")
        XCTAssertEqual(original.rows, [])
        XCTAssertEqual(try proofObject(exported.coverage["originalCensus"])["skippedReason"] as? String, "original-refusal")
    }
}

extension DecompilerC2DataflowCensusTests {
    func testProofGuardedOnlyDepthFailureCannotEscapeQualification() throws {
        let collector = C2ProofDiagnostics.Collector()
        var deep = MacIRValue.register(name: "x3", version: 1)
        for _ in 0..<130 { deep = .unary(op: "(uint64_t)", value: deep) }
        collector.appendGuarded(.init(sourceRow: 0, address: 0x1000, mnemonic: "csel", operands: "x0, x3, x4, eq",
            value: deep, file: "Fixture.swift", line: 1))
        XCTAssertEqual(collector.ledger().count, 0)
        let function = MacIRFunction(name: "guarded_deep", startAddress: 0x1000, instructions: [])
        let verdict = C2DataflowCensus.Analysis(rows: [], skippedReason: "guarded select arm needs path-predicate proof",
            refusalDetails: [], indirectBranchSites: [])
        XCTAssertThrowsError(try C2ProofDiagnostics.export(function: function, machine: [], result: verdict,
            collector: collector, sourceHead: "fixture", flags: [:])) { error in
            guard case C2ProofDiagnostics.ExportError.valueDepthLimit = error else {
                return XCTFail("Unexpected failure: \(error)")
            }
        }
    }
}

extension DecompilerC2DataflowCensusTests {
    private func literalNativeAttempt(_ id: UUID) -> RejectedCFGDiagnostics.Event {
        .nativeAttempt(id: id, start: 0x1000, addresses: [0x1000, 0x1004], ranges: [0..<1, 1..<2],
            predecessors: [[], [0, 1]], successors: [[1], [1]], backEdges: [CFGEdge(1, 1)],
            parameters: [], file: "NativePlanner.swift", line: 250)
    }
    func testProofNativeBindingsAndLoopInputsHaveSeparateNamespaceBothModes() throws {
        let reg = try XCTUnwrap(DecodedScalarCFGPlan.GPR("x3"))
        let edge = CFGEdge(1, 1)
        let source = DecodedScalarNativeValuePlan.DefinitionID.source(row: 0, slot: 0)
        let join = DecodedScalarNativeValuePlan.DefinitionID.join(block: 1, register: 3)
        try proofFixture([.nativeProofBegin(id: nestedProofID, start: 0x1000, file: "Native.swift", line: 10),
            literalNativeAttempt(proofID),
            .nativeUse(id: proofID, binding: .init(row: 1, ordinal: 0, register: reg, definition: join,
                value: .register(name: "x3", version: 2))),
            .nativeFacts(id: proofID, plannerCompleted: true,
                definitions: [source: .init(value: .register(name: "x3", version: 1), width: 64, type: "uint64_t", zeroHigh: false)],
                edges: [.init(edge: edge, register: 3, source: source, destination: join)],
                phiInputs: [join: [edge: source]], before: [[nil, join]], after: [[nil, source]], replacements: [:]),
            .nativeProofEnd(id: nestedProofID, succeeded: true)]) { ledger in
            XCTAssertEqual(C2ProofDiagnostics.captureStatus(ledger), "complete")
            let use = try XCTUnwrap(ledger.first { $0["kind"] as? String == "nativeUse" })
            XCTAssertEqual(use["owningNativePlannerID"] as? String, self.proofID.uuidString)
            XCTAssertEqual(use["owningNativeProofID"] as? String, self.nestedProofID.uuidString)
            XCTAssertNil(use["owningOrdinaryPlannerID"])
            XCTAssertEqual(try self.proofObject(use["definition"])["namespace"] as? String, "decodedScalarNative")
            let facts = try XCTUnwrap(ledger.first { $0["kind"] as? String == "nativeFacts" })
            let input = try self.proofArray(try self.proofArray(facts["phiInputs"])[0]["inputs"])[0]
            XCTAssertEqual(try self.proofObject(input["definition"])["tag"] as? String, "source")
            XCTAssertEqual(try self.proofArray(facts["edges"]).count, 1)
        }
    }
    func testProofNativePartialUsesAndNestedAttemptsRemainDistinctBothModes() throws {
        let reg = try XCTUnwrap(DecodedScalarCFGPlan.GPR("w4"))
        try proofFixture([.nativeProofBegin(id: proofID, start: 0x1000, file: "Outer.swift", line: 1),
            literalNativeAttempt(proofID),
            .nativeProofBegin(id: nestedProofID, start: 0x1000, file: "Inner.swift", line: 2),
            literalNativeAttempt(nestedProofID),
            .nativeUse(id: nestedProofID, binding: .init(row: 1, ordinal: 0, register: reg,
                definition: .entry(4), value: .argument(bindingID: .gpr(4)))),
            .nativeFacts(id: nestedProofID, plannerCompleted: false, definitions: [:], edges: [], phiInputs: [:],
                before: [[nil]], after: [[nil]], replacements: [:]),
            .nativeProofEnd(id: nestedProofID, succeeded: false),
            .nativeUse(id: proofID, binding: .init(row: 1, ordinal: 1, register: reg,
                definition: .source(row: 0, slot: 0), value: .immediate(7))),
            .nativeFacts(id: proofID, plannerCompleted: true, definitions: [:], edges: [], phiInputs: [:],
                before: [], after: [], replacements: [.join(block: 1, register: 4): .source(row: 0, slot: 0)]),
            .nativeProofEnd(id: proofID, succeeded: false)]) { ledger in
            XCTAssertEqual(C2ProofDiagnostics.captureStatus(ledger), "complete")
            let uses = ledger.filter { $0["kind"] as? String == "nativeUse" }
            XCTAssertEqual(uses.count, 2)
            XCTAssertEqual(uses.map { $0["owningNativePlannerID"] as? String }, [self.nestedProofID.uuidString, self.proofID.uuidString])
            XCTAssertEqual(uses.map { $0["ordinal"] as? Int }, [0, 1])
            let facts = ledger.filter { $0["kind"] as? String == "nativeFacts" }
            XCTAssertEqual(facts.map { $0["plannerCompleted"] as? Bool }, [false, true])
            XCTAssertEqual(ledger.filter { $0["kind"] as? String == "nativeProofEnd" }.map { $0["succeeded"] as? Bool }, [false, false])
        }
    }
}
extension DecompilerC2DataflowCensusTests {
    private struct NativeProofSourceRow: DecompilerInstructionRow {
        let source: MacIRSourceSpan
        var address: UInt64 { source.address }
        var bytes: String { source.byteText }
        var mnemonic: String { source.mnemonic }
        var operands: String { source.operands }
        var comment: String? { source.comment }
        var structuredOperands: InstructionOperands? { source.structuredOperands }
    }
    private func literalNativeLoopRows() -> [NativeProofSourceRow] {
        // Canonical envelopes are literal decoder-format inputs, not decoded at fixture construction.
        let x3 = InstructionOperands.Operand.register(.init(index: 3, width: 64))
        let w4 = InstructionOperands.Operand.register(.init(index: 4, width: 32))
        return [
            .init(source: .init(address: 0x1000, byteText: "43 00 80 d2", mnemonic: "mov", operands: "x3, #2",
                structuredOperands: .init(coverage: .complete, opcodeClass: "movz", operands: [x3,
                    .immediate(.init(.unsigned(2), encodedWidth: 16, encodedValue: 2, encodedShift: 0))],
                    presentation: .init(mnemonic: "movz", alias: "mov")))),
            .init(source: .init(address: 0x1004, byteText: "04 00 80 52", mnemonic: "mov", operands: "w4, #0",
                structuredOperands: .init(coverage: .complete, opcodeClass: "movz", operands: [w4,
                    .immediate(.init(.unsigned(0), encodedWidth: 16, encodedValue: 0, encodedShift: 0))],
                    presentation: .init(mnemonic: "movz", alias: "mov")))),
            .init(source: .init(address: 0x1008, byteText: "63 04 00 f1", mnemonic: "subs", operands: "x3, x3, #1",
                structuredOperands: .init(coverage: .complete, opcodeClass: "subs", operands: [x3, x3,
                    .immediate(.init(.unsigned(1), encodedWidth: 12, encodedValue: 1, encodedShift: 0))],
                    presentation: .init(mnemonic: "subs")))),
            .init(source: .init(address: 0x100c, byteText: "84 00 00 51", mnemonic: "sub", operands: "w4, w4, #0",
                structuredOperands: .init(coverage: .complete, opcodeClass: "sub", operands: [w4, w4,
                    .immediate(.init(.unsigned(0), encodedWidth: 12, encodedValue: 0, encodedShift: 0))],
                    presentation: .init(mnemonic: "sub")))),
            .init(source: .init(address: 0x1010, byteText: "c1 ff ff 54", mnemonic: "b.ne", operands: "0x0000000000001008",
                structuredOperands: .init(coverage: .complete, opcodeClass: "b.cond", operands: [
                    .pcRelative(.init(baseAddress: 0x1010, displacement: -8)), .condition(.ne)],
                    presentation: .init(mnemonic: "b", conditionSuffixOperandIndex: 1)))),
            .init(source: .init(address: 0x1014, byteText: "c0 03 5f d6", mnemonic: "ret", operands: "",
                structuredOperands: .unavailable(mnemonic: "ret", operands: "")))
        ]
    }
    private func actualNativeProofFixture(mismatch: Bool) throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            try MacIRConfiguration.$explicitCFGOverride.withValue(false) {
                try MacIRConfiguration.$returnContractOverride.withValue(false) {
                    let rows = literalNativeLoopRows()
                    let expected: [MacIROperation] = [
                        .assign(destination: .register(name: "x3", version: 1), source: .immediate(2)),
                        .assign(destination: .register(name: "w4", version: 1), source: .immediate(0)),
                        .binary(destination: .register(name: "x3", version: 2), op: "-", left: .unknown("unavailable_x3"), right: .immediate(1)),
                        .binary(destination: .register(name: "w4", version: 2), op: "-", left: .unknown("unavailable_w4"), right: .immediate(0)),
                        .conditionalBranch(condition: "!=", left: .unknown("unavailable_x3"), right: .immediate(1), target: .immediate(0x1008)),
                        .returnValue(.unknown("unresolved_return_contract"))
                    ]
                    var offFunction: MacIRFunction?
                    var offText: String?
                    for enabled in [false, true] {
                        let collector = enabled ? C2ProofDiagnostics.Collector() : nil
                        let function = C2ProofDiagnostics.withCollector(collector, phase: "native-build") {
                            MacIRBuilder().buildFunction(name: "proof_native", startAddress: 0x1000, instructions: rows)
                        }
                        XCTAssertEqual(function.instructions.map(\.operation), expected)
                        XCTAssertEqual(function.parameters, [])
                        XCTAssertEqual(function.phis, [])
                        let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
                        // Existing proof calls only; no test-synthesized certificate and no extra production attempts.
                        let state = try XCTUnwrap(C2ProofDiagnostics.withCollector(collector, phase: "native-certificate") {
                            DecodedScalarCFGPlan.prove(function: function, cfg: cfg, attemptLexical: false)
                        })
                        var candidate = function
                        if mismatch { candidate.name = "different_native_function" }
                        let printer = PseudocodePrinter(options: DecompilerOptions(structureControlFlow: false,
                            deadCodeElimination: false, nopElision: false, functionSizeGate: 1024))
                        let names = PseudocodeNameContext(function: function)
                        let plan = C2ProofDiagnostics.withCollector(collector, phase: "actual-native") {
                            DecodedScalarNativeValuePlan.prove(function: candidate, cfg: cfg, certifiedBy: state,
                                renderedName: { printer.valueText(for: $0, names: names) }, reservedNames: [], authoritativeTypes: [:])
                        }
                        if mismatch { XCTAssertNil(plan) } else { XCTAssertNotNil(plan) }
                        let document = C2ProofDiagnostics.withCollector(collector, phase: "native-render") {
                            printer.print(function: function)
                        }
                        // Literal original operation rendering is independent of the overlay's post-write loop predicate.
                        XCTAssertEqual(function.instructions.map { printer.render(operation: $0.operation, names: names) }, [
                            "x3_1 = 0x2", "w4_1 = 0x0", "x3_2 = unavailable_x3 - 0x1", "w4_2 = unavailable_w4 - 0x0",
                            "if (unavailable_x3 != 0x1) __branch(0x1008)", "return unresolved_return_contract"
                        ])
                        let code = document.lines.filter { $0.kind != .metadata }.map {
                            $0.text.components(separatedBy: " // ").first!.trimmingCharacters(in: .whitespaces)
                        }.filter { !$0.isEmpty }
                        XCTAssertEqual(code, ["int64_t proof_native(void) {", "x3_1 = 0x2;", "w4_1 = 0x0;", "L_1008:",
                            "x3_2 = unavailable_x3 - 0x1;", "w4_2 = unavailable_w4 - 0x0;",
                            "if (unavailable_x3 != 0x1) goto L_1008;", "return unresolved_return_contract;", "}"])
                        if enabled {
                            XCTAssertEqual(function, offFunction)
                            XCTAssertEqual(document.text, offText)
                            let ledger = try XCTUnwrap(collector).ledger()
                            let ended = try XCTUnwrap(ledger.first { $0["kind"] as? String == "nativeProofEnd" })
                            XCTAssertEqual(ended["succeeded"] as? Bool, !mismatch)
                            let facts = ledger.filter { $0["kind"] as? String == "nativeFacts" }
                            let uses = ledger.filter { $0["kind"] as? String == "nativeUse" }
                            XCTAssertEqual(facts.count, mismatch ? 0 : 1)
                            XCTAssertEqual(uses.count, mismatch ? 0 : 2)
                            if !mismatch {
                                XCTAssertEqual(facts[0]["plannerCompleted"] as? Bool, true)
                                XCTAssertEqual(uses.map { $0["row"] as? Int }, [2, 3])
                                XCTAssertEqual(uses.map { $0["ordinal"] as? Int }, [0, 0])
                                XCTAssertEqual(try uses.map { try proofObject($0["register"])["index"] as? Int }, [3, 4])
                                XCTAssertEqual(try uses.map { try proofObject($0["definition"])["namespace"] as? String }, ["decodedScalarNative", "decodedScalarNative"])
                                let attempt = try XCTUnwrap(ledger.first { $0["kind"] as? String == "nativeAttempt" })
                                XCTAssertEqual(try proofArray(attempt["backEdges"])[0]["from"] as? Int, 1)
                                XCTAssertEqual(try proofArray(attempt["backEdges"])[0]["to"] as? Int, 1)
                                XCTAssertEqual(facts[0]["owningNativeProofID"] as? String, ended["attemptID"] as? String)
                                XCTAssertFalse(try proofArray(facts[0]["phiInputs"]).isEmpty)
                                XCTAssertFalse(try proofArray(facts[0]["edges"]).isEmpty)
                            }
                            XCTAssertEqual(C2ProofDiagnostics.captureStatus(ledger), "complete")
                        } else {
                            XCTAssertNil(RejectedCFGDiagnostics.sink)
                            offFunction = function; offText = document.text
                        }
                    }
                }
            }
        }
    }
    func testProofActualNativeLoopBindingsBothModes() throws { try actualNativeProofFixture(mismatch: false) }
    func testProofActualNativeMismatchedCertificateBothModes() throws { try actualNativeProofFixture(mismatch: true) }
}

extension DecompilerC2DataflowCensusTests {
    func testProofActualSSAAndLegacyNoNativePlanHaveLiteralPseudocodeBothCaptureModes() throws {
        // This explicitly exercises both product lifters, unlike the native-loop
        // success fixture which deliberately fixes the legacy producer.
        for ssa in [false, true] {
            try MacIRConfiguration.$ssaOverride.withValue(ssa) {
                try MacIRConfiguration.$explicitCFGOverride.withValue(false) {
                    try MacIRConfiguration.$returnContractOverride.withValue(false) {
                        var offFunction: MacIRFunction?
                        var offText: String?
                        for enabled in [false, true] {
                            let collector = enabled ? C2ProofDiagnostics.Collector() : nil
                            let rows = [NativeProofSourceRow(source: .init(address: 0x1000, byteText: "c0 03 5f d6",
                                mnemonic: "ret", operands: "", structuredOperands: .unavailable(mnemonic: "ret", operands: "")))]
                            let function = C2ProofDiagnostics.withCollector(collector, phase: "mode-build") {
                                MacIRBuilder().buildFunction(name: "proof_modes", startAddress: 0x1000,
                                    authoritativeReturnLocation: .void, authoritativeReturnType: "void", instructions: rows)
                            }
                            XCTAssertEqual(function.ssaEnabled, ssa)
                            XCTAssertEqual(function.instructions.map(\.operation), [.returnValue(nil)])
                            let cfg = CFGBuilder.buildCFG(instructions: function.instructions)
                            let state = C2ProofDiagnostics.withCollector(collector, phase: "mode-native-boundary") {
                                DecodedScalarCFGPlan.prove(function: function, cfg: cfg, attemptLexical: false)
                            }
                            XCTAssertNil(state) // No nonentry SUBS self-loop: original native route never reaches its value planner.
                            let printer = PseudocodePrinter(options: DecompilerOptions(structureControlFlow: false,
                                deadCodeElimination: false, nopElision: false, functionSizeGate: 1024))
                            let document = C2ProofDiagnostics.withCollector(collector, phase: "mode-render") { printer.print(function: function) }
                            let code = document.lines.filter { $0.kind != .metadata }.map {
                                $0.text.components(separatedBy: " // ").first!.trimmingCharacters(in: .whitespaces)
                            }.filter { !$0.isEmpty }
                            XCTAssertEqual(code, ["int64_t proof_modes(void) {", "return;", "}"])
                            if enabled {
                                XCTAssertEqual(function, offFunction)
                                XCTAssertEqual(document.text, offText)
                                let ledger = try XCTUnwrap(collector).ledger()
                                XCTAssertFalse(ledger.contains { ($0["kind"] as? String)?.hasPrefix("native") == true })
                                XCTAssertEqual(C2ProofDiagnostics.captureStatus(ledger), "complete")
                            } else { offFunction = function; offText = document.text }
                        }
                    }
                }
            }
        }
    }
}

// authored byte/value fixtures. No execution result is implied.
// Legacy builds retain their old admission; shared exact value rules are checked
// in both mode loops, and new context admission is asserted only for real SSA.
extension DecompilerC2DataflowCensusTests {
    private func exactValueRow(_ address: UInt64, _ bytes: String, _ mnemonic: String,
                                _ operands: String) -> InstructionRow {
        .init(address: address, bytes: bytes, mnemonic: mnemonic, operands: operands,
              hasBreakpoint: false, comment: "")
    }

    private func exactValueSource(_ bytes: String, _ mnemonic: String,
                                   _ operands: String) -> MacIRSourceSpan {
        .init(address: 0x1000, byteText: bytes, mnemonic: mnemonic, operands: operands)
    }

    // A small test-only expression reader. The expectations below are literals,
    // not values computed from a decoder or from the production rule.
    private func exactValueBits(_ value: MacIRValue,
                                 values: [MacIRValue: UInt64] = [:]) -> UInt64? {
        if let found = values[value] { return found }
        switch value {
        case let .immediate(n): return UInt64(bitPattern: n)
        case let .unary(op, inner):
            guard let bits = exactValueBits(inner, values: values) else { return nil }
            if op == "(uint32_t)" { return bits & 0xffffffff }
            if op == "(int32_t)" { return UInt64(bitPattern: Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: bits)))) }
            if op == "__ssa_bitcast_u32" { return bits & 0xffffffff }
            if ["(uint64_t)", "(int64_t)", "__ssa_bitcast_f32",
                "__ssa_bitcast_u64", "__ssa_bitcast_f64"].contains(op) { return bits }
            if op == "!" { return bits == 0 ? 1 : 0 }
            return nil
        case let .binaryExpression(op, left, right):
            if op == MacIRBuilder.signedProjectionOperator {
                let width: Int64?
                if case let .immediate(bits) = right { width = bits }
                else if case let .binaryExpression(context, .immediate(bits), _) = right,
                        context == MacIRBuilder.projectionContextOperator { width = bits }
                else { width = nil }
                guard let bits = exactValueBits(left, values: values), let width else { return nil }
                return width == 32 ? UInt64(bitPattern: Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: bits)))) : bits
            }
            guard let a = exactValueBits(left, values: values),
                  let b = exactValueBits(right, values: values) else { return nil }
            switch op {
            case "+": return a &+ b
            case "-": return a &- b
            case "&": return a & b
            case "|": return a | b
            case "<<": return b < 64 ? a << b : nil
            case "==": return a == b ? 1 : 0
            case "!=": return a != b ? 1 : 0
            case "<", "<=", ">", ">=":
                let signed: Bool
                if case let .binaryExpression(marker, _, _) = left { signed = marker == MacIRBuilder.signedProjectionOperator }
                else { signed = false }
                switch op {
                case "<": return (signed ? Int64(bitPattern: a) < Int64(bitPattern: b) : a < b) ? 1 : 0
                case "<=": return (signed ? Int64(bitPattern: a) <= Int64(bitPattern: b) : a <= b) ? 1 : 0
                case ">": return (signed ? Int64(bitPattern: a) > Int64(bitPattern: b) : a > b) ? 1 : 0
                default: return (signed ? Int64(bitPattern: a) >= Int64(bitPattern: b) : a >= b) ? 1 : 0
                }
            case "&&": return a != 0 && b != 0 ? 1 : 0
            case "||": return a != 0 || b != 0 ? 1 : 0
            default: return nil
            }
        default: return nil
        }
    }

    private func exactValueSelected(_ operation: MacIROperation) -> UInt64? {
        switch operation {
        case let .select(_, condition, left, right, yes, no):
            guard let a = exactValueBits(left), let b = exactValueBits(right),
                  ["==", "!="].contains(condition) else { return nil }
            return exactValueBits((condition == "==" ? a == b : a != b) ? yes : no)
        case let .compareToBool(_, condition, left, right):
            guard let a = exactValueBits(left), let b = exactValueBits(right),
                  ["==", "!="].contains(condition) else { return nil }
            return (condition == "==" ? a == b : a != b) ? 1 : 0
        default: return nil
        }
    }

    private func exactValueSelectFixture(_ source: MacIRSourceSpan, ssa: Bool) -> MacIRFunction {
        var rows = [
            exactValueRow(0x1000, "1f 05 00 71", "cmp", "w8, #1"),
            exactValueRow(0x1004, "00 08 41 7a", "ccmp", "w0, #1, #0, eq"),
            exactValueRow(0x1008, "88 c3 9d b8", "ldursw", "x8, [x28, #-36]"),
            exactValueRow(0x100c, source.byteText, source.mnemonic, source.operands),
            // Prevent the vector-only leaf route from standing in for SSA.
            exactValueRow(0x1010, "29 05 00 91", "add", "x9, x9, #1"),
            exactValueRow(0x1014, "c0 03 5f d6", "ret", "")
        ]
        if source.mnemonic == "csel" {
            // The old second CCMP input is overwritten after its immutable
            // snapshot; the selected false arm is the NEW X10 value.
            rows[0] = exactValueRow(0x1000, "3f b8 03 71", "cmp", "w1, #238")
            rows[1] = exactValueRow(0x1004, "24 10 4a 7a", "ccmp", "w1, w10, #4, ne")
            rows[2] = exactValueRow(0x1008, "ea 03 0c aa", "mov", "x10, x12")
        }
        return MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: ssa)
            .buildFunction(name: "exactValue", startAddress: 0x1000, instructions: rows)
    }

    private func exactValueCheckSelect(_ bytes: String, _ mnemonic: String, _ operands: String,
                                        predicate: UInt64, inputs: [UInt64], expected: UInt64,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let source = exactValueSource(bytes, mnemonic, operands)
        let descriptor = try XCTUnwrap(MacIRBuilder.ssaSnapshotSelect(source), file: file, line: line)
        for ssa in [false, true] {
            // This is the same valueOperation used by production fallback, not
            // execution of a fabricated canonical replacement for the SSA graph.
            let operation = try XCTUnwrap(descriptor.valueOperation(destination: .register(name: "selected_bits", version: 1),
                predicate: .immediate(Int64(predicate)), inputs: inputs.map { .immediate(Int64(bitPattern: $0)) }),
                file: file, line: line)
            XCTAssertEqual(exactValueSelected(operation), expected, file: file, line: line)
            let function = exactValueSelectFixture(source, ssa: ssa)
            XCTAssertEqual(function.ssaEnabled, ssa, file: file, line: line)
            let actual = try XCTUnwrap(function.instructions.first { $0.source.address == 0x100c }, file: file, line: line)
            if ssa {
                switch actual.operation {
                case .select, .compareToBool: break
                default: XCTFail("SSA fallback did not model the matching form", file: file, line: line)
                }
                XCTAssertFalse(function.refusals.contains { $0.scope == .row(0x100c) }, file: file, line: line)
            } else {
                // This lexical CCMP/load-or-overwrite fixture remains refused.
                guard case .unknown = actual.operation else {
                    return XCTFail("legacy output changed", file: file, line: line)
                }
            }
            let effect = MacIRBuilder.ssaEffects(for: source, observesFPSR: true, tracksFPEnvironment: true)
            let expectedReads: Set<Int>, expectedWrites: Set<Int>
            switch mnemonic {
            case "csinc": expectedReads = [8, 96]; expectedWrites = [25]
            case "csel": expectedReads = [10, 11, 96]; expectedWrites = [10]
            case "cset": expectedReads = [96]; expectedWrites = [8]
            default: expectedReads = [32, 33, 96]; expectedWrites = [36, 68]
            }
            XCTAssertEqual(Set(effect.reads.cells), expectedReads, file: file, line: line)
            XCTAssertEqual(Set(effect.writes.map(\.cell)), expectedWrites, file: file, line: line)
            XCTAssertTrue(effect.reads.contains(96), file: file, line: line)
            XCTAssertFalse(effect.writes.contains { $0.cell == 96 || $0.cell >= 98 }, file: file, line: line)
            XCTAssertFalse(effect.reads.contains(98) || effect.reads.contains(99) || effect.reads.contains(100), file: file, line: line)
        }
    }

    func testExactCSINCTrueTruncatesWordBothModes() throws {
        try exactValueCheckSelect("19 15 9f 1a", "csinc", "w25, w8, wzr, ne",
            predicate: 1, inputs: [0x1ffffffff], expected: 0xffffffff)
    }
    func testExactCSINCFalseIsOneBothModes() throws {
        try exactValueCheckSelect("19 15 9f 1a", "csinc", "w25, w8, wzr, ne",
            predicate: 0, inputs: [0x80000000], expected: 1)
    }
    func testExactCSELTrueSnapshotsDistinctArmBothModes() throws {
        try exactValueCheckSelect("6a 01 8a 9a", "csel", "x10, x11, x10, eq",
            predicate: 1, inputs: [0x1122334455667788, 0x8877665544332211], expected: 0x1122334455667788)
    }
    func testExactCSELFalseReadsAliasedOldDestinationBothModes() throws {
        try exactValueCheckSelect("6a 01 8a 9a", "csel", "x10, x11, x10, eq",
            predicate: 0, inputs: [0x1122334455667788, 0x8877665544332211], expected: 0x8877665544332211)
    }
    func testExactCSETTrueIsOneBothModes() throws {
        try exactValueCheckSelect("e8 07 9f 1a", "cset", "w8, ne", predicate: 1, inputs: [], expected: 1)
    }
    func testExactCSETFalseIsZeroBothModes() throws {
        try exactValueCheckSelect("e8 07 9f 1a", "cset", "w8, ne", predicate: 0, inputs: [], expected: 0)
    }
    func testExactFCSELNaNPayloadAndNoEnvironmentBothModes() throws {
        try exactValueCheckSelect("24 0c 20 1e", "fcsel", "s4, s1, s0, eq",
            predicate: 1, inputs: [0x7f800001, 0x80000000], expected: 0x7f800001)
        let effects = MacIRBuilder.ssaEffects(for: exactValueSource("24 0c 20 1e", "fcsel", "s4, s1, s0, eq"))
        XCTAssertEqual(Set(effects.reads.cells), Set([32, 33, 96]))
        XCTAssertEqual(Set(effects.writes.map(\.cell)), Set([36, 68]))
        XCTAssertTrue(effects.writes.contains { $0.cell == 36 && $0.view == .float32 })
    }
    func testExactFCSELFalsePreservesNegativeZeroBothModes() throws {
        try exactValueCheckSelect("24 0c 20 1e", "fcsel", "s4, s1, s0, eq",
            predicate: 0, inputs: [0x7fc12345, 0x80000000], expected: 0x80000000)
        let function = exactValueSelectFixture(exactValueSource("24 0c 20 1e", "fcsel", "s4, s1, s0, eq"), ssa: true)
        let info = try XCTUnwrap(function.ssaInfo)
        let row = try XCTUnwrap(info.sourceAddresses.firstIndex(of: 0x100c))
        let high = try XCTUnwrap(info.plan.rowWriteBindings[row][68])
        XCTAssertEqual(info.values[high], .immediate(0))
        let low = try XCTUnwrap(info.plan.rowWriteBindings[row][36])
        let lowValue = try XCTUnwrap(info.values[low])
        var state = BuilderState()
        state.ssa = .init(current: [36: .init(value: lowValue, bitWidth: 64, view: .float32, origin: .instruction(0x100c)),
                                    68: .init(value: .immediate(0), bitWidth: 64, view: .bits, origin: .instruction(0x100c))],
                          writes: [:], clobbers: [:])
        let q = try XCTUnwrap(state.ssaValue(for: "q4"))
        guard case let .binaryExpression(join, lowBits, highBits) = q,
              join == "__ssa_join_vector_halves" else { return XCTFail("missing physical halves") }
        XCTAssertEqual(exactValueBits(lowBits, values: [lowValue: 0x80000000]), 0x80000000)
        XCTAssertEqual(exactValueBits(highBits), 0)
        // Thus bits32...127 are zero, not copied from the old Vd.
    }

    func testExactConditionalWrongConditionAndWidthRemainOutsideRule() {
        for source in [
            exactValueSource("19 05 9f 1a", "csinc", "w25, w8, wzr, ne"),
            exactValueSource("6a 11 8a 9a", "csel", "x10, x11, x10, eq"),
            exactValueSource("e8 17 9f 1a", "cset", "w8, ne"),
            exactValueSource("24 1c 20 1e", "fcsel", "s4, s1, s0, eq"),
            exactValueSource("24 0c 20 1e", "fcsel", "d4, d1, d0, eq")
        ] { XCTAssertNil(MacIRBuilder.ssaSnapshotSelect(source)) }
    }

    private func exactValueCheckSBFIZ(_ input: UInt64, expected: UInt64) throws {
        for ssa in [false, true] {
            let rows = [exactValueRow(0x1000, "e4 03 14 aa", "mov", "x4, x20"),
                exactValueRow(0x1004, "84 7c 7f 93", "sbfiz", "x4, x4, #1, #32"),
                exactValueRow(0x1008, "c0 03 5f d6", "ret", "")]
            let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: ssa)
                .buildFunction(name: "exactValue_sbfiz", startAddress: 0x1000, instructions: rows)
            XCTAssertEqual(function.ssaEnabled, ssa)
            let instruction = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1004 })
            guard case let .assign(_, .signedBitfield(field)) = instruction.operation else {
                return XCTFail("missing existing exact signed-bitfield operation")
            }
            XCTAssertEqual(field.evaluatedBits(sourceBits: input), expected)
            let effects = MacIRBuilder.ssaEffects(for: instruction.source)
            XCTAssertEqual(Set(effects.reads.cells), Set([4]))
            XCTAssertEqual(Set(effects.writes.map(\.cell)), Set([4]))
        }
    }
    func testExactSBFIZPositiveSignBitBoundaryBothModes() throws {
        try exactValueCheckSBFIZ(0x7fffffff, expected: 0xfffffffe)
    }
    func testExactSBFIZNegativeSignExtensionBothModes() throws {
        try exactValueCheckSBFIZ(0x1234567880000000, expected: 0xffffffff00000000)
    }
    func testExactSBFIZInvalidFieldAndByteMismatchDoNotOptIn() {
        XCTAssertFalse(MacIRBuilder.ssaExactSignedInsert(exactValueSource("84 fc 7f 93", "sbfiz", "x4, x4, #1, #64")))
        XCTAssertFalse(MacIRBuilder.ssaExactSignedInsert(exactValueSource("84 78 7f 93", "sbfiz", "x4, x4, #1, #32")))
    }
    func testExactSBFIZSeededCyclicPhiIsValueNotReturnAuthority() throws {
        // Mirror the real4862c loop: SDIV is already established, while its
        // future MOV backedge is independently byte/text-exact and unconditional.
        let rows = [exactValueRow(0x1000, "e4 03 14 aa", "mov", "x4, x20"),
            exactValueRow(0x1004, "8b 0c cc 1a", "sdiv", "w11, w4, w12"),
            exactValueRow(0x1008, "84 7c 7f 93", "sbfiz", "x4, x4, #1, #32"),
            exactValueRow(0x100c, "e4 03 0b aa", "mov", "x4, x11"),
            exactValueRow(0x1010, "1f 00 00 71", "cmp", "w0, #0"),
            exactValueRow(0x1014, "81 ff ff 54", "b.ne", "0x1004"),
            exactValueRow(0x1018, "c0 03 5f d6", "ret", "")]
        let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: true)
            .buildFunction(name: "exactValue_phi", startAddress: 0x1000, instructions: rows)
        XCTAssertTrue(function.ssaEnabled)
        let instruction = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1008 })
        guard case let .assign(_, .signedBitfield(field)) = instruction.operation else { return XCTFail("seeded SSA phi refused") }
        XCTAssertEqual(field.evaluatedBits(sourceBits: 0xffffffff), 0xfffffffffffffffe)
        XCTAssertTrue(function.phis.contains { $0.cell == 4 })
        XCTAssertTrue(function.instructions.contains { if case .returnValue(.some(.unknown("unresolved_return_contract"))) = $0.operation { return true }; return false })
    }

    private func exactValuePayload(_ value: MacIRValue) -> (UInt64, UInt64)? {
        let low: UInt64 = 0x1122334455667788, high: UInt64 = 0x99aabbccddeeff00
        func half(_ value: MacIRValue) -> UInt64? {
            switch value {
            case let .unary(op, inner):
                if op == "__ssa_low64" { return exactValuePayload(inner)?.0 }
                if op == "__ssa_high64" { return exactValuePayload(inner)?.1 }
                if ["__ssa_bitcast_u64", "__ssa_bitcast_u32", "(uint64_t)"].contains(op) { return half(inner) }
                if op == "(uint32_t)", let bits = half(inner) { return bits & 0xffffffff }
                return nil
            case let .register(name, version) where version == 0:
                if ["v0", "q0", "d0"].contains(name) { return low }
                if name == "vh0" { return high }
                return nil
            case let .argument(id) where id.kind == .simd && id.value == 0: return low
            default: return nil
            }
        }
        switch value {
        case let .binaryExpression(op, left, right) where op == "__ssa_join_vector_halves":
            guard let a = half(left), let b = half(right) else { return nil }; return (a, b)
        case let .register(name, version) where version == 0:
            if ["v0", "q0"].contains(name) { return (low, high) }
            if name == "d0" { return (low, 0) }
            return nil
        case let .argument(id) where id.kind == .simd && id.value == 0: return (low, high)
        default: return nil
        }
    }

    private func exactValueCheckQStore(_ bytes: String, operands: String, base: UInt64,
                                        index: UInt64, expectedAddress: UInt64) throws {
        let source = exactValueSource(bytes, "str", operands)
        let effect = MacIRBuilder.ssaEffects(for: source, observesFPSR: true, tracksFPEnvironment: true)
        let baseCell = operands.contains("x23") ? 23 : 9
        XCTAssertEqual(Set(effect.reads.cells), Set([baseCell, 8, 32, 64, 97]))
        XCTAssertEqual(Set(effect.writes.map(\.cell)), Set([97]))
        for ssa in [false, true] {
            var rows = [exactValueRow(0x1000, bytes, "str", operands)]
            if ssa { rows.append(exactValueRow(0x1004, "29 05 00 91", "add", "x9, x9, #1")) }
            rows.append(exactValueRow(ssa ? 0x1008 : 0x1004, "c0 03 5f d6", "ret", ""))
            let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: ssa)
                .buildFunction(name: "exactValue_qstore", startAddress: 0x1000, instructions: rows)
            XCTAssertEqual(function.ssaEnabled, ssa)
            let instruction = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1000 })
            let memory = try XCTUnwrap(instruction.neonIndexedMemory)
            XCTAssertEqual(memory.effect, .store)
            XCTAssertEqual(instruction.memoryAccess?.byteWidth, 16)
            guard case let .store(payload, _) = instruction.operation else { return XCTFail("missing exact Q store") }
            // Evaluate the actual descriptor with literal values for its captured
            // bindings; its constructor intentionally refuses immediate bindings.
            XCTAssertEqual(exactValueBits(memory.address, values: [memory.base: base, memory.index: index]), expectedAddress)
            let bits = try XCTUnwrap(exactValuePayload(payload))
            XCTAssertEqual(bits.0, 0x1122334455667788)
            XCTAssertEqual(bits.1, 0x99aabbccddeeff00)
        }
    }
    func testExactQStoreX9IndexUsesFull128BothModes() throws {
        try exactValueCheckQStore("20 69 a8 3c", operands: "q0, [x9, x8]",
            base: 0x1000, index: 0x20, expectedAddress: 0x1020)
    }
    func testExactQStoreX23IndexWrapsAddressBothModes() throws {
        try exactValueCheckQStore("e0 6a a8 3c", operands: "q0, [x23, x8]",
            base: 0xfffffffffffffff8, index: 0x18, expectedAddress: 0x10)
    }
    func testExactQStoreWrongOptionShiftAndSPRemainRefused() {
        for source in [exactValueSource("20 09 a8 3c", "str", "q0, [x9, x8]"),
            exactValueSource("20 79 a8 3c", "str", "q0, [x9, x8, lsl #4]"),
            exactValueSource("e0 6b a8 3c", "str", "q0, [sp, x8]")] {
            XCTAssertNil(MacIRBuilder.ssaExactIndexedQStore(source))
        }
    }

    func testExactFCVTNRemainsDeliberatelyRefusedBothModes() {
        for _ in [false, true] {
            let source = exactValueSource("21 68 61 0e", "fcvtn", "v1.2s, v1.2d")
            XCTAssertEqual(C2MachineFlow(rows: [source]).error, "0x1000: unsupported machine mnemonic fcvtn")
            XCTAssertNil(MacIRBuilder.ssaSnapshotSelect(source))
        }
    }
}

extension DecompilerC2DataflowCensusTests {
    private func exactValueNestedRows() -> [InstructionRow] {
        [exactValueRow(0x1000, "d4 00 00 34", "cbz", "w20, 0x1018"),
         exactValueRow(0x1004, "9f 02 08 6b", "cmp", "w20, w8"),
         exactValueRow(0x1008, "00 d1 49 7a", "ccmp", "w8, w9, #0, le"),
         exactValueRow(0x100c, "68 ba 41 b9", "ldr", "w8, [x19, #440]"),
         exactValueRow(0x1010, "00 d9 41 7a", "ccmp", "w8, #1, #0, le"),
         exactValueRow(0x1014, "02 00 00 14", "b", "0x101c"),
         exactValueRow(0x1018, "1f 01 00 71", "cmp", "w8, #0"),
         exactValueRow(0x101c, "e8 07 9f 1a", "cset", "w8, ne"),
         exactValueRow(0x1020, "29 05 00 91", "add", "x9, x9, #1"),
         exactValueRow(0x1024, "c0 03 5f d6", "ret", "")]
    }

    func testSnapshotAndNumericPhiProofRequireMachinePredecessors() throws {
        let rows = exactValueNestedRows()
        let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: true)
            .buildFunction(name: "exact_phi_predecessors", startAddress: 0x1000, instructions: rows)
        let graph = try XCTUnwrap(function.cfg)
        let info = try XCTUnwrap(function.ssaInfo)
        let retained = try XCTUnwrap(info.plan.phis.first { $0.cell == 96 && $0.incoming.count == 2 })
        XCTAssertEqual(Set(retained.incoming.compactMap(\.machineAddress)), Set([0x1014, 0x1018]))
        let incoming = retained.incoming.enumerated().map { index, edge in
            MacIRSSA.Incoming(predecessor: edge.predecessor, definition: index + 1)
        }
        // Authored proof-API inputs isolate predecessor identity from numeric
        // values. The graph and actual edge coordinates come from the byte fixture.
        var plan = MacIRSSA.Plan(definitions: [
            .init(id: 0, cell: 96, bitWidth: 4, view: .flags, origin: .phi(block: retained.block)),
            .init(id: 1, cell: 96, bitWidth: 4, view: .flags, origin: .entry),
            .init(id: 2, cell: 96, bitWidth: 4, view: .flags, origin: .entry)],
            phis: [.init(block: retained.block, cell: 96, destination: 0, incoming: incoming)],
            rowReadBindings: [], rowWriteBindings: [], blockEntryBindings: [], blockExitBindings: [],
            liveIn: [], liveOut: [], aliases: [:], refusals: [])
        let snapshots = Dictionary(uniqueKeysWithValues: [1, 2].map { id in
            (id, MacIRBuilder.SSANZCVSnapshot(left: .immediate(1), right: .immediate(0), width: 32,
                guardDefinition: nil, guardCondition: nil, fallback: nil, numericInputs: []))
        })
        let sources = rows.map { MacIRSourceSpan(address: $0.address, byteText: $0.bytes,
            mnemonic: $0.mnemonic, operands: $0.operands) }
        XCTAssertNotNil(MacIRBuilder.ssaNZCVPredicate(flags: 0, suffix: "ne", snapshots: snapshots,
            plan: plan, graph: graph, sources: sources, memo: [:], phis: [:], occupiedValues: []))
        var numericPlan = plan
        for index in numericPlan.definitions.indices {
            numericPlan.definitions[index].cell = 0
            numericPlan.definitions[index].bitWidth = 64
            numericPlan.definitions[index].view = .integer
        }
        numericPlan.phis[0].cell = 0
        XCTAssertTrue(MacIRBuilder.ssaNumericAncestryIsAvailable(roots: [0], plan: numericPlan,
            sources: sources, graph: graph, actualUnknownSources: []))
        plan.phis[0].incoming[0].predecessor = .functionEntry
        numericPlan.phis[0].incoming[0].predecessor = .functionEntry
        XCTAssertNil(MacIRBuilder.ssaNZCVPredicate(flags: 0, suffix: "ne", snapshots: snapshots,
            plan: plan, graph: graph, sources: sources, memo: [:], phis: [:], occupiedValues: []))
        XCTAssertFalse(MacIRBuilder.ssaNumericAncestryIsAvailable(roots: [0], plan: numericPlan,
            sources: sources, graph: graph, actualUnknownSources: []))
    }

    func testExactNestedCCMPFlagPhiUsesSourceBlockAndAllEdges() throws {
        for ssa in [false, true] {
            let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: ssa)
                .buildFunction(name: "exactValue_nested", startAddress: 0x1000, instructions: exactValueNestedRows())
            XCTAssertEqual(function.ssaEnabled, ssa)
            let phis = function.phis.filter { if case let .register(name, _) = $0.destination { return name.hasPrefix("__mscope_nzcv_") }; return false }
            if ssa {
                let phi = try XCTUnwrap(phis.first)
                XCTAssertEqual(phi.blockAddress, 0x101c)
                XCTAssertTrue(phi.incoming.allSatisfy { $0.machineAddress != nil })
                XCTAssertEqual(Set(phi.incoming.compactMap(\.machineAddress)), Set([0x1014, 0x1018]))
                let row = try XCTUnwrap(function.instructions.first { $0.source.address == 0x101c })
                guard case .compareToBool = row.operation else { return XCTFail("nested flags phi not modeled") }
            } else { XCTAssertTrue(phis.isEmpty) }
        }
    }

    func testExactSignedOverflowIsNotMIAndFallbackPolarityIsExact() throws {
        let a = MacIRValue.register(name: "w20", version: 1), b = MacIRValue.register(name: "w8", version: 1)
        var state = BuilderState()
        state.ssa = .init(current: [20: .init(value: a, bitWidth: 32, view: .integer, origin: .instruction(0xff0)),
                                    8: .init(value: b, bitWidth: 32, view: .integer, origin: .instruction(0xff4))],
                          writes: [:], clobbers: [:])
        let snapshot = try XCTUnwrap(MacIRBuilder.ssaNZCVSnapshot(
            exactValueSource("9f 02 08 6b", "cmp", "w20, w8"), state: state, numericInputs: [], reachingFlags: nil))
        // 0x80000000 - 1 wraps to0x7fffffff: N=0,V=1, so LT is true.
        let values: [MacIRValue: UInt64] = [a: 0x80000000, b: 1]
        XCTAssertEqual(exactValueBits(try XCTUnwrap(MacIRBuilder.ssaNZCVSubtractionCondition(snapshot, suffix: "lt")), values: values), 1)
        XCTAssertEqual(exactValueBits(try XCTUnwrap(MacIRBuilder.ssaNZCVSubtractionCondition(snapshot, suffix: "ge")), values: values), 0)
        XCTAssertNil(MacIRBuilder.ssaNZCVSubtractionCondition(snapshot, suffix: "mi"))
        XCTAssertEqual(MacIRBuilder.ssaNZCVConditionHolds("lt", nzcv: 1), true)
        XCTAssertEqual(MacIRBuilder.ssaNZCVConditionHolds("ne", nzcv: 4), false)
        XCTAssertEqual(MacIRBuilder.ssaNZCVConditionHolds("le", nzcv: 4), true)
        XCTAssertNil(MacIRBuilder.ssaNZCVConditionHolds("mi", nzcv: 1))
    }

    func testExactComparisonWordProjectionIgnoresHigh32Bits() throws {
        let a = MacIRValue.register(name: "x20", version: 1), b = MacIRValue.register(name: "x8", version: 1)
        var state = BuilderState()
        state.ssa = .init(current: [20: .init(value: a, bitWidth: 64, view: .integer, origin: .instruction(0xff0)),
                                    8: .init(value: b, bitWidth: 64, view: .integer, origin: .instruction(0xff4))],
                          writes: [:], clobbers: [:])
        let snapshot = try XCTUnwrap(MacIRBuilder.ssaNZCVSnapshot(
            exactValueSource("9f 02 08 6b", "cmp", "w20, w8"), state: state, numericInputs: [], reachingFlags: nil))
        let equality = try XCTUnwrap(MacIRBuilder.ssaNZCVSubtractionCondition(snapshot, suffix: "eq"))
        XCTAssertEqual(exactValueBits(equality, values: [a: 0x100000000, b: 0]), 1)
    }

    func testExactBadIncomingCCMPDoesNotCommitPartialPhiMemo() {
        for ssa in [false, true] {
            var rows = exactValueNestedRows()
            // Word still says LE; MI text must not acquire a snapshot, nor may
            // a partially resolved other incoming leave a named boolean phi.
            rows[4] = exactValueRow(0x1010, "00 d9 41 7a", "ccmp", "w8, #1, #0, mi")
            let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: ssa)
                .buildFunction(name: "exactValue_bad_phi", startAddress: 0x1000, instructions: rows)
            XCTAssertFalse(function.phis.contains { if case let .register(name, _) = $0.destination { return name.hasPrefix("__mscope_nzcv_") }; return false })
            if ssa {
                XCTAssertTrue(function.instructions.contains { instruction in
                    guard instruction.source.address == 0x101c else { return false }
                    if case .unknown = instruction.operation { return true }; return false
                })
            }
        }
    }

    func testExactCallClobberedSIMDPhiRejectsPayloadAndRollsBackPhi() {
        for ssa in [false, true] {
            let rows = [exactValueRow(0x1000, "1f 00 00 71", "cmp", "w0, #0"),
                exactValueRow(0x1004, "80 00 00 54", "b.eq", "0x1014"),
                exactValueRow(0x1008, "fe 03 00 94", "bl", "0x2000"),
                exactValueRow(0x100c, "9f 02 00 71", "cmp", "w20, #0"),
                exactValueRow(0x1010, "03 00 00 14", "b", "0x101c"),
                exactValueRow(0x1014, "bf 02 00 71", "cmp", "w21, #0"),
                exactValueRow(0x1018, "1f 20 03 d5", "nop", ""),
                exactValueRow(0x101c, "24 0c 20 1e", "fcsel", "s4, s1, s0, eq"),
                exactValueRow(0x1020, "29 05 00 91", "add", "x9, x9, #1"),
                exactValueRow(0x1024, "c0 03 5f d6", "ret", "")]
            let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: ssa)
                .buildFunction(name: "exactValue_clobber_phi", startAddress: 0x1000, instructions: rows)
            XCTAssertTrue(function.instructions.contains { instruction in
                    guard instruction.source.address == 0x101c else { return false }
                    if case .unknown = instruction.operation { return true }; return false
                })
            XCTAssertFalse(function.phis.contains { if case let .register(name, _) = $0.destination { return name.hasPrefix("__mscope_nzcv_") }; return false })
        }
    }

    func testExactFreshLoadAfterCallDoesNotInheritMemoryEpochTaint() throws {
        let rows = [exactValueRow(0x1000, "00 04 00 94", "bl", "0x2000"),
            exactValueRow(0x1004, "e8 02 40 b9", "ldr", "w8, [x23]"),
            exactValueRow(0x1008, "1f 05 00 71", "cmp", "w8, #1"),
            exactValueRow(0x100c, "00 08 41 7a", "ccmp", "w0, #1, #0, eq"),
            exactValueRow(0x1010, "88 c3 9d b8", "ldursw", "x8, [x28, #-36]"),
            exactValueRow(0x1014, "19 15 9f 1a", "csinc", "w25, w8, wzr, ne"),
            exactValueRow(0x1018, "c0 03 5f d6", "ret", "")]
        let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: true)
            .buildFunction(name: "exactValue_fresh", startAddress: 0x1000, instructions: rows)
        let row = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1014 })
        guard case .select = row.operation else { return XCTFail("fresh memory value incorrectly tainted") }
    }

    func testExactPriorUnknownProducerCannotBecomeAvailableThroughPhi() throws {
        let rows = [exactValueRow(0x1000, "1f 00 00 71", "cmp", "w0, #0"),
            exactValueRow(0x1004, "80 00 00 54", "b.eq", "0x1014"),
            exactValueRow(0x1008, "84 78 7f 93", "sbfiz", "x4, x4, #1, #64"),
            exactValueRow(0x100c, "e8 03 04 aa", "mov", "x8, x4"),
            exactValueRow(0x1010, "02 00 00 14", "b", "0x1018"),
            exactValueRow(0x1014, "e8 03 14 aa", "mov", "x8, x20"),
            exactValueRow(0x1018, "1f 05 00 71", "cmp", "w8, #1"),
            exactValueRow(0x101c, "00 08 41 7a", "ccmp", "w0, #1, #0, eq"),
            exactValueRow(0x1020, "88 c3 9d b8", "ldursw", "x8, [x28, #-36]"),
            exactValueRow(0x1024, "19 15 9f 1a", "csinc", "w25, w8, wzr, ne"),
            exactValueRow(0x1028, "c0 03 5f d6", "ret", "")]
        let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: true)
            .buildFunction(name: "exactValue_unknown_phi", startAddress: 0x1000, instructions: rows)
        let row = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1024 })
        guard case .unknown = row.operation else { return XCTFail("prior unknown certified through a phi") }
        XCTAssertTrue(function.refusals.contains { $0.scope == .row(0x1008) })
        let info = try XCTUnwrap(function.ssaInfo), graph = try XCTUnwrap(function.cfg)
        let producer = try XCTUnwrap(info.sourceAddresses.firstIndex(of: 0x1008))
        var loose = info.plan
        let roots = Set(loose.rowWriteBindings[producer].values)
        for id in roots { loose.definitions[id].origin = .instruction(0x1008) }
        let sources = rows.map { MacIRSourceSpan(address: $0.address, byteText: $0.bytes, mnemonic: $0.mnemonic, operands: $0.operands) }
        XCTAssertFalse(MacIRBuilder.ssaNumericAncestryIsAvailable(roots: roots, plan: loose,
            sources: sources, graph: graph, actualUnknownSources: [0x1008]))
    }
}

extension DecompilerC2DataflowCensusTests {
    func testExactQStoreAfterCallRejectsClobberedSSAInput() throws {
        // Legacy's separate untyped fallback is not repaired or certified here;
        // a separate legacy call-clobber repair owns its V/Q tombstones. The newly admitted SSA path
        // must not turn either clobbered payload half into an entry V0.
        let rows = [exactValueRow(0x1000, "00 04 00 94", "bl", "0x2000"),
            exactValueRow(0x1004, "e0 6a a8 3c", "str", "q0, [x23, x8]"),
            exactValueRow(0x1008, "29 05 00 91", "add", "x9, x9, #1"),
            exactValueRow(0x100c, "c0 03 5f d6", "ret", "")]
        let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: true)
            .buildFunction(name: "exactValue_q_clobber", startAddress: 0x1000, instructions: rows)
        let row = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1004 })
        guard case .unknown = row.operation else { return XCTFail("call-clobbered Q store was admitted") }
        XCTAssertNil(row.neonIndexedMemory)
        XCTAssertTrue(function.refusals.contains { $0.scope == .row(0x1004) })
    }

    func testExactSBFIZJoinedCallClobberDoesNotAcquireOrigin() throws {
        let rows = [exactValueRow(0x1000, "1f 00 00 71", "cmp", "w0, #0"),
            exactValueRow(0x1004, "60 00 00 54", "b.eq", "0x1010"),
            exactValueRow(0x1008, "fe 03 00 94", "bl", "0x2000"),
            exactValueRow(0x100c, "02 00 00 14", "b", "0x1014"),
            exactValueRow(0x1010, "e4 03 14 aa", "mov", "x4, x20"),
            exactValueRow(0x1014, "84 7c 7f 93", "sbfiz", "x4, x4, #1, #32"),
            exactValueRow(0x1018, "c0 03 5f d6", "ret", "")]
        let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: true)
            .buildFunction(name: "exactValue_sbfiz_clobber", startAddress: 0x1000, instructions: rows)
        let row = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1014 })
        guard case .unknown = row.operation else { return XCTFail("clobbered phi acquired a signed-field origin") }
    }
}

extension DecompilerC2DataflowCensusTests {
    func testExactFutureUnknownBackedgeCannotCertifyCurrentSBFIZ() throws {
        let rows = [exactValueRow(0x1000, "e4 03 14 aa", "mov", "x4, x20"),
            exactValueRow(0x1004, "84 7c 7f 93", "sbfiz", "x4, x4, #1, #32"),
            // Initially a plan.instruction, but its later value emitter refuses.
            exactValueRow(0x1008, "84 78 7f 93", "sbfiz", "x4, x4, #1, #64"),
            exactValueRow(0x100c, "1f 00 00 71", "cmp", "w0, #0"),
            exactValueRow(0x1010, "a1 ff ff 54", "b.ne", "0x1004"),
            exactValueRow(0x1014, "c0 03 5f d6", "ret", "")]
        let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: true)
            .buildFunction(name: "exactValue_future_unknown", startAddress: 0x1000, instructions: rows)
        let instruction = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1004 })
        guard case .unknown = instruction.operation else { return XCTFail("future unknown backedge was certified") }
        XCTAssertTrue(function.refusals.contains { $0.scope == .row(0x1008) })
    }

    func testExactFCSELDestinationAliasStillSnapshotsBothInputs() throws {
        let source = exactValueSource("21 0c 20 1e", "fcsel", "s1, s1, s0, eq")
        let descriptor = try XCTUnwrap(MacIRBuilder.ssaSnapshotSelect(source))
        for ssa in [false, true] {
            let operation = try XCTUnwrap(descriptor.valueOperation(destination: .register(name: "s1", version: 2),
                predicate: .immediate(1), inputs: [.immediate(0x7f800001), .immediate(0x80000000)]))
            XCTAssertEqual(exactValueSelected(operation), 0x7f800001)
            let function = exactValueSelectFixture(source, ssa: ssa)
            XCTAssertEqual(function.ssaEnabled, ssa)
            let row = try XCTUnwrap(function.instructions.first { $0.source.address == 0x100c })
            if ssa {
                guard case let .select(destination, _, _, _, yes, no) = row.operation else { return XCTFail("alias select missing") }
                XCTAssertNotEqual(destination, yes)
                XCTAssertNotEqual(destination, no)
                XCTAssertEqual(Set(MacIRBuilder.ssaEffects(for: source).reads.cells), Set([32, 33, 96]))
            }
        }
    }

    func testExactCMPXWordCannotAcquireWTextSnapshot() {
        var state = BuilderState()
        state.ssa = .init(current: [20: .init(value: .register(name: "x20", version: 1), bitWidth: 64,
                                                view: .integer, origin: .instruction(0xff0)),
                                    8: .init(value: .register(name: "x8", version: 1), bitWidth: 64,
                                             view: .integer, origin: .instruction(0xff4))], writes: [:], clobbers: [:])
        XCTAssertNil(MacIRBuilder.ssaNZCVSnapshot(
            exactValueSource("9f 02 08 eb", "cmp", "w20, w8"), state: state, numericInputs: [], reachingFlags: nil))
    }
}

extension DecompilerC2DataflowCensusTests {
    func testExactFutureCallResultCannotSeedMOVBackedge() throws {
        let rows = [exactValueRow(0x1000, "e4 03 14 aa", "mov", "x4, x20"),
            exactValueRow(0x1004, "84 7c 7f 93", "sbfiz", "x4, x4, #1, #32"),
            exactValueRow(0x1008, "fe 03 00 94", "bl", "0x2000"),
            exactValueRow(0x100c, "e4 03 00 aa", "mov", "x4, x0"),
            exactValueRow(0x1010, "9f 02 00 71", "cmp", "w20, #0"),
            exactValueRow(0x1014, "81 ff ff 54", "b.ne", "0x1004"),
            exactValueRow(0x1018, "c0 03 5f d6", "ret", "")]
        let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: true)
            .buildFunction(name: "exactValue_future_call", startAddress: 0x1000, instructions: rows)
        let row = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1004 })
        guard case .unknown = row.operation else { return XCTFail("unemitted callResult seeded a future MOV") }
    }
}

extension DecompilerC2DataflowCensusTests {
    private func checkExactCCMPFold(_ fallback: Bool, printed: String,
                                    expected: [UInt64]) throws {
        let guardValue = MacIRValue.register(name: "nzcv_guard", version: 0)
        let term = MacIRValue.register(name: "nzcv_term", version: 0)
        let value = MacIRBuilder.ssaNZCVCCMPCondition(guardValue: guardValue,
            term: term, fallbackHolds: fallback)
        let function = MacIRFunction(name: "ccmp_boolean", startAddress: 0x1000,
            returnType: "void", instructions: [])
        let printer = PseudocodePrinter()
        XCTAssertEqual(printer.valueText(for: value, names: PseudocodeNameContext(function: function)), printed)
        XCTAssertFalse(printed.contains("&& 0x0"))
        XCTAssertFalse(printed.contains("&& 0x1"))
        for ssa in [false, true] {
            for (index, inputs) in [(0, (0, 0)), (1, (0, 1)), (2, (1, 0)), (3, (1, 1))] {
                XCTAssertEqual(exactValueBits(value, values: [guardValue: UInt64(inputs.0),
                    term: UInt64(inputs.1)]), expected[index], "mode=\(ssa)")
            }
        }
    }

    func testExactCCMPFallbackZeroPrintsReducedBooleanAndLiteralTruthTable() throws {
        try checkExactCCMPFold(false, printed: "nzcv_guard_0 && nzcv_term_0", expected: [0, 0, 0, 1])
    }

    func testExactCCMPFallbackOnePrintsReducedBooleanAndLiteralTruthTable() throws {
        try checkExactCCMPFold(true, printed: "!(nzcv_guard_0) || nzcv_term_0", expected: [1, 1, 0, 1])
    }

    func testExactRealCropFlagsAndFreshPayloadHaveIndependentLiteralValuesBothModes() throws {
        // Authored encodings of OTOOL's real CMP/CCMP/LDURSW/CSINC, not image-byte receipts.
        let cases: [(Int64, Int64, UInt64)] = [(1, 1, 1), (1, 4, 7), (2, 1, 7)]
        for ssa in [false, true] {
            for (oldW9, oldW8, expected) in cases {
                var state = BuilderState()
                state.ssa = .init(current: [9: .init(value: .immediate(oldW9), bitWidth: 32,
                    view: .integer, origin: .entry), 8: .init(value: .immediate(oldW8),
                    bitWidth: 32, view: .integer, origin: .entry)], writes: [:], clobbers: [:])
                let cmp = try XCTUnwrap(MacIRBuilder.ssaNZCVSnapshot(
                    exactValueSource("3f 05 00 71", "cmp", "w9, #1"), state: state,
                    numericInputs: [], reachingFlags: nil))
                let ccmp = try XCTUnwrap(MacIRBuilder.ssaNZCVSnapshot(
                    exactValueSource("00 09 41 7a", "ccmp", "w8, #1, #0, eq"), state: state,
                    numericInputs: [], reachingFlags: 0))
                let guardValue = try XCTUnwrap(MacIRBuilder.ssaNZCVSubtractionCondition(cmp, suffix: "eq"))
                let term = try XCTUnwrap(MacIRBuilder.ssaNZCVSubtractionCondition(ccmp, suffix: "ne"))
                let predicate = MacIRBuilder.ssaNZCVCCMPCondition(guardValue: guardValue, term: term, fallbackHolds: true)
                // LDURSW X8,[X24,#-0x24] is flag-neutral but creates the NEW low32 payload7.
                let load = exactValueSource("08 c3 9d b8", "ldursw", "x8, [x24, #-0x24]")
                XCTAssertEqual(Set(MacIRBuilder.ssaEffects(for: load).writes.map(\.cell)), Set([8]))
                let select = try XCTUnwrap(MacIRBuilder.ssaSnapshotSelect(
                    exactValueSource("19 15 9f 1a", "csinc", "w25, w8, wzr, ne")))
                let operation = try XCTUnwrap(select.valueOperation(destination: .register(name: "w25", version: 1),
                    predicate: predicate, inputs: [.immediate(7)]))
                XCTAssertEqual(exactValueSelected(operation), expected, "mode=\(ssa)")
            }
        }
    }

    func testExactRealCropBackedgeSliceRemainsRefusedBothModes() throws {
        // A source-faithful projection of the two real loop windows. Unrelated
        // arithmetic/calls are omitted; no whole-function replay or admission claim.
        let offsets: [UInt64] = [0, 0xc60]
        for offset in offsets {
            let rows = [
                exactValueRow(0x21c98 + offset, "68 3a 40 b9", "ldr", "w8, [x19, #0x38]"),
                exactValueRow(0x21cac + offset, "69 9a 40 f9", "ldr", "x9, [x19, #0x130]"),
                exactValueRow(0x21cb0 + offset, "38 b1 00 91", "add", "x24, x9, #0x2c"),
                exactValueRow(0x21cb4 + offset, "69 ba 41 b9", "ldr", "w9, [x19, #0x1b8]"),
                exactValueRow(0x21cb8 + offset, "3f 05 00 71", "cmp", "w9, #1"),
                exactValueRow(0x21cbc + offset, "00 09 41 7a", "ccmp", "w8, #1, #0, eq"),
                exactValueRow(0x21cc0 + offset, "08 c3 9d b8", "ldursw", "x8, [x24, #-0x24]"),
                exactValueRow(0x21cc4 + offset, "19 15 9f 1a", "csinc", "w25, w8, wzr, ne"),
                exactValueRow(0x21cec + offset, "00 07 06 b8", "str", "w0, [x24], #0x60"),
                exactValueRow(0x21d3c + offset, "f7 06 00 91", "add", "x23, x23, #1"),
                exactValueRow(0x21d40 + offset, "68 3a 80 b9", "ldrsw", "x8, [x19, #0x38]"),
                exactValueRow(0x21d44 + offset, "ff 02 08 eb", "cmp", "x23, x8"),
                exactValueRow(0x21d48 + offset, "6b fb ff 54", "b.lt", "0x\(String(0x21cb4 + offset, radix: 16))"),
                exactValueRow(0x21d7c + offset, "c0 03 5f d6", "ret", "")]
            for ssa in [false, true] {
                let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: ssa)
                    .buildFunction(name: "crop_backedge_projection", startAddress: 0x21c98 + offset, instructions: rows)
                XCTAssertEqual(function.ssaEnabled, ssa)
                let row = try XCTUnwrap(function.instructions.first { $0.source.address == 0x21cc4 + offset })
                guard case .unknown = row.operation else { return XCTFail("unproved future backedge acquired authority") }
            }
            for row in [rows[8], rows[10]] {
                let source = MacIRSourceSpan(address: row.address, byteText: row.bytes,
                    mnemonic: row.mnemonic, operands: row.operands)
                XCTAssertFalse(MacIRBuilder.ssaGuaranteedFutureNumericProducer(source))
            }
        }
    }

    func testExactNZCVPredicateDisplayNamesAvoidFormalLocalAndRecoveredCollisions() throws {
        let key = MacIRBuilder.SSANZCVPredicateKey(definition: 98, condition: "ne")
        let value = MacIRValue.register(name: "__mscope_nzcv_d98_ne", version: 0)
        let phi = MacIRPhi(blockAddress: 0x1004, destination: value, bitWidth: 32,
            incoming: [.init(predecessorAddress: 0x1000, value: .immediate(1))])
        var function = MacIRFunction(name: "predicate_names", startAddress: 0x1000, returnType: "void",
            parameters: [.init(index: 0, register: "x0", type: "int64_t", name: "nzcv_predicate_d98_ne")],
            localVariables: [.init(offset: -8, name: "nzcv.predicate.d98.ne_1", type: "int64_t", byteWidth: 8)],
            nameBindings: [.init(target: .register(name: "x20", version: 1), name: "nzcv_predicate_d98_ne_2",
                type: "int64_t", kind: .registerTemporary)], instructions: [
                    instruction(0x1000, "b", "0x1004", .intrinsic(destination: nil, name: "branch", arguments: [.immediate(0x1004)])),
                    instruction(0x1004, "str", "w25, [x2]", .store(source: value, address: reg(2, 0))),
                    instruction(0x1008, "ret", "", .returnValue(nil))], phis: [phi])
        // The branch makes 0x1004 a real leader with predecessor exit 0x1000.
        // SSA presentation admits this 32-bit phi and its literal incoming value 1.
        function.ssaEnabled = true
        let bindings = MacIRBuilder.ssaNZCVPredicateNameBindings(function: function, predicates: [(key, phi)])
        XCTAssertEqual(bindings.map(\.name), ["nzcv_predicate_d98_ne_3"])
        function.nameBindings.append(contentsOf: bindings)
        let printer = PseudocodePrinter(), names = PseudocodeNameContext(function: function)
        XCTAssertEqual(printer.valueText(for: value, names: names), "nzcv_predicate_d98_ne_3")
        XCTAssertEqual(function.parameters[0].name, "nzcv_predicate_d98_ne")
        XCTAssertEqual(function.localVariables[0].name, "nzcv.predicate.d98.ne_1")
        XCTAssertEqual(function.nameBindings[0].name, "nzcv_predicate_d98_ne_2")
        let document = printer.print(function: function)
        XCTAssertFalse(document.lines.contains { $0.text.contains("__unavailable_cfg_phi") })
        XCTAssertTrue(document.lines.contains { $0.kind == .declaration && $0.text.contains("nzcv_predicate_d98_ne_3;") })
        XCTAssertTrue(document.lines.contains {
            $0.kind == .instruction && $0.sourceAddress == 0x1004 && $0.text.contains("nzcv_predicate_d98_ne_3")
        })
    }

    func testExactNZCVInternalRawStemAvoidsExistingVersionAgnosticOverride() {
        let key = MacIRBuilder.SSANZCVPredicateKey(definition: 98, condition: "ne")
        let occupied = MacIRValue.register(name: "__mscope_nzcv_d98_ne", version: 7)
        let value = MacIRBuilder.ssaNZCVPredicateValue(key: key, occupiedValues: [occupied])
        XCTAssertEqual(value, .register(name: "__mscope_nzcv_d98_ne_1", version: 0))
        let other = MacIRBuilder.ssaNZCVPredicateValue(key: .init(definition: 99, condition: "ne"),
            occupiedValues: [occupied, value])
        XCTAssertNotEqual(value, other)
        let function = MacIRFunction(name: "raw_names", startAddress: 0x1000, returnType: "void", instructions: [])
        let names = PseudocodeNameContext(function: function,
            registerNameOverrides: ["__mscope_nzcv_d98_ne": "old_storage"])
        XCTAssertEqual(PseudocodePrinter().valueText(for: occupied, names: names), "old_storage")
        XCTAssertEqual(PseudocodePrinter().valueText(for: value, names: names), "__mscope_nzcv_d98_ne_1_0")
    }

    func testExactNZCVNameInventoryIncludesCompositeAndUnknownPrintableAtoms() {
        let key = MacIRBuilder.SSANZCVPredicateKey(definition: 9, condition: "ne")
        let value = MacIRValue.register(name: "__mscope_nzcv_d9_ne", version: 0)
        let phi = MacIRPhi(blockAddress: 0x1004, destination: value, bitWidth: 32,
            incoming: [.init(predecessorAddress: 0x1000, value: .immediate(0))])
        let composite = MacIRValue.abiComposite(type: "Pair", fragments: [
            .unknown("nzcv_predicate_d9_ne"), .symbol("nzcv_predicate_d9_ne_1")])
        let function = MacIRFunction(name: "composite_names", startAddress: 0x1000,
            returnType: "void", instructions: [instruction(0x1000, "opaque", "",
                .intrinsic(destination: nil, name: "inventory", arguments: [composite]))], phis: [phi])
        let bindings = MacIRBuilder.ssaNZCVPredicateNameBindings(function: function, predicates: [(key, phi)])
        XCTAssertEqual(bindings.map(\.name), ["nzcv_predicate_d9_ne_2"])
    }

    func testExactNZCVPrinterOnlyPhysicalOverrideCannotCollideWithTypedPredicate() throws {
        var function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: true)
            .buildFunction(name: "printer_override_names", startAddress: 0x1000, instructions: exactValueNestedRows())
        let info = try XCTUnwrap(function.ssaInfo)
        XCTAssertEqual(info.generatedNZCVPredicateTargets.count, 1)
        let target = try XCTUnwrap(info.generatedNZCVPredicateTargets.first)
        guard case let .register(rawName, version) = target else { return XCTFail("predicate target not a register") }
        let binding = try XCTUnwrap(function.nameBindings.first { $0.target == .register(name: rawName, version: version) })
        // This ordinary authored binding only LOOKS synthetic. The typed target
        // sidecar, not a prefix guess, must keep it in the occupied inventory.
        let generic = MacIRValue.register(name: "__mscope_nzcv_d999_ne", version: 0)
        function.nameBindings.append(.init(target: .register(name: "__mscope_nzcv_d999_ne", version: 0),
            name: binding.name + "_1", type: "int64_t", kind: .registerTemporary))
        let overrides = ["x20": binding.name]
        let printer = PseudocodePrinter(), names = PseudocodeNameContext(function: function, registerNameOverrides: overrides)
        XCTAssertEqual(printer.valueText(for: reg(20, 0), names: names), binding.name)
        XCTAssertEqual(printer.valueText(for: generic, names: names), binding.name + "_1")
        XCTAssertEqual(printer.valueText(for: target, names: names), binding.name + "_2")
        XCTAssertTrue(printer.print(function: function, registerNameOverrides: overrides).lines.contains {
            $0.text.contains(binding.name + "_2")
        })
        let intentional = PseudocodeNameContext(function: function, registerNameOverrides: [rawName: "chosen_predicate"])
        XCTAssertEqual(printer.valueText(for: target, names: intentional), "chosen_predicate")
    }

    func testExactNZCVPredicateCannotShadowRenamedCallee() throws {
        var rows = exactValueNestedRows()
        rows[rows.count - 1] = exactValueRow(0x1024, "f7 03 00 94", "bl", "0x2000")
        rows.append(exactValueRow(0x1028, "c0 03 5f d6", "ret", ""))
        let function = MacIRBuilder(explicitCFGEnabled: true, ssaEnabled: true)
            .buildFunction(name: "callee_alias_names", startAddress: 0x1000, instructions: rows)
        let info = try XCTUnwrap(function.ssaInfo)
        let target = try XCTUnwrap(info.generatedNZCVPredicateTargets.first)
        guard case let .register(rawName, version) = target else { return XCTFail("predicate target not a register") }
        let binding = try XCTUnwrap(function.nameBindings.first { $0.target == .register(name: rawName, version: version) })
        let aliases = ["0x2000": binding.name]
        let printer = PseudocodePrinter(), names = PseudocodeNameContext(function: function, callTargetRenames: aliases)
        XCTAssertEqual(names.callTargetRenames["0x2000"], binding.name)
        XCTAssertEqual(printer.valueText(for: target, names: names), binding.name + "_1")
        let document = printer.print(function: function, nameOverrides: aliases)
        XCTAssertTrue(document.lines.contains { $0.sourceAddress == 0x1024 && $0.text.contains(binding.name + "(") })
        XCTAssertTrue(document.lines.contains { $0.text.contains(binding.name + "_1") })
    }
}
