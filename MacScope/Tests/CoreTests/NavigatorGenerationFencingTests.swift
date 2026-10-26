import Foundation
import XCTest
@testable import MacScope

/// Generation fencing: which fingerprint facets changed between two landings, which facts go stale
/// for them, and the workspace landing hook (non-undoable, non-dirtying, image change marks all).
/// Hermetic: fingerprints are built from repeated-digit digests; the binary carries no bytes, so no
/// producer run starts.
@MainActor
final class NavigatorGenerationFencingTests: XCTestCase {
    private let toolchain = "toolchain-key/1|test"
    private let image = "nouuid/aaaaaaaaaaaaaaaa"

    private func sha(_ digit: Character) -> String { String(repeating: digit, count: 64) }

    private func fingerprint(_ facets: [(AnalysisFingerprintFacetKind, Character)],
                             binaryID: UUID = UUID(uuidString: "C0000000-0000-4000-8000-000000000001")!)
        throws -> AnalysisInputFingerprint {
        try AnalysisInputFingerprint(
            imageSlot: .primary, binaryID: binaryID, binaryName: "fixture", binaryPath: "/not-opened/fixture",
            selectedSliceIndex: nil, artifactIdentity: nil, imageByteCount: 256, imageBytesSHA256: sha("a"),
            facets: try facets.map { try AnalysisFacetFingerprint(kind: $0.0, itemCount: 1, sha256: sha($0.1)) },
            overallSHA256: sha("f"))
    }

    private func subject(_ ref: String = "0x1000") -> NavigatorSubject {
        NavigatorSubject(kind: "address", ref: ref, image: image)
    }

    private func fact(_ predicate: String, _ value: NavigatorJSONValue, dependsOn: [String]?) throws -> NavigatorFact {
        try NavigatorFact.make(subject: subject(), predicate: predicate, value: value, status: "authoritative",
                               provenance: [NavigatorProvenance(kind: "loaderRecord", ref: "loader 0x1000",
                                                                rule: "test.rule", ruleVersion: "1")],
                               toolchain: toolchain, dependsOn: dependsOn)
    }

    private func result(_ facts: [NavigatorFact]) -> NavigatorPrimitiveResult {
        NavigatorPrimitiveResult(primitive: "test.primitive", primitiveVersion: "1",
                                 subject: NavigatorSubject(kind: "image", ref: image), budget: [:], facts: facts)
    }

    /// a depends on load metadata, b on xrefs, c on nothing.
    private func facts() throws -> (a: NavigatorFact, b: NavigatorFact, c: NavigatorFact) {
        (try fact("hasName", .string("main"), dependsOn: [AnalysisFingerprintFacetKind.machOLoadMetadata.rawValue]),
         try fact("callsTarget", .string("0x2000"), dependsOn: [AnalysisFingerprintFacetKind.xrefs.rawValue]),
         try fact("isFunctionStart", .bool(true), dependsOn: nil))
    }

