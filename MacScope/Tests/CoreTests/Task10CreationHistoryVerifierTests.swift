import ApplicationServices
import CryptoKit
import Foundation
import XCTest
@testable import MacScope

/// The oracle must reject fabricated creation ancestry, not just changed summary text.
final class Task10CreationHistoryVerifierTests: XCTestCase {
    private let projectID = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
    private let occurrenceID = UUID(uuidString: "10000000-0000-0000-0000-000000000005")!
    private let objective = "Reconstruct the installed deterministic target"

    func testDocumentEditedReadsStrictBooleanFromExactWindowsCloseButton() throws {
        XCTAssertFalse(try documentEditedFixture(edited: kCFBooleanFalse))
        XCTAssertTrue(try documentEditedFixture(edited: kCFBooleanTrue))
    }

    func testDocumentEditedRejectsUnsupportedMissingAndCoercibleNonBooleanValues() {
        XCTAssertThrowsError(try documentEditedFixture(edited: kCFBooleanFalse, status: .attributeUnsupported))
        XCTAssertThrowsError(try documentEditedFixture(edited: nil))
        XCTAssertThrowsError(try documentEditedFixture(edited: "false" as CFString))
        XCTAssertThrowsError(try documentEditedFixture(edited: NSNumber(value: 0)))
    }

    func testDocumentEditedRejectsWrongCloseButtonRoleSubroleAndElementType() {
        XCTAssertThrowsError(try documentEditedFixture(role: "AXWindow"))
        XCTAssertThrowsError(try documentEditedFixture(subrole: "AXMinimizeButton"))
        XCTAssertThrowsError(try documentEditedFixture(closeValue: "not an AX element" as CFString))
        XCTAssertThrowsError(try documentEditedFixture(closeStatus: .attributeUnsupported))
    }

    func testDocumentEditedRejectsCrossProcessOrWrongWindowRelationships() {
        XCTAssertThrowsError(try documentEditedFixture(windowPID: 987))
        XCTAssertThrowsError(try documentEditedFixture(closePID: 987))
        XCTAssertThrowsError(try documentEditedFixture(pidStatus: .cannotComplete))
        XCTAssertThrowsError(try documentEditedFixture(ownsWindow: false))
        XCTAssertThrowsError(try documentEditedFixture(windowStatus: .attributeUnsupported))
    }

    /// Only the external AX transport is substituted; the shared reader's decoding and all
    /// relationships are real. Distinct opaque AX identities require no process or UI launch.
    private func documentEditedFixture(
        edited: CFTypeRef? = kCFBooleanFalse, status: AXError = .success,
        role: String = "AXButton", subrole: String = "AXCloseButton",
        closeValue: CFTypeRef? = nil, closeStatus: AXError = .success,
        windowPID: pid_t = 123, closePID: pid_t = 123, pidStatus: AXError = .success,
        ownsWindow: Bool = true, windowStatus: AXError = .success
    ) throws -> Bool {
        let window = AXUIElementCreateApplication(123)
        let close = AXUIElementCreateApplication(456)
        let otherWindow = AXUIElementCreateApplication(789)
        return try Task10DocumentEditedReader.read(
            window: window, expectedPID: 123,
            attribute: { element, name in
                if CFEqual(element, window), name as String == "AXCloseButton" {
                    return (closeStatus, closeValue ?? close)
                }
                if CFEqual(element, close) {
                    switch name as String {
                    case "AXRole": return (.success, role as CFString)
                    case "AXSubrole": return (.success, subrole as CFString)
                    case "AXWindow": return (windowStatus, ownsWindow ? window : otherWindow)
                    case "AXEdited": return (status, edited)
                    default: break
                    }
                }
                // In particular, querying AXEdited on the window must fail, as observed live.
                return (.attributeUnsupported, nil)
            },
            processID: { element in
                (pidStatus, CFEqual(element, window) ? windowPID : closePID)
            }
        )
    }

    func testPackagePublicationRequiresPhysicalRootReplacementEvenForIdenticalBytes() throws {
        let root = try makePublicationFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Scenario.mscope")
        let before = try Task10SavedPackageObservation.capture(at: package)
        XCTAssertFalse(try before.isNewPublication(after: before))
        let replacement = root.appendingPathComponent("Replacement.mscope")
        try FileManager.default.copyItem(at: package, to: replacement)
        try FileManager.default.moveItem(at: package, to: root.appendingPathComponent("Retired.mscope"))
        try FileManager.default.moveItem(at: replacement, to: package)
        let after = try Task10SavedPackageObservation.capture(at: package)
        XCTAssertEqual(before.workspaceManifest, after.workspaceManifest)
        XCTAssertTrue(try after.isNewPublication(after: before))
    }

