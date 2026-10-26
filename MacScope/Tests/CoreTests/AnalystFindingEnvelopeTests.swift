import Foundation
import XCTest
@testable import MacScope

/// Shared only within CoreTests, including the package transport assertions.
enum AnalystFindingEnvelopeFixture {
    static func make(workspaceID: UUID, documentID: UUID) throws -> AnalystFindingEnvelope {
        let fixture = AnalystFindingNativeFixture()
        let executions = try [fixture.execution()]
        let context = try fixture.context(executions)
        let draft = try Phase2AssistantUnsavedDraftAdapter.make(
            result: fixture.result(context, executions: executions), currentStateByEvidenceID: fixture.states(context))
        return .init(records: [try AnalystFindingDraftConversion.initialRecord(from: draft, findingID: UUID(),
            workspaceID: workspaceID, documentID: documentID,
            now: Date(timeIntervalSinceReferenceDate: 813_456_789.1234567))])
    }
}

@MainActor
final class AnalystFindingEnvelopeTests: XCTestCase {
    func testLifecycleRetainsFullTextAndDecisionsAcrossCompensatingHistory() throws {
        let original = try AnalystFindingEnvelopeFixture.make(workspaceID: UUID(), documentID: UUID()).records[0]
        var lifecycle = original.authoredLifecycle
        func apply(_ operation: AnalystFindingHistoryOperation) throws {
            lifecycle = try lifecycle.applying(operation, identity: original.revisionIdentity,
                initialText: original.content.candidateText, expected: lifecycle.state.vector,
                now: Date(timeIntervalSinceReferenceDate: 123))
        }
        try apply(.edit("Authored interpretation A\nΩ"))
        try apply(.review(.reviewed))
        XCTAssertTrue(lifecycle.isReviewCurrent)
        try apply(.edit("Authored interpretation B"))
        XCTAssertFalse(lifecycle.isReviewCurrent)
        try apply(.undo(3))
        XCTAssertEqual(lifecycle.state.text, "Authored interpretation A\nΩ")
        XCTAssertEqual(lifecycle.state.contentRevision, 4)
        XCTAssertFalse(lifecycle.isReviewCurrent, "Undo must not renew a historical review")
        try apply(.redo(3))
        XCTAssertEqual(lifecycle.state.text, "Authored interpretation B")
        XCTAssertEqual(lifecycle.state.contentRevision, 5)
        try apply(.review(.reviewed))
        try apply(.review(.reviewed))
        XCTAssertEqual(lifecycle.state.reviewRevision, 3, "Equal explicit decisions remain distinct")
        XCTAssertTrue(lifecycle.isReviewCurrent)
        let revised = original.revising(with: lifecycle)
        let envelope = AnalystFindingEnvelope(records: [revised])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let reopened = try decoder.decode(AnalystFindingEnvelope.self, from: encoder.encode(envelope))
        try reopened.validate(workspaceID: original.workspaceID, documentID: original.documentID)
        XCTAssertEqual(reopened, envelope)
        XCTAssertEqual(reopened.schemaVersion, 2)
        XCTAssertEqual(reopened.records[0].content, original.content)
        XCTAssertEqual(reopened.records[0].lifecycle?.history.count, 7)
        XCTAssertEqual(lifecycle.history[0].before.text, original.content.candidateText)
        XCTAssertEqual(lifecycle.history[2].before.latestReview?.decision, .reviewed)
    }

    func testLifecycleRejectsTamperedUnknownAndTruncatedHistory() throws {
        let original = try AnalystFindingEnvelopeFixture.make(workspaceID: UUID(), documentID: UUID()).records[0]
        let lifecycle = try original.authoredLifecycle.applying(.edit("A"), identity: original.revisionIdentity,
            initialText: original.content.candidateText, expected: .init(content: 1, review: 0), now: Date())
        let bytes = try JSONEncoder().encode(AnalystFindingEnvelope(records: [original.revising(with: lifecycle)]))
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        for mutation in 0..<7 {
            var root = base
            var records = try XCTUnwrap(root["records"] as? [[String: Any]])
            var value = try XCTUnwrap(records[0]["lifecycle"] as? [String: Any])
            var history = try XCTUnwrap(value["history"] as? [[String: Any]])
            switch mutation {
            case 0: history.removeAll()
            case 1: history[0]["sequence"] = 2
            case 2:
                var before = try XCTUnwrap(history[0]["before"] as? [String: Any])
                before["text"] = "silently replaced original"
                history[0]["before"] = before
            case 3:
                var after = try XCTUnwrap(history[0]["after"] as? [String: Any])
                after["futureState"] = true
                history[0]["after"] = after
            case 4:
                var operation = try XCTUnwrap(history[0]["operation"] as? [String: Any])
                operation["futureOperation"] = true
                history[0]["operation"] = operation
            case 5: value["futureLifecycle"] = true
            default: history = Array(repeating: history[0], count: AnalystFindingLifecycle.maximumHistoryEntries + 1)
            }
            value["history"] = history; records[0]["lifecycle"] = value; root["records"] = records
            XCTAssertThrowsError(try JSONDecoder().decode(AnalystFindingEnvelope.self,
                from: JSONSerialization.data(withJSONObject: root)), "Mutation \(mutation) must refuse")
        }
    }