    private func makeStore(fingerprint: AnalysisInputFingerprint?) throws -> WorkspaceStore {
        let identity = try MachOSliceArtifactIdentity(uuid: nil, rawCPUType: MachOConstants.cpuTypeARM64, rawCPUSubtype: 0,
                                                      selectedSliceSHA256: sha("a"), selectedSliceByteCount: 256)
        let binary = BinaryImage(id: UUID(), name: "fixture", path: "/not-opened/fixture", kind: "raw fixture",
                                 architecture: "arm64", artifactIdentity: identity)
        var analysis = ImageAnalysis()
        analysis.analysisInputFingerprint = fingerprint
        return WorkspaceStore(workspaceName: "Navigator fencing fixture",
                              snapshot: .init(binaries: [binary], analysisBySlot: [.primary: analysis]),
                              engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    // MARK: - changedFacets

    func testChangedFacetsComparesFacetDigestsAndTreatsUnknownAsChanged() throws {
        let all = Set(AnalysisFingerprintFacetKind.allCases.map(\.rawValue))
        XCTAssertEqual(all.count, 10)
        XCTAssertEqual(NavigatorStateBridge.changedFacets(previous: nil, current: nil), all)

        let base = try fingerprint([(.machOLoadMetadata, "1"), (.relocations, "2"), (.xrefs, "3")])
        let baseKinds: Set<String> = ["machOLoadMetadata", "relocations", "xrefs"]
        XCTAssertEqual(NavigatorStateBridge.changedFacets(previous: nil, current: base), baseKinds)
        XCTAssertEqual(NavigatorStateBridge.changedFacets(previous: base, current: nil), baseKinds)
        XCTAssertEqual(NavigatorStateBridge.changedFacets(previous: base, current: base), [])

        let relocated = try fingerprint([(.machOLoadMetadata, "1"), (.relocations, "4"), (.xrefs, "3")])
        XCTAssertEqual(NavigatorStateBridge.changedFacets(previous: base, current: relocated), ["relocations"])

        let withoutXRefs = try fingerprint([(.machOLoadMetadata, "1"), (.relocations, "2")])
        XCTAssertEqual(NavigatorStateBridge.changedFacets(previous: base, current: withoutXRefs), ["xrefs"])
        XCTAssertEqual(NavigatorStateBridge.changedFacets(previous: withoutXRefs, current: base), ["xrefs"])
    }

    // MARK: - markStaleGeneration

    func testChangedFacetMarksDependentFactsAndTheirAnnotationsStale() throws {
        let (a, b, c) = try facts()
        var store = NavigatorContractStore(toolchain: toolchain)
        XCTAssertNil(store.add(result([a, b, c]), session: "producer"))
        let note = try NavigatorAnnotation.make(session: NavigatorStateBridge.analystSession, seq: 0, author: "analyst",
                                                action: "setType", subject: subject(), predicate: "hasType",
                                                value: .string("Point"), cites: [a.id])
        XCTAssertNil(store.accept(note))
        let staleItem = try NavigatorFrontierItem.make(subject: subject(), gap: "staleAnnotation",
                                                       detail: "\(note.id) cites a reverted fact", toolchain: toolchain)

        XCTAssertEqual(store.markStaleGeneration(changedFacets: ["machOLoadMetadata"]), [a.id])
        XCTAssertEqual(store.staleGeneration, [a.id])
        XCTAssertEqual(Set(store.liveFacts().keys), [b.id, c.id])
        XCTAssertNotNil(store.allFacts()[a.id], "a stale fact is kept, not reverted")
        XCTAssertFalse(store.revertedTargets().contains(a.id))
        XCTAssertTrue(store.liveAnnotations().isEmpty)
        XCTAssertEqual(store.staleAnnotations().map(\.id), [note.id])
        XCTAssertEqual(store.frontier().filter { $0.gap == "staleAnnotation" }.map(\.id), [staleItem.id])

        XCTAssertEqual(store.markStaleGeneration(changedFacets: ["machOLoadMetadata"]), [], "already stale")
        XCTAssertEqual(store.markStaleGeneration(changedFacets: ["selectedSliceBytes"]), [], "nothing depends on it")
        XCTAssertEqual(store.markStaleGeneration(changedFacets: []), [])

        XCTAssertNil(store.add(result([a]), session: "producer"), "the producer re-asserts the fact")
        XCTAssertTrue(store.staleGeneration.isEmpty)
        XCTAssertEqual(Set(store.liveFacts().keys), [a.id, b.id, c.id])
        XCTAssertEqual(store.liveAnnotations().map(\.id), [note.id])
        XCTAssertTrue(store.frontier().filter { $0.gap == "staleAnnotation" }.isEmpty)
    }

    // MARK: - Workspace landing

    func testLandingFencesOnlyFactsOfChangedFacetsWithoutUndoOrDirtying() throws {
        let previous = try fingerprint([(.machOLoadMetadata, "1"), (.xrefs, "2")])
        let current = try fingerprint([(.machOLoadMetadata, "1"), (.xrefs, "3")])
        let store = try makeStore(fingerprint: current)
        let (a, b, c) = try facts()
        XCTAssertNil(store.registerAndApplyNavigatorMutation(in: .primary, undoable: false, marksDocument: false) {
            $0.add(self.result([a, b, c]), session: "producer")
        })
        let wasDirty = store.isDirty
        let couldUndo = store.undoManager.canUndo

        store.navigatorAnalysisDidLand(in: .primary, previousFingerprint: previous)

        let state = try XCTUnwrap(store.navigatorState(for: .primary))
        XCTAssertEqual(state.staleGeneration, [b.id])
        XCTAssertEqual(Set(state.liveFacts().keys), [a.id, c.id])
        let generation = try XCTUnwrap(store.navigatorGenerations[.primary])
        XCTAssertEqual(generation.imageIdentity, image)
        XCTAssertEqual(generation, store.navigatorGeneration(for: .primary))
        XCTAssertNil(store.navigatorProducerRunsBySlot[.primary], "no image bytes, no producer run")
        XCTAssertEqual(store.isDirty, wasDirty)
        XCTAssertEqual(store.undoManager.canUndo, couldUndo)
    }

    func testLandingWithUnchangedFacetsKeepsEveryFactLive() throws {
        let current = try fingerprint([(.machOLoadMetadata, "1"), (.xrefs, "2")])
        let store = try makeStore(fingerprint: current)
        let (a, b, c) = try facts()
        XCTAssertNil(store.registerAndApplyNavigatorMutation(in: .primary, undoable: false, marksDocument: false) {
            $0.add(self.result([a, b, c]), session: "producer")
        })
        store.navigatorAnalysisDidLand(in: .primary, previousFingerprint: current)
        let state = try XCTUnwrap(store.navigatorState(for: .primary))
        XCTAssertTrue(state.staleGeneration.isEmpty)
        XCTAssertEqual(Set(state.liveFacts().keys), [a.id, b.id, c.id])
    }

    func testLandingUnderADifferentImageMarksEveryFactStale() throws {
        let current = try fingerprint([(.machOLoadMetadata, "1"), (.xrefs, "2")])
        let store = try makeStore(fingerprint: current)
        let (a, b, c) = try facts()
        XCTAssertNil(store.registerAndApplyNavigatorMutation(in: .primary, undoable: false, marksDocument: false) {
            $0.add(self.result([a, b, c]), session: "producer")
        })
        store.navigatorGenerations[.primary] = NavigatorGeneration(
            imageIdentity: "nouuid/bbbbbbbbbbbbbbbb", inputKey: sha("b"), knowledgeVersion: NavigatorStateBridge.knowledgeVersion)

        store.navigatorAnalysisDidLand(in: .primary, previousFingerprint: current)

        let state = try XCTUnwrap(store.navigatorState(for: .primary))
        XCTAssertEqual(state.staleGeneration, [a.id, b.id, c.id])
        XCTAssertTrue(state.liveFacts().isEmpty)
        XCTAssertEqual(store.navigatorGenerations[.primary]?.imageIdentity, image)
    }

    func testLandingOnASlotWithoutStateRecordsOnlyTheGeneration() throws {
        let store = try makeStore(fingerprint: try fingerprint([(.xrefs, "2")]))
        store.navigatorAnalysisDidLand(in: .primary, previousFingerprint: nil)
        XCTAssertNil(store.navigatorStates[.primary])
        XCTAssertEqual(store.navigatorGenerations[.primary]?.imageIdentity, image)
    }
}
