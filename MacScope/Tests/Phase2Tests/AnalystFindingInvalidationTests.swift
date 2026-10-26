import Foundation
import XCTest
@testable import MacScope
@testable import MacScopeAnalysisCore

/// Findings that cite contract facts, retraction, and invalidation, run against hand-built navigator
/// stores passed as `source:` overrides. No binary is opened and no analysis or inference runs; the
/// support source a real workspace builds from its bridge is exercised only where it is empty.
@MainActor
final class AnalystFindingInvalidationTests: XCTestCase {
    private let slot = ImageSlot.primary

    private func store() -> WorkspaceStore {
        WorkspaceStore(workspaceName: "Finding invalidation", snapshot: .init(binaries: [], analysisBySlot: [:]),
                       engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    private func result(in store: WorkspaceStore) throws -> Phase2AssistantSessionResult {
        let state = store.phase2ReadCurrentState(for: nil)
        let fixture = InvalidationNativeFixture(workspace: state.workspace, revision: state.workspaceRevision)
        let executions = try [fixture.execution()]
        let context = try fixture.context(executions)
        return fixture.result(context, executions: executions, request: fixture.request(context, revision: fixture.revision))
    }

    private func accepted(in store: WorkspaceStore) throws -> AnalystFindingRecord {
        store.stageAnalystFinding(from: try result(in: store),
            publicationToken: .capture(intent: .askMacScope, store: store))
        return try store.acceptPendingAnalystFinding()
    }

    /// Accepts one finding per citation list, then installs each of them again carrying its citations. Every
    /// accepted finding has its own request, which the envelope requires to be unique. Any undo step the
    /// setup registered is forgotten so each test starts from a clean manager.
    @discardableResult
    private func install(_ citationLists: [[FactCitation]], in store: WorkspaceStore) throws -> [AnalystFindingRecord] {
        var records: [AnalystFindingRecord] = []
        for citations in citationLists {
            let base = try accepted(in: store)
            records.append(AnalystFindingRecord(id: base.id, workspaceID: base.workspaceID, documentID: base.documentID,
                createdAt: base.createdAt, content: base.content, citesFacts: citations))
        }
        store.installValidatedAnalystFindings(AnalystFindingEnvelope(records: records))
        store.undoManager.removeAllActions()
        return records
    }

    private func standing(_ id: UUID, in store: WorkspaceStore) throws -> AnalystFindingStanding {
        try XCTUnwrap(store.analystFindings.records.first { $0.id == id }).standing
    }

    private func assertRefuses(_ expected: AnalystFindingError, file: StaticString = #filePath, line: UInt = #line,
                               _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? AnalystFindingError, expected, file: file, line: line)
        }
    }

    // MARK: - hand-built navigator state

    private func generation(_ image: String = "image-A") -> NavigatorGeneration {
        .init(imageIdentity: image, inputKey: "key-1", knowledgeVersion: "kv-1")
    }

    private func fact(_ ref: String, name: String, image: String = "image-A") throws -> NavigatorFact {
        try NavigatorFact.make(subject: .init(kind: "type", ref: ref, image: "Fixture"), predicate: "hasName",
            value: .string(name), status: "authoritative",
            provenance: [.init(kind: "loaderRecord", ref: "loader-\(ref)-\(name)")], toolchain: "fixture-toolchain",
            generation: generation(image))
    }

    private func citation(_ fact: NavigatorFact) -> FactCitation { .init(id: fact.id, generation: fact.generation, slot: slot) }

    private func source(_ store: NavigatorContractStore, identity: String = "image-A") -> AnalystFindingSupportSource {
        .init(stores: [slot: store], imageIdentities: [slot: identity])
    }

    // MARK: - retract

    func testRetractUndoRedoRoundTripKeepsTextReviewAndCitations() throws {
        let store = store()
        let evidence = try fact("0x1", name: "Alpha")
        let record = try install([[citation(evidence)]], in: store)[0]
        _ = try store.reviewAnalystFinding(store.analystFindingEditToken(for: record.id), decision: .reviewed)
        let reviewed = try XCTUnwrap(store.analystFindings.records.first)
        let retracted = try store.retractFinding(store.analystFindingEditToken(for: record.id), reason: "  Superseded by 0x2  ")
        XCTAssertEqual(retracted.standing, .retracted(reason: "Superseded by 0x2"))
        XCTAssertEqual(retracted.authoredText, reviewed.authoredText)
        XCTAssertEqual(retracted.contentRevision, reviewed.contentRevision)
        XCTAssertEqual(retracted.reviewRevision, reviewed.reviewRevision)
        XCTAssertTrue(retracted.authoredLifecycle.isReviewCurrent)
        XCTAssertEqual(retracted.citations, record.citations)
        XCTAssertEqual(store.undoManager.undoActionName, "Retract Finding")
        store.undoManager.undo()
        XCTAssertEqual(try standing(record.id, in: store), .active)
        XCTAssertEqual(store.analystFindings.records[0].authoredText, reviewed.authoredText)
        store.undoManager.redo()
        XCTAssertEqual(try standing(record.id, in: store), .retracted(reason: "Superseded by 0x2"))
        XCTAssertEqual(store.analystFindings.records[0].authoredLifecycle.history.map(\.operation.kind),
                       [.review, .retract, .undo, .redo])
        XCTAssertEqual(store.analystFindings.records[0].content, record.content)
        XCTAssertEqual(try store.persistableAnalystFindings()?.records[0], store.analystFindings.records[0])
    }

