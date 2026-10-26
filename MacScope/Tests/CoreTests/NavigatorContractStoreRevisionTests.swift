import XCTest
@testable import MacScope

/// Contract store revision 1.1: operations and refusals, annotation premises, provenance union,
/// the bounded journal, `conflictingFacts`, and the vocabulary terms the revision appends.
/// Hermetic: every record is built in memory.
final class NavigatorContractStoreRevisionTests: XCTestCase {
    private let toolchain = "toolchain-key/1|test"
    private let image = "nouuid/aaaaaaaaaaaaaaaa"

    private func subject(_ ref: String = "0x1000") -> NavigatorSubject {
        NavigatorSubject(kind: "address", ref: ref, image: image)
    }

    private func provenance(_ ref: String = "loader 0x1000", rule: String = "test.rule") -> [NavigatorProvenance] {
        [NavigatorProvenance(kind: "loaderRecord", ref: ref, rule: rule, ruleVersion: "1")]
    }

    private func fact(_ predicate: String, _ value: NavigatorJSONValue, status: String = "authoritative",
                      ref: String = "0x1000", provenance entries: [NavigatorProvenance]? = nil,
                      tier: Int64? = nil, derivedFrom: [[String]]? = nil) throws -> NavigatorFact {
        try NavigatorFact.make(subject: subject(ref), predicate: predicate, value: value, status: status,
                               provenance: entries ?? provenance(), toolchain: toolchain, tier: tier,
                               derivedFrom: derivedFrom)
    }

    private func result(_ facts: [NavigatorFact], frontier: [NavigatorFrontierItem] = []) -> NavigatorPrimitiveResult {
        NavigatorPrimitiveResult(primitive: "test.primitive", primitiveVersion: "1",
                                 subject: NavigatorSubject(kind: "image", ref: image), budget: [:],
                                 facts: facts, frontier: frontier)
    }

    // MARK: - Operations and refusals

    func testAddAcceptRevertAndUndoSession() throws {
        var store = NavigatorContractStore(toolchain: toolchain)
        let name = try fact("hasName", .string("main"))
        XCTAssertNil(store.add(result([name]), session: "producer"))
        XCTAssertNotNil(store.liveFacts()[name.id])

        let agreeing = try NavigatorAnnotation.make(
            session: "nav", seq: 0, author: "navigator", action: "rename", subject: subject(), predicate: "hasName",
            value: .string("main"), cites: [name.id], rationale: "matches the exported symbol")
        XCTAssertNil(store.accept(agreeing))
        XCTAssertEqual(store.liveAnnotations().map(\.id), [agreeing.id])
        XCTAssertEqual(store.accept(agreeing)?.code, "preconditionFailed")

        let contradicting = try NavigatorAnnotation.make(
            session: "nav", seq: 1, author: "navigator", action: "rename", subject: subject(), predicate: "hasName",
            value: .string("start"), cites: [name.id], rationale: "a guess")
        XCTAssertEqual(store.accept(contradicting)?.code, "conflictsWithAuthority")

        let unsupported = try NavigatorAnnotation.make(
            session: "nav", seq: 2, author: "navigator", action: "setType", subject: subject(), predicate: "hasType",
            value: .string("int"), cites: [try fact("hasType", .string("int")).id], rationale: "cites a fact never added")
        XCTAssertEqual(store.accept(unsupported)?.code, "unknownFact")

        XCTAssertEqual(store.revert(name.revert, session: "nav")?.code, "notReversible")
        XCTAssertEqual(store.revert("revert:not-an-id", session: "nav")?.code, "malformedInput")

        XCTAssertNil(store.revert(agreeing.revert, session: "nav"))
        XCTAssertEqual(store.annotations()[agreeing.id]?.reverted, true)
        XCTAssertTrue(store.liveAnnotations().isEmpty)
        XCTAssertEqual(store.revert(agreeing.revert, session: "nav")?.code, "unknownFact")

        XCTAssertTrue(store.isUndoable("nav"))
        XCTAssertEqual(try store.undoSession("nav").get(), 2)
        XCTAssertNil(store.annotations()[agreeing.id])
        XCTAssertNotNil(store.liveFacts()[name.id])
        XCTAssertEqual(try store.undoSession("nav").get(), 0)
    }

