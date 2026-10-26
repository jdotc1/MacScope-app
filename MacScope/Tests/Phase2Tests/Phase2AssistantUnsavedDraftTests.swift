import Foundation
import XCTest
@testable import MacScope

final class Phase2AssistantUnsavedDraftTests: XCTestCase {
    private struct Fixture {
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

    func testNativeGroundedAnswerPreservesWholeCandidateAndOriginalContext() throws {
        let fixture = Fixture()
        let executions = try [fixture.execution(), fixture.execution()]
        let source = try fixture.context(executions)
        let reference = try XCTUnwrap(source.records.first?.evidenceID)
        let text = String(repeating: "Untrimmed complete answer\n", count: 128) + "Ω\n "
        let result = fixture.result(source, executions: executions, evidenceIDs: [reference], text: text)
        let draft = try Phase2AssistantUnsavedDraftAdapter.make(result: result,
            currentStateByEvidenceID: fixture.states(source))
        XCTAssertEqual(draft.originalRequest, result.request)
        XCTAssertEqual(draft.candidate, result.inferenceOutcome?.finalCandidate)
        XCTAssertEqual(draft.candidate.text, text)
        XCTAssertEqual(draft.runnerReportedProviderRevision, 7)
        XCTAssertEqual(draft.originalContext, source)
        XCTAssertEqual(draft.recompiledContext.records.count, 1)
        XCTAssertEqual(draft.recompiledContext.records.first, source.records.first)
        XCTAssertEqual(draft.originalContext.records.count, 2)
        XCTAssertNotEqual(draft.originalContext.canonicalBytes, draft.recompiledContext.canonicalBytes)
        let withOmission = try Phase2GroundedContextCompiler().compile(
            records: executions.map { try XCTUnwrap($0.acceptedEvidence) },
            currentStateByEvidenceID: fixture.states(source),
            limits: .init(maximumRecords: 1, maximumCanonicalBytes: 1_048_576))
        let omittedSource = fixture.result(withOmission, executions: executions, evidenceIDs: [reference])
        let retained = try Phase2AssistantUnsavedDraftAdapter.make(result: omittedSource,
            currentStateByEvidenceID: fixture.states(source))
        XCTAssertEqual(retained.originalContext.omissions, withOmission.omissions)
        XCTAssertEqual(retained.originalContext.omissions.count, 1)
        XCTAssertTrue(retained.recompiledContext.omissions.isEmpty)
    }

