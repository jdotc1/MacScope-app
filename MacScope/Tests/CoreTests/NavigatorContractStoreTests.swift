import XCTest
@testable import MacScope

final class NavigatorContractStoreTests: XCTestCase {
    private let subject = NavigatorSubject(kind: "function", ref: "0x1000", image: "fixture")

    private func derived(_ predicate: String, _ value: String, from parents: [[String]]) throws -> NavigatorFact {
        try NavigatorFact.make(
            subject: subject,
            predicate: predicate,
            value: .string(value),
            status: "derived",
            provenance: [NavigatorProvenance(kind: "rule", ref: predicate, rule: predicate, ruleVersion: "1")],
            toolchain: "test",
            tier: 1,
            derivedFrom: parents
        )
    }

    func testAddRejectsSelfAndIntraResultDerivationCyclesWithoutJournaling() throws {
        let seedA = try derived("hasName", "a", from: [["f-00000000000000000000000000000000"]])
        let selfDerived = try derived("hasName", "a", from: [[seedA.id]])
        var store = NavigatorContractStore(toolchain: "test")
        let selfResult = NavigatorPrimitiveResult(
            primitive: "fixture", primitiveVersion: "1", subject: subject, budget: [:], facts: [selfDerived]
        )

        XCTAssertEqual(store.add(selfResult, session: "self")?.code, "preconditionFailed")
        XCTAssertTrue(store.journal.isEmpty)

        let seedB = try derived("hasType", "b", from: [[seedA.id]])
        let cycleA = try derived("hasName", "a", from: [[seedB.id]])
        let cycleResult = NavigatorPrimitiveResult(
            primitive: "fixture", primitiveVersion: "1", subject: subject, budget: [:], facts: [cycleA, seedB]
        )

        XCTAssertEqual(store.add(cycleResult, session: "pair")?.code, "preconditionFailed")
        XCTAssertTrue(store.journal.isEmpty)
    }

    func testFactMakeRejectsRuleWithoutRuleVersionBeforeDerivingID() {
        XCTAssertThrowsError(
            try NavigatorFact.make(
                subject: subject,
                predicate: "hasName",
                value: .string("name"),
                status: "authoritative",
                provenance: [NavigatorProvenance(kind: "rule", ref: "fixture", rule: "fixture")],
                toolchain: "test"
            )
        ) { error in
            guard let contractError = error as? NavigatorContractError else {
                return XCTFail("expected NavigatorContractError, got \(error)")
            }
            XCTAssertEqual(contractError.reasons, ["fact.provenance[0]: rule and ruleVersion go together"])
        }
    }

    func testRestorePreservesSuppliedAnnotationGapFrontierAndRegeneratesDerivedItemsOnce() throws {
        let nfc = "\u{e9}"
        let nfd = "e\u{301}"
        let staleEvidence = try NavigatorFact.make(
            subject: subject, predicate: "isFunctionStart", value: .bool(true), status: "proven",
            provenance: [NavigatorProvenance(kind: "proofCertificate", ref: "sha256:" + String(repeating: "0", count: 64))],
            toolchain: "test"
        )
        let liveEvidence = try NavigatorFact.make(
            subject: subject, predicate: "callsTarget", value: .string("target"), status: "authoritative",
            provenance: [NavigatorProvenance(kind: "loaderRecord", ref: "live")], toolchain: "test"
        )
        let annotations = try [
            NavigatorAnnotation.make(
                session: "navigator", seq: 0, author: "navigator", action: "rename", subject: subject,
                predicate: "hasName", value: .string("stale"), cites: [staleEvidence.id], rationale: "test"
            ),
            NavigatorAnnotation.make(
                session: "navigator", seq: 1, author: "navigator", action: "rename", subject: subject,
                predicate: "hasName", value: .string("left"), cites: [liveEvidence.id], rationale: "test"
            ),
            NavigatorAnnotation.make(
                session: "navigator", seq: 2, author: "navigator", action: "rename", subject: subject,
                predicate: "hasName", value: .string("right"), cites: [liveEvidence.id], rationale: "test"
            ),
        ]
        let supplied = try [
            NavigatorFrontierItem.make(
                subject: subject, gap: "staleAnnotation",
                detail: "\(annotations[0].id) cites a reverted fact", toolchain: nfc
            ),
            NavigatorFrontierItem.make(
                subject: subject, gap: "conflictingAnnotations", detail: "supplied conflict", toolchain: nfd
            ),
        ]
        var source = NavigatorContractStore(toolchain: nfd, baseFacts: [staleEvidence, liveEvidence], baseFrontier: supplied)
        for annotation in annotations { XCTAssertNil(source.accept(annotation)) }
        XCTAssertNil(source.revert(staleEvidence.revert, session: "revert"))

        let state = source.state()
        let restored = NavigatorContractStore(state: state)

        XCTAssertEqual(restored.frontier(), state.frontier)
        XCTAssertEqual(
            try NavigatorJSONCanonical.encode(restored.frontier().first { $0.id == supplied[0].id }!.json).utf8.map { $0 },
            try NavigatorJSONCanonical.encode(supplied[0].json).utf8.map { $0 }
        )
    }
}
