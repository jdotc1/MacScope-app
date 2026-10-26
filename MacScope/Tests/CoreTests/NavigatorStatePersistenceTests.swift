import Foundation
import XCTest
@testable import MacScope

/// Persistence of the navigator store: the per-slot envelope (stale marks, generation, shape and
/// decode failures, canonical-ref warnings), the manifest key, and a package save and reopen.
/// Hermetic: records are built in memory and the package fixture is a raw 256-byte image.
@MainActor
final class NavigatorStatePersistenceTests: XCTestCase {
    private let toolchain = "toolchain-key/1|test"
    private let image = "nouuid/aaaaaaaaaaaaaaaa"

    private func subject(_ ref: String = "0x1000") -> NavigatorSubject {
        NavigatorSubject(kind: "address", ref: ref, image: image)
    }

    private func provenance() -> [NavigatorProvenance] {
        [NavigatorProvenance(kind: "loaderRecord", ref: "loader 0x1000", rule: "test.rule", ruleVersion: "1")]
    }

    private func fact(_ predicate: String, _ value: NavigatorJSONValue, subject: NavigatorSubject? = nil,
                      dependsOn: [String]? = nil) throws -> NavigatorFact {
        try NavigatorFact.make(subject: subject ?? self.subject(), predicate: predicate, value: value,
                               status: "authoritative", provenance: provenance(), toolchain: toolchain,
                               dependsOn: dependsOn)
    }

    private func result(_ facts: [NavigatorFact]) -> NavigatorPrimitiveResult {
        NavigatorPrimitiveResult(primitive: "test.primitive", primitiveVersion: "1",
                                 subject: NavigatorSubject(kind: "image", ref: image), budget: [:], facts: facts)
    }

    /// A store with two facts, an analyst annotation citing the first and a stale mark on the second.
    private func fencedStore() throws -> (store: NavigatorContractStore, name: NavigatorFact, type: NavigatorFact,
                                          note: NavigatorAnnotation) {
        var store = NavigatorContractStore(toolchain: toolchain)
        let name = try fact("hasName", .string("main"), dependsOn: ["machOLoadMetadata"])
        let type = try fact("hasType", .string("int"), dependsOn: ["machOLoadMetadata"])
        XCTAssertNil(store.add(result([name, type]), session: "producer"))
        let note = try NavigatorAnnotation.make(session: NavigatorStateBridge.analystSession, seq: 0, author: "analyst",
                                                action: "rename", subject: subject(), predicate: "hasName",
                                                value: .string("entry"), cites: [name.id])
        XCTAssertNil(store.accept(note))
        XCTAssertEqual(store.markStale([type.id]), [type.id])
        return (store, name, type, note)
    }