    func testRetractIsADirtyMutationButARefusedRetractIsNot() throws {
        let store = store()
        let record = try install([[]], in: store)[0]
        let before = store.analystFindings, generation = store.mutationGeneration
        let token = try store.analystFindingEditToken(for: record.id)
        assertRefuses(.invalidContent) { _ = try store.retractFinding(token, reason: " \n ") }
        assertRefuses(.invalidContent) {
            _ = try store.retractFinding(token, reason: String(repeating: "r", count: AnalystFindingLifecycle.maximumReasonBytes + 1))
        }
        XCTAssertEqual(store.analystFindings, before)
        XCTAssertEqual(store.mutationGeneration, generation)
        XCTAssertFalse(store.undoManager.canUndo)
        _ = try store.retractFinding(token, reason: "wrong function")
        XCTAssertNotEqual(store.mutationGeneration, generation)
        XCTAssertTrue(store.hasUnsavedChanges)
        XCTAssertTrue(store.undoManager.canUndo)
        // The token is spent; a second retraction needs a fresh one and is refused as already retracted.
        XCTAssertThrowsError(try store.retractFinding(token, reason: "again"))
        assertRefuses(.invalidStanding) {
            _ = try store.retractFinding(store.analystFindingEditToken(for: record.id), reason: "again")
        }
    }

    func testRetractedFindingRefusesEditAndReviewWithoutChangingDocument() throws {
        let store = store()
        let record = try install([[]], in: store)[0]
        _ = try store.retractFinding(store.analystFindingEditToken(for: record.id), reason: "withdrawn")
        let before = store.analystFindings, generation = store.mutationGeneration
        let token = try store.analystFindingEditToken(for: record.id)
        assertRefuses(.retracted) { _ = try store.editAnalystFinding(token, text: "new text") }
        assertRefuses(.retracted) { _ = try store.reviewAnalystFinding(token, decision: .reviewed) }
        assertRefuses(.retracted) { _ = try store.readmitAnalystFinding(token, source: .init()) }
        XCTAssertEqual(store.analystFindings, before)
        XCTAssertEqual(store.mutationGeneration, generation)
        store.undoManager.undo()
        XCTAssertEqual(try standing(record.id, in: store), .active)
        _ = try store.editAnalystFinding(store.analystFindingEditToken(for: record.id), text: "now allowed")
        XCTAssertEqual(store.analystFindings.records[0].authoredText, "now allowed")
    }

    func testRetractionSurvivesSaveAndReopenWithoutAnUndoStep() throws {
        let original = store()
        let record = try install([[]], in: original)[0]
        _ = try original.retractFinding(original.analystFindingEditToken(for: record.id), reason: "withdrawn")
        let saved = try XCTUnwrap(original.persistableAnalystFindings())
        XCTAssertEqual(saved.schemaVersion, 2)
        XCTAssertTrue(saved.usesV2Extensions)
        let reopened = WorkspaceStore(workspaceName: "Reopened", snapshot: .init(binaries: [], analysisBySlot: [:]),
            engine: AnalysisEngine(), autosaveScheduler: nil, documentID: original.documentID, workspaceID: original.workspaceID)
        try WorkspaceStore.validateAnalystFindingsForRestore(saved, workspaceID: reopened.workspaceID, documentID: reopened.documentID)
        reopened.installValidatedAnalystFindings(saved)
        XCTAssertEqual(try standing(record.id, in: reopened), .retracted(reason: "withdrawn"))
        XCTAssertFalse(reopened.undoManager.canUndo)
        // A reopened retraction has no undo step, so the finding stays frozen.
        assertRefuses(.retracted) {
            _ = try reopened.editAnalystFinding(reopened.analystFindingEditToken(for: record.id), text: "x")
        }
    }

    // MARK: - stale marks

    func testMarkStaleIsASystemMarkWithNoUndoStep() throws {
        let store = store()
        let record = try install([[.init(id: "fx")]], in: store)[0]
        let generation = store.mutationGeneration
        let marked = try store.markAnalystFindingStale(record.id, reason: .factStale)
        XCTAssertEqual(marked.standing, .stale(.factStale))
        XCTAssertEqual(marked.authoredText, record.authoredText)
        XCTAssertEqual(marked.contentRevision, record.contentRevision)
        XCTAssertNotEqual(store.mutationGeneration, generation, "A stale mark is a durable document change")
        XCTAssertFalse(store.undoManager.canUndo, "The analyst undoes a stale mark only by readmitting")
        assertRefuses(.invalidStanding) { _ = try store.markAnalystFindingStale(record.id, reason: .imageChanged) }
        XCTAssertEqual(try standing(record.id, in: store), .stale(.factStale))
        assertRefuses(.wrongOwner) { _ = try store.markAnalystFindingStale(UUID(), reason: .factStale) }
    }

