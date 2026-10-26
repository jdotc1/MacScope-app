import Foundation
import XCTest
@testable import MacScope

final class F2J1CaptureRecorderContractTests: XCTestCase {
    private typealias R = F2J1CaptureRecorder
    private let candidate = String(repeating: "a", count: 40)
    private let digest = String(repeating: "b", count: 64)
    private let assertion = R.Assertion(originalExpression: "original assertion", passed: false,
        diagnostic: "synthetic failure retained")

    private func identity(ssa: Bool, selector: String? = nil, sha: String? = nil,
                          nonce: UUID = UUID()) throws -> R.Identity {
        try R.Identity(nonce: nonce, candidateSHA: sha ?? candidate,
            selector: selector ?? R.s1Selectors[0], imageOwner: "synthetic-owner",
            functionStart: 0x1000, functionEnd: 0x1008,
            effectiveBytesDigest: digest, backend: "synthetic-macir",
            effectiveFlags: ["ssaEnabled": String(ssa), "explicitCFGEnabled": "true",
                "MACSCOPE_SSA_LIFTER": ssa ? "1" : "0", "MacScopeSSALifter": String(ssa)],
            options: .default)
    }
    private func render(ssa: Bool, selector: String? = nil, sha: String? = nil,
                        withCFG: Bool = true) throws -> R.RenderSnapshot {
        let source = MacIRSourceSpan(address: 0x1004, byteText: "", mnemonic: "ret", operands: "")
        var function = MacIRFunction(name: "synthetic", startAddress: 0x1000, endAddress: 0x1008,
            instructions: [MacIRInstruction(source: source, operation: .returnValue(nil))])
        function.ssaEnabled = ssa
        if withCFG {
            function.cfg = MacIRCFG.build(instructions: function.instructions,
                jumpTables: [:], knownTailCallTargets: [:], authoredCallSignaturesByTarget: [:])
        }
        let document = PseudocodeDocument(functionName: "synthetic", entryAddress: 0x1000,
            lines: [.init(lineNumber: 1, text: "return;", source: source)])
        return try R.RenderSnapshot(identity: identity(ssa: ssa, selector: selector, sha: sha),
            function: function, document: document)
    }

    func testOnCaptureRetainsOneRenderAndIndependentGateFailures() throws {
        let snapshot = try render(ssa: true)
        let gates = R.Gates(completeEdges: .refused("precise dead-block edge"), completePhis: .accepted)
        let record = try R.s1On(render: snapshot, gates: gates, assertion: assertion)
        XCTAssertTrue(record.render === snapshot)
        XCTAssertEqual(record.render.sourceMap, snapshot.document.lines)
        XCTAssertEqual(record.render.function, snapshot.function)
        XCTAssertEqual(record.render.instructionOrder, snapshot.function.instructions.map(\.source))
        XCTAssertEqual(record.gates, gates)
        XCTAssertEqual(record.assertion, assertion)
        XCTAssertTrue(record.hasCompleteOnObservation, "A recorded refusal is evidence, not an approval")
        XCTAssertNil(record.preH05)
    }

    func testMissingCFGOrGateObservationCannotCountAsCompleteCapture() throws {
        let missingGraph = try R.s1On(render: render(ssa: true, withCFG: false),
            gates: .init(completeEdges: .accepted, completePhis: .accepted), assertion: assertion)
        XCTAssertFalse(missingGraph.hasCompleteOnObservation)
        let missingGate = try R.s1On(render: render(ssa: true),
            gates: .init(completeEdges: .notObserved, completePhis: .accepted), assertion: assertion)
        XCTAssertFalse(missingGate.hasCompleteOnObservation)
    }

    func testOffOracleRequiresDistinctExplicitPreH05Attestation() throws {
        let baselineSHA = String(repeating: "c", count: 40)
        let baseline = try render(ssa: false, sha: baselineSHA)
        XCTAssertThrowsError(try R.preH05Off(render: baseline, attestation: nil, assertion: assertion))
        XCTAssertThrowsError(try R.preH05Off(render: baseline,
            attestation: .init(candidateSHA: candidate, receiptReference: "synthetic-receipt", authority: "test"),
            assertion: assertion))
        let record = try R.preH05Off(render: baseline,
            attestation: .init(candidateSHA: baselineSHA, receiptReference: "synthetic-pre-H05-receipt",
                authority: "synthetic-owner-attestation"), assertion: assertion)
        let current = try render(ssa: true)
        XCTAssertNotEqual(record.render.identity.nonce, current.identity.nonce)
        XCTAssertNotEqual(record.render.identity.candidateSHA, current.identity.candidateSHA)
        XCTAssertEqual(record.render.document, baseline.document)
        XCTAssertEqual(record.render.calls, baseline.calls)
        XCTAssertEqual(record.render.refusals, baseline.refusals)
        XCTAssertFalse(record.hasCompleteOnObservation)
    }