    func testLifecycleVersionDispatchPreservesInitialRecordsAndRejectsDowngrade() throws {
        let first = try AnalystFindingEnvelopeFixture.make(workspaceID: UUID(), documentID: UUID()).records[0]
        let initialBytes = try JSONEncoder().encode(first)
        let initialObject = try XCTUnwrap(JSONSerialization.jsonObject(with: initialBytes) as? [String: Any])
        XCTAssertNil(initialObject["schemaVersion"])
        XCTAssertNil(initialObject["lifecycle"])
        let second = try AnalystFindingEnvelopeFixture.make(workspaceID: first.workspaceID, documentID: first.documentID).records[0]
        let lifecycle = try second.authoredLifecycle.applying(.review(.needsChanges), identity: second.revisionIdentity,
            initialText: second.content.candidateText, expected: .init(content: 1, review: 0), now: Date())
        let mixed = AnalystFindingEnvelope(records: [first, second.revising(with: lifecycle)])
        let bytes = try JSONEncoder().encode(mixed)
        let reopened = try JSONDecoder().decode(AnalystFindingEnvelope.self, from: bytes)
        XCTAssertEqual(reopened.records[0], first)
        XCTAssertEqual(reopened.records[1].content, second.content)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        root["schemaVersion"] = 1
        XCTAssertThrowsError(try JSONDecoder().decode(AnalystFindingEnvelope.self,
            from: JSONSerialization.data(withJSONObject: root)))
        root["schemaVersion"] = 3
        XCTAssertThrowsError(try JSONDecoder().decode(AnalystFindingEnvelope.self,
            from: JSONSerialization.data(withJSONObject: root)))
    }

    func testLifecycleRejectsStaleVectorsInvalidBoundsAndOutOfOrderUndo() throws {
        let original = try AnalystFindingEnvelopeFixture.make(workspaceID: UUID(), documentID: UUID()).records[0]
        let lifecycle = try original.authoredLifecycle.applying(.edit("A"), identity: original.revisionIdentity,
            initialText: original.content.candidateText, expected: .init(content: 1, review: 0), now: Date())
        for operation in [AnalystFindingHistoryOperation.edit(""), .edit(String(repeating: "Ω", count: 32_769)),
                          .undo(2), .redo(1)] {
            XCTAssertThrowsError(try lifecycle.applying(operation, identity: original.revisionIdentity,
                initialText: original.content.candidateText, expected: lifecycle.state.vector, now: Date()))
        }
        XCTAssertThrowsError(try lifecycle.applying(.review(.reviewed), identity: original.revisionIdentity,
            initialText: original.content.candidateText, expected: .init(content: 1, review: 0), now: Date()))
    }

    func testCompleteNativeValueRoundTripIgnoresManifestDateStrategies() throws {
        let workspaceID = UUID(), documentID = UUID()
        let envelope = try AnalystFindingEnvelopeFixture.make(workspaceID: workspaceID, documentID: documentID)
        try WorkspaceStore.validateAnalystFindingsForRestore(envelope, workspaceID: workspaceID, documentID: documentID)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let reopened = try decoder.decode(AnalystFindingEnvelope.self, from: encoder.encode(envelope))
        XCTAssertEqual(reopened, envelope)
        let native = try AnalystFindingDraftConversion.restoredValue(reopened.records[0].content)
        XCTAssertEqual(native.candidate.text, "Entire authored answer\nΩ")
        XCTAssertEqual(native.originalRequest.requestID, envelope.records[0].content.originalRequest.requestID)
        XCTAssertEqual(native.originalContext.canonicalBytes, envelope.records[0].content.originalRequest.groundedContext.canonicalBytes)
    }

    func testFutureSchemaAndRevisionHistoryRefuseInsteadOfFlattening() throws {
        let envelope = try AnalystFindingEnvelopeFixture.make(workspaceID: UUID(), documentID: UUID())
        let bytes = try JSONEncoder().encode(envelope)
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        root["schemaVersion"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(AnalystFindingEnvelope.self,
            from: JSONSerialization.data(withJSONObject: root)))
        root["schemaVersion"] = 1
        let original = try XCTUnwrap(root["records"] as? [[String: Any]])
        let changes: [[String: Any]] = [["contentRevision": 2], ["reviewRevision": 1],
                                      ["review": "approved"], ["transitionHistory": [["future": true]]]]
        for change in changes {
            var record = original[0]
            record.merge(change) { _, replacement in replacement }
            root["records"] = [record]
            XCTAssertThrowsError(try JSONDecoder().decode(AnalystFindingEnvelope.self,
                from: JSONSerialization.data(withJSONObject: root)))
        }
    }

    func testWrongOwnerAndDuplicateRequestRefuseWholeEnvelope() throws {
        let workspaceID = UUID(), documentID = UUID()
        let envelope = try AnalystFindingEnvelopeFixture.make(workspaceID: workspaceID, documentID: documentID)
        XCTAssertThrowsError(try envelope.validate(workspaceID: UUID(), documentID: documentID))
        let repeated = AnalystFindingEnvelope(records: envelope.records + envelope.records)
        XCTAssertThrowsError(try repeated.validate(workspaceID: workspaceID, documentID: documentID))
    }
}

private struct AnalystFindingNativeFixture {
        let workspace = Phase2ReadWorkspaceIdentity(document: .init(instanceID: UUID()), instanceID: UUID())
        var precondition: Phase2ReadPrecondition {
            .init(workspace: workspace, workspaceRevision: 1, strictWholeWorkspace: true,
                  image: nil, dependencies: [])
        }
        var current: Phase2ReadCurrentState {
            .init(workspace: workspace, workspaceRevision: 1, image: nil, facetRevisions: [])
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