    func testUnacceptedNonAnswerOrUngroundedResultCannotBecomeDraft() throws {
        let fixture = Fixture()
        let executions = try [fixture.execution()]
        let context = try fixture.context(executions)
        let states = fixture.states(context)
        for result in [fixture.result(context, executions: executions, kind: .insufficientEvidence),
                       fixture.result(context, executions: executions, unverified: ["0x1234"]),
                       fixture.result(context, executions: executions, disposition: .cancelled),
                       fixture.result(context, executions: executions, failure: .inferenceInvalidRequest)] {
            XCTAssertThrowsError(try Phase2AssistantUnsavedDraftAdapter.make(result: result, currentStateByEvidenceID: states)) {
                XCTAssertEqual($0 as? Phase2AssistantUnsavedDraftError, .unacceptedAnswer)
            }
        }
        XCTAssertThrowsError(try Phase2AssistantUnsavedDraftAdapter.make(
            result: fixture.result(context, executions: executions, omitContext: true), currentStateByEvidenceID: states)) {
            XCTAssertEqual($0 as? Phase2AssistantUnsavedDraftError, .missingSourceContext)
        }
        XCTAssertThrowsError(try Phase2AssistantUnsavedDraftAdapter.make(
            result: fixture.result(context, executions: executions, omitRequest: true), currentStateByEvidenceID: states)) {
            XCTAssertEqual($0 as? Phase2AssistantUnsavedDraftError, .missingRequest)
        }
        for provider in [Optional<UInt64>.none, .some(0)] {
            XCTAssertThrowsError(try Phase2AssistantUnsavedDraftAdapter.make(
                result: fixture.result(context, executions: executions, provider: provider), currentStateByEvidenceID: states)) {
                XCTAssertEqual($0 as? Phase2AssistantUnsavedDraftError,
                    provider == nil ? .missingProviderRevision : .invalidProviderRevision(0))
            }
        }
        let otherContext = try fixture.context([fixture.execution()])
        XCTAssertThrowsError(try Phase2AssistantUnsavedDraftAdapter.make(result: fixture.result(context,
            executions: executions, request: fixture.request(context, phase: .toolSelection)), currentStateByEvidenceID: states)) {
            XCTAssertEqual($0 as? Phase2AssistantUnsavedDraftError, .requestPhaseMismatch)
        }
        let otherWorkspace = Phase2ReadWorkspaceIdentity(document: fixture.workspace.document, instanceID: UUID())
        XCTAssertThrowsError(try Phase2AssistantUnsavedDraftAdapter.make(result: fixture.result(context,
            executions: executions, request: fixture.request(context, workspaceOverride: otherWorkspace)), currentStateByEvidenceID: states)) {
            XCTAssertEqual($0 as? Phase2AssistantUnsavedDraftError,
                .requestOwnerMismatch(evidenceID: context.records[0].evidenceID))
        }
        XCTAssertThrowsError(try Phase2AssistantUnsavedDraftAdapter.make(result: fixture.result(context,
            executions: executions, request: fixture.request(otherContext)), currentStateByEvidenceID: states)) {
            XCTAssertEqual($0 as? Phase2AssistantUnsavedDraftError, .requestContextMismatch)
        }
        XCTAssertThrowsError(try Phase2AssistantUnsavedDraftAdapter.make(result: fixture.result(context,
            executions: executions, request: fixture.request(context, revision: 2)), currentStateByEvidenceID: states)) {
            XCTAssertEqual($0 as? Phase2AssistantUnsavedDraftError,
                .requestLifecycleMismatch(evidenceID: context.records[0].evidenceID))
        }
    }

    func testUnknownDuplicateOrConflictingEvidenceReferenceRefusesWholeDraft() throws {
        let fixture = Fixture(), unknown = UUID()
        let execution = try fixture.execution()
        let context = try fixture.context([execution])
        let id = context.records[0].evidenceID
        let invalid: [([UUID], Phase2AssistantUnsavedDraftError)] = [
            ([], .invalidReferences), ([id, id], .invalidReferences), ([unknown], .unacceptedAnswer)
        ]
        for (ids, expected) in invalid {
            XCTAssertThrowsError(try Phase2AssistantUnsavedDraftAdapter.make(result: fixture.result(context,
                executions: [execution], evidenceIDs: ids), currentStateByEvidenceID: fixture.states(context))) {
                XCTAssertEqual($0 as? Phase2AssistantUnsavedDraftError, expected)
            }
        }
        XCTAssertThrowsError(try Phase2AssistantUnsavedDraftAdapter.make(result: fixture.result(context,
            executions: []), currentStateByEvidenceID: fixture.states(context))) {
            XCTAssertEqual($0 as? Phase2AssistantUnsavedDraftError, .missingAcceptedEvidence(id))
        }
        XCTAssertThrowsError(try Phase2AssistantUnsavedDraftAdapter.make(result: fixture.result(context,
            executions: [execution, execution]), currentStateByEvidenceID: fixture.states(context))) {
            XCTAssertEqual($0 as? Phase2AssistantUnsavedDraftError, .conflictingAcceptedEvidence(id))
        }
        let rejected = Phase2ReadExecution(candidate: execution.candidate,
            outcome: .init(invocationID: execution.candidate.invocationID, sequence: 1, disposition: .cancelled),
            acceptedEvidence: execution.acceptedEvidence)
        XCTAssertThrowsError(try Phase2AssistantUnsavedDraftAdapter.make(result: fixture.result(context,
            executions: [rejected]), currentStateByEvidenceID: fixture.states(context))) {
            XCTAssertEqual($0 as? Phase2AssistantUnsavedDraftError, .conflictingAcceptedEvidence(id))
        }
        XCTAssertThrowsError(try Phase2AssistantUnsavedDraftAdapter.make(result: fixture.result(context,
            executions: [execution], primary: rejected), currentStateByEvidenceID: fixture.states(context))) {
            XCTAssertEqual($0 as? Phase2AssistantUnsavedDraftError, .conflictingAcceptedEvidence(id))
        }
    }

