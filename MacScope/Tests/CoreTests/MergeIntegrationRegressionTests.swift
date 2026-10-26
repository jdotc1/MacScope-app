import Foundation
import XCTest
@testable import MacScope

final class MergeIntegrationRegressionTests: XCTestCase {
    private func row(_ address: UInt64, _ operation: MacIROperation,
                     mnemonic: String = "nop", operands: String = "") -> MacIRInstruction {
        .init(source: .init(address: address, byteText: "00 00 00 00",
            mnemonic: mnemonic, operands: operands), operation: operation)
    }

    private func field(_ source: MacIRValue, bits: Int = 64) throws -> MacIRValue {
        let register = bits == 64 ? "x8" : "w8"
        let origin = MacIRSignedBitfield.Origin(functionName: "integration", functionStart: 0x1000,
            instructionAddress: 0x1008, mnemonic: "sbfx", sourceRegister: register,
            destinationRegister: bits == 64 ? "x9" : "w9", definition: source, definitionBits: bits)
        return .signedBitfield(try XCTUnwrap(MacIRSignedBitfield(source: source, operandBits: bits,
            sourceLSB: 0, fieldBits: 8, insertLSB: 0, origin: origin)))
    }

    private func widthFixture(bits: Int) throws {
        let result = MacIRValue.register(name: bits == 64 ? "x8" : "w8", version: 1)
        let expression = try field(result, bits: bits)
        let frame = try XCTUnwrap(MacIRCallFrame(target: "callee", knownSignature: nil,
            controlInputs: .none, arguments: try XCTUnwrap(MacIRCallArguments([]))))
        let function = MacIRFunction(name: "width", startAddress: 0x1000, instructions: [
            row(0x1000, .call(frame: frame, result: result)),
            row(0x1004, .store(source: .unary(op: "(uint32_t)", value: result),
                address: .register(name: "x20", version: 0))),
            row(0x1008, .store(source: expression, address: .register(name: "x21", version: 0)))
        ])
        let facts = MacIRCallerReturnEvidence.widthFactsForTesting(result: result,
            function: function, expression: expression)
        XCTAssertEqual(facts.candidates, [1, 2], "A field source must enter the same candidate bucket")
        XCTAssertEqual(facts.indexed, facts.fullScan, "Indexing cannot hide a wider source read")
        XCTAssertEqual(facts.indexed, bits == 32)
        XCTAssertEqual(facts.auditedWidth, bits)
        XCTAssertEqual(facts.readWidth, bits)
    }

    func testSignedFieldWidthIndexKeepsWideRead() throws { try widthFixture(bits: 64) }
    func testSignedFieldWidthIndexKeepsNarrowRead() throws { try widthFixture(bits: 32) }

    private func reach(starts: Set<UInt64>) throws -> [Set<UInt64>] {
        let value = MacIRValue.register(name: "x8", version: 1)
        let wrapped = try field(value)
        let function = MacIRFunction(name: "reach", startAddress: 0x1000, instructions: [
            row(0x1000, .assign(destination: value, source: .immediate(0x2000))),
            row(0x1004, .store(source: wrapped, address: .register(name: "x20", version: 0)))
        ])
        return MacIRSlotReturnAuthority.targetSetsForTesting(function: function,
            starts: starts, queries: [(wrapped, 1), (wrapped, 1)])
    }

    func testSignedFieldReachRetainsFunctionStartVeto() throws {
        XCTAssertEqual(try reach(starts: [0x2000]), [[0x2000], [0x2000]])
    }
    func testSignedFieldReachDoesNotInventStart() throws {
        XCTAssertEqual(try reach(starts: [0x3000]), [[], []])
    }

    func testSignedFieldPhiDependencyRetainsSnapshot() throws {
        let destination = MacIRValue.register(name: "x8", version: 1)
        let source = try field(destination)
        let function = MacIRFunction(name: "edge", startAddress: 0x1000, instructions: [])
        XCTAssertTrue(PseudocodePrinter().edgeCopyNeedsSnapshotsForTesting(
            destinations: [destination], incoming: [source], function: function))
    }
    func testSignedFieldPhiDependencyAllowsDisjointSource() throws {
        let destination = MacIRValue.register(name: "x9", version: 1)
        let source = try field(.register(name: "x8", version: 1))
        let function = MacIRFunction(name: "edge", startAddress: 0x1000, instructions: [])
        XCTAssertFalse(PseudocodePrinter().edgeCopyNeedsSnapshotsForTesting(
            destinations: [destination], incoming: [source], function: function))
    }

