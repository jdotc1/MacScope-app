import XCTest
import MacScope

/// Compiles without `@testable` so the Phase-A client surface cannot be
/// accidentally satisfied by internal-only declarations.
final class MacIRCallArgumentPublicAPITests: XCTestCase {
    func testFrozenPublicSurfacePreservesOriginalSelectorValue() throws {
        let selectorEvidence = try XCTUnwrap(
            MacIRCallSelectorEvidence(name: "description", selrefAddress: 0x1_0000)
        )
        let arguments = try XCTUnwrap(MacIRCallArguments([
            MacIRCallArgument(
                location: .gpr(index: 0, carrierWidth: 64),
                role: .fixed(sourcePosition: 0),
                value: .unknown("receiver")
            ),
            MacIRCallArgument(
                location: .gpr(index: 1, carrierWidth: 64),
                role: .fixed(sourcePosition: 1),
                value: .unknown("selector"),
                selectorEvidence: selectorEvidence
            ),
        ]))
        let signature = MacIRCallSignature(
            target: "_objc_msgSend",
            returnType: "id",
            parameters: [
                MacIRCallParameter(index: 0, register: "x0", type: "id"),
                MacIRCallParameter(index: 1, register: "x1", type: "SEL"),
            ],
            isVariadic: true
        )
        let frame = try XCTUnwrap(MacIRCallFrame(
            target: "_objc_msgSend",
            knownSignature: signature,
            tailCountEvidence: .objectiveCSelectorColonCount(0),
            controlInputs: .none,
            arguments: arguments
        ))

        XCTAssertEqual(
            arguments.denseFixedPrefixValues(),
            [.unknown("receiver"), .unknown("selector")],
            "the public argument projection must preserve original values; selector presentation is frame-owned"
        )
        XCTAssertEqual(frame.knownSignature, signature)
        XCTAssertEqual(frame.tailCountEvidence?.expectedTailCount, 0)
        XCTAssertEqual(frame.expectedTailCount, 0)
    }
}
