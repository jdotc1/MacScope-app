import Foundation
import XCTest
@testable import MacScope

final class CallResultPlanningTests: XCTestCase {
    private func rows(_ entries: [(String, String, String)], start: UInt64 = 0x1000) -> [InstructionRow] {
        entries.enumerated().map { offset, entry in
            InstructionRow(address: start + UInt64(offset * 4), bytes: entry.0,
                mnemonic: entry.1, operands: entry.2, hasBreakpoint: false, comment: nil)
        }
    }

    private func slot(_ returnType: String = "void", arguments: Int = 1) -> FunctionPointerSignatureV1 {
        FunctionPointerSignatureV1(returnType: returnType,
            parameters: (0..<arguments).map { .init(name: "arg\($0)", type: "uint64_t") })
    }

    private func build(_ source: [InstructionRow], slots: [UInt64: FunctionPointerSignatureV1] = [:],
                       authored: [String: FunctionSignatureOverride] = [:], types: [TypeDefinition] = []) -> MacIRFunction {
        PseudocodePrinter().buildFunction(functionName: "result_caller", startAddress: 0x1000,
            signatureOverrides: [0x1000: FunctionSignatureOverride(returnType: "uint64_t", args: [])],
            authoredCallSignaturesByTarget: authored, slotCallContracts: slots, types: types,
            explicitCFGEnabled: true, ssaEnabled: true, instructions: source)
    }

    private func call(_ function: MacIRFunction, at address: UInt64) throws -> (MacIRCallFrame, MacIRValue?) {
        XCTAssertTrue(function.ssaEnabled)
        let instruction = try XCTUnwrap(function.instructions.first { $0.source.address == address })
        guard case let .call(frame, result) = instruction.operation else {
            XCTFail("Expected a retained call")
            throw NSError(domain: "CallResultPlanningTests", code: 1)
        }
        return (frame, result)
    }

    private func definition(_ function: MacIRFunction, at address: UInt64, cell: Int = 0) throws
        -> (MacIRSSAInfo, Int) {
        let info = try XCTUnwrap(function.ssaInfo)
        let row = try XCTUnwrap(info.sourceAddresses.firstIndex(of: address))
        let id = try XCTUnwrap(info.plan.rowWriteBindings[row][cell])
        return (info, info.plan.canonicalID(id))
    }

    func testRejectedVoidSlotCaptureKeepsPlannedUnknownResultThroughRET() throws {
        let source = rows([("1f 20 03 d5", "nop", ""), ("00 01 3f d6", "blr", "x8"),
                           ("c0 03 5f d6", "ret", "")])
        for contracts in [[UInt64: FunctionPointerSignatureV1](), [0x1004: slot()]] {
            let function = build(source, slots: contracts)
            let (frame, possible) = try call(function, at: 0x1004)
            let result = try XCTUnwrap(possible)
            XCTAssertNil(frame.typedIndirectSignature)
            let (info, id) = try definition(function, at: 0x1004)
            guard case .callResult = info.plan.definitions[id].origin else {
                return XCTFail("Unknown return must have a planned call-result definition")
            }
            XCTAssertEqual(info.plan.definitions[id].bitWidth, 64)
            XCTAssertEqual(info.values[id], result)
            XCTAssertEqual(info.plan.rowReadBindings[2][0], id)
            XCTAssertEqual(function.returnValue, result)
        }
    }