    private func originState(joined: Bool) -> BuilderState {
        var state = BuilderState()
        state.signedBitfieldFunctionName = "integration"
        state.returnProducerEntryAddress = 0x1000
        state.currentRowAddress = 0x1008
        state.ssa = .init(current: [8: .init(value: .register(name: "x8", version: 1),
            bitWidth: 64, view: .integer, origin: joined ? .phi(block: 1) : .instruction(0x1000))],
            writes: [:], clobbers: [:])
        state.synchronizeSSARegisterState()
        return state
    }

    func testJoinedFieldOriginRemainsRefused() throws {
        let state = originState(joined: true)
        XCTAssertEqual(state.currentIntegerDefinitionByIndex[8]?.isJoinedDefinition, true)
        XCTAssertNil(state.signedBitfieldOrigin(mnemonic: "sbfx", source: "x8", destination: "x9"))
    }
    func testOrdinaryFieldOriginRetainsAdmission() throws {
        let state = originState(joined: false)
        XCTAssertEqual(state.currentIntegerDefinitionByIndex[8]?.isJoinedDefinition, false)
        let origin = try XCTUnwrap(state.signedBitfieldOrigin(mnemonic: "sbfx", source: "x8", destination: "x9"))
        XCTAssertNotNil(MacIRSignedBitfield(source: .register(name: "x8", version: 1), operandBits: 64,
            sourceLSB: 0, fieldBits: 8, insertLSB: 0, origin: origin))
        var missingCoordinate = state
        missingCoordinate.currentRowAddress = nil
        XCTAssertNil(missingCoordinate.signedBitfieldOrigin(mnemonic: "sbfx", source: "x8", destination: "x9"))
    }

    private func census(accounting: Bool) -> C2DataflowCensus.Analysis {
        var function = MacIRFunction(name: "unresolved", startAddress: 0x1000, instructions: [
            row(0x1000, .intrinsic(destination: nil, name: "branch",
                arguments: [.register(name: "x8", version: 0)]), mnemonic: "br", operands: "x8")
        ])
        function.refusals = [.init(reason: .unknownEffects, scope: .function,
            detail: "entry block has an in-graph predecessor")]
        let printer = PseudocodePrinter()
        return C2DataflowCensus.analyze(function: function, document: printer.print(function: function),
            machine: function.instructions.map(\.source), printer: printer,
            names: .init(function: function), ssaAccountingEnabled: accounting)
    }

    func testCensusOffRetainsMainEvidence() {
        let off = census(accounting: false)
        XCTAssertEqual(off.detectorSkippedReason, "unresolved indirect branch at 0x1000")
        XCTAssertEqual(off.skippedReason, off.detectorSkippedReason)
        XCTAssertEqual(off.indirectBranchSites, [0x1000])
        XCTAssertTrue(off.lifterRefusals.isEmpty)
        XCTAssertTrue(off.rows.isEmpty)
    }
    func testCensusOnRetainsBothEvidenceChannels() {
        let off = census(accounting: false), on = census(accounting: true)
        XCTAssertEqual(on.detectorSkippedReason, off.detectorSkippedReason)
        XCTAssertEqual(on.refusalDetails, off.refusalDetails)
        XCTAssertEqual(on.indirectBranchSites, off.indirectBranchSites)
        XCTAssertEqual(on.lifterRefusals.map(\.detail), ["entry block has an in-graph predecessor"])
        XCTAssertNotEqual(on.skippedReason, off.skippedReason)
    }

    private let baseSummary: [String: Any] = ["functionsTotal": 1, "functionsSkipped": 1,
        "coverageCounting": "main fixture", "completeWarmImageReport": true]
    private let additions: [String: Any] = ["entryBackedgeRefusalFunctions": 1,
        "lifterRefusalFunctions": 1, "ssaMetricsByFunction": [], "totalPhis": 0,
        "totalJoinBlocks": 0, "phiBoundSatisfied": true, "resolvedJumpTables": 0,
        "jumpTableEscapes": [], "jumpTableAddressCoverage": "fixture",
        "peakRSSBytes": 0, "peakRSSScope": "fixture"]