    func testModeSelectorAndRenderIdentityMismatchesAreRejected() throws {
        XCTAssertThrowsError(try R.s1On(render: render(ssa: false),
            gates: .init(completeEdges: .accepted, completePhis: .accepted), assertion: assertion))
        XCTAssertThrowsError(try R.s1On(render: render(ssa: true, selector: R.j1Selector),
            gates: .init(completeEdges: .accepted, completePhis: .accepted), assertion: assertion))
        let snapshot = try render(ssa: true)
        var altered = snapshot.document
        altered.entryAddress = 0x2000
        XCTAssertThrowsError(try R.RenderSnapshot(identity: snapshot.identity,
            function: snapshot.function, document: altered))
        XCTAssertThrowsError(try identity(ssa: true, sha: "historical-filename-is-not-a-sha"))
    }

    func testJ1KeepsExactTypedCastAndTokenSpanWithoutAdmittingRepair() throws {
        let source = MacIRSourceSpan(address: 0x1000, byteText: "", mnemonic: "cbz", operands: "x0, 0x1004")
        let terminal = MacIRSourceSpan(address: 0x1004, byteText: "", mnemonic: "ret", operands: "")
        var function = MacIRFunction(name: "synthetic", startAddress: 0x1000, endAddress: 0x1008,
            instructions: [.init(source: source, operation: .intrinsic(destination: nil, name: "nop", arguments: [])),
                .init(source: terminal, operation: .returnValue(nil))])
        function.ssaEnabled = true
        let signature = "void synthetic(uint64_t value) {"
        let document = PseudocodeDocument(functionName: "synthetic", entryAddress: 0x1000, lines: [
            .init(lineNumber: 1, kind: .signature, text: signature),
            .init(lineNumber: 2, text: "if ((uint64_t)value == 0) goto L_1004;", source: source),
            .init(lineNumber: 3, text: "L_1004:", source: terminal),
            .init(lineNumber: 4, text: "return;", source: terminal),
            .init(lineNumber: 5, kind: .closingBrace, text: "}")
        ])
        let contract = OrdinaryC.Contract(signature: signature,
            inputs: [.init(name: "value", type: .u64, entrySlot: 0)], fields: [], calls: [:], exterior: [:],
            terminalRow: 44, terminalPayload: "return;", terminalName: nil, returnType: nil,
            rowsByAddress: [0x1000: 43, 0x1004: 44], allowedLabels: ["L_1004"],
            memoryEffects: [:], helpers: [:], deadResults: [], permissions: [])
        let program = try OrdinaryC.Program(lines: OrdinaryC.lines(document), contract: contract)
        let snapshot = try R.RenderSnapshot(identity: identity(ssa: true, selector: R.j1Selector),
            function: function, document: document)
        let record = try R.j1(render: snapshot, program: program, assertion: assertion)
        XCTAssertTrue(record.render === snapshot)
        XCTAssertEqual(record.sourceRow, 43)
        XCTAssertEqual(try program.row(at: record.predicateSpan), 43)
        guard case let .binary(_, left, _) = record.predicate.node,
              case let .cast(type, inner) = left.node,
              case let .name(name) = inner.node else {
            return XCTFail("The original cast tree must remain intact")
        }
        XCTAssertEqual(type, .u64)
        XCTAssertEqual(name, "value")
        XCTAssertEqual(record.assertion, assertion)
        var otherDocument = document
        otherDocument.lines[1].text = "if (value == 0) goto L_1004;"
        let other = try R.RenderSnapshot(identity: snapshot.identity, function: function, document: otherDocument)
        XCTAssertThrowsError(try R.j1(render: other, program: program, assertion: assertion))
    }
}