    func testEditAndReviewKeepAStaleFindingStaleAndUndoKeepsItStale() throws {
        let store = store()
        let record = try install([[.init(id: "fx")]], in: store)[0]
        _ = try store.markAnalystFindingStale(record.id, reason: .premiseReverted)
        _ = try store.editAnalystFinding(store.analystFindingEditToken(for: record.id), text: "Revised against new facts")
        _ = try store.reviewAnalystFinding(store.analystFindingEditToken(for: record.id), decision: .reviewed)
        XCTAssertEqual(try standing(record.id, in: store), .stale(.premiseReverted))
        store.undoManager.undo()
        store.undoManager.undo()
        XCTAssertEqual(try standing(record.id, in: store), .stale(.premiseReverted))
        XCTAssertEqual(store.analystFindings.records[0].authoredText, record.authoredText)
    }

    // MARK: - readmit

    func testReadmitIsRefusedUntilEveryCitationIsSupported() throws {
        let store = store()
        let evidence = try fact("0x1", name: "Alpha")
        let record = try install([[citation(evidence)]], in: store)[0]
        _ = try store.markAnalystFindingStale(record.id, reason: .factStale)

        var fenced = NavigatorContractStore(toolchain: "fixture-toolchain", baseFacts: [evidence])
        fenced.markStale([evidence.id])
        let before = store.analystFindings, generation = store.mutationGeneration
        let token = try store.analystFindingEditToken(for: record.id)
        assertRefuses(.supportNotConfirmed) { _ = try store.readmitAnalystFinding(token, source: source(fenced)) }
        XCTAssertEqual(store.analystFindings, before)
        XCTAssertEqual(store.mutationGeneration, generation)
        XCTAssertFalse(store.undoManager.canUndo)

        let live = NavigatorContractStore(toolchain: "fixture-toolchain", baseFacts: [evidence])
        let readmitted = try store.readmitAnalystFinding(token, source: source(live))
        XCTAssertEqual(readmitted.standing, .active)
        XCTAssertEqual(store.undoManager.undoActionName, "Readmit Finding")
        XCTAssertNotEqual(store.mutationGeneration, generation)
        store.undoManager.undo()
        XCTAssertEqual(try standing(record.id, in: store), .stale(.factStale))
        store.undoManager.redo()
        XCTAssertEqual(try standing(record.id, in: store), .active)
        XCTAssertEqual(store.analystFindings.records[0].authoredLifecycle.history.map(\.operation.kind),
                       [.stale, .readmit, .undo, .redo])
    }

    func testReadmitWithTheWorkspaceStateAloneRefusesCitationsNothingSupports() throws {
        // A workspace with no analysed image has no navigator state, so a citation cannot be supported.
        let store = store()
        let evidence = try fact("0x1", name: "Alpha")
        let record = try install([[citation(evidence)]], in: store)[0]
        _ = try store.markAnalystFindingStale(record.id, reason: .factStale)
        XCTAssertTrue(store.analystFindingSupportSource().stores.isEmpty)
        assertRefuses(.supportNotConfirmed) {
            _ = try store.readmitAnalystFinding(store.analystFindingEditToken(for: record.id))
        }
        XCTAssertEqual(try standing(record.id, in: store), .stale(.factStale))
    }

    func testReadmitIsRefusedWhileEvidenceContradicts() throws {
        let store = store()
        let foo = try fact("0x1", name: "Foo"), bar = try fact("0x1", name: "Bar")
        let record = try install([[citation(foo), citation(bar)]], in: store)[0]
        _ = try store.markAnalystFindingStale(record.id, reason: .factStale)
        let state = NavigatorContractStore(toolchain: "fixture-toolchain", baseFacts: [foo, bar])
        let report = try store.supportCheck(for: record.id, source: source(state))
        XCTAssertEqual(report.conflicting, [citation(foo), citation(bar)])
        XCTAssertFalse(report.invalidates)
        assertRefuses(.supportNotConfirmed) {
            _ = try store.readmitAnalystFinding(store.analystFindingEditToken(for: record.id), source: source(state))
        }
    }

    func testReadmitOfAFindingThatIsNotStaleIsRefusedAsInvalidStanding() throws {
        let store = store()
        let evidence = try fact("0x1", name: "Alpha")
        let record = try install([[citation(evidence)]], in: store)[0]
        let live = source(NavigatorContractStore(toolchain: "fixture-toolchain", baseFacts: [evidence]))
        assertRefuses(.invalidStanding) {
            _ = try store.readmitAnalystFinding(store.analystFindingEditToken(for: record.id), source: live)
        }
        XCTAssertFalse(store.undoManager.canUndo)
    }

    // MARK: - supportCheck