    private func validity(accounting: Bool) -> (valid: Bool, invalidReason: String?) {
        DecompilerC2DataflowCensusTests.summaryValidityForTesting(ssaAccountingEnabled: accounting,
            partiallyAnalyzed: 0, affected: 0, skipped: 1, analysisReasons: ["unknown-use: x8"],
            refusalsByReason: ["wrong-class": 1], cancelled: false)
    }

    func testCensusOffRetainsMainSummaryContract() {
        var samples = 0
        let summary = DecompilerC2DataflowCensusTests.assemblingSummaryForTesting(base: baseSummary,
            ssaAccountingEnabled: false) { samples += 1; return additions }
        XCTAssertEqual(samples, 0)
        XCTAssertEqual(summary as NSDictionary, baseSummary as NSDictionary)
        XCTAssertTrue(validity(accounting: false).valid)
    }
    func testCensusOnAddsOnlyAccountedSummaryFields() {
        var samples = 0
        let summary = DecompilerC2DataflowCensusTests.assemblingSummaryForTesting(base: baseSummary,
            ssaAccountingEnabled: true) { samples += 1; return additions }
        XCTAssertEqual(samples, 1)
        XCTAssertEqual(Set(summary.keys).subtracting(baseSummary.keys), Set(additions.keys))
        for key in baseSummary.keys { XCTAssertEqual(summary[key] as? AnyHashable, baseSummary[key] as? AnyHashable) }
        XCTAssertFalse(validity(accounting: true).valid)
    }
    private func phiDiagnosticFixture(ssaEnabled: Bool, retained: Bool)
        -> (function: MacIRFunction, phi: MacIRPhi, incoming: MacIRPhi.Incoming, names: PseudocodeNameContext) {
        let destination = MacIRValue.register(name: "x0", version: 3)
        let other = MacIRValue.register(name: "x0", version: 2)
        let incoming = MacIRPhi.Incoming(predecessorAddress: 0x1004, value: other)
        let phi = MacIRPhi(blockAddress: 0x1010, destination: destination,
            bitWidth: 64, incoming: [incoming], cell: 0)
        var function = MacIRFunction(name: "diagnostic", startAddress: 0x1000,
            instructions: [row(0x1000, .assign(destination: other, source: .immediate(7))),
                row(0x1010, .returnValue(retained ? destination : other))], phis: [phi])
        function.ssaEnabled = ssaEnabled
        return (function, phi, incoming,
            PseudocodeNameContext(function: function, registerNameOverrides: ["x0": "shared"]))
    }

    func testPhiDiagnosticsSeparateEqualDisplayNamesFromNativeValues() {
        for enabled in [false, true] {
            let fixture = phiDiagnosticFixture(ssaEnabled: enabled, retained: false)
            let document = PseudocodeDocument(functionName: "diagnostic", lines: [
                .init(lineNumber: 1, text: "shared = 7;"),
                .init(lineNumber: 2, text: "return shared;")])
            let result = C2DataflowCensus.phiEdgeDiagnostic(function: fixture.function, document: document,
                printer: PseudocodePrinter(), names: fixture.names, phi: fixture.phi, incoming: fixture.incoming)
            XCTAssertNotEqual(result.destinationValueID, result.incomingValueID)
            XCTAssertTrue(result.sameDisplayValueIDs.contains(result.destinationValueID))
            XCTAssertTrue(result.sameDisplayValueIDs.contains(result.incomingValueID))
            XCTAssertEqual(result.phiIndex, 0)
            XCTAssertEqual(result.joinAddress, 0x1010)
            XCTAssertEqual(result.predecessorAddress, 0x1004)
            XCTAssertEqual(result.cell, 0)
            XCTAssertEqual(result.allIncoming.map(\.predecessorAddress), [0x1004])
            XCTAssertEqual(result.allIncoming.map(\.valueID), [result.incomingValueID])
            XCTAssertFalse(result.censusCopyRequirementSatisfied)
            XCTAssertEqual(result.retainedByComparisonPresentation, !enabled)
            XCTAssertTrue(result.destinationUseAddresses.isEmpty)
            XCTAssertFalse(result.matchingSyntheticEdgeLineSeen)
            XCTAssertFalse(result.matchingSyntheticDestinationAssignmentSeen)
        }
    }