    private func manifest(_ navigatorState: [String: NavigatorEngineStateEnvelope]?) -> WorkspacePackageManifest {
        WorkspacePackageManifest(
            documentID: UUID(uuidString: "B0000000-0000-4000-8000-000000000001")!,
            workspaceUUID: UUID(uuidString: "B0000000-0000-4000-8000-000000000002")!,
            workspaceName: "Navigator state",
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 1),
            binaries: [],
            session: nil,
            navigatorState: navigatorState
        )
    }

    private func packageURL() throws -> URL {
        let root = TestWorkRoot.scratch
            .appendingPathComponent("navigator-state-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("Navigator.mscope")
    }

    private func assertFailure(_ envelope: NavigatorEngineStateEnvelope, _ expected: NavigatorEngineStateEnvelope.Failure,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try envelope.decodedState(), file: file, line: line) { error in
            XCTAssertEqual(error as? NavigatorEngineStateEnvelope.Failure, expected, file: file, line: line)
        }
    }

    // MARK: - Envelope

    func testEnvelopeRoundTripCarriesStateGenerationAndStaleMarks() throws {
        let (store, name, type, note) = try fencedStore()
        let generation = NavigatorGeneration(imageIdentity: image, inputKey: String(repeating: "b", count: 64),
                                             knowledgeVersion: NavigatorStateBridge.knowledgeVersion)
        let envelope = try NavigatorEngineStateEnvelope(store: store, generation: generation)
        XCTAssertEqual(envelope.schema, NavigatorEngineStateEnvelope.currentSchema)
        XCTAssertEqual(envelope.generation, generation)
        XCTAssertEqual(envelope.staleGeneration, [type.id])
        XCTAssertNoThrow(try envelope.validateShape())

        let data = try JSONEncoder().encode(envelope)
        let decodedEnvelope = try JSONDecoder().decode(NavigatorEngineStateEnvelope.self, from: data)
        XCTAssertEqual(decodedEnvelope, envelope)

        let decoded = try decodedEnvelope.decodedState()
        XCTAssertEqual(decoded.state, store.state())
        XCTAssertTrue(decoded.warnings.isEmpty)

        let restored = NavigatorContractStore(state: decoded.state, staleGeneration: decodedEnvelope.staleGeneration ?? [])
        XCTAssertEqual(restored.staleGeneration, store.staleGeneration)
        XCTAssertEqual(restored.state(), store.state())
        XCTAssertEqual(Array(restored.liveFacts().keys), [name.id])
        XCTAssertEqual(restored.liveAnnotations().map(\.id), [note.id])
    }

    func testEnvelopeWithoutStaleMarksEncodesNoStaleField() throws {
        var store = NavigatorContractStore(toolchain: toolchain)
        XCTAssertNil(store.add(result([try fact("hasName", .string("main"))]), session: "producer"))
        let envelope = try NavigatorEngineStateEnvelope(store: store, generation: nil)
        XCTAssertNil(envelope.staleGeneration)
        XCTAssertNil(envelope.generation)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schema", "state"])
    }

    func testShapeAndDecodeFailuresAreTyped() throws {
        assertFailure(NavigatorEngineStateEnvelope(schema: 2, state: "{}"), .unsupportedSchema(2))
        assertFailure(NavigatorEngineStateEnvelope(state: "{}", staleGeneration: ["bogus"]), .invalidStaleMark("bogus"))

        let oversize = String(repeating: " ", count: NavigatorEngineStateEnvelope.maximumStateBytes + 1)
        assertFailure(NavigatorEngineStateEnvelope(state: oversize), .stateTooLarge(NavigatorEngineStateEnvelope.maximumStateBytes + 1))

        XCTAssertThrowsError(try NavigatorEngineStateEnvelope(state: "{").decodedState()) { error in
            guard case .undecodableState = error as? NavigatorEngineStateEnvelope.Failure else {
                return XCTFail("expected undecodableState, got \(error)")
            }
        }
        assertFailure(NavigatorEngineStateEnvelope(state: "{}"), .invalidState(["$: unknown record kind"]))
    }

    func testLegacyNonCanonicalRefsDecodeWithWarnings() throws {
        var store = NavigatorContractStore(toolchain: toolchain)
        let legacy = try fact("hasName", .string("Point"), subject: NavigatorSubject(kind: "type", ref: "0x1000", image: "Fixture"))
        XCTAssertNil(store.add(result([legacy]), session: "producer"))
        let envelope = try NavigatorEngineStateEnvelope(store: store, generation: nil)
        let decoded = try envelope.decodedState()
        XCTAssertEqual(decoded.warnings, ["state.facts[0].subject.image: not a canonical image ref"])
        XCTAssertEqual(decoded.state, store.state())
    }

    // MARK: - Manifest

    func testManifestKeyIsOmittedWhenAbsentAndRoundTripsWhenPresent() throws {
        let absent = try JSONEncoder().encode(manifest(nil))
        let absentObject = try XCTUnwrap(JSONSerialization.jsonObject(with: absent) as? [String: Any])
        XCTAssertNil(absentObject["navigatorState"])
        let decodedAbsent = try JSONDecoder().decode(WorkspacePackageManifest.self, from: absent)
        XCTAssertNil(decodedAbsent.navigatorState)
        XCTAssertFalse(decodedAbsent.navigatorStateUndecodable)

        let envelope = try NavigatorEngineStateEnvelope(store: try fencedStore().store, generation: nil)
        let present = manifest(["0": envelope])
        let data = try JSONEncoder().encode(present)
        let presentObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(presentObject["navigatorState"])
        let decoded = try JSONDecoder().decode(WorkspacePackageManifest.self, from: data)
        XCTAssertEqual(decoded.navigatorState, ["0": envelope])
        XCTAssertFalse(decoded.navigatorStateUndecodable)
        XCTAssertEqual(decoded, present)
    }

    func testUndecodableManifestValueOpensEmptyAndIsFlagged() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest(nil))) as? [String: Any])
        object["navigatorState"] = ["0": ["schema": "x"]]
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(WorkspacePackageManifest.self, from: data)
        XCTAssertNil(decoded.navigatorState)
        XCTAssertTrue(decoded.navigatorStateUndecodable)

        let reencoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertNil(reencoded["navigatorState"], "the flag is never encoded and the bad value is not written back")
    }

    // MARK: - Package save and reopen

    func testPackageSaveAndReopenRestoresTheMirroredAnnotation() throws {
        let binary = BinaryImage(id: UUID(), name: "raw", path: "/not-opened/raw", kind: "raw fixture", architecture: "arm64")
        var analysis = ImageAnalysis()
        analysis.imageBytes = Data(repeating: 0, count: 256)
        analysis.hexBytes = analysis.imageBytes
        let source = WorkspaceStore(workspaceName: "Navigator persistence fixture",
                                    snapshot: .init(binaries: [binary], analysisBySlot: [.primary: analysis]),
                                    engine: AnalysisEngine(), autosaveScheduler: nil)
        source.setCustomName(0x1000, in: .primary, name: "entry")

        // No artifact identity: the mirrored subject carries no image ref.
        let address = NavigatorSubject(kind: "address", ref: "0x1000")
        let entry = try NavigatorAnnotation.make(session: NavigatorStateBridge.analystSession, seq: 0, author: "analyst",
                                                 action: "rename", subject: address, predicate: "hasName",
                                                 value: .string("entry"))
        XCTAssertEqual(try XCTUnwrap(source.navigatorState(for: .primary)).liveAnnotations().map(\.id), [entry.id])

        let written = try source.writeDocumentPackageThrowing(to: try packageURL())
        let saved = try XCTUnwrap(written.manifest.navigatorState)
        XCTAssertEqual(Array(saved.keys), ["0"])
        XCTAssertTrue(written.manifest.requiredReaderFeatures.contains(WorkspacePackageManifest.navigatorStateReaderFeature))
        XCTAssertTrue(try XCTUnwrap(saved["0"]).decodedState().warnings.isEmpty)

        let onDisk = try MacScopeDocumentPackage.validatedManifest(
            manifestData: Data(contentsOf: MacScopeDocumentPackage.manifestURL(in: written.url)))
        XCTAssertEqual(onDisk.navigatorState, saved)
        XCTAssertFalse(onDisk.navigatorStateUndecodable)

        let reopened = try WorkspaceStore.restoredPackage(from: written.url, scheduleDurableRecovery: false)
        let state = try XCTUnwrap(reopened.navigatorState(for: .primary))
        XCTAssertEqual(state.liveAnnotations().map(\.id), [entry.id])
        XCTAssertEqual(state.display(address, "hasName").source, "analyst")
        XCTAssertEqual(state.display(address, "hasName").values, ["\"entry\""])
        XCTAssertEqual(reopened.snapshot.addressOverrides[.primary(0x1000)]?.customName, "entry")
        XCTAssertFalse(reopened.isDirty, "restoring navigator state does not dirty the document")
    }

    func testWorkspaceWithoutNavigatorStateSavesNoKeyOrReaderFeature() throws {
        let binary = BinaryImage(id: UUID(), name: "raw", path: "/not-opened/raw", kind: "raw fixture", architecture: "arm64")
        var analysis = ImageAnalysis()
        analysis.imageBytes = Data(repeating: 0, count: 256)
        analysis.hexBytes = analysis.imageBytes
        let source = WorkspaceStore(workspaceName: "Navigator persistence fixture",
                                    snapshot: .init(binaries: [binary], analysisBySlot: [.primary: analysis]),
                                    engine: AnalysisEngine(), autosaveScheduler: nil)
        XCTAssertNil(source.persistableNavigatorState())
        let written = try source.writeDocumentPackageThrowing(to: try packageURL())
        XCTAssertNil(written.manifest.navigatorState)
        XCTAssertFalse(written.manifest.requiredReaderFeatures.contains(WorkspacePackageManifest.navigatorStateReaderFeature))
        let reopened = try WorkspaceStore.restoredPackage(from: written.url, scheduleDurableRecovery: false)
        XCTAssertNil(reopened.navigatorStates[.primary])
    }
}