    func testSupportCheckComparesCitationsWithTheLiveFactsAndGenerations() throws {
        let store = store()
        let kept = try fact("0x1", name: "Alpha"), fenced = try fact("0x2", name: "Beta")
        let moved = try fact("0x3", name: "Gamma")
        let gone = FactCitation(id: "f" + String(repeating: "0", count: 64), generation: generation(), slot: slot)
        let outdated = FactCitation(id: moved.id,
            generation: .init(imageIdentity: "image-A", inputKey: "older-key", knowledgeVersion: "kv-1"), slot: slot)
        let record = try install([[citation(kept), citation(fenced), outdated, gone]], in: store)[0]
        var state = NavigatorContractStore(toolchain: "fixture-toolchain", baseFacts: [kept, fenced, moved])
        state.markStale([fenced.id])
        let report = try store.supportCheck(for: record.id, source: source(state))
        XCTAssertEqual(report.supported, [citation(kept)])
        XCTAssertEqual(report.stale, [citation(fenced), outdated])
        XCTAssertEqual(report.unsupported, [gone])
        XCTAssertTrue(report.conflicting.isEmpty)
        XCTAssertTrue(report.invalidates)
        XCTAssertEqual(report.staleReason, .factStale)
        XCTAssertEqual(store.supportCheck(for: record, source: source(state)), report)
        let replaced = try store.supportCheck(for: record.id, source: source(state, identity: "image-B"))
        XCTAssertEqual(replaced.staleReason, .imageChanged)
        XCTAssertEqual(Set(replaced.stale), Set([citation(kept), citation(fenced), outdated, gone]),
                       "A changed image outranks every other cause, including a fact that no longer exists")
        assertRefuses(.wrongOwner) { _ = try store.supportCheck(for: UUID()) }
    }

    func testFindingWithoutCitationsIsAlwaysFullySupported() throws {
        let store = store()
        let record = try install([[]], in: store)[0]
        let report = try store.supportCheck(for: record.id, source: .init())
        XCTAssertTrue(report.isFullySupported)
        XCTAssertNil(report.staleReason)
        XCTAssertTrue(store.reconcileAnalystFindings(source: .init()).isEmpty)
    }

    // MARK: - invalidation hooks

    func testFencingMarksOnlyTheActiveFindingsWhoseFactsWereFenced() throws {
        let store = store()
        let kept = try fact("0x1", name: "Alpha"), fenced = try fact("0x2", name: "Beta")
        let records = try install([[citation(fenced)], [citation(kept)], [], [citation(fenced)]], in: store)
        _ = try store.retractFinding(store.analystFindingEditToken(for: records[3].id), reason: "withdrawn")
        var state = NavigatorContractStore(toolchain: "fixture-toolchain", baseFacts: [kept, fenced])
        state.markStale([fenced.id])
        let marks = store.analystFindingsFactsFenced(in: [slot], source: source(state))
        XCTAssertEqual(marks, [AnalystFindingStaleMark(findingID: records[0].id, reason: .factStale),
                               AnalystFindingStaleMark(findingID: records[3].id, reason: .factStale)])
        XCTAssertEqual(try standing(records[0].id, in: store), .stale(.factStale))
        XCTAssertEqual(try standing(records[1].id, in: store), .active)
        XCTAssertEqual(try standing(records[2].id, in: store), .active)
        XCTAssertEqual(try standing(records[3].id, in: store), .retracted(reason: "withdrawn"))
        XCTAssertTrue(store.analystFindingsFactsFenced(in: [slot], source: source(state)).isEmpty, "A stale finding is not marked twice")
        XCTAssertEqual(try store.persistableAnalystFindings()?.records.count, 4)
    }

    func testFencingInAnotherSlotLeavesTheFindingActive() throws {
        let store = store()
        let fenced = try fact("0x2", name: "Beta")
        let record = try install([[citation(fenced)]], in: store)[0]
        var state = NavigatorContractStore(toolchain: "fixture-toolchain", baseFacts: [fenced])
        state.markStale([fenced.id])
        XCTAssertTrue(store.analystFindingsFactsFenced(in: [ImageSlot(rawValue: 1)], source: source(state)).isEmpty)
        XCTAssertEqual(try standing(record.id, in: store), .active)
    }

    func testReplacingTheImageMarksFindingsCitedAgainstTheOldIdentity() throws {
        let store = store()
        let evidence = try fact("0x1", name: "Alpha")
        let records = try install([[citation(evidence)], [.init(id: "bare")]], in: store)
        let replaced = source(NavigatorContractStore(toolchain: "fixture-toolchain", baseFacts: [evidence]), identity: "image-B")
        let marks = store.analystFindingsImageIdentityChanged(in: slot, source: replaced)
        XCTAssertEqual(marks.first, AnalystFindingStaleMark(findingID: records[0].id, reason: .imageChanged))
        XCTAssertEqual(try standing(records[0].id, in: store), .stale(.imageChanged))
        XCTAssertEqual(try standing(records[1].id, in: store), .stale(.factStale),
                       "A bare citation the new state cannot find is unsupported, hence stale")
        XCTAssertFalse(store.undoManager.canUndo)
    }

