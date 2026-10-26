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

/// Complete original typed fixtures must retain ordinary native structure.
/// This regression uses only the pre-existing fixture, planner and audit APIs.
final class OrdinaryCTypedUpsamplerProductRegressionTests: XCTestCase {
    func testFullTypedNativeUpsamplersRecoverOrdinaryControl() throws {
        try MacIRConfiguration.$ssaOverride.withValue(false) {
            for seed in [RegionalCallSeed.jinit, .j12init] {
                let full = try OrdinaryCRecordedCallFixture.upsampler(seed)
                XCTAssertFalse(full.function.ssaEnabled)
                XCTAssertEqual(full.function.callSignatures.map(\.target), ["_jround_up"])
                let cfg = CFGBuilder.buildCFG(instructions: full.function.instructions)
                let physical = try XCTUnwrap(RegionalPhysicalStatePlan.prove(function: full.function,
                    cfg: cfg, attemptLexical: false))
                let values = try XCTUnwrap(RegionalOrdinaryValuePlan.prove(function: full.function,
                    cfg: cfg, certifiedBy: physical))
                let callRow = seed == .jinit ? 187 : 131
                let reads = values.useBindings.filter { $0.row == callRow }
                XCTAssertEqual(reads.count, 2)
                let first = try XCTUnwrap(reads.first { $0.register.index == 0 })
                let second = try XCTUnwrap(reads.first { $0.register.index == 1 })
                XCTAssertEqual(first.register.width, 32)
                XCTAssertEqual(first.definition, .source(row: callRow - 2, slot: 0))
                XCTAssertEqual(second.register.width, 64)
                XCTAssertEqual(second.definition, .source(row: callRow - 1, slot: 0))
                XCTAssertNotNil(RegionalOrdinaryControlPlan.prove(function: full.function,
                    cfg: cfg, certifiedBy: physical, values: values))
                XCTAssertNil(full.document.structureFallback)
                let audit = try OrdinaryCOutputAudit.analyze(document: full.document,
                    function: full.function, baselineText: full.baselineText)
                XCTAssertTrue(audit.errors.isEmpty)
                XCTAssertLessThan(audit.rawEquivalentTotal, seed.baselineRaw)
                XCTAssertLessThan(audit.gotoEquivalentTotal, seed.baselineTotal)
                XCTAssertFalse(audit.loops.isEmpty)
                XCTAssertEqual(audit.rawEquivalentTotal, 0)
                XCTAssertEqual(audit.gotoEquivalentTotal, seed == .jinit ? 12 : 10)
                XCTAssertEqual(audit.loops.count, 1)
                // A nonempty signature ledger requires bounded native call admission.
                let row = seed == .jinit ? 187 : 131
                XCTAssertEqual(full.rows[row - 2].bytes, "60 8a 40 b9")
                XCTAssertEqual(full.rows[row - 1].bytes, "61 9a 81 b9")
                XCTAssertEqual(full.rows[row - 2].address, seed == .jinit ? 0x3b0fc : 0x3b978)
                XCTAssertEqual(full.rows[row - 1].address, seed == .jinit ? 0x3b100 : 0x3b97c)
            }
        }
    }

}