    func testTypedVoidLeavesOnlyClobberAndDoesNotConsumeOrdinaryNames() throws {
        let function = build(rows([("e0 00 80 d2", "mov", "x0, #7"),
            ("00 01 3f d6", "blr", "x8"), ("60 00 80 d2", "mov", "x0, #3"),
            ("c0 03 5f d6", "ret", "")]), slots: [0x1004: slot()])
        let (frame, result) = try call(function, at: 0x1004)
        XCTAssertEqual(frame.typedIndirectSignature?.returnType, "void")
        XCTAssertNil(result)
        let (info, id) = try definition(function, at: 0x1004)
        XCTAssertEqual(info.plan.definitions[id].origin, .callClobber(0x1004))
        XCTAssertEqual(info.values[id], .unknown("unavailable_x0"))
        let later = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1008 })
        guard case let .assign(destination, _) = later.operation else { return XCTFail("Expected MOV") }
        XCTAssertEqual(destination, .register(name: "x0", version: 2))
    }

    func testRejectedCaptureCannotBorrowFollowingOrdinaryDefinitionName() throws {
        let function = build(rows([("e0 00 80 d2", "mov", "x0, #7"),
            ("00 01 3f d6", "blr", "x8"), ("20 01 80 d2", "mov", "x0, #9"),
            ("c0 03 5f d6", "ret", "")]), slots: [0x1004: slot(arguments: 2)])
        let (frame, possible) = try call(function, at: 0x1004)
        let result = try XCTUnwrap(possible)
        XCTAssertNil(frame.typedIndirectSignature)
        let later = try XCTUnwrap(function.instructions.first { $0.source.address == 0x1008 })
        guard case let .assign(destination, _) = later.operation else { return XCTFail("Expected MOV") }
        XCTAssertNotEqual(result, destination)
        XCTAssertEqual(destination, .register(name: "x0", version: 2))
        let (info, id) = try definition(function, at: 0x1004)
        XCTAssertEqual(info.values[id], result)
    }

    func testVoidJoinKeepsUnknownIncomingAndNoNumericCallSeed() throws {
        let source = rows([("82 00 00 34", "cbz", "w2, 0x1010"),
            ("e0 00 80 d2", "mov", "x0, #7"), ("00 01 3f d6", "blr", "x8"),
            ("02 00 00 14", "b", "0x1014"), ("20 01 80 d2", "mov", "x0, #9"),
            ("c0 03 5f d6", "ret", "")])
        let function = build(source, slots: [0x1008: slot()])
        let (_, result) = try call(function, at: 0x1008)
        XCTAssertNil(result)
        let (info, id) = try definition(function, at: 0x1008)
        XCTAssertEqual(info.plan.definitions[id].origin, .callClobber(0x1008))
        let phi = try XCTUnwrap(info.plan.phis.first { $0.cell == 0 && $0.incoming.contains { $0.definition == id } })
        let published = try XCTUnwrap(function.phis.first { $0.cell == 0 && $0.destination == info.values[phi.destination] })
        XCTAssertTrue(published.incoming.contains { $0.value == .unknown("unavailable_x0") })
        let graph = try XCTUnwrap(function.cfg)
        XCTAssertFalse(MacIRBuilder.ssaNumericAncestryIsAvailable(roots: [phi.destination], plan: info.plan,
            sources: source.map { MacIRSourceSpan(address: $0.address, byteText: $0.bytes,
                mnemonic: $0.mnemonic, operands: $0.operands) }, graph: graph, actualUnknownSources: [], actualKnownSources: [0x1008],
            actualCallResultDefinitions: []))
    }

    func testLoopCandidateDoesNotInventFutureCallArgumentOrNumericEvidence() throws {
        let function = build(rows([("1f 20 03 d5", "nop", ""), ("00 01 3f d6", "blr", "x8"),
            ("e2 ff ff 35", "cbnz", "w2, 0x1004"), ("c0 03 5f d6", "ret", "")]),
            slots: [0x1004: slot()])
        let (frame, possible) = try call(function, at: 0x1004)
        let result = try XCTUnwrap(possible)
        XCTAssertNil(frame.typedIndirectSignature)
        let (info, id) = try definition(function, at: 0x1004)
        XCTAssertEqual(info.values[id], result)
        let phi = try XCTUnwrap(info.plan.phis.first { $0.cell == 0 && $0.incoming.contains { $0.definition == id } })
        let graph = try XCTUnwrap(function.cfg)
        let source = rows([("1f 20 03 d5", "nop", ""), ("00 01 3f d6", "blr", "x8"),
                           ("e2 ff ff 35", "cbnz", "w2, 0x1004"), ("c0 03 5f d6", "ret", "")])
            .map { MacIRSourceSpan(address: $0.address, byteText: $0.bytes, mnemonic: $0.mnemonic, operands: $0.operands) }
        XCTAssertFalse(MacIRBuilder.ssaNumericAncestryIsAvailable(roots: [phi.destination], plan: info.plan,
            sources: source, graph: graph, actualUnknownSources: [], actualKnownSources: [],
            actualCallResultDefinitions: []))
    }

    func testRejectedAuthoredVoidUsesUnknownOrCatalogResultBank() throws {
        let rejected = FunctionSignatureOverride(returnType: "void")
        for (target, expectedCell, expectedView) in [("no_declared_target", 0, MacIRSSA.ScalarView.integer),
                                                    ("_drand48", 32, MacIRSSA.ScalarView.float64)] {
            let function = build(rows([("00 04 00 94", "bl", target), ("c0 03 5f d6", "ret", "")]),
                authored: [target: rejected])
            let (frame, possible) = try call(function, at: 0x1000)
            let result = try XCTUnwrap(possible)
            if target == "_drand48" { XCTAssertEqual(frame.knownSignature?.returnType, "double") }
            else { XCTAssertNil(frame.knownSignature) }
            let (info, id) = try definition(function, at: 0x1000, cell: expectedCell)
            guard case .callResult = info.plan.definitions[id].origin else { return XCTFail("Missing planned result") }
            XCTAssertEqual(info.plan.definitions[id].view, expectedView)
            XCTAssertEqual(info.values[id], result)
        }
    }

    func testRejectedNineScalarAuthoredShapeUsesCatalogFPResult() throws {
        let rejected = FunctionSignatureOverride(returnType: "uint64_t", args: (0..<9).map {
            ArgOverride(index: $0, name: "arg\($0)", type: "uint64_t")
        })
        let function = build(rows([("00 04 00 94", "bl", "_drand48"), ("c0 03 5f d6", "ret", "")]),
            authored: ["_drand48": rejected])
        let (frame, possible) = try call(function, at: 0x1000)
        let result = try XCTUnwrap(possible)
        XCTAssertEqual(frame.knownSignature?.returnType, "double")
        let (info, id) = try definition(function, at: 0x1000, cell: 32)
        XCTAssertEqual(info.plan.definitions[id].view, .float64)
        XCTAssertEqual(info.values[id], result)
    }

    func testDirectAndIndirectAuthorityMapsCannotCrossMnemonicKinds() throws {
        let direct = build(rows([("00 04 00 94", "bl", "no_declared_target"),
                                 ("c0 03 5f d6", "ret", "")]), slots: [0x1000: slot(arguments: 0)])
        XCTAssertNotNil(try call(direct, at: 0x1000).1)
        let indirect = build(rows([("00 01 3f d6", "blr", "x8"), ("c0 03 5f d6", "ret", "")]),
            authored: ["x8": FunctionSignatureOverride(returnType: "void", args: [])])
        let (frame, result) = try call(indirect, at: 0x1000)
        XCTAssertNil(frame.typedIndirectSignature)
        XCTAssertNotNil(result)
    }

    func testNonvoidIntegerSlotResultKeepsFollowingTypedCapture() throws {
        let function = build(rows([("00 01 3f d6", "blr", "x8"), ("20 01 3f d6", "blr", "x9"),
                                   ("00 00 80 d2", "mov", "x0, #0"), ("c0 03 5f d6", "ret", "")]),
            slots: [0x1000: slot("int", arguments: 0), 0x1004: slot(arguments: 1)])
        let (first, result) = try call(function, at: 0x1000)
        XCTAssertEqual(first.typedIndirectSignature?.returnType, "int")
        XCTAssertNotNil(result)
        let (second, voidResult) = try call(function, at: 0x1004)
        XCTAssertEqual(second.typedIndirectSignature?.returnType, "void")
        XCTAssertNil(voidResult)
    }

    private var richTypes: [TypeDefinition] {
        CTypeHeaderParser.parse("""
        struct IntegerPair { uint64_t low; uint64_t high; };
        struct Pair { double real; double imag; };
        struct Large { uint64_t first; uint64_t second; uint64_t third; };
        """).types
    }

    private func richIntegerCall(_ returnType: String = "uint64_t") -> FunctionSignatureOverride {
        FunctionSignatureOverride(returnType: returnType, args: [
            ArgOverride(rowToken: "source:pair", name: "pair", type: "IntegerPair", provenance: .script)
        ])
    }

    func testAcceptedRichResultKeepsDirectEvidenceForFollowingTypedConsumer() throws {
        let function = build(rows([("e0 00 80 d2", "mov", "x0, #7"),
            ("21 01 80 d2", "mov", "x1, #9"), ("00 04 00 94", "bl", "_drand48"),
            ("20 01 3f d6", "blr", "x9"), ("00 00 80 d2", "mov", "x0, #0"),
            ("c0 03 5f d6", "ret", "")]), slots: [0x100c: slot()],
            authored: ["_drand48": richIntegerCall()], types: richTypes)
        let (frame, possible) = try call(function, at: 0x1008)
        let result = try XCTUnwrap(possible)
        XCTAssertNil(frame.knownSignature)
        XCTAssertEqual(frame.richArguments?.map(\.rowID.rawValue), ["source:pair"])
        XCTAssertEqual(frame.richArguments?.first?.pieces.map(\.valueByteOffset), [0, 8])
        let (info, id) = try definition(function, at: 0x1008)
        XCTAssertEqual(info.values[id], result)
        XCTAssertEqual(info.plan.definitions[id].view, .integer)
        guard case .callResult = info.plan.definitions[id].origin else { return XCTFail("Missing selected GPR result") }
        let (_, fpID) = try definition(function, at: 0x1008, cell: 32)
        XCTAssertEqual(info.plan.definitions[fpID].origin, .callClobber(0x1008))
        XCTAssertEqual(info.values[fpID], .unknown("unavailable_v0"))
        let (consumer, consumerResult) = try call(function, at: 0x100c)
        XCTAssertEqual(consumer.typedIndirectSignature?.returnType, "void")
        XCTAssertNil(consumerResult)
    }

    func testRejectedRichCaptureSelectsExactCatalogFPBinding() throws {
        let function = build(rows([("00 04 00 94", "bl", "_drand48"),
            ("c0 03 5f d6", "ret", "")]), authored: ["_drand48": richIntegerCall()], types: richTypes)
        let (frame, possible) = try call(function, at: 0x1000)
        let result = try XCTUnwrap(possible)
        XCTAssertNil(frame.richArguments)
        XCTAssertEqual(frame.knownSignature?.returnType, "double")
        let (info, id) = try definition(function, at: 0x1000, cell: 32)
        XCTAssertEqual(info.plan.definitions[id].view, .float64)
        XCTAssertEqual(info.plan.definitions[id].bitWidth, 64)
        XCTAssertEqual(info.values[id], result)
        guard case .register(name: "d0", version: _) = result else { return XCTFail("Expected exact D0 result") }
        guard case .callResult = info.plan.definitions[id].origin else { return XCTFail("Missing selected FP result") }
        let (_, gprID) = try definition(function, at: 0x1000)
        XCTAssertEqual(info.plan.definitions[gprID].origin, .callClobber(0x1000))
        XCTAssertEqual(info.values[gprID], .unknown("unavailable_x0"))
    }

    func testMixedBankJoinKeepsBitsPhiAndRefusesTypedArgumentAuthority() throws {
        let source = rows([("a2 00 00 34", "cbz", "w2, 0x1014"),
            ("e0 00 80 d2", "mov", "x0, #7"), ("21 01 80 d2", "mov", "x1, #9"),
            ("00 04 00 94", "bl", "_drand48"), ("02 00 00 14", "b", "0x1018"),
            ("00 04 00 94", "bl", "_drand48"), ("03 00 66 9e", "fmov", "x3, d0"),
            ("20 01 3f d6", "blr", "x9"), ("c0 03 5f d6", "ret", "")])
        let function = build(source, slots: [0x101c: slot()],
            authored: ["_drand48": richIntegerCall()], types: richTypes)
        XCTAssertNotNil(try call(function, at: 0x100c).0.richArguments)
        let fallback = try XCTUnwrap(try call(function, at: 0x1014).1)
        let (consumer, consumerResult) = try call(function, at: 0x101c)
        XCTAssertNil(consumer.typedIndirectSignature)
        XCTAssertNotNil(consumerResult)
        let (info, fallbackID) = try definition(function, at: 0x1014, cell: 32)
        let (_, richClobberID) = try definition(function, at: 0x100c, cell: 32)
        let phi = try XCTUnwrap(info.plan.phis.first {
            $0.cell == 32 && Set($0.incoming.map(\.definition)) == [fallbackID, richClobberID]
        })
        XCTAssertEqual(info.plan.definitions[phi.destination].view, .bits)
        let published = try XCTUnwrap(function.phis.first { $0.destination == info.values[phi.destination] })
        XCTAssertEqual(published.scalarView, .bits64)
        XCTAssertTrue(published.incoming.contains { $0.value == .unary(op: "__ssa_bitcast_u64", value: fallback) })
        XCTAssertTrue(published.incoming.contains { $0.value == .unknown("unavailable_v0") })
    }

    func testRichLoopDoesNotUpgradeCachedPhiArgumentEvidence() throws {
        let function = build(rows([("e0 00 80 d2", "mov", "x0, #7"),
            ("21 01 80 d2", "mov", "x1, #9"), ("00 04 00 94", "bl", "_drand48"),
            ("c2 ff ff 35", "cbnz", "w2, 0x1004"), ("c0 03 5f d6", "ret", "")]),
            authored: ["_drand48": richIntegerCall()], types: richTypes)
        let (frame, result) = try call(function, at: 0x1008)
        XCTAssertNil(frame.richArguments)
        XCTAssertEqual(frame.knownSignature?.returnType, "double")
        XCTAssertNotNil(result)
        let (info, id) = try definition(function, at: 0x1008)
        XCTAssertEqual(info.plan.definitions[id].origin, .callClobber(0x1008))
        XCTAssertTrue(info.plan.phis.contains { $0.cell == 0 && $0.incoming.contains { $0.definition == id } })
    }

    func testCompositeRichReturnsPublishOnlyTheirExactPieces() throws {
        for (type, cells, view) in [("IntegerPair", [0, 1], MacIRSSA.ScalarView.integer),
                                    ("Pair", [32, 33], MacIRSSA.ScalarView.float64)] {
            let function = build(rows([("00 04 00 94", "bl", "_drand48"),
                ("c0 03 5f d6", "ret", "")]),
                authored: ["_drand48": FunctionSignatureOverride(returnType: type, args: [])], types: richTypes)
            let (frame, possible) = try call(function, at: 0x1000)
            XCTAssertNotNil(frame.richArguments)
            guard case let .abiComposite(resultType, fragments)? = possible else { return XCTFail("Expected rich pieces") }
            XCTAssertEqual(resultType, type)
            XCTAssertEqual(fragments.count, cells.count)
            for (cell, value) in zip(cells, fragments) {
                let (info, id) = try definition(function, at: 0x1000, cell: cell)
                XCTAssertEqual(info.values[id], value)
                XCTAssertEqual(info.plan.definitions[id].view, view)
                guard case .callResult = info.plan.definitions[id].origin else { return XCTFail("Missing exact rich piece") }
            }
            if type == "Pair" {
                let (info, id) = try definition(function, at: 0x1000)
                XCTAssertEqual(info.plan.definitions[id].origin, .callClobber(0x1000))
                XCTAssertEqual(info.values[id], .unknown("unavailable_x0"))
            }
        }
    }

    func testIndirectResultBufferCaptureAndFallbackHaveDisjointResults() throws {
        for capturesBuffer in [false, true] {
            let prefix: [(String, String, String)] = capturesBuffer ? [("28 00 80 d2", "mov", "x8, #1")] : []
            let address: UInt64 = capturesBuffer ? 0x1004 : 0x1000
            let function = build(rows(prefix + [("00 04 00 94", "bl", "unknown_large"),
                ("c0 03 5f d6", "ret", "")]), authored: ["unknown_large":
                    FunctionSignatureOverride(returnType: "Large", args: [])], types: richTypes)
            let (frame, result) = try call(function, at: address)
            let (info, id) = try definition(function, at: address)
            let (_, x8ID) = try definition(function, at: address, cell: 8)
            XCTAssertEqual(info.plan.definitions[x8ID].origin, .callClobber(address))
            if capturesBuffer {
                XCTAssertNotNil(frame.indirectResultPointer)
                XCTAssertNil(result)
                XCTAssertEqual(info.plan.definitions[id].origin, .callClobber(address))
                XCTAssertEqual(info.values[id], .unknown("unavailable_x0"))
            } else {
                XCTAssertNil(frame.indirectResultPointer)
                let value = try XCTUnwrap(result)
                XCTAssertEqual(info.values[id], value)
                guard case .callResult = info.plan.definitions[id].origin else { return XCTFail("Missing unknown fallback") }
            }
        }
    }
}