    func testRevertingAnAnnotationMarksADependentFindingPremiseReverted() throws {
        let store = store()
        let base = try fact("0x1", name: "Alpha")
        let annotation = try NavigatorAnnotation.make(session: "s1", seq: 1, author: "analyst", action: "rename",
            subject: .init(kind: "type", ref: "0x1", image: "Fixture"), predicate: "hasName", value: .string("Renamed"),
            cites: [base.id], generation: generation())
        let derived = try NavigatorFact.make(subject: .init(kind: "type", ref: "0x2", image: "Fixture"),
            predicate: "hasName", value: .string("Derived"), status: "derived",
            provenance: [.init(kind: "rule", ref: "r", rule: "ruleA", ruleVersion: "1")], toolchain: "fixture-toolchain",
            tier: 1, derivedFrom: [[annotation.premise]], generation: generation())
        var state = NavigatorContractStore(toolchain: "fixture-toolchain", baseFacts: [base, derived])
        XCTAssertNil(state.accept(annotation))
        let record = try install([[citation(derived)]], in: store)[0]
        XCTAssertTrue(store.analystFindingsAnnotationReverted(in: slot, source: source(state)).isEmpty,
                      "Nothing is reverted yet")
        XCTAssertNil(state.revert(annotation.revert, session: "s2"))
        let marks = store.analystFindingsAnnotationReverted(in: slot, source: source(state))
        XCTAssertEqual(marks, [AnalystFindingStaleMark(findingID: record.id, reason: .premiseReverted)])
        XCTAssertEqual(try standing(record.id, in: store), .stale(.premiseReverted))
    }

    func testReopenedDocumentIsReconciledOnceItsNavigatorStateIsInstalled() throws {
        let store = store()
        let evidence = try fact("0x1", name: "Alpha"), fenced = try fact("0x2", name: "Beta")
        let records = try install([[citation(evidence)], [citation(fenced)]], in: store)
        // Before the navigator state is installed nothing is judged, so an opening document keeps every finding.
        XCTAssertTrue(store.reconcileAnalystFindingsAfterOpen(source: .init(stores: [:], imageIdentities: [slot: "image-A"])).isEmpty)
        XCTAssertEqual(try standing(records[0].id, in: store), .active)
        var state = NavigatorContractStore(toolchain: "fixture-toolchain", baseFacts: [evidence, fenced])
        state.markStale([fenced.id])
        let marks = store.reconcileAnalystFindingsAfterOpen(source: source(state))
        XCTAssertEqual(marks, [AnalystFindingStaleMark(findingID: records[1].id, reason: .factStale)])
        XCTAssertEqual(try standing(records[0].id, in: store), .active)
        XCTAssertEqual(try standing(records[1].id, in: store), .stale(.factStale))
    }

    func testReopenedDocumentWithAnotherImageMarksImageChangedEvenBeforeStateIsInstalled() throws {
        let store = store()
        let evidence = try fact("0x1", name: "Alpha")
        let record = try install([[citation(evidence)]], in: store)[0]
        let marks = store.reconcileAnalystFindingsAfterOpen(source: .init(stores: [:], imageIdentities: [slot: "image-B"]))
        XCTAssertEqual(marks, [AnalystFindingStaleMark(findingID: record.id, reason: .imageChanged)])
        XCTAssertEqual(try standing(record.id, in: store), .stale(.imageChanged))
    }


    // MARK: - retained invalidation regressions

    func testUndoRetractionKeepsPartialCitationInvalidation() throws {
        let store = store()
        let kept = try fact("0x1", name: "Alpha"), fenced = try fact("0x2", name: "Beta")
        let record = try install([[citation(kept), citation(fenced)]], in: store)[0]
        _ = try store.retractFinding(store.analystFindingEditToken(for: record.id), reason: "withdrawn")
        var state = NavigatorContractStore(toolchain: "fixture-toolchain", baseFacts: [kept, fenced])
        state.markStale([fenced.id])
        let marks = store.analystFindingsFactsFenced(in: [slot], source: source(state))
        XCTAssertEqual(marks, [.init(findingID: record.id, reason: .factStale)])
        XCTAssertEqual(try standing(record.id, in: store), .retracted(reason: "withdrawn"))
        XCTAssertEqual(store.undoManager.undoActionName, "Retract Finding")
        store.undoManager.undo()
        XCTAssertEqual(try standing(record.id, in: store), .stale(.factStale))
        let support = try store.supportCheck(for: record.id, source: source(state))
        XCTAssertEqual(support.supported, [citation(kept)])
        XCTAssertEqual(support.stale, [citation(fenced)])
        store.undoManager.redo()
        XCTAssertEqual(try standing(record.id, in: store), .retracted(reason: "withdrawn"))
        XCTAssertEqual(store.analystFindings.records[0].authoredLifecycle.state.staleReason, .factStale)
    }

    func testLatentStaleMarkRetainsDistinctIdentityStandingAndSource() throws {
        let store = store()
        let fenced = try fact("0x2", name: "Beta")
        let records = try install([[citation(fenced)], [citation(fenced)]], in: store)
        _ = try store.retractFinding(store.analystFindingEditToken(for: records[1].id), reason: "withdrawn")
        var state = NavigatorContractStore(toolchain: "fixture-toolchain", baseFacts: [fenced])
        state.markStale([fenced.id])
        let evidenceSource = source(state)
        let marks = store.analystFindingsFactsFenced(in: [slot], source: evidenceSource)
        XCTAssertEqual(marks.map(\.findingID), records.map(\.id))
        XCTAssertEqual(Set(marks.map(\.findingID)).count, 2)
        let latent = try XCTUnwrap(marks.last)
        XCTAssertEqual(latent.findingID, records[1].id)
        XCTAssertEqual(latent.reason, .factStale)
        let withdrawn = try XCTUnwrap(store.analystFindings.records.first { $0.id == latent.findingID })
        XCTAssertEqual(withdrawn.standing, .retracted(reason: "withdrawn"))
        XCTAssertEqual(withdrawn.authoredLifecycle.state.staleReason, .factStale)
        XCTAssertEqual(withdrawn.authoredLifecycle.history.last?.operation, AnalystFindingHistoryOperation.stale(.factStale))
        XCTAssertEqual(withdrawn.citations, [citation(fenced)])
        XCTAssertEqual(store.supportCheck(for: withdrawn, source: evidenceSource).stale, [citation(fenced)])
        XCTAssertTrue(store.analystFindingsFactsFenced(in: [slot], source: evidenceSource).isEmpty)
    }

