import Foundation
import XCTest
@testable import MacScope

/// Workspace ownership of the navigator store: the undoable entry points, the mutation funnel and
/// the analyst-edit mirrors. Hermetic: one in-memory binary with an artifact identity and no bytes,
/// so no producer run starts.
@MainActor
final class NavigatorStateBridgeTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)
    private let image = "nouuid/aaaaaaaaaaaaaaaa"
    private let toolchain = "toolchain-key/1|test"

    private func identity() throws -> MachOSliceArtifactIdentity {
        try MachOSliceArtifactIdentity(uuid: nil, rawCPUType: MachOConstants.cpuTypeARM64, rawCPUSubtype: 0,
                                       selectedSliceSHA256: digest, selectedSliceByteCount: 256)
    }

    private func makeStore() throws -> WorkspaceStore {
        let binary = BinaryImage(id: UUID(), name: "fixture", path: "/not-opened/fixture", kind: "raw fixture",
                                 architecture: "arm64", artifactIdentity: try identity())
        return WorkspaceStore(workspaceName: "Navigator bridge fixture",
                              snapshot: .init(binaries: [binary], analysisBySlot: [.primary: ImageAnalysis()]),
                              engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    private func subject(_ ref: String = "0x1000") -> NavigatorSubject {
        NavigatorSubject(kind: "address", ref: ref, image: image)
    }

    /// A proven fact cites a certificate by content hash; the fixture's hash names no certificate,
    /// which the form check accepts (resolution is the producer landing's job).
    private let certificateRef = "sha256:" + String(repeating: "0", count: 64)

    private func fact(_ predicate: String, _ value: NavigatorJSONValue, status: String) throws -> NavigatorFact {
        var provenance = [NavigatorProvenance(kind: "loaderRecord", ref: "loader 0x1000",
                                              rule: "test.rule", ruleVersion: "1")]
        if status == "proven" {
            provenance.append(NavigatorProvenance(kind: "proofCertificate", ref: certificateRef))
        }
        return try NavigatorFact.make(subject: subject(), predicate: predicate, value: value, status: status,
                                      provenance: provenance, toolchain: toolchain)
    }

    private func result(_ facts: [NavigatorFact]) -> NavigatorPrimitiveResult {
        NavigatorPrimitiveResult(primitive: "test.primitive", primitiveVersion: "1",
                                 subject: NavigatorSubject(kind: "image", ref: image), budget: [:], facts: facts)
    }

    private func analystNote(_ action: String, _ predicate: String, _ value: NavigatorJSONValue,
                             seq: Int64 = 0) throws -> NavigatorAnnotation {
        try NavigatorAnnotation.make(session: NavigatorStateBridge.analystSession, seq: seq, author: "analyst",
                                     action: action, subject: subject(), predicate: predicate, value: value)
    }

    // MARK: - Reading

    private func state(_ store: WorkspaceStore, file: StaticString = #filePath, line: UInt = #line) throws
        -> NavigatorContractStore {
        try XCTUnwrap(store.navigatorState(for: .primary), "the slot has a navigator store", file: file, line: line)
    }

    func testEmptySlotHasNoStoreAndPersistsNothing() throws {
        let store = try makeStore()
        XCTAssertNil(store.navigatorStates[.primary])
        XCTAssertNil(store.navigatorState(for: .primary))
        XCTAssertNil(store.persistableNavigatorState())
        XCTAssertNil(store.navigatorProducerRunsBySlot[.primary])
        XCTAssertEqual(store.previewNavigatorRevert("revert:not-an-id", in: .primary).refusal?.code, "malformedInput")
    }

    func testGenerationOfASliceWithIdentityUsesItsImageRef() throws {
        let store = try makeStore()
        let generation = try XCTUnwrap(store.navigatorGeneration(for: .primary))
        XCTAssertEqual(generation.imageIdentity, image)
        XCTAssertEqual(generation.knowledgeVersion, NavigatorStateBridge.knowledgeVersion)
        XCTAssertTrue(AnalysisFacetFingerprint.isLowercaseSHA256(generation.inputKey))
        XCTAssertEqual(store.navigatorGeneration(for: .primary), generation, "the generation is a pure function")
        XCTAssertNil(store.navigatorGeneration(for: ImageSlot(rawValue: 7)))
    }

    // MARK: - acceptAnnotation

    func testAcceptAnnotationIsOneNamedUndoStepThatRestoresDirtyState() throws {
        let store = try makeStore()
        let wasDirty = store.isDirty
        let note = try analystNote("setFact", "isFunctionStart", .bool(true))

        XCTAssertNil(store.acceptAnnotation(note, in: .primary))
        XCTAssertEqual(store.undoManager.undoActionName, "Accept Annotation")
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(try state(store).toolchain, NavigatorStateBridge.pendingToolchain)
        XCTAssertEqual(try state(store).liveAnnotations().map(\.id), [note.id])
        XCTAssertEqual(try state(store).display(subject(), "isFunctionStart").values, ["true"])

        XCTAssertEqual(store.acceptAnnotation(note, in: .primary)?.code, "preconditionFailed")
        XCTAssertEqual(try state(store).annotations().count, 1)

        store.undoManager.undo()
        XCTAssertNil(store.navigatorStates[.primary], "undo restores the slot's previous (absent) store")
        XCTAssertEqual(store.isDirty, wasDirty)

        store.undoManager.redo()
        XCTAssertEqual(try state(store).liveAnnotations().map(\.id), [note.id])
        XCTAssertTrue(store.isDirty)
    }

    func testRefusedAcceptRegistersNothing() throws {
        let store = try makeStore()
        let uncited = try NavigatorAnnotation.make(
            session: NavigatorStateBridge.navigatorSession, seq: 0, author: "navigator", action: "rename",
            subject: subject(), predicate: "hasName", value: .string("main"),
            cites: [try fact("hasName", .string("main"), status: "authoritative").id], rationale: "cites a fact never added")
        let couldUndo = store.undoManager.canUndo
        let wasDirty = store.isDirty
        XCTAssertEqual(store.acceptAnnotation(uncited, in: .primary)?.code, "unknownFact")
        XCTAssertNil(store.navigatorStates[.primary])
        XCTAssertEqual(store.undoManager.canUndo, couldUndo)
        XCTAssertEqual(store.isDirty, wasDirty)
    }

    // MARK: - Command-form mutation

    func testCommandFormMutationIsOneNamedUndoStepAndARefusalRegistersNothing() throws {
        let store = try makeStore()
        let wasDirty = store.isDirty
        let couldUndo = store.undoManager.canUndo
        let refused = store.registerAndApplyNavigatorMutation({ (state: inout NavigatorContractStore) -> NavigatorRefusal? in
            state.revert("revert:not-an-id", session: NavigatorStateBridge.navigatorSession)
        }, in: .primary)
        XCTAssertEqual(refused?.code, "malformedInput")
        XCTAssertNil(store.navigatorStates[.primary])
        XCTAssertEqual(store.undoManager.canUndo, couldUndo)
        XCTAssertEqual(store.isDirty, wasDirty)

        let note = try analystNote("setFact", "isFunctionStart", .bool(true))
        let accepted = store.registerAndApplyNavigatorMutation({ (state: inout NavigatorContractStore) -> NavigatorRefusal? in
            state.accept(note)
        }, in: .primary)
        XCTAssertNil(accepted)
        XCTAssertEqual(store.undoManager.undoActionName, "Navigator Change")
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(try state(store).liveAnnotations().map(\.id), [note.id])

        store.undoManager.undo()
        XCTAssertNil(store.navigatorStates[.primary])
        XCTAssertEqual(store.isDirty, wasDirty)
    }

    // MARK: - revertNavigator

    func testRevertNavigatorPreviewsRevertsAndUndoes() throws {
        let store = try makeStore()
        let proven = try fact("hasType", .string("int"), status: "proven")
        let authoritative = try fact("hasName", .string("main"), status: "authoritative")
        let wasDirty = store.isDirty
        let added = store.registerAndApplyNavigatorMutation(in: .primary, undoable: false, marksDocument: false) {
            $0.add(self.result([proven, authoritative]), session: "fixture")
        }
        XCTAssertNil(added)
        XCTAssertEqual(store.isDirty, wasDirty, "a non-dirtying mutation leaves the document state alone")
        XCTAssertEqual(Set(try state(store).liveFacts().keys), [proven.id, authoritative.id])

        let preview = store.previewNavigatorRevert(proven.revert, in: .primary)
        XCTAssertNil(preview.refusal)
        XCTAssertEqual(preview.factsLost, [proven.id])
        XCTAssertTrue(preview.annotationsAffected.isEmpty)
        XCTAssertNotNil(try state(store).liveFacts()[proven.id], "a preview mutates nothing")

        XCTAssertNil(store.revertNavigator(proven.revert, in: .primary))
        XCTAssertEqual(store.undoManager.undoActionName, "Revert Navigator Fact")
        XCTAssertTrue(store.isDirty)
        XCTAssertNil(try state(store).liveFacts()[proven.id])
        XCTAssertEqual(store.revertNavigator(proven.revert, in: .primary)?.code, "unknownFact")

        store.undoManager.undo()
        XCTAssertNotNil(try state(store).liveFacts()[proven.id])
        XCTAssertEqual(store.isDirty, wasDirty)

        XCTAssertEqual(store.previewNavigatorRevert(authoritative.revert, in: .primary).refusal?.code, "notReversible")
        XCTAssertEqual(store.revertNavigator(authoritative.revert, in: .primary)?.code, "notReversible")
        XCTAssertNotNil(try state(store).liveFacts()[authoritative.id])
    }

    // MARK: - Override mirror

    func testRenameIsMirroredAsAnAnalystAnnotationInsideTheEditsUndoGroup() throws {
        let store = try makeStore()
        store.setCustomName(0x1000, in: .primary, name: "entry")
        let entry = try analystNote("rename", "hasName", .string("entry"))
        var current = try state(store)
        XCTAssertEqual(store.undoManager.undoActionName, "Rename")
        XCTAssertEqual(current.liveAnnotations().map(\.id), [entry.id])
        XCTAssertEqual(current.liveAnnotations().first?.subject, subject())
        XCTAssertEqual(current.liveAnnotations().first?.session, NavigatorStateBridge.analystSession)
        XCTAssertEqual(current.liveAnnotations().first?.seq, 0)
        XCTAssertEqual(current.display(subject(), "hasName"),
                       NavigatorContractStore.Displayed(source: "analyst", values: ["\"entry\""], support: [entry.id]))

        store.setCustomName(0x1000, in: .primary, name: "start")
        current = try state(store)
        XCTAssertEqual(current.liveAnnotations().count, 2)
        XCTAssertEqual(current.display(subject(), "hasName").values, ["\"start\""], "the latest analyst value shows")

        store.undoManager.undo()
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1000)]?.customName, "entry")
        current = try state(store)
        XCTAssertEqual(current.liveAnnotations().map(\.id), [entry.id])
        XCTAssertEqual(current.display(subject(), "hasName").values, ["\"entry\""])

        store.setCustomName(0x1000, in: .primary, name: nil)
        XCTAssertNil(store.snapshot.addressOverrides[.primary(0x1000)])
        current = try state(store)
        XCTAssertTrue(current.liveAnnotations().isEmpty, "clearing the name reverts its analyst annotation")
        XCTAssertEqual(current.annotations()[entry.id]?.reverted, true)
        XCTAssertEqual(current.display(subject(), "hasName").source, "fallback")

        store.undoManager.undo()
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1000)]?.customName, "entry")
        XCTAssertEqual(try state(store).display(subject(), "hasName").values, ["\"entry\""])

        store.undoManager.undo()
        XCTAssertNil(store.snapshot.addressOverrides[.primary(0x1000)])
        XCTAssertNil(store.navigatorStates[.primary], "undoing the first rename drops the mirror with it")
    }

    // MARK: - Manual-xref mirror

    func testCallXRefEditsAreMirroredAsCallsTargetAnnotations() throws {
        let store = try makeStore()
        store.addManualXRef(from: 0x1000, to: 0x2000, kind: XRefKind.call, in: .primary)
        var shown = try state(store).display(subject(), "callsTarget")
        XCTAssertEqual(shown.source, "analyst")
        XCTAssertEqual(shown.values, ["\"0x2000\""])
        let first = try XCTUnwrap(try state(store).liveAnnotations().first)
        XCTAssertEqual(first.action, "addXref")
        XCTAssertEqual(first.subject, subject())

        store.addManualXRef(from: 0x1000, to: 0x3000, kind: XRefKind.call, in: .primary)
        shown = try state(store).display(subject(), "callsTarget")
        XCTAssertEqual(shown.values, ["\"0x2000\"", "\"0x3000\""], "callsTarget is multi-valued")
        XCTAssertFalse(shown.conflict)

        let edge = try XCTUnwrap(store.snapshot.manualXRefs.first { $0.to == 0x2000 })
        store.removeManualXRef(id: edge.id)
        XCTAssertEqual(try state(store).display(subject(), "callsTarget").values, ["\"0x3000\""])

        store.undoManager.undo()
        XCTAssertEqual(try state(store).display(subject(), "callsTarget").values,
                       ["\"0x2000\"", "\"0x3000\""])

        let annotationsBefore = try state(store).annotations()
        store.addManualXRef(from: 0x1000, to: 0x4000, kind: XRefKind.data, in: .primary)
        XCTAssertTrue(store.snapshot.manualXRefs.contains { $0.to == 0x4000 })
        XCTAssertEqual(try state(store).annotations(), annotationsBefore,
                       "non-call kinds have no contract predicate")
    }
}
