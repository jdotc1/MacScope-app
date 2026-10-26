import Foundation
import XCTest
#if canImport(MacScope)
@testable import MacScope
#if canImport(MacScopeAnalysisCore)
@testable import MacScopeAnalysisCore
#endif
#elseif canImport(RenderAll)
@testable import RenderAll
#endif

/// Complete captured machine bytes and envelopes anchor the positive controls;
/// no hand-written output stands in for the original full-context fixture.
final class OrdinaryCTypedUpsamplerBridgeTests: XCTestCase {
    func testNativeBoundaryRejectsWrongArgumentsAndUnaccountedSignatures() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let full = try OrdinaryCRecordedCallFixture.upsampler(.jinit)
            let cfg = CFGBuilder.buildCFG(instructions: full.function.instructions)
            XCTAssertNil(RegionalBoundaryPlan.prove(function: full.function, cfg: cfg))
            XCTAssertNotNil(RegionalBoundaryPlan.prove(function: full.function, cfg: cfg,
                admitNativeFixedIntegerCalls: true))
            let row = 187
            let (frame, result) = try call(full.function, row: row)
            let arguments = frame.arguments.canonicalPhysicalEntriesForAudit
            func refused(_ function: MacIRFunction) {
                XCTAssertNil(RegionalBoundaryPlan.prove(function: function,
                    cfg: CFGBuilder.buildCFG(instructions: function.instructions),
                    admitNativeFixedIntegerCalls: true))
            }
            var wrong = full.function
            var foreign = arguments
            foreign[1] = .init(location: arguments[1].location, role: arguments[1].role,
                value: .register(name: "x2", version: 1))
            wrong.instructions[row].operation = .call(frame: try replacing(frame, arguments: foreign), result: result)
            refused(wrong)
            wrong = full.function
            let extra = arguments + [.init(location: .gpr(index: 2, carrierWidth: 64),
                role: .fixed(sourcePosition: 2), value: .register(name: "x2", version: 1))]
            var threeParameters = try XCTUnwrap(frame.knownSignature)
            threeParameters.parameters.append(.init(index: 2, register: "x2", type: "int64_t", name: "c"))
            wrong.callSignatures = [threeParameters]
            wrong.instructions[row].operation = .call(frame: try replacing(frame, arguments: extra,
                signature: threeParameters), result: result)
            refused(wrong)
            wrong = full.function
            var extraSignature = try XCTUnwrap(frame.knownSignature)
            extraSignature.target = "_unaccounted"
            wrong.callSignatures.append(extraSignature)
            refused(wrong)
            wrong = full.function
            wrong.instructions[row].operation = .call(frame: frame, result: .register(name: "x1", version: 91))
            refused(wrong)
        }
    }

    func testNativePhysicalProofRejectsForgedWCastAndInterveningDefinitions() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            let full = try OrdinaryCRecordedCallFixture.upsampler(.jinit)
            let row = 187
            XCTAssertNotNil(RegionalPhysicalStatePlan.prove(function: full.function,
                cfg: CFGBuilder.buildCFG(instructions: full.function.instructions),
                attemptLexical: false))
            let (frame, result) = try call(full.function, row: row)
            func refused(_ function: MacIRFunction) {
                // No stale lexical certificate is borrowed for changed records.
                // Canonical-byte, producer and local-current-cell gates all remain active.
                XCTAssertNil(RegionalPhysicalStatePlan.prove(function: function,
                    cfg: CFGBuilder.buildCFG(instructions: function.instructions), attemptLexical: false))
            }
            var wrong = full.function
            guard case let .load(_, address) = wrong.instructions[row - 2].operation else {
                return XCTFail("retained W0 producer must be a load")
            }
            wrong.instructions[row - 2].source = try machineSource([0x60, 0x46, 0x40, 0xf9],
                at: wrong.instructions[row - 2].source.address) // LDR X0,[X19,#0x88]
            wrong.instructions[row - 2].operation = .load(destination: .register(name: "x0", version: 991), address: address)
            wrong.instructions[row - 2].memoryAccess = .init(byteWidth: 8)
            // The call still contains the old W0 cast: spelling cannot establish a W write.
            XCTAssertNotNil(RegionalBoundaryPlan.prove(function: wrong,
                cfg: CFGBuilder.buildCFG(instructions: wrong.instructions), admitNativeFixedIntegerCalls: true))
            refused(wrong)
            wrong = full.function
            wrong.instructions[row - 1].source = try machineSource([0x00, 0x00, 0x80, 0xd2],
                at: wrong.instructions[row - 1].source.address) // MOV X0,#0
            wrong.instructions[row - 1].operation = .assign(destination: .register(name: "x0", version: 992), source: .immediate(0))
            wrong.instructions[row - 1].memoryAccess = nil
            refused(wrong)
            wrong = full.function
            let (intervening, _) = try call(full.function, row: 35)
            wrong.instructions[row - 1].source = try machineSource([0x00, 0x01, 0x3f, 0xd6],
                at: wrong.instructions[row - 1].source.address) // BLR X8
            wrong.instructions[row - 1].operation = .call(frame: intervening, result: .register(name: "x0", version: 993))
            wrong.instructions[row - 1].memoryAccess = nil
            refused(wrong)
            wrong = full.function
            var arguments = frame.arguments.canonicalPhysicalEntriesForAudit
            arguments[0] = .init(location: arguments[0].location, role: arguments[0].role,
                value: .unary(op: "(uint64_t)", value: .unary(op: "(uint32_t)",
                    value: .register(name: "x0", version: 991))))
            wrong.instructions[row].operation = .call(frame: try replacing(frame, arguments: arguments), result: result)
            refused(wrong)
            wrong = full.function
            guard case let .load(destination, _) = wrong.instructions[row - 2].operation else {
                return XCTFail("Expected the retained load definition")
            }
            // Matching destination and machine bytes do not authorize a changed
            // semantic address: complete producer replay must still agree.
            wrong.instructions[row - 2].operation = .load(destination: destination, address: .immediate(0))
            XCTAssertNotNil(RegionalBoundaryPlan.prove(function: wrong,
                cfg: CFGBuilder.buildCFG(instructions: wrong.instructions), admitNativeFixedIntegerCalls: true))
            refused(wrong)
        }
    }

    func testExactTypedOpaqueBridgeAndFullOwnershipInBothModes() throws {
        for ssa in [false, true] {
            try MacIRConfiguration.$ssaOverride.withValue(ssa) {
                for seed in [RegionalCallSeed.jinit, .j12init] {
                    let fixtures = try OrdinaryCUpsamplerFixturePair.make(seed)
                    XCTAssertEqual(fixtures.full.function.ssaEnabled, ssa)
                    try fixtures.requireFullTypedRowOwnership()
                    XCTAssertTrue(fixtures.fullAudit.errors.isEmpty)
                    XCTAssertFalse(fixtures.fullAudit.loops.isEmpty)
                    XCTAssertEqual(fixtures.fullAudit.rawEquivalentTotal, 0)
                    let expectedGotos = ssa ? (seed == .jinit ? 17 : 15) : (seed == .jinit ? 12 : 10)
                    XCTAssertEqual(fixtures.fullAudit.gotoEquivalentTotal, expectedGotos)
                    XCTAssertEqual(fixtures.fullAudit.loops.count, 1)
                    XCTAssertEqual(fixtures.full.document.lines.count, fixtures.opaque.document.lines.count)
                    // The semantic contract remains explicitly opaque, including
                    // the unchanged knownSignature == nil source-frame gate.
                    for row in fixtures.opaque.callRows {
                        let (frame, _) = try call(fixtures.opaque.function, row: row)
                        XCTAssertNil(frame.knownSignature)
                    }
                }
            }
        }
    }

    func testBridgeRejectsCallNoncallProvenanceAndLoopMutationsInBothModes() throws {
        for ssa in [false, true] {
            try MacIRConfiguration.$ssaOverride.withValue(ssa) {
                for seed in [RegionalCallSeed.jinit, .j12init] {
                    let fixtures = try OrdinaryCUpsamplerFixturePair.make(seed)
                    let full = fixtures.full, opaque = fixtures.opaque
                    let row = fixtures.roundRow
                    let line = try XCTUnwrap(full.document.lines.firstIndex {
                        $0.sourceAddress == full.rows[row].address && $0.text.contains("_jround_up(")
                    })
                    func reject(_ document: PseudocodeDocument, function: MacIRFunction? = nil) {
                        let changed = copy(full, function: function ?? full.function, document: document)
                        XCTAssertThrowsError(try OrdinaryCUpsamplerFixturePair.validateBridge(full: changed, opaque: opaque, seed: seed))
                    }
                    var changed = full.document
                    changed.lines[line].text = changed.lines[line].text.replacingOccurrences(of: "(uint32_t)", with: "(int32_t)")
                    reject(changed)
                    changed = full.document
                    changed.lines[line].text = changed.lines[line].text.replacingOccurrences(of: "_jround_up(", with: "_other(")
                    reject(changed)
                    changed = full.document
                    changed.lines[line].text = "x1_999 = " + changed.lines[line].text
                    reject(changed)
                    changed = full.document
                    changed.lines[line].text = changed.lines[line].text.replacingOccurrences(of: ", x1", with: ", x2")
                    XCTAssertNotEqual(changed.lines[line].text, full.document.lines[line].text)
                    reject(changed)
                    let other = try XCTUnwrap(full.document.lines.indices.first { $0 != line && full.document.lines[$0].sourceAddress != nil })
                    changed = full.document
                    changed.lines[other].text += " /* changed */"
                    reject(changed)
                    changed = full.document
                    changed.lines[other].source = nil
                    reject(changed)
                    XCTAssertNotNil(full.document.regionTree)
                    changed = full.document
                    changed.regionTree = nil
                    reject(changed)
                    var function = full.function
                    var extraSignature = try XCTUnwrap(function.callSignatures.first)
                    extraSignature.target = "_unaccounted"
                    function.callSignatures.append(extraSignature)
                    reject(full.document, function: function)
                    function = full.function
                    function.instructions[0].operation = .returnValue(nil)
                    reject(full.document, function: function)
                    // Identical dual changes must not manufacture captured authority.
                    let forgedFull = copy(full, function: full.function, document: full.document, baseline: "not the retained baseline")
                    let forgedOpaque = copy(opaque, function: opaque.function, document: opaque.document, baseline: "not the retained baseline")
                    XCTAssertThrowsError(try OrdinaryCUpsamplerFixturePair.validateBridge(full: forgedFull, opaque: forgedOpaque, seed: seed))
                }
            }
        }
    }

    private func machineSource(_ bytes: [UInt8], at address: UInt64) throws -> MacIRSourceSpan {
        let decoded = ARM64Decoder().decode(Data(bytes), baseAddress: address)
        XCTAssertEqual(decoded.count, 1)
        let instruction = try XCTUnwrap(decoded.first)
        let operands = try XCTUnwrap(instruction.structuredOperands)
        return .init(address: instruction.address, byteText: instruction.byteText,
            mnemonic: instruction.mnemonic, operands: instruction.operands,
            comment: instruction.comment, structuredOperands: operands)
    }

    private func call(_ function: MacIRFunction, row: Int) throws -> (MacIRCallFrame, MacIRValue?) {
        guard case let .call(frame, result) = function.instructions[row].operation else {
            throw OrdinaryC.Failure.invalidContract("missing retained round call")
        }
        return (frame, result)
    }
    private func replacing(_ frame: MacIRCallFrame, arguments: [MacIRCallArgument],
                           signature: MacIRCallSignature? = nil) throws -> MacIRCallFrame {
        let values = try XCTUnwrap(MacIRCallArguments(arguments,
            observationScope: frame.arguments.observationScope))
        return try XCTUnwrap(MacIRCallFrame(target: frame.target, knownSignature: signature ?? frame.knownSignature,
            tailCountEvidence: frame.tailCountEvidence, controlInputs: frame.controlInputs, arguments: values,
            richArguments: frame.richArguments, indirectResultPointer: frame.indirectResultPointer,
            typedIndirectSignature: frame.typedIndirectSignature, typedIndirectCalleeType: frame.typedIndirectCalleeType,
            unknownArgumentCount: frame.unknownArgumentCount))
    }
    private func copy(_ fixture: OrdinaryCRecordedCallFixture, function: MacIRFunction,
                      document: PseudocodeDocument, baseline: String? = nil) -> OrdinaryCRecordedCallFixture {
        .init(start: fixture.start, baselineText: baseline ?? fixture.baselineText,
            callRows: fixture.callRows, rows: fixture.rows, input: fixture.input, function: function, document: document)
    }
}