    func testDerivationMayRestOnAnAcceptedAnnotationPremise() throws {
        var store = NavigatorContractStore(toolchain: toolchain)
        let premise = NavigatorAnnotation.premise(session: "analyst", seq: 0)
        XCTAssertEqual(premise, "ann:analyst/0")
        let derived = try fact("hasType", .string("int"), status: "derived", tier: 1, derivedFrom: [[premise]])

        XCTAssertEqual(store.add(result([derived]), session: "rules")?.code, "unknownFact")
        XCTAssertTrue(store.allFacts().isEmpty)

        let analyst = try NavigatorAnnotation.make(
            session: "analyst", seq: 0, author: "analyst", action: "setType", subject: subject(), predicate: "hasType",
            value: .string("int"))
        XCTAssertNil(store.accept(analyst))
        XCTAssertEqual(store.livePremises(), [premise])
        XCTAssertNil(store.add(result([derived]), session: "rules"))
        XCTAssertNotNil(store.liveFacts()[derived.id])

        XCTAssertNil(store.revert(analyst.revert, session: "analyst"))
        XCTAssertTrue(store.livePremises().isEmpty)
        XCTAssertNil(store.liveFacts()[derived.id], "a derivation whose only premise was reverted is not live")
        XCTAssertNotNil(store.allFacts()[derived.id])
    }

    func testDerivedFactRestingOnACandidateIsRefused() throws {
        var store = NavigatorContractStore(toolchain: toolchain)
        let candidate = try fact("hasType", .object(["alternatives": .array([.string("int"), .string("long")])]),
                                 status: "candidate", tier: 2)
        let derived = try fact("hasType", .string("int"), status: "derived", provenance: provenance(rule: "test.derive"),
                               tier: 1, derivedFrom: [[candidate.id]])
        XCTAssertEqual(store.add(result([candidate, derived]), session: "rules")?.code, "preconditionFailed")
        XCTAssertTrue(store.allFacts().isEmpty)
    }

    // MARK: - Provenance union

    func testEqualFactsUnionTheirProvenance() throws {
        var store = NavigatorContractStore(toolchain: toolchain)
        let first = try fact("hasName", .string("main"), provenance: provenance("loader A"))
        let second = try fact("hasName", .string("main"), provenance: provenance("loader B"))
        XCTAssertEqual(first.id, second.id, "the id digests the rule key, not the provenance ref")

        XCTAssertNil(store.add(result([first]), session: "one"))
        XCTAssertNil(store.add(result([second]), session: "two"))
        XCTAssertNil(store.add(result([first]), session: "three"))
        XCTAssertEqual(store.liveFacts().count, 1)
        XCTAssertEqual(store.allFacts()[first.id]?.provenance.map(\.ref), ["loader A", "loader B"])
        XCTAssertTrue(NavigatorContractValidator.validateState(store.state().json).isEmpty)

        XCTAssertEqual(try store.undoSession("two").get(), 1)
        XCTAssertEqual(store.allFacts()[first.id]?.provenance.map(\.ref), ["loader A"])

        let merged = NavigatorContractStore.merge(first, second)
        XCTAssertEqual(merged.id, first.id)
        XCTAssertEqual(merged.provenance.map(\.ref), ["loader A", "loader B"])
        XCTAssertEqual(NavigatorContractStore.merge(merged, first).provenance, merged.provenance)
    }

    // MARK: - Bounded journal

    func testJournalBoundFoldsTheOldestEntryAndRefusesItsUndo() throws {
        XCTAssertEqual(NavigatorContractStore.journalBound, 1024)
        XCTAssertEqual(NavigatorContractStore(toolchain: toolchain).journalLimit, 1024)
        XCTAssertEqual(NavigatorContractStore(toolchain: toolchain, journalLimit: 0).journalLimit, 1)

        var store = NavigatorContractStore(toolchain: toolchain, journalLimit: 2)
        let a = try fact("hasName", .string("a"), ref: "0x1000")
        let b = try fact("hasName", .string("b"), ref: "0x2000")
        let c = try fact("hasName", .string("c"), ref: "0x3000")
        XCTAssertNil(store.add(result([a]), session: "a"))
        XCTAssertNil(store.add(result([b]), session: "b"))
        XCTAssertNil(store.evictedBefore)

        XCTAssertNil(store.add(result([c]), session: "c"))
        XCTAssertEqual(store.journal.count, 2)
        XCTAssertEqual(store.evictedBefore, 1)
        XCTAssertEqual(store.baseFacts.map(\.id), [a.id])
        XCTAssertEqual(Set(store.liveFacts().keys), [a.id, b.id, c.id])

        var unbounded = NavigatorContractStore(toolchain: toolchain)
        XCTAssertNil(unbounded.add(result([a]), session: "a"))
        XCTAssertNil(unbounded.add(result([b]), session: "b"))
        XCTAssertNil(unbounded.add(result([c]), session: "c"))
        let keys = [(subject("0x1000"), "hasName"), (subject("0x2000"), "hasName"), (subject("0x3000"), "hasName")]
        XCTAssertEqual(store.snapshot(keys), unbounded.snapshot(keys), "folding changes no view")
        XCTAssertEqual(store.state(), unbounded.state())

        XCTAssertFalse(store.isUndoable("a"))
        switch store.undoSession("a") {
        case .success: XCTFail("a folded session is not reversible")
        case .failure(let refusal): XCTAssertEqual(refusal.code, "notReversible")
        }
        XCTAssertNotNil(store.liveFacts()[a.id])

        XCTAssertTrue(store.isUndoable("b"))
        XCTAssertEqual(try store.undoSession("b").get(), 1)
        XCTAssertEqual(Set(store.liveFacts().keys), [a.id, c.id])
    }