    func testPackagePublicationRejectsChangedLogicalDocumentOrDifferentPackage() throws {
        let root = try makePublicationFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Scenario.mscope")
        let before = try Task10SavedPackageObservation.capture(at: package)
        let other = root.appendingPathComponent("Other.mscope")
        try FileManager.default.copyItem(at: package, to: other)
        XCTAssertThrowsError(try Task10SavedPackageObservation.capture(at: other).isNewPublication(after: before))
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: before.workspaceManifest) as? [String: Any])
        manifest["documentID"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: manifest).write(to: package.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try Task10SavedPackageObservation.capture(at: package).isNewPublication(after: before))
    }

    func testInPlaceManifestChangeIsNotAPackagePublication() throws {
        let root = try makePublicationFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Scenario.mscope")
        let before = try Task10SavedPackageObservation.capture(at: package)
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: before.workspaceManifest) as? [String: Any])
        manifest["modifiedAt"] = "2026-10-04T15:00:00Z"
        try JSONSerialization.data(withJSONObject: manifest).write(to: package.appendingPathComponent("manifest.json"))
        let after = try Task10SavedPackageObservation.capture(at: package)
        XCTAssertNotEqual(before.workspaceManifest, after.workspaceManifest)
        XCTAssertFalse(try after.isNewPublication(after: before))
    }

    func testPackagePublicationRejectsSymlinkAndMismatchedCheckpointBytes() throws {
        let root = try makePublicationFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Scenario.mscope")
        let checkpoint = package.appendingPathComponent("Reconstruction/checkpoint-manifest.json")
        try Data("changed".utf8).write(to: checkpoint)
        XCTAssertThrowsError(try Task10SavedPackageObservation.capture(at: package))
        let original = root.appendingPathComponent("outside.json")
        try FileManager.default.moveItem(at: checkpoint, to: original)
        try FileManager.default.createSymbolicLink(at: checkpoint, withDestinationURL: original)
        XCTAssertThrowsError(try Task10SavedPackageObservation.capture(at: package))
    }

    private func makePublicationFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Task10Save-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let package = root.appendingPathComponent("Scenario.mscope")
        try FileManager.default.createDirectory(at: package.appendingPathComponent("Reconstruction"), withIntermediateDirectories: true)
        let checkpoint = Data("{\"schemaVersion\":1}".utf8)
        let manifest: [String: Any] = [
            "formatIdentifier": "org.macscope.workspace-package", "formatVersion": 3,
            "documentID": "10000000-0000-0000-0000-000000000001",
            "workspaceUUID": "10000000-0000-0000-0000-000000000002",
            "reconstruction": [
                "checkpointManifestPath": "Reconstruction/checkpoint-manifest.json",
                "checkpointManifestSHA256": SHA256.hash(data: checkpoint).map { String(format: "%02x", $0) }.joined(),
            ],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: package.appendingPathComponent("manifest.json"))
        try checkpoint.write(to: package.appendingPathComponent("Reconstruction/checkpoint-manifest.json"))
        return root
    }

    func testActualSelectedNavigatorObjectiveAndOrdinalBindExactJobUUID() throws {
        let jobID = try XCTUnwrap(UUID(uuidString: "2339CF36-5FCE-4925-906A-014C12C7753A"))
        XCTAssertEqual(try Task10CreationHistoryVerifier.selectedNavigatorJobID(
            identifier: "reconstruction:job:2339CF36-5FCE-4925-906A-014C12C7753A",
            label: "Reconstruct the installed deterministic target, #1 · created",
            isSelected: true, expectedObjective: objective, visibleCreationOrdinal: 1
        ), jobID)
    }

    func testUnselectedWrongObjectiveOrdinalOrMalformedNavigatorIdentityRejected() {
        let identifier = "reconstruction:job:2339CF36-5FCE-4925-906A-014C12C7753A"
        let label = "Reconstruct the installed deterministic target, #1 · created"
        for (candidateID, candidateLabel, selected) in [
            (identifier, label, false),
            (identifier, "Another objective, #1 · created", true),
            (identifier, "Reconstruct the installed deterministic target, #10 · created", true),
            ("reconstruction:job:invalid", label, true),
            ("another:job:2339CF36-5FCE-4925-906A-014C12C7753A", label, true),
        ] {
            XCTAssertThrowsError(try Task10CreationHistoryVerifier.selectedNavigatorJobID(
                identifier: candidateID, label: candidateLabel, isSelected: selected,
                expectedObjective: objective, visibleCreationOrdinal: 1
            ))
        }
    }

    func testEmptyIdentityUsesActualEmptyHeaderRatherThanPopulatedHeaderFallback() {
        XCTAssertTrue(Task10CreationHistoryVerifier.hasEmptyIdentity(
            "No reconstruction job | Create a bounded job from deliberately selected project items."
        ))
        XCTAssertFalse(Task10CreationHistoryVerifier.hasEmptyIdentity("Reconstruction job | Job 1"))
        XCTAssertFalse(Task10CreationHistoryVerifier.hasEmptyIdentity("No job"))
    }

    func testProductionCanonicalInitialCutPrecedesActualExecution() throws {
        let sample = try makeSample()
        let proof = try verify(sample)
        XCTAssertEqual(proof.creationOrdinal, 1)
        XCTAssertEqual(proof.currentRevision, 1)
        XCTAssertEqual(proof.initialTaskCount, 3)
    }

    func testAbsentRevisionZeroCannotProveCreationOrder() throws {
        var sample = try makeSample()
        sample.checkpoints.removeFirst()
        XCTAssertThrowsError(try verify(sample))
    }

    func testTamperedRevisionZeroRejectedEvenWithMatchingOuterFileHash() throws {
        var sample = try makeSample()
        sample.checkpoints[0]["coordinatorState"] = "retrieving"
        XCTAssertThrowsError(try verify(sample))
    }

    func testCanonicalButNonInitialRevisionZeroRejected() throws {
        var sample = try makeSample()
        sample.checkpoints[0]["runningTaskIDs"] = sample.checkpoints[0]["pendingTaskIDs"]
        sample.checkpoints[0]["pendingTaskIDs"] = [String]()
        try reseal(&sample.checkpoints[0])
        sample.checkpoints[1]["parentCheckpointSHA256"] = sample.checkpoints[0]["canonicalSHA256"]
        try reseal(&sample.checkpoints[1])
        XCTAssertThrowsError(try verify(sample))
    }

    func testCanonicalBrokenParentChainRejected() throws {
        var sample = try makeSample()
        sample.checkpoints[1]["parentCheckpointSHA256"] = String(repeating: "f", count: 64)
        try reseal(&sample.checkpoints[1])
        XCTAssertThrowsError(try verify(sample))
    }

    func testWrongJobOrdinalObjectiveOrProjectCannotMatchVisibleIdentity() throws {
        for key in ["creationOrdinal", "objective", "reconstructionProjectID", "jobID"] {
            var sample = try makeSample()
            sample.job[key] = key == "creationOrdinal" ? 2 : UUID().uuidString as Any
            XCTAssertThrowsError(try verify(sample), key)
        }
    }

    func testWrongSelectedOccurrenceOrTaskIdentityRejected() throws {
        var sample = try makeSample()
        var identity = try XCTUnwrap(sample.tasks[0]["identity"] as? [String: Any])
        identity["canonicalSHA256"] = String(repeating: "f", count: 64)
        sample.tasks[0]["identity"] = identity
        XCTAssertThrowsError(try verify(sample))
        let valid = try makeSample()
        XCTAssertThrowsError(try verify(valid, occurrence: UUID()))
    }

    func testPendingOnlyHistoryIsNotAutomatedProgress() throws {
        var sample = try makeSample()
        sample.checkpoints[1]["pendingTaskIDs"] = sample.checkpoints[0]["pendingTaskIDs"]
        sample.checkpoints[1]["runningTaskIDs"] = [String]()
        try reseal(&sample.checkpoints[1])
        for index in sample.tasks.indices { sample.tasks[index]["state"] = "pending" }
        XCTAssertThrowsError(try verify(sample))
        XCTAssertFalse(try Task10CreationHistoryVerifier.hasAutomatedProgress(
            "Reconstruction progress | 0 of 3 tasks completed; 3 pending, 0 running, 0 completed, 0 failed, 0 blocked"
        ))
        XCTAssertTrue(try Task10CreationHistoryVerifier.hasAutomatedProgress(
            "Reconstruction progress | 0 of 3 tasks completed; 2 pending, 1 running, 0 completed, 0 failed, 0 blocked"
        ))
    }

    func testWrongOuterPackageHashAndCurrentPointerRejected() throws {
        let sample = try makeSample()
        XCTAssertThrowsError(try verify(sample, corruptOuterHash: true))
        var wrongPointer = sample
        wrongPointer.job["currentCheckpointID"] = UUID().uuidString
        XCTAssertThrowsError(try verify(wrongPointer))
    }

    private struct Sample {
        var job: [String: Any]
        var tasks: [[String: Any]]
        var checkpoints: [[String: Any]]
    }

    private func verify(
        _ sample: Sample, occurrence: UUID? = nil, corruptOuterHash: Bool = false
    ) throws -> Task10CreationHistoryVerifier.Proof {
        let checkpoints = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1, "jobs": [sample.job], "tasks": sample.tasks,
            "checkpoints": sample.checkpoints,
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        let workspace = try JSONSerialization.data(withJSONObject: [
            "formatIdentifier": "org.macscope.workspace-package", "formatVersion": 3,
            "reconstruction": [
                "checkpointManifestPath": "Reconstruction/checkpoint-manifest.json",
                "checkpointManifestSHA256": corruptOuterHash ? String(repeating: "f", count: 64)
                    : SHA256.hash(data: checkpoints).map { String(format: "%02x", $0) }.joined(),
            ],
        ])
        return try Task10CreationHistoryVerifier.verify(
            workspaceManifest: workspace, checkpointManifest: checkpoints,
            expectedProjectID: projectID, expectedOccurrenceID: occurrence ?? occurrenceID,
            expectedObjective: objective, visibleCreationOrdinal: 1
        )
    }

    private func makeSample() throws -> Sample {
        let jobID = UUID()
        let subject = ReconstructionSubjectCoordinate.artifact(ReconstructionArtifactCoordinate(
            occurrenceID: ReconstructionArtifactOccurrenceID(rawValue: occurrenceID),
            contentIdentity: try ReconstructionContentIdentity(
                algorithm: .sha256, digest: String(repeating: "a", count: 64), byteCount: 39
            )
        ))
        var tasks: [ReconstructionTaskRecord] = []
        for kind in [ReconstructionTaskKind.ingest, .classify, .discoverRelations] {
            let identity = try ReconstructionTaskIdentity.make(
                taskID: UUID(), jobID: jobID, kind: kind, subject: subject,
                dependencyTaskIDs: tasks.last.map { [$0.identity.taskID] } ?? [],
                operationContractIdentity: "reconstruction.\(kind.rawValue).v1"
            )
            tasks.append(ReconstructionTaskRecord(identity: identity, state: .pending, diagnostic: nil))
        }
        let initial = try checkpoint(jobID: jobID, parent: nil, tasks: tasks)
        tasks[0] = ReconstructionTaskRecord(identity: tasks[0].identity, state: .running, diagnostic: nil)
        let later = try checkpoint(jobID: jobID, parent: initial, tasks: tasks)
        let job = try ReconstructionJobRecord(
            jobID: jobID, reconstructionProjectID: projectID, objective: objective,
            objectiveSHA256: SHA256.hash(data: Data(objective.utf8)).map { String(format: "%02x", $0) }.joined(),
            creationCorpusManifestSHA256: initial.corpusManifestSHA256, state: .created,
            currentCheckpointID: later.checkpointID, terminalReason: nil,
            budget: try ReconstructionJobBudget(maxRounds: 2, maxTasks: 8, maxEvidenceRecords: 32, maxEncodedBytes: 32768),
            creationOrdinal: 1
        )
        return Sample(job: try object(job), tasks: try tasks.map(object), checkpoints: try [initial, later].map(object))
    }

    private func checkpoint(
        jobID: UUID, parent: ReconstructionCheckpoint?, tasks: [ReconstructionTaskRecord]
    ) throws -> ReconstructionCheckpoint {
        try ReconstructionCheckpoint.make(
            checkpointID: UUID(), jobID: jobID, revision: parent.map { $0.revision + 1 } ?? 0,
            parentCheckpointID: parent?.checkpointID, parentCheckpointSHA256: parent?.canonicalSHA256,
            corpusManifestSHA256: String(repeating: "b", count: 64),
            evidenceFrontierSHA256: String(repeating: "c", count: 64),
            pendingTaskIDs: tasks.filter { $0.state == .pending }.map(\.identity.taskID),
            runningTaskIDs: tasks.filter { $0.state == .running }.map(\.identity.taskID),
            completedTaskIDs: [], failedTaskIDs: [], blockedTaskIDs: [],
            unresolvedEvidenceGapSHA256: String(repeating: "d", count: 64),
            modelReceiptIDs: [], toolReceiptIDs: [], coordinatorState: .created, terminalReason: nil
        )
    }

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: ReconstructionCanonicalJSON.encode(value)) as? [String: Any])
    }

    private func reseal(_ checkpoint: inout [String: Any]) throws {
        checkpoint.removeValue(forKey: "canonicalSHA256")
        checkpoint.removeValue(forKey: "canonicalEncodedByteCount")
        let preimage = try JSONSerialization.data(withJSONObject: checkpoint, options: [.sortedKeys, .withoutEscapingSlashes])
        checkpoint["canonicalEncodedByteCount"] = preimage.count
        checkpoint["canonicalSHA256"] = SHA256.hash(data: preimage).map { String(format: "%02x", $0) }.joined()
    }
}
