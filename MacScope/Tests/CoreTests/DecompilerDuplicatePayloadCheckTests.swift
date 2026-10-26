import Foundation
import XCTest
@testable import MacScope

#if DEBUG
final class DecompilerDuplicatePayloadCheckTests: XCTestCase {
    private func snapshot() throws -> CP6RecoveryTextCheck.Snapshot {
        // The two arms overlap at block 3, while block 2 can bypass it.
        // Direct MacIR construction keeps this a non-phi checker fixture.
        let function = CP2GraphFixture.function([[1, 2], [3], [3, 4], [4], []])
        XCTAssertTrue(function.phis.isEmpty)
        let capture = CP6RecoveryTextCheck.Capture()
        var printer = PseudocodePrinter(options: .recoveryForSemantics)
        printer.bypassRecoveryReadabilityForTesting = true
        printer.recoveryTextCheckCapture = capture
        let document = printer.print(function: function)
        XCTAssertNil(document.structureFallback)
        let result = try XCTUnwrap(capture.snapshot)
        XCTAssertEqual(Array(document.lines.prefix(result.lines.count)), result.lines)
        return result
    }

    private func repeatedPayload(_ snapshot: CP6RecoveryTextCheck.Snapshot) throws -> Int {
        var seen = Set<Int>()
        return try XCTUnwrap(snapshot.emission.blocks.indices.first { index in
            let occurrence = snapshot.emission.blocks[index]
            return !seen.insert(occurrence.block).inserted && !occurrence.payload.isEmpty
        }, "fixture must emit a nonempty payload for the same CFG block twice")
    }

    func testAcceptsIdenticalDuplicatePayloadsWithoutPhi() throws {
        let original = try snapshot()
        _ = try repeatedPayload(original)
        XCTAssertNil(CP6RecoveryTextCheck.failure(lines: original.lines, plan: original.plan,
                                                 cfg: original.cfg, emission: original.emission))
        XCTAssertTrue(original.isValid)
    }

    func testRejectsChangedDuplicatePayloadEvenWhenSnapshotAndTextAgreeWithoutPhi() throws {
        var changed = try snapshot()
        let repeated = try repeatedPayload(changed)
        let start = changed.emission.blocks[repeated].start
        changed.lines[start].text += " altered_copy();"
        changed.emission.blocks[repeated].payload[0] = changed.lines[start]
        XCTAssertEqual(CP6RecoveryTextCheck.failure(lines: changed.lines, plan: changed.plan,
                                                   cfg: changed.cfg, emission: changed.emission),
                       "duplicate occurrences have different block payloads")
        XCTAssertFalse(changed.isValid)
    }
}
#endif
