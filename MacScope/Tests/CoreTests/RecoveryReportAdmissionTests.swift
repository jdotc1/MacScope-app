import CryptoKit
import Foundation
import XCTest
@testable import MacScope

@MainActor
final class RecoveryReportAdmissionTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)

    private func identity(slot: Int = 0, subtype: Int32 = 0) throws -> RecoveryImportIdentity {
        let slice = try MachOSliceArtifactIdentity(uuid: nil, rawCPUType: 0x0100000c,
            rawCPUSubtype: subtype, selectedSliceSHA256: digest, selectedSliceByteCount: 4096)
        let content = try ReconstructionContentIdentity(algorithm: .sha256, digest: digest, byteCount: 4096)
        let coordinate = try ReconstructionImageCoordinate(
            artifact: ReconstructionArtifactCoordinate(occurrenceID: .init(rawValue: UUID()), contentIdentity: content),
            image: ReconstructionImageBinding(binaryID: UUID(), imageSlot: ImageSlot(rawValue: slot),
                selectedSliceIndex: 0, architecture: slice.architectureVariant == .arm64e ? .arm64e : .arm64,
                machOIdentity: slice),
            analysisFingerprintSHA256: digest)
        return try RecoveryImportIdentity(coordinate: coordinate, sliceOffset: 0)
    }

    private func fact(_ id: String = "parent", image: String, parents: [String] = []) -> [String: Any] {
        ["id": id, "image": image, "subject": "type:0x1000", "predicate": "name", "value": id,
         "authority": parents.isEmpty ? "authoritative" : "derived", "anchors": parents.isEmpty ? ["record:0x1000"] : [],
         "parents": parents, "rule": "swift.nominal.name/v1"]
    }

    private func report(_ identity: RecoveryImportIdentity, facts: [[String: Any]]? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "schema": "swiftrecover-analysis/2", "image_key": identity.imageKey,
            "image": ["artifact_sha256": digest, "slice_sha256": digest, "slice_offset": 0,
                      "slice_size": 4096, "cpu_type": 0x0100000c,
                      "cpu_subtype": identity.coordinate.image.machOIdentity?.rawCPUSubtype ?? 0],
            "facts": facts ?? [fact(image: identity.imageKey)], "frontier": [["reason": "unresolved source"]],
            "functions": [], "completion": ["analysis_finished": true,
                "whole_application_source_recovered": false, "source_validation": "not_run"]
        ], options: [.sortedKeys])
    }

    private func bundle(_ identity: RecoveryImportIdentity, data: Data? = nil,
                        facts: [[String: Any]]? = nil) throws -> RecoveryImportBundle {
        let bytes = try data ?? report(identity, facts: facts)
        let manifest = Data("\(RecoveryImportIdentity.digest(bytes))  analysis.json\n".utf8)
        return try RecoveryImportBundle(identity: identity, expectedIdentity: identity,
            manifest: manifest, files: ["analysis.json": bytes])
    }

    func testAdmitsSeparateProducerAndPreservesNotRunAndFrontier() throws {
        let image = try identity(), importer = RecoveryReportAdmission(), fence = NativeDecompilerAdmissionFence()
        var store = NavigatorContractStore(toolchain: "test-toolchain")
        let ticket = try importer.begin(taskID: UUID(), identity: image, generation: XCTUnwrap(fence.advance()))
        try importer.accept(bundle(image), ticket: ticket, currentIdentity: image, store: &store)
        let fact = try XCTUnwrap(store.liveFacts().values.first)
        XCTAssertEqual(fact.provenance.first?.rule, RecoveryReportAdmission.producer)
        XCTAssertNotEqual(fact.provenance.first?.rule, SwiftMetadataFactProjection.rule)
        XCTAssertEqual(fact.provenance.first?.ruleVersion, "1")
        let shown = try XCTUnwrap(importer.presentation(currentIdentity: image, store: store))
        XCTAssertEqual(shown.factCount, 1)
        XCTAssertEqual(shown.sourceValidation, "not_run")
        XCTAssertEqual(shown.unresolved.count, 1)
    }

    func testImageSwitchDuringAnalysisRejectsCompletion() throws {
        let image = try identity(), other = try identity(slot: 1)
        let importer = RecoveryReportAdmission(), fence = NativeDecompilerAdmissionFence()
        var store = NavigatorContractStore(toolchain: "test")
        let ticket = try importer.begin(taskID: UUID(), identity: image, generation: XCTUnwrap(fence.advance()))
        XCTAssertThrowsError(try importer.accept(bundle(image), ticket: ticket, currentIdentity: other, store: &store)) {
            XCTAssertEqual($0 as? RecoveryImportError, .staleCompletion)
        }
        XCTAssertTrue(store.liveFacts().isEmpty)
    }

    func testStaleCompletionUsesExistingCoordinatorFence() throws {
        let image = try identity(), importer = RecoveryReportAdmission(), fence = NativeDecompilerAdmissionFence()
        var store = NavigatorContractStore(toolchain: "test")
        let ticket = try importer.begin(taskID: UUID(), identity: image, generation: XCTUnwrap(fence.advance()))
        _ = fence.advance()
        XCTAssertThrowsError(try importer.accept(bundle(image), ticket: ticket, currentIdentity: image, store: &store)) {
            XCTAssertEqual($0 as? RecoveryImportError, .staleCompletion)
        }
        XCTAssertTrue(store.liveFacts().isEmpty)
    }

    func testCancelReopenDoesNotAdmitOldTask() throws {
        let image = try identity(), importer = RecoveryReportAdmission(), fence = NativeDecompilerAdmissionFence()
        var store = NavigatorContractStore(toolchain: "test")
        let ticket = try importer.begin(taskID: UUID(), identity: image, generation: XCTUnwrap(fence.advance()))
        fence.revoke()
        importer.invalidate()
        let reopenedFence = NativeDecompilerAdmissionFence()
        let fresh = try importer.begin(taskID: UUID(), identity: image, generation: XCTUnwrap(reopenedFence.advance()))
        let captured = try bundle(image)
        XCTAssertThrowsError(try importer.accept(captured, ticket: ticket, currentIdentity: image, store: &store)) {
            XCTAssertEqual($0 as? RecoveryImportError, .staleCompletion)
        }
        try importer.accept(captured, ticket: fresh, currentIdentity: image, store: &store)
        XCTAssertEqual(store.liveFacts().count, 1)
    }

    func testDuplicateTaskAndCompletionRejected() throws {
        let image = try identity(), importer = RecoveryReportAdmission(), fence = NativeDecompilerAdmissionFence(), id = UUID()
        var store = NavigatorContractStore(toolchain: "test")
        let generation = try XCTUnwrap(fence.advance())
        let ticket = try importer.begin(taskID: id, identity: image, generation: generation)
        XCTAssertThrowsError(try importer.begin(taskID: id, identity: image, generation: generation)) {
            XCTAssertEqual($0 as? RecoveryImportError, .duplicateTask)
        }
        let captured = try bundle(image)
        try importer.accept(captured, ticket: ticket, currentIdentity: image, store: &store)
        XCTAssertThrowsError(try importer.accept(captured, ticket: ticket, currentIdentity: image, store: &store)) {
            XCTAssertEqual($0 as? RecoveryImportError, .staleCompletion)
        }
        XCTAssertEqual(store.journal.count, 1)
    }

    func testRevokedParentFactCannotSupportLaterImport() throws {
        let image = try identity(), importer = RecoveryReportAdmission(), fence = NativeDecompilerAdmissionFence(), id = UUID()
        var store = NavigatorContractStore(toolchain: "test")
        let ticket = try importer.begin(taskID: id, identity: image, generation: XCTUnwrap(fence.advance()))
        try importer.accept(bundle(image), ticket: ticket, currentIdentity: image, store: &store)
        store.undoSession(id.uuidString)
        let next = try importer.begin(taskID: UUID(), identity: image, generation: XCTUnwrap(fence.advance()))
        let child = fact("child", image: image.imageKey, parents: ["parent"])
        XCTAssertThrowsError(try importer.accept(bundle(image, facts: [child]), ticket: next,
            currentIdentity: image, store: &store)) { XCTAssertEqual($0 as? RecoveryImportError, .inactiveParent) }
        XCTAssertTrue(store.liveFacts().isEmpty)
    }

    func testMalformedJSONRejectedWithoutPublication() throws {
        let image = try identity(), importer = RecoveryReportAdmission(), fence = NativeDecompilerAdmissionFence()
        var store = NavigatorContractStore(toolchain: "test")
        let ticket = try importer.begin(taskID: UUID(), identity: image, generation: XCTUnwrap(fence.advance()))
        XCTAssertThrowsError(try importer.accept(bundle(image, data: Data("{".utf8)), ticket: ticket,
            currentIdentity: image, store: &store)) { XCTAssertEqual($0 as? RecoveryImportError, .malformedReport) }
        XCTAssertNil(importer.presentation(currentIdentity: image, store: store))
        XCTAssertTrue(store.liveFacts().isEmpty)
    }

    func testWrongManifestRejectedBeforeMalformedJSON() throws {
        let image = try identity(), bytes = Data("{".utf8)
        XCTAssertThrowsError(try RecoveryImportBundle(identity: image, expectedIdentity: image,
            manifest: Data("\(digest)  analysis.json\n".utf8), files: ["analysis.json": bytes])) {
            XCTAssertEqual($0 as? RecoveryImportError, .wrongManifest)
        }
    }

    func testArtifactReceiptRejectedBeforeManifest() throws {
        XCTAssertThrowsError(try RecoveryImportBundle(identity: identity(), expectedIdentity: identity(slot: 1),
            manifest: Data(), files: [:])) { XCTAssertEqual($0 as? RecoveryImportError, .artifactMismatch) }
    }

    func testIdenticalAddressesAndBytesInDifferentImagesRemainDistinct() throws {
        let first = try identity(), second = try identity(slot: 1)
        XCTAssertEqual(first.imageKey, second.imageKey)
        XCTAssertNotEqual(first.hostImageKey, second.hostImageKey)
        var store = NavigatorContractStore(toolchain: "test")
        for image in [first, second] {
            let importer = RecoveryReportAdmission(), fence = NativeDecompilerAdmissionFence()
            let ticket = try importer.begin(taskID: UUID(), identity: image, generation: XCTUnwrap(fence.advance()))
            try importer.accept(bundle(image), ticket: ticket, currentIdentity: image, store: &store)
        }
        XCTAssertEqual(store.liveFacts().count, 2)
        XCTAssertEqual(Set(store.liveFacts().values.compactMap { $0.subject.image }).count, 2)
    }

    func testDerivedFactsFollowHostRevocationAndDependencyOrder() throws {
        let image = try identity(), importer = RecoveryReportAdmission(), fence = NativeDecompilerAdmissionFence(), id = UUID()
        var store = NavigatorContractStore(toolchain: "test")
        let ticket = try importer.begin(taskID: id, identity: image, generation: XCTUnwrap(fence.advance()))
        let facts = [fact("child", image: image.imageKey, parents: ["parent"]), fact(image: image.imageKey)]
        try importer.accept(bundle(image, facts: facts), ticket: ticket, currentIdentity: image, store: &store)
        XCTAssertEqual(store.liveFacts().count, 2)
        store.undoSession(id.uuidString)
        XCTAssertEqual(importer.presentation(currentIdentity: image, store: store)?.factCount, 0)
    }

    func testUnknownPredicateIsVisibleFrontierWithoutInventedFact() throws {
        let image = try identity(), importer = RecoveryReportAdmission(), fence = NativeDecompilerAdmissionFence()
        var store = NavigatorContractStore(toolchain: "test")
        var unsupported = fact(image: image.imageKey)
        unsupported["predicate"] = "demangler_tree"
        let ticket = try importer.begin(taskID: UUID(), identity: image, generation: XCTUnwrap(fence.advance()))
        try importer.accept(bundle(image, facts: [unsupported]), ticket: ticket, currentIdentity: image, store: &store)
        XCTAssertTrue(store.liveFacts().isEmpty)
        XCTAssertTrue(store.journal.isEmpty)
        let shown = try XCTUnwrap(importer.presentation(currentIdentity: image, store: store))
        XCTAssertEqual(shown.factCount, 0)
        XCTAssertEqual(shown.sourceValidation, "not_run")
        XCTAssertEqual(shown.unresolved.count, 2)
        XCTAssertTrue(shown.unresolved.contains { $0.contains("demangler_tree") })
    }

    func testSignedArm64eCapabilitySubtypeMatchesProducerIdentity() throws {
        let image = try identity(subtype: Int32(bitPattern: 0x80000002))
        let importer = RecoveryReportAdmission(), fence = NativeDecompilerAdmissionFence()
        var store = NavigatorContractStore(toolchain: "test")
        let ticket = try importer.begin(taskID: UUID(), identity: image, generation: XCTUnwrap(fence.advance()))
        try importer.accept(bundle(image), ticket: ticket, currentIdentity: image, store: &store)
        XCTAssertEqual(store.liveFacts().count, 1)
    }

    func testSupersededTaskIDCannotBeReissuedAfterAnotherTaskOrInvalidation() throws {
        let image = try identity(), importer = RecoveryReportAdmission(), fence = NativeDecompilerAdmissionFence(), id = UUID()
        let generation = try XCTUnwrap(fence.advance())
        _ = try importer.begin(taskID: id, identity: image, generation: generation)
        _ = try importer.begin(taskID: UUID(), identity: image, generation: generation)
        XCTAssertThrowsError(try importer.begin(taskID: id, identity: image, generation: generation))
        importer.invalidate()
        XCTAssertThrowsError(try importer.begin(taskID: id, identity: image, generation: generation))
    }

    func testAuthoritativeFactCannotDiscardParentDependency() throws {
        let image = try identity(), importer = RecoveryReportAdmission(), fence = NativeDecompilerAdmissionFence()
        var store = NavigatorContractStore(toolchain: "test")
        var child = fact("child", image: image.imageKey, parents: ["parent"])
        child["authority"] = "authoritative"
        child["anchors"] = ["record:0x1000"]
        let ticket = try importer.begin(taskID: UUID(), identity: image, generation: XCTUnwrap(fence.advance()))
        XCTAssertThrowsError(try importer.accept(bundle(image, facts: [fact(image: image.imageKey), child]),
            ticket: ticket, currentIdentity: image, store: &store)) {
            XCTAssertEqual($0 as? RecoveryImportError, .malformedReport)
        }
        XCTAssertTrue(store.liveFacts().isEmpty)
    }

    func testSourceFactIDCannotChangeProofLineage() throws {
        let image = try identity(), importer = RecoveryReportAdmission(), fence = NativeDecompilerAdmissionFence()
        var store = NavigatorContractStore(toolchain: "test")
        let ticket = try importer.begin(taskID: UUID(), identity: image, generation: XCTUnwrap(fence.advance()))
        try importer.accept(bundle(image), ticket: ticket, currentIdentity: image, store: &store)
        var changed = fact(image: image.imageKey)
        changed["anchors"] = ["different-record"]
        let next = try importer.begin(taskID: UUID(), identity: image, generation: XCTUnwrap(fence.advance()))
        XCTAssertThrowsError(try importer.accept(bundle(image, facts: [changed]), ticket: next,
            currentIdentity: image, store: &store)) { XCTAssertEqual($0 as? RecoveryImportError, .malformedReport) }
        XCTAssertEqual(store.journal.count, 1)
    }
}
