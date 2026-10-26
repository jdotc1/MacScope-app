import Foundation
import XCTest
@testable import MacScope

/// U6d: the editor's pseudocode pane passes the image's constant strings to the printer, so a
/// printf call shows the arguments its format string implies (HOP-5c), with `formatString`
/// provenance. On the reconstruction C sample, whose `_main` calls `printf("%u:%u\n", ...)`.
@MainActor
final class PseudocodePaneConstantStringsTests: XCTestCase {
    private func mainInput() throws -> PseudocodeRenderInput {
        let url = ReconstructionSourceRepairLoopbackTests.fixtureDirectory.appendingPathComponent("original-arm64")
        let snapshot = try AnalysisEngine().analyze(url: url)
        let slot = snapshot.primarySlot
        let main = try XCTUnwrap(snapshot.analysis(in: slot)?.functions.first { $0.startAddress == 0x1_0000_04a0 },
                                 "_main at 0x1000004a0")
        return snapshot.pseudocodeRenderInput(selectedAddress: main.startAddress, in: slot)
    }

    func testThePaneShowsPrintfArgumentsRecoveredFromTheFormatString() throws {
        let input = try mainInput()
        XCTAssertTrue(input.constantStrings.values.contains { $0.text == "%u:%u\n" }, "the C string is in the image's map")

        let text = PseudocodeView.document(for: input).text
        XCTAssertTrue(text.contains("printf(\"%u:%u\\n\", "), text)

        var withoutStrings = input
        withoutStrings.constantStrings = [:]
        XCTAssertNotEqual(PseudocodeView.document(for: withoutStrings).text, text,
                          "without the map the pane can't recover the variadic tail")
    }

    func testReopenedDatabasePaneShowsPrintfWithoutRehydrate() throws {
        let url = ReconstructionSourceRepairLoopbackTests.fixtureDirectory.appendingPathComponent("original-arm64")
        let snapshot = try AnalysisEngine().analyze(url: url)
        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let saved = try database.saveSnapshot(workspaceName: "Printf", snapshot: snapshot)
        let reopened = try XCTUnwrap(database.loadSnapshot(workspaceID: XCTUnwrap(saved.id)))
        let input = reopened.pseudocodeRenderInput(selectedAddress: 0x1_0000_04a0, in: reopened.primarySlot)
        let text = PseudocodeView.document(for: input).text
        XCTAssertEqual(input.constantStrings, snapshot.constantStrings)
        XCTAssertTrue(text.contains("printf(\"%u:%u\\n\", "), text)
    }

    func testTheRecoveredTailCarriesFormatStringProvenance() throws {
        let input = try mainInput()
        let function = PseudocodePrinter().buildFunction(
            functionName: input.functionName,
            startAddress: input.startAddress,
            objcSelectors: input.objcSelectors,
            constantStrings: input.constantStrings,
            instructions: input.instructions
        )
        let frame = try XCTUnwrap(function.instructions.lazy.compactMap { instruction -> MacIRCallFrame? in
            guard case let .call(frame, _) = instruction.operation, frame.target.contains("printf") else { return nil }
            return frame
        }.first, "printf call in _main")
        guard case let .formatString(evidence) = frame.tailCountEvidence else {
            return XCTFail("expected format-string evidence, got \(String(describing: frame.tailCountEvidence))")
        }
        XCTAssertEqual(MacIRCallFormatStringEvidence.provenance, "formatString")
        XCTAssertEqual(evidence.format, "%u:%u\n")
        XCTAssertEqual(frame.expectedTailCount, 2)
    }
}
