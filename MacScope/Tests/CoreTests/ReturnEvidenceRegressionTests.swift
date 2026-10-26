import Foundation
import XCTest
@testable import MacScope

final class ReturnEvidenceRegressionTests: XCTestCase {
    func testUnresolvedReturnStillReportsReloadedFrameEscape() throws {
        // stp fp,lr,[sp,#-32]!; mov fp,sp; ldr x0,[sp]; ret
        let words: [UInt32] = [0xa9be7bfd, 0x910003fd, 0xf94003e0, 0xd65f03c0]
        let bytes = Data(words.flatMap { word in
            (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) }
        })
        let instructions = ARM64Decoder(validateStructuredOperands: true)
            .decode(bytes, baseAddress: 0x1000).map { InstructionRow(decoded: $0) }
        let function = PseudocodePrinter().buildFunction(
            functionName: "frame_return", startAddress: 0x1000, instructions: instructions)
        let marker = MacIRValue.unknown(MacIRIndirectTargetResolution.unresolvedReturnContractMarker)
        XCTAssertEqual(function.returnValue, marker)
        XCTAssertEqual(function.instructions.last?.operation, .returnValue(marker))

        let result = try XCTUnwrap(MacIRIndirectTargetResolution.poisonReport(
            functions: [function], functionStarts: [function.startAddress]).functions.first)
        XCTAssertFalse(result.visible)
        XCTAssertTrue(result.hasEscapedFrameWrite)
        XCTAssertEqual(result.firstRejectingReason, "escaped frame")
        XCTAssertEqual(result.firstFrameEscape?.shape, "returned")
    }
}