    func testFoldedAcceptAndRevertKeepTheirEffect() throws {
        var store = NavigatorContractStore(toolchain: toolchain, journalLimit: 1)
        let analyst = try NavigatorAnnotation.make(
            session: "analyst", seq: 0, author: "analyst", action: "rename", subject: subject(), predicate: "hasName",
            value: .string("entry"))
        XCTAssertNil(store.accept(analyst))
        XCTAssertNil(store.revert(analyst.revert, session: "analyst"))
        XCTAssertEqual(store.baseAnnotations.map(\.id), [analyst.id])
        XCTAssertEqual(store.annotations()[analyst.id]?.reverted, true)
        XCTAssertTrue(store.liveAnnotations().isEmpty)
        XCTAssertFalse(store.isUndoable("analyst"))
    }

    // MARK: - conflictingFacts

    func testCompetingAuthoritativeValuesRaiseConflictingFactsUntilOneGoesStale() throws {
        var store = NavigatorContractStore(toolchain: toolchain)
        let main = try fact("hasName", .string("main"), provenance: provenance(rule: "test.symbols"))
        let start = try fact("hasName", .string("start"), provenance: provenance(rule: "test.metadata"))
        XCTAssertNil(store.add(result([main]), session: "p1"))
        XCTAssertNil(store.add(result([start]), session: "p2"))

        let conflicts = store.frontier().filter { $0.gap == "conflictingFacts" }
        XCTAssertEqual(conflicts.count, 1)
        let item = try XCTUnwrap(conflicts.first)
        XCTAssertEqual(item.blockedBy, [main.id, start.id].sortedByScalars())
        XCTAssertEqual(item.subject, subject())
        XCTAssertEqual(item.detail, "hasName: \"main\" | \"start\"")
        XCTAssertEqual(item.primitives.map(\.name), ["revert"])
        XCTAssertTrue(NavigatorContractValidator.validateState(store.state().json).isEmpty)

        let shown = store.display(subject(), "hasName")
        XCTAssertEqual(shown.source, "authoritative")
        XCTAssertEqual(shown.values, ["\"main\"", "\"start\""])
        XCTAssertTrue(shown.conflict)

        XCTAssertEqual(store.markStale([start.id]), [start.id])
        XCTAssertEqual(store.markStale([start.id, "f-00000000000000000000000000000000"]), [])
        XCTAssertNil(store.liveFacts()[start.id])
        XCTAssertTrue(store.frontier().filter { $0.gap == "conflictingFacts" }.isEmpty)
        XCTAssertFalse(store.display(subject(), "hasName").conflict)

        XCTAssertNil(store.add(result([start]), session: "p3"))
        XCTAssertFalse(store.staleGeneration.contains(start.id), "re-asserting a fact clears its stale mark")
        XCTAssertEqual(store.frontier().filter { $0.gap == "conflictingFacts" }.count, 1)

        XCTAssertEqual(try store.undoSession("p2").get(), 1)
        XCTAssertEqual(try store.undoSession("p3").get(), 1)
        XCTAssertTrue(store.frontier().filter { $0.gap == "conflictingFacts" }.isEmpty)
    }

    func testMultiValuedAndCandidateFactsRaiseNoConflict() throws {
        var store = NavigatorContractStore(toolchain: toolchain)
        let first = try fact("callsTarget", .string("0x2000"))
        let second = try fact("callsTarget", .string("0x3000"))
        let candidate = try fact("hasType", .object(["alternatives": .array([.string("int"), .string("long")])]),
                                 status: "candidate", tier: 2)
        XCTAssertNil(store.add(result([first, second, candidate]), session: "p"))
        XCTAssertTrue(store.frontier().filter { $0.gap == "conflictingFacts" }.isEmpty)
        XCTAssertEqual(store.display(subject(), "callsTarget").values, ["\"0x2000\"", "\"0x3000\""])
        XCTAssertFalse(store.display(subject(), "callsTarget").conflict)
        XCTAssertEqual(NavigatorContractStore.conflictStatuses, ["authoritative", "proven", "derived"])
    }