    func testPhiDiagnosticsRequireExactEdgeAndInstructionOwnership() {
        for enabled in [false, true] {
            let fixture = phiDiagnosticFixture(ssaEnabled: enabled, retained: true)
            var source = MacIRSourceSpan(address: 0x2000, byteText: "", mnemonic: "phi", operands: "")
            source.syntheticPhiEdge = .init(blockAddress: fixture.phi.blockAddress,
                predecessor: fixture.incoming.predecessor, destination: fixture.phi.destination)
            var wrongValue = source
            wrongValue.syntheticPhiEdge?.destination = fixture.incoming.value
            var wrongJoin = source
            wrongJoin.syntheticPhiEdge?.blockAddress = 0x1020
            var wrongPredecessor = source
            wrongPredecessor.syntheticPhiEdge?.predecessor = .machine(0x1008)
            let document = PseudocodeDocument(functionName: "diagnostic", lines: [
                .init(lineNumber: 1, kind: .declaration, text: "int64_t shared = 0;", source: source),
                .init(lineNumber: 2, text: "shared = 7;", source: wrongValue),
                .init(lineNumber: 3, text: "shared = 7;", source: wrongJoin),
                .init(lineNumber: 4, text: "shared = 7;", source: wrongPredecessor),
                .init(lineNumber: 5, text: "L_edge:", source: source),
                .init(lineNumber: 6, text: "tmp = shared;", source: source)])
            let result = C2DataflowCensus.phiEdgeDiagnostic(function: fixture.function, document: document,
                printer: PseudocodePrinter(), names: fixture.names, phi: fixture.phi, incoming: fixture.incoming)
            XCTAssertTrue(result.retainedByComparisonPresentation)
            XCTAssertEqual(result.destinationUseAddresses, [0x1010])
            XCTAssertTrue(result.matchingSyntheticEdgeLineSeen)
            XCTAssertFalse(result.matchingSyntheticDestinationAssignmentSeen)
            XCTAssertEqual(result.matchingSyntheticLines.map(\.number), [5, 6])
        }
    }

    func testPhiDiagnosticsRecordExactCopyWithoutChangingInputs() {
        for enabled in [false, true] {
            let fixture = phiDiagnosticFixture(ssaEnabled: enabled, retained: true)
            var source = MacIRSourceSpan(address: 0x2000, byteText: "", mnemonic: "phi", operands: "")
            source.syntheticPhiEdge = .init(blockAddress: 0x1010, predecessorAddress: 0x1004,
                destination: fixture.phi.destination)
            let document = PseudocodeDocument(functionName: "diagnostic", lines: [
                .init(lineNumber: 1, text: "shared = tmp;", source: source)])
            let originalFunction = fixture.function, originalDocument = document
            let first = C2DataflowCensus.phiEdgeDiagnostic(function: fixture.function, document: document,
                printer: PseudocodePrinter(), names: fixture.names, phi: fixture.phi, incoming: fixture.incoming)
            let second = C2DataflowCensus.phiEdgeDiagnostic(function: fixture.function, document: document,
                printer: PseudocodePrinter(), names: fixture.names, phi: fixture.phi, incoming: fixture.incoming)
            XCTAssertEqual(first, second)
            XCTAssertTrue(first.matchingSyntheticDestinationAssignmentSeen)
            XCTAssertEqual(first.censusCopyRequirementSatisfied, enabled)
            XCTAssertEqual(first.matchingSyntheticLines.map(\.text), ["shared = tmp;"])
            XCTAssertEqual(fixture.function, originalFunction)
            XCTAssertEqual(document, originalDocument)
            XCTAssertEqual(document.text, originalDocument.text)
        }
    }