    func testImageReplacementRecordsStalenessUnderRetraction() throws {
        let store = store()
        let evidence = try fact("0x1", name: "Alpha")
        let record = try install([[citation(evidence)]], in: store)[0]
        _ = try store.retractFinding(store.analystFindingEditToken(for: record.id), reason: "withdrawn")
        let marks = store.analystFindingsImageIdentityChanged(in: slot,
            source: .init(stores: [:], imageIdentities: [slot: "image-B"]))
        XCTAssertEqual(marks, [.init(findingID: record.id, reason: .imageChanged)])
        XCTAssertEqual(try standing(record.id, in: store), .retracted(reason: "withdrawn"))
        store.undoManager.undo()
        XCTAssertEqual(try standing(record.id, in: store), .stale(.imageChanged))
    }

    func testFullAuthoredHistoryStillRecordsDurableSystemStaleMark() throws {
        let store = store()
        let evidence = try fact("0x1", name: "Alpha")
        let record = try install([[citation(evidence)]], in: store)[0]
        for _ in 0..<AnalystFindingLifecycle.maximumHistoryEntries {
            _ = try store.reviewAnalystFinding(store.analystFindingEditToken(for: record.id), decision: .reviewed)
        }
        let full = try XCTUnwrap(store.analystFindings.records.first)
        XCTAssertEqual(full.authoredLifecycle.history.count, 256)
        XCTAssertEqual(full.standing, .active)
        store.undoManager.removeAllActions()
        var state = NavigatorContractStore(toolchain: "fixture-toolchain", baseFacts: [evidence])
        state.markStale([evidence.id])
        let marks = store.analystFindingsFactsFenced(in: [slot], source: source(state))
        XCTAssertEqual(marks, [.init(findingID: record.id, reason: .factStale)])
        let stale = try XCTUnwrap(store.analystFindings.records.first)
        XCTAssertEqual(stale.standing, .stale(.factStale))
        XCTAssertEqual(stale.authoredLifecycle.history.count, 257)
        XCTAssertEqual(Array(stale.authoredLifecycle.history.prefix(256)), full.authoredLifecycle.history)
        XCTAssertEqual(stale.authoredLifecycle.history.filter { $0.operation.kind != .stale }.count, 256)
        XCTAssertEqual(stale.authoredLifecycle.history.last?.operation, AnalystFindingHistoryOperation.stale(.factStale))
        XCTAssertFalse(store.undoManager.canUndo)
        assertRefuses(.bounds) {
            _ = try store.reviewAnalystFinding(store.analystFindingEditToken(for: record.id), decision: .reviewed)
        }
        let saved = try XCTUnwrap(store.persistableAnalystFindings())
        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(AnalystFindingEnvelope.self, from: data)
        try WorkspaceStore.validateAnalystFindingsForRestore(decoded, workspaceID: store.workspaceID, documentID: store.documentID)
        XCTAssertEqual(decoded, saved)
        XCTAssertEqual(decoded.records[0].standing, .stale(.factStale))
        XCTAssertTrue(store.analystFindingsFactsFenced(in: [slot], source: source(state)).isEmpty)
    }

    func testFullHistoryRefusesAnExtraAuthoredOperationBeforeInvalidation() throws {
        let store = store()
        let record = try install([[]], in: store)[0]
        for _ in 0..<AnalystFindingLifecycle.maximumHistoryEntries {
            _ = try store.reviewAnalystFinding(store.analystFindingEditToken(for: record.id), decision: .reviewed)
        }
        let before = store.analystFindings
        assertRefuses(.bounds) {
            _ = try store.reviewAnalystFinding(store.analystFindingEditToken(for: record.id), decision: .needsChanges)
        }
        XCTAssertEqual(store.analystFindings, before)
    }

    func testUndoAnnotationAcceptanceReconcilesDependentFinding() throws {
        let image = BinaryImage(id: UUID(), name: "image0", path: "/tmp/finding-undo-image0",
            kind: "Mach-O executable", architecture: "arm64", slot: slot)
        let store = WorkspaceStore(workspaceName: "Finding undo",
            snapshot: .init(binaries: [image], analysisBySlot: [slot: ImageAnalysis()]),
            engine: AnalysisEngine(), autosaveScheduler: nil)
        let annotation = try NavigatorAnnotation.make(session: "s1", seq: 1, author: "analyst", action: "rename",
            subject: .init(kind: "type", ref: "0x1", image: "Fixture"), predicate: "hasName", value: .string("Renamed"))
        XCTAssertNil(store.acceptAnnotation(annotation, in: slot))
        store.stageAnalystFinding(from: try result(in: store),
            publicationToken: .capture(intent: .askMacScope, store: store), derivedFrom: [annotation.id])
        let record = try store.acceptPendingAnalystFinding()
        XCTAssertEqual(record.standing, .active)
        XCTAssertTrue(try store.supportCheck(for: record.id).isFullySupported)
        store.undoManager.undo()
        XCTAssertNil(store.navigatorState(for: slot)?.annotations()[annotation.id])
        XCTAssertEqual(try standing(record.id, in: store), .stale(.factStale))
        XCTAssertTrue(try store.supportCheck(for: record.id).invalidates)
        XCTAssertTrue(store.hasUnsavedChanges)
        store.undoManager.redo()
        XCTAssertNotNil(store.navigatorState(for: slot)?.annotations()[annotation.id])
        XCTAssertEqual(try standing(record.id, in: store), .stale(.factStale), "Restoring evidence is not readmission")
        XCTAssertTrue(store.hasUnsavedChanges)
    }

