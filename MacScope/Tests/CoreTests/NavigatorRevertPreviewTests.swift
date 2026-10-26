import Foundation
import XCTest
@testable import MacScope

/// Revert preview: the preview reports exactly what the revert then does (facts lost through
/// derivations, annotations made stale, frontier items raised), mutates nothing, and carries the
/// revert's refusal with empty lists. Hermetic: every record is built in memory.
final class NavigatorRevertPreviewTests: XCTestCase {
    private let toolchain = "toolchain-key/1|test"
    private let image = "nouuid/aaaaaaaaaaaaaaaa"

    private func subject(_ ref: String = "0x1000") -> NavigatorSubject {
        NavigatorSubject(kind: "address", ref: ref, image: image)
    }

    /// A proven fact cites a certificate by content hash; the fixture's hash names no certificate,
    /// which the form check accepts (resolution is the producer landing's job).
    private let certificateRef = "sha256:" + String(repeating: "0", count: 64)

    private func fact(_ predicate: String, _ value: NavigatorJSONValue, status: String, rule: String = "test.rule",
                      tier: Int64? = nil, derivedFrom: [[String]]? = nil) throws -> NavigatorFact {
        var provenance = [NavigatorProvenance(kind: "loaderRecord", ref: "loader 0x1000", rule: rule, ruleVersion: "1")]
        if status == "proven" {
            provenance.append(NavigatorProvenance(kind: "proofCertificate", ref: certificateRef))
        }
        return try NavigatorFact.make(subject: subject(), predicate: predicate, value: value, status: status,
                                      provenance: provenance, toolchain: toolchain, tier: tier, derivedFrom: derivedFrom)
    }

    private func result(_ facts: [NavigatorFact]) -> NavigatorPrimitiveResult {
        NavigatorPrimitiveResult(primitive: "test.primitive", primitiveVersion: "1",
                                 subject: NavigatorSubject(kind: "image", ref: image), budget: [:], facts: facts)
    }

    /// A proven fact P, a derived fact D resting only on P, and an analyst annotation citing P.
    private func fixture() throws -> (store: NavigatorContractStore, proven: NavigatorFact, derived: NavigatorFact,
                                      note: NavigatorAnnotation) {
        var store = NavigatorContractStore(toolchain: toolchain)
        let proven = try fact("hasName", .string("main"), status: "proven")
        let derived = try fact("hasType", .string("int"), status: "derived", rule: "test.derive", tier: 1,
                               derivedFrom: [[proven.id]])
        XCTAssertNil(store.add(result([proven]), session: "producer"))
        XCTAssertNil(store.add(result([derived]), session: "rules"))
        let note = try NavigatorAnnotation.make(session: "analyst", seq: 0, author: "analyst", action: "rename",
                                                subject: subject(), predicate: "hasName", value: .string("main"),
                                                cites: [proven.id])
        XCTAssertNil(store.accept(note))
        XCTAssertEqual(Set(store.liveFacts().keys), [proven.id, derived.id])
        XCTAssertEqual(store.liveAnnotations().map(\.id), [note.id])
        return (store, proven, derived, note)
    }

    func testPreviewMatchesTheRevertAndMutatesNothing() throws {
        let (store, proven, derived, note) = try fixture()
        let staleItem = try NavigatorFrontierItem.make(subject: subject(), gap: "staleAnnotation",
                                                       detail: "\(note.id) cites a reverted fact", toolchain: toolchain)
        let stateBefore = store.state()
        let frontierBefore = store.frontier().map(\.id)

        let preview = store.preview(revert: proven.revert)
        XCTAssertNil(preview.refusal)
        XCTAssertEqual(preview.factsLost, [derived.id, proven.id].sortedByScalars())
        XCTAssertEqual(preview.annotationsAffected, [note.id])
        XCTAssertEqual(preview.frontierRaised, [staleItem.id])
        XCTAssertEqual(store.state(), stateBefore, "a preview mutates nothing")

        var reverted = store
        XCTAssertNil(reverted.revert(proven.revert, session: "nav"))
        let liveAfter = reverted.liveFacts()
        XCTAssertEqual(Array(store.liveFacts().keys).filter { liveAfter[$0] == nil }.sortedByScalars(), preview.factsLost)
        XCTAssertNotNil(reverted.allFacts()[derived.id], "the derived fact is kept, only no longer live")
        XCTAssertTrue(reverted.liveAnnotations().isEmpty)
        XCTAssertEqual(reverted.staleAnnotations().map(\.id), preview.annotationsAffected)
        XCTAssertEqual(reverted.frontier().map(\.id).filter { !frontierBefore.contains($0) }, preview.frontierRaised)
    }

    func testPreviewOfAnAnnotationRevertAffectsOnlyThatAnnotation() throws {
        let (store, _, _, note) = try fixture()
        let preview = store.preview(revert: note.revert)
        XCTAssertNil(preview.refusal)
        XCTAssertTrue(preview.factsLost.isEmpty)
        XCTAssertEqual(preview.annotationsAffected, [note.id])
        XCTAssertTrue(preview.frontierRaised.isEmpty)
        XCTAssertEqual(store.annotations()[note.id]?.reverted, false)
    }

    func testPreviewCarriesTheRefusalWithEmptyLists() throws {
        var (store, _, _, _) = try fixture()
        let authoritative = try fact("isFunctionStart", .bool(true), status: "authoritative")
        XCTAssertNil(store.add(result([authoritative]), session: "producer"))

        let notReversible = store.preview(revert: authoritative.revert)
        XCTAssertEqual(notReversible.refusal?.code, "notReversible")
        XCTAssertEqual(notReversible.factsLost, [])
        XCTAssertEqual(notReversible.annotationsAffected, [])
        XCTAssertEqual(notReversible.frontierRaised, [])

        XCTAssertEqual(store.preview(revert: "revert:not-an-id").refusal?.code, "malformedInput")
        let absent = try fact("hasType", .string("long"), status: "proven")
        XCTAssertEqual(store.preview(revert: absent.revert).refusal?.code, "unknownFact")

        var trial = store
        XCTAssertEqual(trial.revert(authoritative.revert, session: "nav")?.code, notReversible.refusal?.code,
                       "the preview's refusal is the revert's refusal")
        XCTAssertNotNil(trial.liveFacts()[authoritative.id])
    }
}
