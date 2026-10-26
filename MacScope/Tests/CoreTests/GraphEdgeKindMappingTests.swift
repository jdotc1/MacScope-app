import XCTest
import LumenTokens
import LumenUI
@testable import MacScope

/// UF-2: MacScope's edge kinds map onto Lumen's (taken / not taken / unconditional / call).
final class GraphEdgeKindMappingTests: XCTestCase {
    func testConditionalSourcesNeedBothABranchAndAFallthrough() {
        let sources = LumenGraphEdgeKind.conditionalSources([
            (from: 0x10, kind: "branch"), (from: 0x10, kind: "fallthrough"),   // conditional jump
            (from: 0x20, kind: "branch"),                                      // unconditional jump
            (from: 0x30, kind: "fallthrough"),                                 // implicit fall-through
            (from: 0x40, kind: "call"), (from: 0x40, kind: "fallthrough"),
        ])
        XCTAssertEqual(sources, [0x10])
    }

    func testKindsMapAsAgreedWithTheLumenSession() {
        XCTAssertEqual(LumenGraphEdgeKind.macScope(kind: "branch", isConditionalSource: true), .taken)
        XCTAssertEqual(LumenGraphEdgeKind.macScope(kind: "fallthrough", isConditionalSource: true), .notTaken)
        XCTAssertEqual(LumenGraphEdgeKind.macScope(kind: "branch", isConditionalSource: false), .unconditional)
        XCTAssertEqual(LumenGraphEdgeKind.macScope(kind: "fallthrough", isConditionalSource: false), .unconditional)
        XCTAssertEqual(LumenGraphEdgeKind.macScope(kind: "switch", isConditionalSource: true), .unconditional)
        XCTAssertEqual(LumenGraphEdgeKind.macScope(kind: "call", isConditionalSource: false), .call)
        XCTAssertEqual(LumenGraphEdgeKind.macScope(kind: "reference", isConditionalSource: true), .call)
        XCTAssertEqual(LumenGraphEdgeKind.macScope(kind: "", isConditionalSource: false), .unconditional)
    }
}