    func testPhiDiagnosticsSurviveExistingSummaryDetailEncoding() throws {
        for enabled in [false, true] {
            let fixture = phiDiagnosticFixture(ssaEnabled: enabled, retained: false)
            let document = PseudocodeDocument(functionName: "diagnostic", lines: [])
            let evidence = C2DataflowCensus.phiEdgeDiagnostic(function: fixture.function, document: document,
                printer: PseudocodePrinter(), names: fixture.names, phi: fixture.phi, incoming: fixture.incoming)
            let detail = C2DataflowCensus.RefusalDetail(reason: "phi has no emitted predecessor edge copy",
                instructionAddress: 0x1004, mnemonic: "b", register: "x0", valueName: "shared",
                displayedLineNumber: nil, phiEdgeDiagnostic: evidence)
            let data = try JSONEncoder().encode([detail])
            XCTAssertEqual(try JSONDecoder().decode([C2DataflowCensus.RefusalDetail].self, from: data), [detail])
            let records = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            let nested = try XCTUnwrap(records.first?["phiEdgeDiagnostic"] as? [String: Any])
            XCTAssertEqual((nested["joinAddress"] as? NSNumber)?.uint64Value, 0x1010)
            XCTAssertEqual((nested["predecessorAddress"] as? NSNumber)?.uint64Value, 0x1004)
            XCTAssertEqual(nested["matchingSyntheticDestinationAssignmentSeen"] as? Bool, false)
            let legacy = C2DataflowCensus.RefusalDetail(reason: "unrelated", instructionAddress: nil,
                mnemonic: nil, register: nil, valueName: nil, displayedLineNumber: nil)
            let legacyData = try JSONEncoder().encode([legacy])
            let legacyRecords = try XCTUnwrap(JSONSerialization.jsonObject(with: legacyData) as? [[String: Any]])
            XCTAssertNil(legacyRecords.first?["phiEdgeDiagnostic"])
            XCTAssertEqual(try JSONDecoder().decode([C2DataflowCensus.RefusalDetail].self, from: legacyData), [legacy])
        }
    }


    func testPhiDiagnosticsKeepNonRefusedIncomingSideOfJoin() {
        for enabled in [false, true] {
            var fixture = phiDiagnosticFixture(ssaEnabled: enabled, retained: true)
            fixture.phi.incoming.append(.init(predecessorAddress: 0x1008, value: .immediate(99)))
            fixture.function.phis = [fixture.phi]
            var source = MacIRSourceSpan(address: 0x2000, byteText: "", mnemonic: "phi", operands: "")
            source.syntheticPhiEdge = .init(blockAddress: 0x1010, predecessorAddress: 0x1008,
                destination: fixture.phi.destination)
            let document = PseudocodeDocument(functionName: "diagnostic", lines: [
                .init(lineNumber: 1, text: "shared = 99;", source: source)])
            let result = C2DataflowCensus.phiEdgeDiagnostic(function: fixture.function, document: document,
                printer: PseudocodePrinter(), names: fixture.names, phi: fixture.phi, incoming: fixture.incoming)
            XCTAssertFalse(result.matchingSyntheticDestinationAssignmentSeen)
            XCTAssertEqual(result.allIncoming.map(\.predecessorAddress), [0x1004, 0x1008])
            XCTAssertEqual(result.allIncoming.map(\.matchingSyntheticDestinationAssignmentSeen), [false, true])
            XCTAssertEqual(result.allIncoming.map(\.censusCopyRequirementSatisfied), [false, enabled])
            XCTAssertNotEqual(result.allIncoming[0].valueID, result.allIncoming[1].valueID)
            XCTAssertTrue(result.values.contains { $0.id == result.allIncoming[1].valueID })
        }
    }


