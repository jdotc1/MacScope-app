import Foundation
import XCTest
@testable import MacScope

/// Lifecycle legality for retract, stale and readmit; the nil-tolerant citation encoding; the v1 envelope
/// and package paths; and the pure support check against hand-built navigator stores. No real binary,
/// store wiring or inference is involved.
private struct LifecycleHarness {
    let record: AnalystFindingRecord
    private(set) var lifecycle: AnalystFindingLifecycle

    init(_ record: AnalystFindingRecord) { self.record = record; lifecycle = record.authoredLifecycle }

    mutating func apply(_ operation: AnalystFindingHistoryOperation) throws {
        lifecycle = try lifecycle.applying(operation, identity: record.revisionIdentity,
            initialText: record.content.candidateText, expected: lifecycle.state.vector,
            now: Date(timeIntervalSinceReferenceDate: 100 + Double(lifecycle.history.count)))
    }
    func applied(_ operation: AnalystFindingHistoryOperation) throws -> AnalystFindingLifecycle {
        var copy = self
        try copy.apply(operation)
        return copy.lifecycle
    }
    var revised: AnalystFindingRecord { record.revising(with: lifecycle) }
}

private func XCTAssertFindingError(_ expected: AnalystFindingError, file: StaticString = #filePath, line: UInt = #line,
                                   _ body: () throws -> Void) {
    XCTAssertThrowsError(try body(), file: file, line: line) {
        XCTAssertEqual($0 as? AnalystFindingError, expected, file: file, line: line)
    }
}

private enum NavigatorFixtures {
    static let toolchain = "fixture-toolchain"
    static func generation(_ image: String = "image-A", key: String = "key-1") -> NavigatorGeneration {
        .init(imageIdentity: image, inputKey: key, knowledgeVersion: "kv-1")
    }
    static func subject(_ ref: String) -> NavigatorSubject { .init(kind: "type", ref: ref, image: "Fixture") }
    static func fact(_ ref: String, predicate: String = "hasName", name: String,
                     generation: NavigatorGeneration? = NavigatorFixtures.generation()) throws -> NavigatorFact {
        try NavigatorFact.make(subject: subject(ref), predicate: predicate, value: .string(name), status: "authoritative",
            provenance: [.init(kind: "loaderRecord", ref: "loader-\(ref)-\(name)")], toolchain: toolchain,
            generation: generation)
    }
    static func reversibleFact(_ ref: String, name: String, from premise: NavigatorFact) throws -> NavigatorFact {
        try NavigatorFact.make(subject: subject(ref), predicate: "hasName", value: .string(name), status: "derived",
            provenance: [.init(kind: "rule", ref: "r", rule: "ruleA", ruleVersion: "1")],
            toolchain: toolchain, tier: 1, derivedFrom: [[premise.id]], generation: generation())
    }
    static func store(_ facts: [NavigatorFact]) -> NavigatorContractStore {
        NavigatorContractStore(toolchain: toolchain, baseFacts: facts)
    }
    static func source(_ stores: [ImageSlot: NavigatorContractStore],
                       identities: [ImageSlot: String]? = nil) -> AnalystFindingSupportSource {
        .init(stores: stores, imageIdentities: identities ?? stores.mapValues { _ in "image-A" })
    }
    static func citing(_ record: AnalystFindingRecord, _ citations: [FactCitation], id: UUID = UUID()) -> AnalystFindingRecord {
        .init(id: id, workspaceID: record.workspaceID, documentID: record.documentID, createdAt: record.createdAt,
              content: record.content, citesFacts: citations)
    }
}

@MainActor
final class AnalystFindingStandingTests: XCTestCase {
    private func makeRecord() throws -> AnalystFindingRecord {
        try AnalystFindingEnvelopeFixture.make(workspaceID: UUID(), documentID: UUID()).records[0]
    }

    // MARK: - retract

    func testRetractRecordsTrimmedReasonAndLeavesTextRevisionsAndReviewUntouched() throws {
        var harness = LifecycleHarness(try makeRecord())
        try harness.apply(.review(.reviewed))
        let before = harness.lifecycle.state
        try harness.apply(.retract("  The conclusion was wrong \n"))
        let state = harness.lifecycle.state
        XCTAssertEqual(harness.lifecycle.standing, .retracted(reason: "The conclusion was wrong"))
        XCTAssertEqual(state.text, before.text)
        XCTAssertEqual(state.contentRevision, before.contentRevision)
        XCTAssertEqual(state.reviewRevision, before.reviewRevision)
        XCTAssertEqual(state.selectedReviewRevision, before.selectedReviewRevision)
        XCTAssertTrue(harness.lifecycle.isReviewCurrent)
        XCTAssertEqual(harness.lifecycle.history.map(\.operation.kind), [.review, .retract])
        XCTAssertEqual(harness.lifecycle.history[1].before.retractionReason, nil)
        XCTAssertEqual(harness.lifecycle.history[1].after.retractionReason, "The conclusion was wrong")
    }

    func testRetractRefusesEmptyOversizedAndRepeatedReasons() throws {
        var harness = LifecycleHarness(try makeRecord())
        XCTAssertFindingError(.invalidContent) { _ = try harness.applied(.retract("")) }
        XCTAssertFindingError(.invalidContent) { _ = try harness.applied(.retract(" \n\t ")) }
        let longest = String(repeating: "a", count: AnalystFindingLifecycle.maximumReasonBytes)
        XCTAssertNoThrow(try harness.applied(.retract(longest)))
        XCTAssertFindingError(.invalidContent) { _ = try harness.applied(.retract(longest + "a")) }
        XCTAssertFindingError(.invalidContent) {
            // 513 two-byte scalars are 1,026 bytes.
            _ = try harness.applied(.retract(String(repeating: "\u{00E9}", count: 513)))
        }
        try harness.apply(.retract("first"))
        XCTAssertFindingError(.invalidStanding) { try harness.apply(.retract("second")) }
        XCTAssertEqual(harness.lifecycle.history.count, 1, "A refused operation must not enter history")
    }

