import Foundation
import XCTest
@testable import MacScope

/// Regression guards only: call-result identity is not an own-return contract.
/// Byte strings and explicit source rows are paired fixtures, not decoded here.
final class CallOriginAuthorityRefusalTests: XCTestCase {
    private typealias Row = (bytes: String, mnemonic: String, operands: String)
    private let entry: UInt64 = 0x1000
    private let callee: UInt64 = 0x2000
    private let call: Row = ("ff 03 00 94", "bl", "0x2000")
    private let ret: Row = ("c0 03 5f d6", "ret", "")

    private func check(_ fixture: [Row], ownVoid: Bool,
                       expected: Set<BuilderState.ReturnContractProducer>,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        // Preserve LR across BL and preserve x19 even in the saved-copy cases.
        // SP remains 16-byte aligned. The call is at 0x1004, so its imm26 is 0x3ff.
        let framed: [Row] = [("f3 7b bf a9", "stp", "x19, x30, [sp, #-16]!")]
            + Array(fixture.dropLast())
            + [("f3 7b c1 a8", "ldp", "x19, x30, [sp], #16"), ret]
        let callPC = entry + 4
        let rows = framed.enumerated().map { index, row in
            InstructionRow(address: entry + UInt64(index * 4), bytes: row.bytes,
                mnemonic: row.mnemonic, operands: row.operands, hasBreakpoint: false, comment: nil)
        }
        let sources = rows.map {
            MacIRSourceSpan(address: $0.address, byteText: $0.bytes,
                            mnemonic: $0.mnemonic, operands: $0.operands)
        }
        let returnPC = entry + UInt64((framed.count - 1) * 4)
        let shape = ReturnContract.ReturnShape.gpr(width: 64, type: "void *")
        let declaredCallee = ReturnContract(kind: .value(shape), tier: .header,
            evidence: [.init(source: .header, at: callee, detail: "fixture: void *g(void)")])
        let declaredVoid = ReturnContract(kind: .void, tier: .header,
            evidence: [.init(source: .header, at: entry, detail: "fixture: void w(void)")])
        // Two real lifter modes, independently crossed with the return-table flag.
        // Merely looping the return-table flag would not exercise both lifters.
        for ssa in [false, true] {
            for enabled in [false, true] {
                try MacIRConfiguration.$ssaOverride.withValue(ssa) {
                    try MacIRConfiguration.$returnContractOverride.withValue(enabled) {
                        let proof = BuilderState.returnContractProducerFacts(sources: sources, entry: entry)
                        XCTAssertEqual(proof.producers[returnPC], expected, file: file, line: line)
                        XCTAssertEqual(proof.exits, [.returnInstruction(returnPC)], file: file, line: line)
                        XCTAssertTrue(proof.reachableAddresses.contains(callPC), file: file, line: line)
                        let table = ReturnContractTable.build(
                            key: .init(snapshotID: UUID(), slot: .primary),
                            imageFacts: .init(functionStarts: [entry, callee], imageComplete: true),
                            localFacts: [
                                entry: .init(name: "w", header: ownVoid ? declaredVoid : nil, sources: sources),
                                callee: .init(name: "g", header: declaredCallee, producers: [.load],
                                              exits: [.returnInstruction(callee)])
                            ], callSites: [entry: [.init(address: callPC, target: .direct(callee),
                                consumption: expected == [.calleeResult(callee)] ? .flowsToReturn : .unknown,
                                isTailCall: false)]])
                        XCTAssertEqual(table.entries[callee]?.kind, .value(shape), file: file, line: line)
                        let wrapper = try XCTUnwrap(table.entries[entry], file: file, line: line)
                        if ownVoid {
                            XCTAssertEqual(wrapper.kind, .void, file: file, line: line)
                        } else {
                            guard case .unresolved = wrapper.kind else {
                                return XCTFail("Callee provenance must not promote w: \(wrapper.kind)", file: file, line: line)
                            }
                        }
                        let function = MacIRBuilder(explicitCFGEnabled: ssa, ssaEnabled: ssa).buildFunction(
                            name: "w", startAddress: entry,
                            authoritativeReturnLocation: ownVoid ? .void : nil,
                            authoritativeReturnType: ownVoid ? "void" : nil,
                            authoredCallSignaturesByTarget: ["0x2000": .init(returnType: "void *", args: [])],
                            instructions: rows)
                        XCTAssertEqual(function.ssaEnabled, ssa, file: file, line: line)
                        let callInstruction = try XCTUnwrap(function.instructions.first {
                            $0.source.address == callPC
                        }, file: file, line: line)
                        guard case let .call(frame, result) = callInstruction.operation else {
                            return XCTFail("Fixture must retain its actual call", file: file, line: line)
                        }
                        XCTAssertEqual(frame.target, "0x2000", file: file, line: line)
                        XCTAssertNotNil(result, "The known callee has a real value result", file: file, line: line)
                        let returns = function.instructions.filter { $0.source.address == returnPC }
                        XCTAssertEqual(returns.count, 1, file: file, line: line)
                        let expectedValue: MacIRValue? = ownVoid ? nil :
                            .unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker)
                        XCTAssertEqual(returns.first?.operation, .returnValue(expectedValue), file: file, line: line)
                        XCTAssertEqual(function.returnValue, expectedValue, file: file, line: line)
                    }
                }
            }
        }
    }

    func testVoidWrapperDirectIdentityRefusesPromotion() throws {
        // Scoring witness only: libjpeg-turbo 3.2.0 jdatadst.c:64-76 declares
        // init_destination void while jpeglib.h:898 declares alloc_small void *.
        // The synthetic address-bound declarations above, not that name, authorize this fixture.
        try check([call, ret], ownVoid: true, expected: [.calleeResult(callee)])
    }

    func testVoidWrapperSavedIdentityRefusesPromotion() throws {
        // Second source counterexample: jdcolor.c:266-284 build_rgb_y_table is void
        // after the pointer-returning allocator. Exact copies still cannot change own ABI.
        try check([call, ("f3 03 00 aa", "mov", "x19, x0"),
                   ("e0 03 13 aa", "mov", "x0, x19"), ret],
                  ownVoid: true, expected: [.calleeResult(callee)])
    }

    func testUnboundWrapperDirectIdentityRefusesPromotion() throws {
        try check([call, ret], ownVoid: false, expected: [.calleeResult(callee)])
    }

    func testUnboundWrapperSavedIdentityRefusesPromotion() throws {
        try check([call, ("f3 03 00 aa", "mov", "x19, x0"),
                   ("e0 03 13 aa", "mov", "x0, x19"), ret],
                  ownVoid: false, expected: [.calleeResult(callee)])
    }

    func testInterveningEntryRegisterWriteRefusesCallIdentity() throws {
        try check([call, ("e0 03 13 aa", "mov", "x0, x19"), ret],
                  ownVoid: false, expected: [.unknown])
    }

    func testInterveningSavedRegisterWriteRefusesCallIdentity() throws {
        try check([call, ("f3 03 00 aa", "mov", "x19, x0"),
                   ("f3 03 14 aa", "mov", "x19, x20"),
                   ("e0 03 13 aa", "mov", "x0, x19"), ret],
                  ownVoid: false, expected: [.unknown])
    }

    func testNarrowW0CopyRefusesCalleeShape() throws {
        try check([call, ("e0 03 00 2a", "mov", "w0, w0"), ret],
                  ownVoid: false, expected: [.arithmetic])
    }

    func testNarrowSavedCopyRefusesCalleeShape() throws {
        try check([call, ("f3 03 00 2a", "mov", "w19, w0"),
                   ("e0 03 13 aa", "mov", "x0, x19"), ret],
                  ownVoid: false, expected: [.arithmetic])
    }
}