    // MARK: - staging, acceptance and persistence

    func testAcceptingAnAnswerThatCitesNothingStillWorksAndRecordsNoCitations() throws {
        let store = store()
        let record = try accepted(in: store)
        XCTAssertTrue(record.citations.isEmpty)
        XCTAssertNil(record.citesFacts)
        XCTAssertEqual(record.standing, .active)
        XCTAssertFalse(try XCTUnwrap(store.persistableAnalystFindings()).usesV2Extensions)
    }

    func testAcceptanceRefusesAnAnswerWhoseCitedFactsAreNotInTheState() throws {
        let store = store()
        store.stageAnalystFinding(from: try result(in: store), publicationToken: .capture(intent: .askMacScope, store: store),
                                  derivedFrom: ["f" + String(repeating: "a", count: 64)])
        let pending = try XCTUnwrap(store.pendingAnalystFinding)
        XCTAssertEqual(pending.citations.map(\.id), ["f" + String(repeating: "a", count: 64)])
        XCTAssertNil(pending.citations[0].generation, "An id nothing knows keeps a bare citation")
        let generation = store.mutationGeneration
        assertRefuses(.supportNotConfirmed) { _ = try store.acceptPendingAnalystFinding() }
        XCTAssertTrue(store.analystFindings.isEmpty)
        XCTAssertEqual(store.mutationGeneration, generation)
        XCTAssertFalse(store.undoManager.canUndo)
    }

    func testCitationsAreResolvedAgainstTheStateWhenAnAnswerIsStaged() throws {
        let evidence = try fact("0x1", name: "Alpha")
        let state = NavigatorContractStore(toolchain: "fixture-toolchain", baseFacts: [evidence])
        let citations = AnalystFindingDraftConversion.citations(
            derivedFrom: [evidence.id, evidence.id, "unknown"], in: source(state), slot: nil)
        XCTAssertEqual(citations, [citation(evidence), FactCitation(id: "unknown", generation: nil, slot: nil)])
        XCTAssertEqual(AnalystFindingDraftConversion.citations(derivedFrom: [evidence.id], in: source(state), slot: ImageSlot(rawValue: 4)),
                       [FactCitation(id: evidence.id, generation: nil, slot: ImageSlot(rawValue: 4))])
        XCTAssertTrue(AnalystFindingDraftConversion.citations(derivedFrom: [], in: source(state), slot: nil).isEmpty)
    }

    func testCitingFindingsAndTheirStandingSurviveAPackagePayloadRoundTrip() throws {
        let store = store()
        let evidence = try fact("0x1", name: "Alpha")
        let record = try install([[citation(evidence)]], in: store)[0]
        _ = try store.markAnalystFindingStale(record.id, reason: .imageChanged)
        let expected = store.analystFindings
        let payload = try store.makePackagePayload()
        let captured = try MacScopeDocumentPackage.validatedContents(manifestData: payload.manifestData,
            attachmentsByBinaryID: payload.attachmentsByBinaryID, reconstructionState: payload.reconstructionState,
            instructionSidecarData: payload.instructionSidecarData)
        XCTAssertEqual(captured.manifest.analystFindings, expected)
        XCTAssertEqual(captured.manifest.analystFindings?.records[0].citations, [citation(evidence)])
        XCTAssertEqual(captured.manifest.analystFindings?.records[0].standing, .stale(.imageChanged))
        let features = captured.manifest.requiredReaderFeatures
        XCTAssertTrue(features.contains(WorkspacePackageManifest.analystFindingsReaderFeature))
        XCTAssertTrue(features.contains(WorkspacePackageManifest.analystFindingHistoryReaderFeature))
        XCTAssertTrue(features.contains(WorkspacePackageManifest.analystFindingCitationsReaderFeature))
    }