    func testRetractedFindingIsFrozenUntilTheRetractionIsUndone() throws {
        var harness = LifecycleHarness(try makeRecord())
        try harness.apply(.retract("withdrawn"))
        XCTAssertFindingError(.retracted) { try harness.apply(.edit("new text")) }
        XCTAssertFindingError(.retracted) { try harness.apply(.review(.reviewed)) }
        XCTAssertFindingError(.retracted) { try harness.apply(.readmit) }
        try harness.apply(.undo(1))
        XCTAssertEqual(harness.lifecycle.standing, .active)
        XCTAssertEqual(harness.lifecycle.state.text, harness.record.content.candidateText)
        try harness.apply(.redo(1))
        XCTAssertEqual(harness.lifecycle.standing, .retracted(reason: "withdrawn"))
        try harness.apply(.undo(1))
        try harness.apply(.edit("allowed again"))
        XCTAssertEqual(harness.lifecycle.state.text, "allowed again")
        XCTAssertEqual(harness.lifecycle.history.map(\.operation.kind), [.retract, .undo, .redo, .undo, .edit])
    }

    func testRetractIsLegalFromStaleAndUndoKeepsTheStaleMark() throws {
        var harness = LifecycleHarness(try makeRecord())
        try harness.apply(.stale(.factStale))
        try harness.apply(.retract("withdrawn"))
        XCTAssertEqual(harness.lifecycle.standing, .retracted(reason: "withdrawn"), "Retraction outranks staleness")
        XCTAssertEqual(harness.lifecycle.state.staleReason, .factStale)
        try harness.apply(.undo(2))
        XCTAssertEqual(harness.lifecycle.standing, .stale(.factStale))
    }

    // MARK: - stale

    func testStaleMarkChangesStandingOnlyAndIsLegalOncePerStandingCycle() throws {
        var harness = LifecycleHarness(try makeRecord())
        try harness.apply(.edit("Authored text"))
        let before = harness.lifecycle.state
        try harness.apply(.stale(.imageChanged))
        let state = harness.lifecycle.state
        XCTAssertEqual(harness.lifecycle.standing, .stale(.imageChanged))
        XCTAssertEqual(state.text, before.text)
        XCTAssertEqual(state.contentRevision, before.contentRevision)
        XCTAssertEqual(state.reviewRevision, before.reviewRevision)
        XCTAssertFindingError(.invalidStanding) { try harness.apply(.stale(.factStale)) }
        XCTAssertEqual(harness.lifecycle.state.staleReason, .imageChanged, "The first reason is kept")
    }

    func testStaleMarkIsASystemActionWithNoUndoStackEffect() throws {
        var harness = LifecycleHarness(try makeRecord())
        try harness.apply(.edit("A"))              // 1
        try harness.apply(.stale(.premiseReverted)) // 2
        XCTAssertFindingError(.unsupportedRevisionState) { try harness.apply(.undo(2)) }
        try harness.apply(.undo(1))                // The edit is still the top of the stack.
        XCTAssertEqual(harness.lifecycle.state.text, harness.record.content.candidateText)
        XCTAssertEqual(harness.lifecycle.standing, .stale(.premiseReverted), "Undoing an edit does not clear a stale mark")
        try harness.apply(.redo(1))
        XCTAssertEqual(harness.lifecycle.state.text, "A")
        XCTAssertEqual(harness.lifecycle.standing, .stale(.premiseReverted))
    }

    func testStaleMarkIsLegalWhileRetractedAndSurvivesUndoingTheRetraction() throws {
        var harness = LifecycleHarness(try makeRecord())
        try harness.apply(.retract("withdrawn"))
        try harness.apply(.stale(.imageChanged))
        XCTAssertEqual(harness.lifecycle.standing, .retracted(reason: "withdrawn"))
        try harness.apply(.undo(1))
        XCTAssertEqual(harness.lifecycle.standing, .stale(.imageChanged))
    }

    func testEditAndReviewOfAStaleFindingKeepItStale() throws {
        var harness = LifecycleHarness(try makeRecord())
        try harness.apply(.stale(.factStale))
        try harness.apply(.edit("Revised against the new facts"))
        try harness.apply(.review(.reviewed))
        XCTAssertEqual(harness.lifecycle.standing, .stale(.factStale))
        try harness.apply(.undo(3))
        try harness.apply(.undo(2))
        XCTAssertEqual(harness.lifecycle.standing, .stale(.factStale))
        XCTAssertEqual(harness.lifecycle.state.text, harness.record.content.candidateText)
    }

    func testStaleOperationFieldsAreExactlyOne() throws {
        var harness = LifecycleHarness(try makeRecord())
        let malformed: [AnalystFindingHistoryOperation] = [
            .init(kind: .stale, replacementText: nil, decision: nil, targetSequence: nil),
            .init(kind: .stale, replacementText: nil, decision: nil, targetSequence: nil, reason: "x", staleReason: .factStale),
            .init(kind: .retract, replacementText: nil, decision: nil, targetSequence: nil, staleReason: .factStale),
            .init(kind: .retract, replacementText: nil, decision: nil, targetSequence: nil),
            .init(kind: .readmit, replacementText: nil, decision: nil, targetSequence: nil, reason: "x"),
            .init(kind: .edit, replacementText: "x", decision: nil, targetSequence: nil, reason: "x"),
        ]
        for operation in malformed {
            XCTAssertFindingError(.invalidContent) { try harness.apply(operation) }
        }
        XCTAssertTrue(harness.lifecycle.history.isEmpty)
    }

    // MARK: - readmit