    func testStaleOwnerOrMissingCurrentStateRefusesThroughNativeCompiler() throws {
        let fixture = Fixture()
        let executions = try [fixture.execution()]
        let context = try fixture.context(executions), id = context.records[0].evidenceID
        let result = fixture.result(context, executions: executions)
        XCTAssertThrowsError(try Phase2AssistantUnsavedDraftAdapter.make(result: result, currentStateByEvidenceID: [:])) {
            XCTAssertEqual($0 as? Phase2GroundedContextError, .missingCurrentState(id))
        }
        let stale = Phase2ReadCurrentState(workspace: fixture.workspace, workspaceRevision: 2,
                                           image: nil, facetRevisions: [])
        XCTAssertThrowsError(try Phase2AssistantUnsavedDraftAdapter.make(result: result, currentStateByEvidenceID: [id: stale])) {
            XCTAssertEqual($0 as? Phase2GroundedContextError, .stale(id))
        }
        let other = Phase2ReadCurrentState(workspace: .init(document: fixture.workspace.document, instanceID: UUID()),
            workspaceRevision: 1, image: nil, facetRevisions: [])
        XCTAssertThrowsError(try Phase2AssistantUnsavedDraftAdapter.make(result: result, currentStateByEvidenceID: [id: other])) {
            XCTAssertEqual($0 as? Phase2GroundedContextError, .ownerMismatch(id))
        }
    }

    func testThreeReferenceAndCanonicalByteBudgetsNeverSilentlyDropNamedEvidence() throws {
        let fixture = Fixture()
        let executions = try [fixture.execution(), fixture.execution(), fixture.execution()]
        let context = try fixture.context(executions)
        let draft = try Phase2AssistantUnsavedDraftAdapter.make(result: fixture.result(context, executions: executions),
            currentStateByEvidenceID: fixture.states(context))
        XCTAssertEqual(draft.recompiledContext.records.count, 3)
        XCTAssertTrue(draft.recompiledContext.omissions.isEmpty)
        XCTAssertThrowsError(try Phase2AssistantUnsavedDraftAdapter.make(result: fixture.result(context,
            executions: executions, evidenceIDs: context.records.map(\.evidenceID) + [UUID()]),
            currentStateByEvidenceID: fixture.states(context))) {
            XCTAssertEqual($0 as? Phase2AssistantUnsavedDraftError, .invalidReferences)
        }
        // Adversarial internally constructed source: three individually admitted large native
        // rows cannot fit together. The adapter must refuse the compiler's named omission.
        let largeValue = Phase2ReadCandidateData.value(.list(Array(repeating: .text(String(repeating: "x", count: 60_000)), count: 8)))
        let large = try [fixture.execution(data: largeValue), fixture.execution(data: largeValue), fixture.execution(data: largeValue)]
        let records = try large.flatMap { try fixture.context([$0]).records }
        let malformed = Phase2GroundedContext.make(records: records, omissions: [], canonicalBytes: Data(), digest: "fixture-only")
        XCTAssertThrowsError(try Phase2AssistantUnsavedDraftAdapter.make(result: fixture.result(malformed,
            executions: large), currentStateByEvidenceID: fixture.states(malformed))) {
            guard let error = $0 as? Phase2AssistantUnsavedDraftError, case .namedEvidenceOmitted = error else {
                return XCTFail("Named evidence must not disappear into a successful draft: \($0)")
            }
        }
    }

    func testRecompiledNativeRecordMustMatchOriginalAcceptedFacts() throws {
        let fixture = Fixture()
        let first = try fixture.execution()
        let context = try fixture.context([first]), id = context.records[0].evidenceID
        let different = try fixture.execution(data: .value(.text("Different native fact")), evidenceID: id)
        XCTAssertThrowsError(try Phase2AssistantUnsavedDraftAdapter.make(result: fixture.result(context,
            executions: [different]), currentStateByEvidenceID: fixture.states(context))) {
            XCTAssertEqual($0 as? Phase2AssistantUnsavedDraftError, .nativeRecordMismatch(id))
        }
    }
}