    func testPhiMissingCopyRefusalCarriesDiagnosticIntoSummary() throws {
        for enabled in [false, true] {
            let left = MacIRValue.register(name: "x1", version: 1)
            let right = MacIRValue.register(name: "x1", version: 2)
            let joined = MacIRValue.register(name: "x1", version: 3)
            let phi = MacIRPhi(blockAddress: 0x2010, destination: joined, bitWidth: 64,
                incoming: [.init(predecessorAddress: 0x2008, value: left),
                    .init(predecessorAddress: 0x200c, value: right)], cell: 1)
            var function = MacIRFunction(name: "missing_copy", startAddress: 0x2000, returnType: "void", instructions: [
                row(0x2000, .conditionalBranch(condition: "==", left: .register(name: "x0", version: 0),
                    right: .immediate(0), target: .immediate(0x200c)), mnemonic: "cbz", operands: "x0, 0x200c"),
                row(0x2004, .assign(destination: left, source: .register(name: "x20", version: 0)),
                    mnemonic: "mov", operands: "x1, x20"),
                row(0x2008, .intrinsic(destination: nil, name: "branch", arguments: [.immediate(0x2010)]),
                    mnemonic: "b", operands: "0x2010"),
                row(0x200c, .assign(destination: right, source: .register(name: "x21", version: 0)),
                    mnemonic: "mov", operands: "x1, x21"),
                row(0x2010, .store(source: joined, address: .register(name: "x2", version: 0)),
                    mnemonic: "str", operands: "x1, [x2]"),
                row(0x2014, .returnValue(nil), mnemonic: "ret")], phis: [phi])
            function.ssaEnabled = enabled
            // Intentionally omit both edge copies while retaining the phi use.
            // This tests refusal-to-summary plumbing, not a printer defect.
            let document = PseudocodeDocument(functionName: "missing_copy", lines: [
                .init(lineNumber: 1, text: "*(x2_0) = x1_3;", source: function.instructions[4].source)])
            let result = C2DataflowCensus.analyze(function: function, document: document,
                machine: function.instructions.map(\.source), printer: PseudocodePrinter(),
                names: PseudocodeNameContext(function: function), ssaAccountingEnabled: enabled)
            let details = result.refusalDetails.filter { $0.reason == "phi has no emitted predecessor edge copy" }
            XCTAssertEqual(details.count, 2)
            XCTAssertEqual(details.map(\.instructionAddress), [0x2008, 0x200c])
            let first = try XCTUnwrap(details.first?.phiEdgeDiagnostic)
            let second = try XCTUnwrap(details.last?.phiEdgeDiagnostic)
            XCTAssertEqual(first.joinAddress, 0x2010)
            XCTAssertEqual(first.phiIndex, 0)
            XCTAssertEqual(first.allIncoming.map(\.predecessorAddress), [0x2008, 0x200c])
            XCTAssertEqual(first.destinationValueID, second.destinationValueID)
            XCTAssertNotEqual(first.incomingValueID, second.incomingValueID)
            XCTAssertFalse(first.censusCopyRequirementSatisfied)
            XCTAssertFalse(second.censusCopyRequirementSatisfied)
            // The existing summary serializes result.refusalDetails this way.
            let data = try JSONEncoder().encode(result.refusalDetails)
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            XCTAssertEqual(encoded.filter { $0["phiEdgeDiagnostic"] != nil }.count, 2)
            XCTAssertEqual(document.text, "*(x2_0) = x1_3;")
        }
    }

}


extension MergeIntegrationRegressionTests {
    func testLegacyPhiDiagnosticJSONDoesNotInventFunctionEntryKind() throws {
        let json = #"{"predecessorAddress":4100,"valueID":7,"matchingSyntheticEdgeLineSeen":false,"matchingSyntheticDestinationAssignmentSeen":false,"censusCopyRequirementSatisfied":false,"matchingSyntheticLines":[]}"#
        let decoded = try JSONDecoder().decode(C2DataflowCensus.PhiIncomingDiagnostic.self,
            from: Data(json.utf8))
        XCTAssertEqual(decoded.predecessorAddress, 4100)
        XCTAssertEqual(decoded.valueID, 7)
        XCTAssertNil(decoded.predecessorKind, "A legacy diagnostic is not virtual-entry authority")
        XCTAssertFalse(decoded.censusCopyRequirementSatisfied)
    }

    func testTypedPhiDiagnosticJSONKeepsMachineAddressAndOmitsVirtualAddress() throws {
        for predecessor in [MacIRPhiPredecessor.machine(0x1004), .functionEntry] {
            let kind = predecessor == .functionEntry ? "functionEntry" : "machine"
            let record = C2DataflowCensus.PhiIncomingDiagnostic(
                predecessorAddress: predecessor.machineAddress, predecessorKind: kind, valueID: 7,
                matchingSyntheticEdgeLineSeen: false, matchingSyntheticDestinationAssignmentSeen: false,
                censusCopyRequirementSatisfied: false, matchingSyntheticLines: [])
            let encoded = try JSONEncoder().encode(record)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(object["predecessorKind"] as? String, kind)
            if predecessor == .functionEntry {
                XCTAssertNil(object["predecessorAddress"], "No synthetic address may impersonate a machine predecessor")
            } else {
                XCTAssertEqual((object["predecessorAddress"] as? NSNumber)?.uint64Value, 4100)
            }
            XCTAssertEqual(try JSONDecoder().decode(C2DataflowCensus.PhiIncomingDiagnostic.self, from: encoded), record)
        }
    }
}