    func testReadmitIsLegalOnlyFromStaleAndNotWhileRetracted() throws {
        var harness = LifecycleHarness(try makeRecord())
        XCTAssertFindingError(.invalidStanding) { try harness.apply(.readmit) }
        try harness.apply(.stale(.factStale))
        try harness.apply(.readmit)
        XCTAssertEqual(harness.lifecycle.standing, .active)
        XCTAssertFindingError(.invalidStanding) { try harness.apply(.readmit) }
        try harness.apply(.stale(.imageChanged))
        try harness.apply(.retract("withdrawn"))
        XCTAssertFindingError(.retracted) { try harness.apply(.readmit) }
    }

    func testReadmitUndoRestoresTheStaleMarkAndRedoClearsItAgain() throws {
        var harness = LifecycleHarness(try makeRecord())
        try harness.apply(.stale(.premiseReverted)) // 1
        try harness.apply(.readmit)                 // 2
        XCTAssertEqual(harness.lifecycle.standing, .active)
        try harness.apply(.undo(2))
        XCTAssertEqual(harness.lifecycle.standing, .stale(.premiseReverted))
        try harness.apply(.redo(2))
        XCTAssertEqual(harness.lifecycle.standing, .active)
        XCTAssertEqual(harness.lifecycle.history.map(\.operation.kind), [.stale, .readmit, .undo, .redo])
    }

    func testClearsStalenessNamesReadmitAndTheRedoOfOne() throws {
        var harness = LifecycleHarness(try makeRecord())
        try harness.apply(.stale(.factStale)) // 1
        XCTAssertTrue(harness.lifecycle.clearsStaleness(.readmit))
        XCTAssertFalse(harness.lifecycle.clearsStaleness(.edit("x")))
        XCTAssertFalse(harness.lifecycle.clearsStaleness(.retract("x")))
        XCTAssertFalse(harness.lifecycle.clearsStaleness(.stale(.factStale)))
        try harness.apply(.readmit)           // 2
        try harness.apply(.undo(2))           // 3
        XCTAssertTrue(harness.lifecycle.clearsStaleness(.redo(2)))
        XCTAssertFalse(harness.lifecycle.clearsStaleness(.redo(1)), "Sequence 1 is a stale mark, not a readmit")
        XCTAssertFalse(harness.lifecycle.clearsStaleness(.redo(0)))
        XCTAssertFalse(harness.lifecycle.clearsStaleness(.redo(99)))
        XCTAssertFalse(harness.lifecycle.clearsStaleness(.undo(2)))
    }

    // MARK: - replay and encoding

    func testStandingHistoryReplaysAndTheLifecycleRoundTripsThroughAnEnvelope() throws {
        let record = try makeRecord()
        var harness = LifecycleHarness(record)
        try harness.apply(.edit("A"))
        try harness.apply(.stale(.factStale))
        try harness.apply(.retract("withdrawn"))
        try harness.apply(.undo(3))
        try harness.apply(.redo(3))
        try harness.apply(.undo(3))
        try harness.apply(.readmit)
        try harness.apply(.undo(5 + 2))
        try harness.lifecycle.validate(initialText: record.content.candidateText, identity: record.revisionIdentity)
        let envelope = AnalystFindingEnvelope(records: [harness.revised])
        XCTAssertEqual(envelope.schemaVersion, 2)
        XCTAssertTrue(envelope.usesV2Extensions)
        let reopened = try JSONDecoder().decode(AnalystFindingEnvelope.self, from: JSONEncoder().encode(envelope))
        try reopened.validate(workspaceID: record.workspaceID, documentID: record.documentID)
        XCTAssertEqual(reopened, envelope)
        XCTAssertEqual(reopened.records[0].standing, .stale(.factStale))
    }

    func testForgedStandingOrKindsFailReplayOnDecode() throws {
        let record = try makeRecord()
        var harness = LifecycleHarness(record)
        try harness.apply(.stale(.factStale))
        let bytes = try JSONEncoder().encode(AnalystFindingEnvelope(records: [harness.revised]))
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for mutation in 0..<4 {
            var root = base
            var records = try XCTUnwrap(root["records"] as? [[String: Any]])
            var lifecycle = try XCTUnwrap(records[0]["lifecycle"] as? [String: Any])
            var state = try XCTUnwrap(lifecycle["state"] as? [String: Any])
            var history = try XCTUnwrap(lifecycle["history"] as? [[String: Any]])
            switch mutation {
            case 0: state["retractionReason"] = "forged"; lifecycle["state"] = state
            case 1: state["staleReason"] = "imageChanged"; lifecycle["state"] = state
            case 2:
                var operation = try XCTUnwrap(history[0]["operation"] as? [String: Any])
                operation["kind"] = "readmit"; operation.removeValue(forKey: "staleReason")
                history[0]["operation"] = operation; lifecycle["history"] = history
            default:
                var operation = try XCTUnwrap(history[0]["operation"] as? [String: Any])
                operation["staleReason"] = "unknownReason"
                history[0]["operation"] = operation; lifecycle["history"] = history
            }
            records[0]["lifecycle"] = lifecycle; root["records"] = records
            XCTAssertThrowsError(try JSONDecoder().decode(AnalystFindingEnvelope.self,
                from: JSONSerialization.data(withJSONObject: root)), "Mutation \(mutation) must refuse")
        }
    }

