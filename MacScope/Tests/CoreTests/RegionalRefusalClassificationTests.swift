import Foundation
import XCTest
@testable import MacScope

/// A41: `RegionalPhysicalStatePlan.proveClassified` separates a function the proof does not model
/// (`.inapplicable`) from independent evidence that disagrees with the function's own records
/// (`.contradiction`). Only a contradiction refuses SSA edge projection.
final class RegionalRefusalClassificationTests: XCTestCase {
    private func row(_ address: UInt64, _ mnemonic: String, _ operands: String) -> InstructionRow {
        .init(address: address, bytes: "00000000", mnemonic: mnemonic, operands: operands,
              hasBreakpoint: false, comment: nil)
    }

    func testCallFreeFunctionIsInapplicableNotContradiction() throws {
        let function = MacIRBuilder(ssaEnabled: true).buildFunction(
            name: "_call_free", instructions: [
                row(0x9000, "cbz", "x0, 0x9008"),
                row(0x9004, "mov", "x0, #0x1"),
                row(0x9008, "ret", "")
            ])
        let cfg = try XCTUnwrap(function.cfg).compatibilityCFG
        let result = RegionalPhysicalStatePlan.proveClassified(function: function, cfg: cfg)
        guard case let .failure(refusal) = result else { return XCTFail("call-free function cannot be proved") }
        XCTAssertFalse(refusal.isContradiction, "shape refusal: \(refusal)")
        guard case .inapplicable = refusal else { return XCTFail("expected inapplicable, got \(refusal)") }
    }

    func testRefusalCombinationOrder() {
        // success wins, then contradiction, then inapplicable
        let both: Result<Int, RegionalRefusal> = RegionalRefusalRecorder.classify {
            RegionalRefusalRecorder.inapplicable("a")
            RegionalRefusalRecorder.contradict("b")
            return nil
        }
        XCTAssertEqual(both, .failure(.contradiction(guard: "b")))
        let ok: Result<Int, RegionalRefusal> = RegionalRefusalRecorder.classify {
            RegionalRefusalRecorder.contradict("b")
            return 1
        }
        XCTAssertEqual(ok, .success(1))
        let none: Result<Int, RegionalRefusal> = RegionalRefusalRecorder.classify { nil }
        XCTAssertEqual(none, .failure(.inapplicable(guard: "unmodeled-shape")))
    }
}