    func testFindingsWrittenBeforeCitationsExistReopenAndSaveAsVersionTwoWithoutLoss() throws {
        let store = store()
        let record = try accepted(in: store)
        let original = try XCTUnwrap(store.persistableAnalystFindings())
        XCTAssertEqual(original.schemaVersion, 1)
        let payload = try store.makePackagePayload()
        let captured = try MacScopeDocumentPackage.validatedContents(manifestData: payload.manifestData,
            attachmentsByBinaryID: payload.attachmentsByBinaryID, reconstructionState: payload.reconstructionState,
            instructionSidecarData: payload.instructionSidecarData)
        XCTAssertEqual(captured.manifest.analystFindings, original)
        XCTAssertEqual(captured.manifest.analystFindings?.records[0].content, record.content)
        let features = captured.manifest.requiredReaderFeatures
        XCTAssertTrue(features.contains(WorkspacePackageManifest.analystFindingsReaderFeature))
        XCTAssertTrue(features.contains(WorkspacePackageManifest.analystFindingCitationsReaderFeature))
        XCTAssertFalse(features.contains(WorkspacePackageManifest.analystFindingHistoryReaderFeature))
    }
}

private struct InvalidationNativeFixture {
        let workspace: Phase2ReadWorkspaceIdentity
        let revision: UInt64
        var precondition: Phase2ReadPrecondition {
            .init(workspace: workspace, workspaceRevision: revision, strictWholeWorkspace: true,
                  image: nil, dependencies: [])
        }
        var current: Phase2ReadCurrentState {
            .init(workspace: workspace, workspaceRevision: revision, image: nil, facetRevisions: [])
        }
        func execution(data: Phase2ReadCandidateData = .value(.text("Original native fact")),
                       evidenceID: UUID = UUID()) throws -> Phase2ReadExecution {
            let descriptor = Phase2ReadOperationDescriptor(registryVersion: .v1, id: .workspaceSummary,
                operationVersion: .v1, effects: [.a1])
            let candidate = Phase2ReadEvidenceCandidate(candidateID: UUID(), invocationID: UUID(), sequence: 1,
                registryVersion: .v1, operationID: .workspaceSummary, operationVersion: .v1,
                producingPrincipal: .app, precondition: precondition,
                citations: [.init(id: UUID(), target: .workspace(workspace), dependencies: [])],
                data: data, cancelled: false)
            let request = Phase2ReadRequest(requestID: UUID(), invocationID: candidate.invocationID, sequence: 1,
                proposingPrincipal: .model, descriptor: descriptor, subject: .workspace(workspace),
                precondition: precondition, limits: .maximum)
            let authorization = Phase2ReadAuthorization(request: request, canonicalDescriptor: descriptor,
                authorizingPrincipal: .app, approvedLimits: .maximum)
            var acceptor = Phase2EvidenceAcceptor()
            let terminal = acceptor.evaluate(candidate, authorization: authorization, against: current,
                                             acceptingEvidenceID: evidenceID)
            _ = try XCTUnwrap(acceptor.acceptedEvidence(for: candidate.invocationID))
            return .init(candidate: candidate, outcome: terminal,
                         acceptedEvidence: acceptor.acceptedEvidence(for: candidate.invocationID))
        }
        func context(_ executions: [Phase2ReadExecution]) throws -> Phase2GroundedContext {
            let evidence = try executions.map { try XCTUnwrap($0.acceptedEvidence) }
            return try Phase2GroundedContextCompiler().compile(records: evidence,
                currentStateByEvidenceID: Dictionary(uniqueKeysWithValues: evidence.map { ($0.evidenceID, current) }))
        }
        func request(_ context: Phase2GroundedContext, phase: Phase2InferencePhase = .finalization,
                     workspaceOverride: Phase2ReadWorkspaceIdentity? = nil,
                     revision: UInt64 = 1) -> Phase2InferenceRequest {
            .init(protocolVersion: .init(rawValue: Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion),
                phase: phase, sessionID: UUID(), turnID: UUID(), requestID: UUID(),
                document: workspace.document, workspace: workspaceOverride ?? workspace,
                lifecycleRevision: revision, userGoal: "Authored goal", groundedContext: context,
                toolHandles: [], limits: .assistantMaximum)
        }
        func result(_ context: Phase2GroundedContext, executions: [Phase2ReadExecution],
                    evidenceIDs: [UUID]? = nil, text: String = "Entire authored answer\nΩ",
                    kind: Phase2InferenceFinalKind = .answer,
                    request: Phase2InferenceRequest? = nil, omitRequest: Bool = false,
                    provider: UInt64? = 7, disposition: Phase2InferenceDisposition = .completed,
                    unverified: [String] = [], failure: Phase2AssistantSessionFailure? = nil,
                    omitContext: Bool = false, primary: Phase2ReadExecution? = nil) -> Phase2AssistantSessionResult {
            let candidate = Phase2InferenceFinalCandidate(kind: kind, text: text,
                evidenceIDs: evidenceIDs ?? context.records.map(\.evidenceID))
            return .init(intent: .askMacScope, request: omitRequest ? nil : (request ?? self.request(context)),
                groundedContext: omitContext ? nil : context, readExecution: primary ?? executions.first, readExecutions: executions,
                inferenceOutcome: .init(disposition: disposition, previewDeltas: [], toolProposals: [],
                    finalCandidate: candidate, providerUsage: nil, violation: nil,
                    acceptedEventCount: 1, cumulativeEventBytes: 1),
                providerRevision: provider, failure: failure, unverifiedAddresses: unverified)
        }
        func states(_ context: Phase2GroundedContext) -> [UUID: Phase2ReadCurrentState] {
            Dictionary(uniqueKeysWithValues: context.records.map { ($0.evidenceID, current) })
        }
    }