    func testLifecycleWithoutStandingEncodesNoStandingKeys() throws {
        let record = try makeRecord()
        var harness = LifecycleHarness(record)
        try harness.apply(.edit("A"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AnalystFindingEnvelope(records: [harness.revised]))) as? [String: Any])
        let lifecycle = try XCTUnwrap((object["records"] as? [[String: Any]])?[0]["lifecycle"] as? [String: Any])
        let state = try XCTUnwrap(lifecycle["state"] as? [String: Any])
        XCTAssertNil(state["staleReason"])
        XCTAssertNil(state["retractionReason"])
        let operation = try XCTUnwrap(((lifecycle["history"] as? [[String: Any]])?[0])?["operation"] as? [String: Any])
        XCTAssertNil(operation["reason"])
        XCTAssertNil(operation["staleReason"])
        XCTAssertFalse(harness.revised.usesV2Extensions, "An edit-only lifecycle is readable by the previous build")
    }

    func testUsesV2ExtensionsFollowsHistoryKindsAndCitations() throws {
        let record = try makeRecord()
        XCTAssertFalse(record.usesV2Extensions)
        var harness = LifecycleHarness(record)
        try harness.apply(.review(.reviewed))
        XCTAssertFalse(harness.revised.usesV2Extensions)
        for operation in [AnalystFindingHistoryOperation.retract("x"), .stale(.factStale)] {
            XCTAssertTrue(record.revising(with: try harness.applied(operation)).usesV2Extensions)
        }
        XCTAssertTrue(NavigatorFixtures.citing(record, [FactCitation(id: "f1")]).usesV2Extensions)
    }

    // MARK: - citations

    func testCitationCodableIsNilTolerantAndStrict() throws {
        let bare = FactCitation(id: "f1")
        let bareObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(bare)) as? [String: Any])
        XCTAssertEqual(Set(bareObject.keys), ["id"])
        XCTAssertEqual(try JSONDecoder().decode(FactCitation.self, from: JSONEncoder().encode(bare)), bare)
        let full = FactCitation(id: "f2", generation: NavigatorFixtures.generation(), slot: ImageSlot(rawValue: 3))
        XCTAssertEqual(try JSONDecoder().decode(FactCitation.self, from: JSONEncoder().encode(full)), full)
        XCTAssertEqual(try JSONDecoder().decode(FactCitation.self,
            from: Data(#"{"id":"f3","generation":null,"slot":null}"#.utf8)), FactCitation(id: "f3"))
        XCTAssertThrowsError(try JSONDecoder().decode(FactCitation.self, from: Data(#"{"id":"f4","futureField":1}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(FactCitation.self, from: Data(#"{"generation":null}"#.utf8)))
    }

    func testCitationValidationRefusesMalformedAndDuplicateEntries() throws {
        XCTAssertFindingError(.invalidContent) { try FactCitation(id: "").validate() }
        XCTAssertFindingError(.invalidContent) { try FactCitation(id: "f\u{0007}").validate() }
        XCTAssertFindingError(.invalidContent) { try FactCitation(id: String(repeating: "f", count: 257)).validate() }
        XCTAssertFindingError(.invalidContent) {
            try FactCitation(id: "f1", generation: NavigatorFixtures.generation(key: "")).validate()
        }
        XCTAssertNoThrow(try FactCitation.validate([FactCitation(id: "f1", slot: .primary),
                                                    FactCitation(id: "f1", slot: ImageSlot(rawValue: 1)),
                                                    FactCitation(id: "f1")]))
        XCTAssertFindingError(.invalidContent) {
            try FactCitation.validate([FactCitation(id: "f1", slot: .primary), FactCitation(id: "f1", slot: .primary)])
        }
        let tooMany = (0...AnalystFindingRecord.maximumCitations).map { FactCitation(id: "f\($0)") }
        XCTAssertFindingError(.bounds) { try FactCitation.validate(tooMany) }
        XCTAssertNoThrow(try FactCitation.validate(Array(tooMany.dropLast())))
    }

    func testRecordWithoutCitationsKeepsItsPreV2BytesAndEmptyListNormalizesToNil() throws {
        let record = try makeRecord()
        XCTAssertNil(record.citesFacts)
        XCTAssertTrue(record.citations.isEmpty)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        XCTAssertNil(object["citesFacts"])
        XCTAssertNil(object["schemaVersion"])
        let empty = AnalystFindingRecord(id: record.id, workspaceID: record.workspaceID, documentID: record.documentID,
                                         createdAt: record.createdAt, content: record.content, citesFacts: [])
        XCTAssertNil(empty.citesFacts)
        XCTAssertEqual(empty, record)
        XCTAssertEqual(try JSONDecoder().decode(AnalystFindingRecord.self, from: JSONEncoder().encode(record)), record)
    }

    func testV1EnvelopeDecodesWithEmptyCitationsAndStaysReadableByTheOldBuild() throws {
        let workspaceID = UUID(), documentID = UUID()
        let envelope = try AnalystFindingEnvelopeFixture.make(workspaceID: workspaceID, documentID: documentID)
        let bytes = try JSONEncoder().encode(envelope)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(root["schemaVersion"] as? Int, 1)
        XCTAssertNil((root["records"] as? [[String: Any]])?[0]["citesFacts"])
        let reopened = try JSONDecoder().decode(AnalystFindingEnvelope.self, from: bytes)
        try reopened.validate(workspaceID: workspaceID, documentID: documentID)
        XCTAssertEqual(reopened, envelope)
        XCTAssertTrue(reopened.records[0].citations.isEmpty)
        XCTAssertFalse(reopened.usesV2Extensions)
        XCTAssertEqual(reopened.schemaVersion, 1)
    }

    func testCitationsRoundTripInRecordOrderAndSurviveALifecycleThatPromotesTheRecord() throws {
        let workspaceID = UUID(), documentID = UUID()
        let base = try AnalystFindingEnvelopeFixture.make(workspaceID: workspaceID, documentID: documentID).records[0]
        let citations = [FactCitation(id: "fb", generation: NavigatorFixtures.generation(), slot: .primary),
                         FactCitation(id: "fa")]
        let cited = NavigatorFixtures.citing(base, citations, id: base.id)
        let first = AnalystFindingEnvelope(records: [cited])
        XCTAssertEqual(first.schemaVersion, 1, "A record without a lifecycle stays a version 1 record")
        XCTAssertTrue(first.usesV2Extensions)
        try first.validate(workspaceID: workspaceID, documentID: documentID)
        let decoded = try JSONDecoder().decode(AnalystFindingEnvelope.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(decoded, first)
        XCTAssertEqual(decoded.records[0].citations, citations)
        var harness = LifecycleHarness(cited)
        try harness.apply(.stale(.factStale))
        let promoted = AnalystFindingEnvelope(records: [harness.revised])
        XCTAssertEqual(promoted.schemaVersion, 2)
        try promoted.validate(workspaceID: workspaceID, documentID: documentID)
        let reopened = try JSONDecoder().decode(AnalystFindingEnvelope.self, from: JSONEncoder().encode(promoted))
        XCTAssertEqual(reopened, promoted)
        XCTAssertEqual(reopened.records[0].citations, citations)
        XCTAssertEqual(reopened.records[0].standing, .stale(.factStale))
    }

    func testEnvelopeRefusesDuplicateCitationsAndOversizedCitationLists() throws {
        let workspaceID = UUID(), documentID = UUID()
        let base = try AnalystFindingEnvelopeFixture.make(workspaceID: workspaceID, documentID: documentID).records[0]
        let duplicated = NavigatorFixtures.citing(base, [FactCitation(id: "f1"), FactCitation(id: "f1")], id: base.id)
        XCTAssertThrowsError(try AnalystFindingEnvelope(records: [duplicated]).validate(workspaceID: workspaceID,
                                                                                          documentID: documentID))
        let many = (0...AnalystFindingRecord.maximumCitations).map { FactCitation(id: "f\($0)") }
        XCTAssertThrowsError(try AnalystFindingEnvelope(records: [NavigatorFixtures.citing(base, many, id: base.id)])
            .validate(workspaceID: workspaceID, documentID: documentID))
    }

    // MARK: - package reader feature

    func testReaderFeatureStringsAreStable() {
        XCTAssertEqual(WorkspacePackageManifest.analystFindingCitationsReaderFeature, "analyst.findings.v2")
        XCTAssertEqual(WorkspacePackageManifest.analystFindingHistoryReaderFeature, "analyst.findings.history.v2")
        XCTAssertEqual(MacScopeDocumentPackage.UnsupportedReaderFeaturesError(
            features: [WorkspacePackageManifest.analystFindingCitationsReaderFeature]).errorDescription,
            "This workspace carries analyst findings that cite contract facts and needs a MacScope build that supports analyst.findings.v2 (October 2026 or newer).")
    }

    func testV1FindingsSaveAsV2AndReopenWithoutDataLoss() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        let store = WorkspaceStore(workspaceName: "V1 findings", snapshot: .init(binaries: [], analysisBySlot: [:]),
            engine: AnalysisEngine(), autosaveScheduler: nil)
        let original = try AnalystFindingEnvelopeFixture.make(workspaceID: store.workspaceID, documentID: store.documentID)
        store.installValidatedAnalystFindings(original)
        let url = fixture.root.appendingPathComponent("V1ToV2.mscope")
        _ = try store.writeDocumentPackageThrowing(to: url)
        let opened = try MacScopeDocumentPackage.openPackage(from: url)
        let features = opened.manifest.requiredReaderFeatures
        XCTAssertTrue(features.contains(WorkspacePackageManifest.analystFindingsReaderFeature))
        XCTAssertTrue(features.contains(WorkspacePackageManifest.analystFindingCitationsReaderFeature))
        XCTAssertFalse(features.contains(WorkspacePackageManifest.analystFindingHistoryReaderFeature))
        XCTAssertEqual(opened.manifest.analystFindings, original)
        let reopened = try WorkspaceStore.restoredPackage(from: url, scheduleDurableRecovery: false)
        XCTAssertEqual(try reopened.persistableAnalystFindings(), original)
        XCTAssertEqual(try reopened.persistableAnalystFindings()?.records[0].content, original.records[0].content)
    }

    func testPackageWrittenBeforeTheFeatureStillOpensWhenItsFindingsPredateIt() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        let envelope = try AnalystFindingEnvelopeFixture.make(workspaceID: fixture.manifest.workspaceUUID,
            documentID: fixture.manifest.documentID)
        var manifest = fixture.manifest
        manifest.analystFindings = envelope
        try MacScopeDocumentPackage.writePackage(manifest, attachmentsByBinaryID: [fixture.binaryID: fixture.binaryBytes],
            reconstructionState: fixture.state, reconstructionAttachmentSources: [fixture.source], to: fixture.packageURL)
        try Self.stripFeature(WorkspacePackageManifest.analystFindingCitationsReaderFeature, from: fixture.packageURL)
        let opened = try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)
        XCTAssertEqual(opened.manifest.analystFindings, envelope)
        XCTAssertFalse(opened.manifest.requiredReaderFeatures.contains(WorkspacePackageManifest.analystFindingCitationsReaderFeature))
    }

    func testCitingFindingsRequireTheFeatureAndAPhantomFeatureIsRefused() throws {
        let fixture = try ReconstructionPackageFixture.make()
        defer { fixture.remove() }
        let base = try AnalystFindingEnvelopeFixture.make(workspaceID: fixture.manifest.workspaceUUID,
            documentID: fixture.manifest.documentID).records[0]
        let envelope = AnalystFindingEnvelope(records: [NavigatorFixtures.citing(base,
            [FactCitation(id: "f1", generation: NavigatorFixtures.generation(), slot: .primary)], id: base.id)])
        var manifest = fixture.manifest
        manifest.analystFindings = envelope
        try MacScopeDocumentPackage.writePackage(manifest, attachmentsByBinaryID: [fixture.binaryID: fixture.binaryBytes],
            reconstructionState: fixture.state, reconstructionAttachmentSources: [fixture.source], to: fixture.packageURL)
        let opened = try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)
        XCTAssertEqual(opened.manifest.analystFindings, envelope)
        XCTAssertTrue(opened.manifest.requiredReaderFeatures.contains(WorkspacePackageManifest.analystFindingCitationsReaderFeature))
        try Self.stripFeature(WorkspacePackageManifest.analystFindingCitationsReaderFeature, from: fixture.packageURL)
        XCTAssertThrowsError(try MacScopeDocumentPackage.openPackage(from: fixture.packageURL)) {
            XCTAssertEqual($0 as? ReconstructionPackageValidationError,
                .stateGraphInvalid("analyst finding v2 reader feature disagreement"))
        }
        let legacy = try ReconstructionPackageFixture.make()
        defer { legacy.remove() }
        try legacy.write()
        let url = MacScopeDocumentPackage.manifestURL(in: legacy.packageURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        object["requiredReaderFeatures"] = [WorkspacePackageManifest.analystFindingCitationsReaderFeature]
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
        XCTAssertThrowsError(try MacScopeDocumentPackage.openPackage(from: legacy.packageURL)) {
            XCTAssertEqual($0 as? ReconstructionPackageValidationError,
                .stateGraphInvalid("analyst finding v2 reader feature disagreement"))
        }
    }

    private static func stripFeature(_ feature: String, from packageURL: URL) throws {
        let url = MacScopeDocumentPackage.manifestURL(in: packageURL)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        root["requiredReaderFeatures"] = (root["requiredReaderFeatures"] as? [String])?.filter { $0 != feature }
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]).write(to: url)
    }

    // MARK: - support check on hand-built stores

    private let slot = ImageSlot.primary

    func testSupportedCitationsWithAndWithoutGenerationAndSlot() throws {
        let fact = try NavigatorFixtures.fact("0x1", name: "Alpha")
        let source = NavigatorFixtures.source([slot: NavigatorFixtures.store([fact])])
        let citations = [FactCitation(id: fact.id, generation: fact.generation, slot: slot),
                         FactCitation(id: fact.id, generation: nil, slot: nil)]
        let result = AnalystFindingSupport.check(citations, source: source)
        XCTAssertEqual(result.supported, citations)
        XCTAssertTrue(result.unsupported.isEmpty)
        XCTAssertTrue(result.stale.isEmpty)
        XCTAssertTrue(result.conflicting.isEmpty)
        XCTAssertTrue(result.isFullySupported)
        XCTAssertFalse(result.invalidates)
        XCTAssertNil(result.staleReason)
    }

    func testUnknownFactIsUnsupportedAndNamedFactStale() throws {
        let fact = try NavigatorFixtures.fact("0x1", name: "Alpha")
        let source = NavigatorFixtures.source([slot: NavigatorFixtures.store([fact])])
        let missing = FactCitation(id: "f" + String(repeating: "0", count: 64), generation: fact.generation, slot: slot)
        let result = AnalystFindingSupport.check([missing, FactCitation(id: fact.id, slot: slot)], source: source)
        XCTAssertEqual(result.unsupported, [missing])
        XCTAssertEqual(result.supported, [FactCitation(id: fact.id, slot: slot)])
        XCTAssertTrue(result.stale.isEmpty)
        XCTAssertTrue(result.invalidates)
        XCTAssertFalse(result.isFullySupported)
        XCTAssertEqual(result.staleReason, .factStale)
    }

    func testFactFencedByGenerationFencingIsStaleWithFactStale() throws {
        let fact = try NavigatorFixtures.fact("0x1", name: "Alpha")
        var store = NavigatorFixtures.store([fact])
        XCTAssertEqual(store.markStale([fact.id]), [fact.id])
        let citation = FactCitation(id: fact.id, generation: fact.generation, slot: slot)
        let result = AnalystFindingSupport.check([citation], source: NavigatorFixtures.source([slot: store]))
        XCTAssertEqual(result.stale, [citation])
        XCTAssertEqual(result.causes[citation], .factStale)
        XCTAssertEqual(result.staleReason, .factStale)
        XCTAssertTrue(result.supported.isEmpty)
    }

    func testRevertedFactIsStale() throws {
        let premise = try NavigatorFixtures.fact("0x2", name: "Seed")
        let fact = try NavigatorFixtures.reversibleFact("0x1", name: "Alpha", from: premise)
        var store = NavigatorFixtures.store([premise, fact])
        XCTAssertNil(store.revert(fact.revert, session: "analyst-1"))
        let citation = FactCitation(id: fact.id, slot: slot)
        let result = AnalystFindingSupport.check([citation], source: NavigatorFixtures.source([slot: store]))
        XCTAssertEqual(result.stale, [citation])
        XCTAssertEqual(result.staleReason, .factStale)
    }

    func testChangedGenerationOfALiveFactIsStale() throws {
        let cited = NavigatorFixtures.generation(key: "key-1")
        let now = NavigatorFixtures.generation(key: "key-2")
        let fact = try NavigatorFixtures.fact("0x1", name: "Alpha", generation: now)
        let source = NavigatorFixtures.source([slot: NavigatorFixtures.store([fact])])
        let stale = FactCitation(id: fact.id, generation: cited, slot: slot)
        let current = FactCitation(id: fact.id, generation: now, slot: slot)
        let result = AnalystFindingSupport.check([stale, current], source: source)
        XCTAssertEqual(result.stale, [stale])
        XCTAssertEqual(result.supported, [current])
        XCTAssertEqual(result.causes[stale], .factStale)
        let otherImage = FactCitation(id: fact.id, generation: NavigatorFixtures.generation("image-Z", key: "key-2"), slot: nil)
        let crossed = AnalystFindingSupport.check([otherImage], source: source)
        XCTAssertEqual(crossed.causes[otherImage], .imageChanged)
    }

    func testChangedImageIdentityIsStaleEvenWhenTheFactStillExists() throws {
        let fact = try NavigatorFixtures.fact("0x1", name: "Alpha")
        let store = NavigatorFixtures.store([fact])
        let citation = FactCitation(id: fact.id, generation: fact.generation, slot: slot)
        let replaced = AnalystFindingSupportSource(stores: [slot: store], imageIdentities: [slot: "image-B"])
        let result = AnalystFindingSupport.check([citation], source: replaced)
        XCTAssertEqual(result.stale, [citation])
        XCTAssertEqual(result.causes[citation], .imageChanged)
        XCTAssertEqual(result.staleReason, .imageChanged)
        let sameImage = AnalystFindingSupportSource(stores: [slot: store], imageIdentities: [slot: "image-A"])
        XCTAssertTrue(AnalystFindingSupport.check([citation], source: sameImage).isFullySupported)
    }

    func testPremiseRevertedWhenAnAnnotationUnderADerivedFactIsReverted() throws {
        let base = try NavigatorFixtures.fact("0x1", name: "Alpha")
        let annotation = try NavigatorAnnotation.make(session: "s1", seq: 1, author: "analyst", action: "rename",
            subject: NavigatorFixtures.subject("0x1"), predicate: "hasName", value: .string("Renamed"), cites: [base.id],
            generation: NavigatorFixtures.generation())
        let derived = try NavigatorFact.make(subject: NavigatorFixtures.subject("0x2"), predicate: "hasName",
            value: .string("Derived"), status: "derived",
            provenance: [.init(kind: "rule", ref: "r", rule: "ruleA", ruleVersion: "1")],
            toolchain: NavigatorFixtures.toolchain, tier: 1, derivedFrom: [[annotation.premise]],
            generation: NavigatorFixtures.generation())
        var store = NavigatorFixtures.store([base, derived])
        XCTAssertNil(store.accept(annotation))
        let onDerived = FactCitation(id: derived.id, generation: derived.generation, slot: slot)
        let onAnnotation = FactCitation(id: annotation.id, generation: annotation.generation, slot: slot)
        XCTAssertTrue(AnalystFindingSupport.check([onDerived, onAnnotation],
            source: NavigatorFixtures.source([slot: store])).isFullySupported)
        XCTAssertNil(store.revert(annotation.revert, session: "s2"))
        let result = AnalystFindingSupport.check([onDerived, onAnnotation], source: NavigatorFixtures.source([slot: store]))
        XCTAssertEqual(Set(result.stale), [onDerived, onAnnotation])
        XCTAssertEqual(result.causes[onDerived], .premiseReverted)
        XCTAssertEqual(result.causes[onAnnotation], .premiseReverted)
        XCTAssertEqual(result.staleReason, .premiseReverted)
    }

    func testAnnotationWhoseCitedFactDiedIsStale() throws {
        let premise = try NavigatorFixtures.fact("0x2", name: "Seed")
        let base = try NavigatorFixtures.reversibleFact("0x1", name: "Alpha", from: premise)
        let annotation = try NavigatorAnnotation.make(session: "s1", seq: 1, author: "analyst", action: "rename",
            subject: NavigatorFixtures.subject("0x1"), predicate: "hasName", value: .string("Renamed"), cites: [base.id])
        var store = NavigatorFixtures.store([premise, base])
        XCTAssertNil(store.accept(annotation))
        XCTAssertNil(store.revert(base.revert, session: "s2"))
        let citation = FactCitation(id: annotation.id, slot: slot)
        let result = AnalystFindingSupport.check([citation], source: NavigatorFixtures.source([slot: store]))
        XCTAssertEqual(result.stale, [citation])
        XCTAssertEqual(result.causes[citation], .factStale)
    }

    func testReasonPrecedenceImageChangedThenPremiseRevertedThenFactStale() {
        func make(_ causes: [AnalystFindingStaleReason]) -> SupportResult {
            var result = SupportResult()
            for (index, cause) in causes.enumerated() {
                let citation = FactCitation(id: "f\(index)")
                result.stale.append(citation); result.causes[citation] = cause
            }
            return result
        }
        XCTAssertEqual(make([.factStale, .premiseReverted, .imageChanged]).staleReason, .imageChanged)
        XCTAssertEqual(make([.factStale, .premiseReverted]).staleReason, .premiseReverted)
        XCTAssertEqual(make([.factStale]).staleReason, .factStale)
        XCTAssertNil(make([]).staleReason)
        var unsupportedOnly = SupportResult()
        unsupportedOnly.unsupported = [FactCitation(id: "gone")]
        XCTAssertEqual(unsupportedOnly.staleReason, .factStale)
    }

    func testContradictoryLiveFactsAreBothReportedAndNeitherSupportsTheFinding() throws {
        let foo = try NavigatorFixtures.fact("0x1", name: "Foo")
        let bar = try NavigatorFixtures.fact("0x1", name: "Bar")
        let elsewhere = try NavigatorFixtures.fact("0x2", name: "Baz")
        let source = NavigatorFixtures.source([slot: NavigatorFixtures.store([foo, bar, elsewhere])])
        let cFoo = FactCitation(id: foo.id, generation: foo.generation, slot: slot)
        let cBar = FactCitation(id: bar.id, generation: bar.generation, slot: slot)
        let cBaz = FactCitation(id: elsewhere.id, generation: elsewhere.generation, slot: slot)
        let result = AnalystFindingSupport.check([cFoo, cBaz, cBar], source: source)
        XCTAssertEqual(result.conflicting, [cFoo, cBar])
        XCTAssertEqual(result.supported, [cBaz])
        XCTAssertFalse(result.invalidates, "A contradiction is reported; it does not stale the finding")
        XCTAssertFalse(result.isFullySupported, "A contradiction blocks readmission")
        XCTAssertNil(result.staleReason)
        XCTAssertTrue(AnalystFindingSupport.check([cFoo, cBaz], source: source).isFullySupported,
                      "Citing only one of the two facts is not a contradiction")
    }

    func testMultiValuedPredicatesNeverConflict() throws {
        let one = try NavigatorFixtures.fact("0x1", predicate: "conformsTo", name: "ProtocolA")
        let two = try NavigatorFixtures.fact("0x1", predicate: "conformsTo", name: "ProtocolB")
        let source = NavigatorFixtures.source([slot: NavigatorFixtures.store([one, two])])
        let result = AnalystFindingSupport.check([FactCitation(id: one.id, slot: slot), FactCitation(id: two.id, slot: slot)],
                                                 source: source)
        XCTAssertTrue(result.conflicting.isEmpty)
        XCTAssertTrue(result.isFullySupported)
    }

    func testSlotQualifiedCitationsLookOnlyInTheirSlotAndBareOnesInEverySlot() throws {
        let other = ImageSlot(rawValue: 1)
        let fact = try NavigatorFixtures.fact("0x1", name: "Alpha")
        let source = NavigatorFixtures.source([slot: NavigatorFixtures.store([]), other: NavigatorFixtures.store([fact])])
        let wrongSlot = FactCitation(id: fact.id, slot: slot)
        let rightSlot = FactCitation(id: fact.id, slot: other)
        let anySlot = FactCitation(id: fact.id)
        let result = AnalystFindingSupport.check([wrongSlot, rightSlot, anySlot], source: source)
        XCTAssertEqual(result.unsupported, [wrongSlot])
        XCTAssertEqual(result.supported, [rightSlot, anySlot])
    }

    // MARK: - stale marks

    func testStaleMarksCoverOnlyActiveFindingsWhoseCitationsFail() throws {
        let record = try makeRecord()
        let live = try NavigatorFixtures.fact("0x1", name: "Alpha")
        let fenced = try NavigatorFixtures.fact("0x2", name: "Beta")
        var store = NavigatorFixtures.store([live, fenced])
        _ = store.markStale([fenced.id])
        let source = NavigatorFixtures.source([slot: store])
        let failing = NavigatorFixtures.citing(record, [FactCitation(id: fenced.id, generation: fenced.generation, slot: slot)])
        let healthy = NavigatorFixtures.citing(record, [FactCitation(id: live.id, generation: live.generation, slot: slot)])
        let uncited = NavigatorFixtures.citing(record, [])
        var retractedHarness = LifecycleHarness(NavigatorFixtures.citing(record,
            [FactCitation(id: fenced.id, generation: fenced.generation, slot: slot)]))
        try retractedHarness.apply(.retract("withdrawn"))
        var staleHarness = LifecycleHarness(NavigatorFixtures.citing(record,
            [FactCitation(id: fenced.id, generation: fenced.generation, slot: slot)]))
        try staleHarness.apply(.stale(.imageChanged))
        let marks = AnalystFindingSupport.staleMarks(
            in: [failing, healthy, uncited, retractedHarness.revised, staleHarness.revised], touching: nil, source: source)
        XCTAssertEqual(marks, [.init(findingID: failing.id, reason: .factStale)])
    }

    func testStaleMarksHonourTheSlotsTouchedAndSkipSlotsWithoutInstalledState() throws {
        let record = try makeRecord()
        let other = ImageSlot(rawValue: 1)
        let fenced0 = try NavigatorFixtures.fact("0x1", name: "Alpha")
        let fenced1 = try NavigatorFixtures.fact("0x2", name: "Beta")
        var store0 = NavigatorFixtures.store([fenced0]); _ = store0.markStale([fenced0.id])
        var store1 = NavigatorFixtures.store([fenced1]); _ = store1.markStale([fenced1.id])
        let first = NavigatorFixtures.citing(record, [FactCitation(id: fenced0.id, generation: fenced0.generation, slot: slot)])
        let second = NavigatorFixtures.citing(record, [FactCitation(id: fenced1.id, generation: fenced1.generation, slot: other)])
        let both = NavigatorFixtures.source([slot: store0, other: store1])
        XCTAssertEqual(AnalystFindingSupport.staleMarks(in: [first, second], touching: [other], source: both).map(\.findingID),
                       [second.id])
        XCTAssertEqual(AnalystFindingSupport.staleMarks(in: [first, second], touching: nil, source: both).map(\.findingID),
                       [first.id, second.id])
        let onlyFirst = AnalystFindingSupportSource(stores: [slot: store0], imageIdentities: [slot: "image-A", other: "image-A"])
        XCTAssertEqual(AnalystFindingSupport.staleMarks(in: [first, second], touching: nil, source: onlyFirst).map(\.findingID),
                       [first.id], "A slot whose navigator state is not installed yet says nothing about its citations")
        let changed = AnalystFindingSupportSource(stores: [slot: store0], imageIdentities: [slot: "image-A", other: "image-B"])
        XCTAssertEqual(AnalystFindingSupport.staleMarks(in: [second], touching: nil, source: changed),
                       [.init(findingID: second.id, reason: .imageChanged)])
    }

    func testImageChangeMarksNeedAGenerationOnTheChangedSlot() throws {
        let record = try makeRecord()
        let other = ImageSlot(rawValue: 1)
        let onSlot = NavigatorFixtures.citing(record, [FactCitation(id: "f1", generation: NavigatorFixtures.generation("image-A"), slot: slot)])
        let noGeneration = NavigatorFixtures.citing(record, [FactCitation(id: "f1", generation: nil, slot: slot)])
        let elsewhere = NavigatorFixtures.citing(record, [FactCitation(id: "f1", generation: NavigatorFixtures.generation("image-A"), slot: other)])
        var retracted = LifecycleHarness(NavigatorFixtures.citing(record,
            [FactCitation(id: "f1", generation: NavigatorFixtures.generation("image-A"), slot: slot)]))
        try retracted.apply(.retract("withdrawn"))
        let records = [onSlot, noGeneration, elsewhere, retracted.revised]
        XCTAssertEqual(AnalystFindingSupport.imageChangeMarks(in: records, slot: slot, currentIdentity: "image-B"),
                       [.init(findingID: onSlot.id, reason: .imageChanged)])
        XCTAssertTrue(AnalystFindingSupport.imageChangeMarks(in: records, slot: slot, currentIdentity: "image-A").isEmpty)
    }
}