    func testRestoredStateReDerivesStoreRaisedItems() throws {
        var store = NavigatorContractStore(toolchain: toolchain)
        XCTAssertNil(store.add(result([try fact("hasName", .string("main"), provenance: provenance(rule: "r.a")),
                                       try fact("hasName", .string("start"), provenance: provenance(rule: "r.b"))]),
                               session: "p"))
        let state = store.state()
        XCTAssertEqual(state.frontier.filter { $0.gap == "conflictingFacts" }.count, 1)
        let restored = NavigatorContractStore(state: state)
        XCTAssertTrue(restored.baseFrontier.isEmpty, "a store-raised item the restored store regenerates is not kept twice")
        XCTAssertEqual(restored.state(), state)
        XCTAssertEqual(restored.frontier().filter { $0.gap == "conflictingFacts" }.count, 1)
    }

    func testRestoreAppliesStaleMarksBeforeReconcilingThePersistedFrontier() throws {
        var store = NavigatorContractStore(toolchain: toolchain)
        let a = try fact("hasName", .string("main"), provenance: provenance(rule: "r.a"))
        let b = try fact("hasName", .string("start"), provenance: provenance(rule: "r.b"))
        XCTAssertNil(store.add(result([a, b]), session: "p"))
        let state = store.state()
        XCTAssertEqual(state.frontier.map(\.gap), ["conflictingFacts"])

        // Restoring with `b` stale: the conflict no longer holds, so the persisted item is not
        // regenerated and, having a stale blocker, is not shown; re-asserting `b` brings the conflict
        // back exactly once, without a duplicate from the persisted copy.
        var restored = NavigatorContractStore(state: state, staleGeneration: [b.id])
        XCTAssertEqual(restored.staleGeneration, [b.id])
        XCTAssertEqual(Array(restored.liveFacts().keys), [a.id])
        XCTAssertTrue(restored.frontier().isEmpty)
        XCTAssertNil(restored.add(result([b]), session: "p2"))
        XCTAssertTrue(restored.staleGeneration.isEmpty)
        XCTAssertEqual(restored.frontier().filter { $0.gap == "conflictingFacts" }.count, 1)
        XCTAssertEqual(restored.frontier(), state.frontier)

        // An unknown stale id is ignored, as `markStale` ignores it.
        XCTAssertTrue(NavigatorContractStore(state: state, staleGeneration: ["not-a-fact"]).staleGeneration.isEmpty)
    }

    // MARK: - Vocabulary 1.1

    func testVocabularyRevisionOneOneTerms() {
        XCTAssertEqual(NavigatorContractVocabulary.schemaVersion, 1)
        XCTAssertEqual(NavigatorContractVocabulary.predicates.count, 22)
        XCTAssertEqual(NavigatorContractVocabulary.gaps.count, 25)
        XCTAssertEqual(NavigatorContractVocabulary.refusals.count, 10)
        XCTAssertEqual(Set(NavigatorContractVocabulary.gaps).count, NavigatorContractVocabulary.gaps.count)
        for gap in ["conflictingFacts", "budgetExceeded", "producerIncomplete", "staleAnnotation"] {
            XCTAssertTrue(NavigatorContractVocabulary.gaps.containsExactly(gap), gap)
        }
        for refusal in ["budgetExceeded", "notReversible", "conflictsWithAuthority"] {
            XCTAssertTrue(NavigatorContractVocabulary.refusals.containsExactly(refusal), refusal)
        }
        XCTAssertEqual(NavigatorContractVocabulary.predicates["methodTableEntry"]?.multi, true)
        XCTAssertEqual(NavigatorContractVocabulary.predicates["conformanceMethod"]?.multi, true)
        XCTAssertEqual(NavigatorContractVocabulary.predicates["metadataAccessorOf"]?.value,
                       NavigatorContractVocabulary.ValueKind.string)
        XCTAssertEqual(NavigatorContractVocabulary.predicates["pointerAuthKey"]?.value,
                       NavigatorContractVocabulary.ValueKind.object)
        XCTAssertEqual(NavigatorContractVocabulary.budgetKeys, ["instructions", "bytes", "solverSteps", "wallMillis"])
        XCTAssertEqual(NavigatorContractVocabulary.asJSON["predicates"]?.objectValue?.count, 22)
        XCTAssertEqual(NavigatorContractVocabulary.asJSON["gaps"]?.arrayValue?.count, 25)
        XCTAssertNil(NavigatorContractVocabulary.predicate(named: "has\u{0}Name"))
    }
}
