import CryptoKit
import XCTest

@testable import MacScope

@MainActor
final class Phase2AssistantShellContinuationDispatchAdapterTests: XCTestCase {
    func testDispatchBindsExactV6EnvelopeAndReducesCorrelatedFinalOnly() async throws {
        let fixture = DispatchFixture()
        let coordinator = DispatchCoordinator { request in
            do {
                let data = try Phase2AIWorkerAppCodec().encodeRequest(request)
                let wire = try Phase2AIWorkerWireCodec().decodeRequest(data)
                XCTAssertEqual(wire.phase, .shellContinuation)
                XCTAssertEqual(wire.protocolVersion, 6)
                XCTAssertEqual(wire.requestID, fixture.coordinate.continuationRequestID)
                XCTAssertEqual(wire.shellContinuationCoordinate?.integrityDigest,
                               fixture.coordinate.integrityDigest)
                XCTAssertEqual(wire.shellContinuationCoordinate?.appCoordinate(), fixture.coordinate)
                XCTAssertTrue(wire.toolHandles.isEmpty)
                XCTAssertTrue(request.userGoal.contains("shell output"), request.userGoal)
                XCTAssertTrue(
                    request.userGoal.contains(fixture.coordinate.shellExecutionResultDigest),
                    request.userGoal
                )
                return fixture.finished(outcome: fixture.outcome)
            } catch {
                XCTFail("v6 request must encode: \(error)")
                return .invalidRequest
            }
        }
        let adapter = Phase2AssistantShellContinuationDispatchAdapter(
            coordinator: coordinator,
            context: { coordinate in fixture.context(coordinate: coordinate) }
        )

        guard case .completed(let outcome) = await adapter.dispatchShellContinuation(
            coordinate: fixture.coordinate,
            executionResult: fixture.executionResult
        ) else { return XCTFail("Expected completed continuation") }
        XCTAssertEqual(outcome.disposition, .completed)
        XCTAssertEqual(outcome.finalCandidate?.text, "Done")
        XCTAssertEqual(outcome.providerUsage?.totalTokens, 3)
        XCTAssertTrue(outcome.toolProposals.isEmpty)
        XCTAssertTrue(outcome.shellProposals.isEmpty)
        XCTAssertTrue(outcome.debuggerActionProposals.isEmpty)
    }

    func testDispatchRejectsCoordinatorFailure() async {
        let fixture = DispatchFixture()
        let adapter = Phase2AssistantShellContinuationDispatchAdapter(
            coordinator: DispatchCoordinator { _ in .providerAuthorityChanged },
            context: { coordinate in fixture.context(coordinate: coordinate) }
        )
        if case .completed = await adapter.dispatchShellContinuation(
            coordinate: fixture.coordinate,
            executionResult: fixture.executionResult
        ) {
            XCTFail("Foreign continuation event must fail closed")
        }
    }

    func testDispatchRejectsForeignDocumentContextBeforeCoordinatorCall() async {
        let fixture = DispatchFixture()
        var coordinatorWasCalled = false
        let adapter = Phase2AssistantShellContinuationDispatchAdapter(
            coordinator: DispatchCoordinator { _ in
                coordinatorWasCalled = true
                return fixture.finished(outcome: fixture.outcome)
            },
            context: { coordinate in
                fixture.context(coordinate: coordinate, documentID: UUID())
            }
        )

        if case .completed = await adapter.dispatchShellContinuation(
            coordinate: fixture.coordinate,
            executionResult: fixture.executionResult
        ) {
            XCTFail("Foreign document context must fail closed")
        }
        XCTAssertFalse(coordinatorWasCalled)
    }

    func testDispatchRejectsExecutionResultWhoseBytesDoNotMatchCoordinate() async {
        let fixture = DispatchFixture()
        let foreign = fixture.executionResult(replacingStandardOutput: "foreign output")
        var coordinatorWasCalled = false
        let adapter = Phase2AssistantShellContinuationDispatchAdapter(
            coordinator: DispatchCoordinator { _ in
                coordinatorWasCalled = true
                return fixture.finished(outcome: fixture.outcome)
            },
            context: { coordinate in fixture.context(coordinate: coordinate) }
        )

        if case .completed = await adapter.dispatchShellContinuation(
            coordinate: fixture.coordinate,
            executionResult: foreign
        ) {
            XCTFail("Foreign shell bytes must fail closed")
        }
        XCTAssertFalse(coordinatorWasCalled)
    }
}

@MainActor
private final class DispatchCoordinator: Phase2AssistantInferenceCoordinating {
    typealias Body = @MainActor (Phase2InferenceRequest) async
        -> Phase2ReadyInferenceExecutionResult
    private let body: Body

    init(body: @escaping Body) {
        self.body = body
    }

    func run(request: Phase2InferenceRequest) async -> Phase2ReadyInferenceExecutionResult {
        await body(request)
    }
}

private struct DispatchFixture: @unchecked Sendable {
    let evidenceID = UUID()
    let documentID = UUID()
    let workspaceID = UUID()
    let conversationID = UUID()
    let turnID = UUID()
    let requestID = UUID()
    let executionResult: Phase2AIShellOneShotExecutionResult
    let coordinate: Phase2AssistantShellContinuationCoordinate

    init() {
        let executionID = UUID()
        let proposalID = UUID()
        let now = Date(timeIntervalSince1970: 100)
        let result = Phase2AIShellOneShotExecutionResult(
            id: executionID,
            proposalID: proposalID,
            executablePath: "/usr/bin/true",
            arguments: [],
            workingDirectoryPath: nil,
            timeoutMilliseconds: 1_000,
            maximumOutputBytes: 1_024,
            disposition: .completed,
            terminationStatus: 0,
            standardOutput: "shell output\n",
            standardError: "",
            outputWasTruncated: false,
            startedAt: now,
            completedAt: now,
            failureMessage: nil
        )
        executionResult = result
        coordinate = Phase2AssistantShellContinuationCoordinate(
            workspaceID: workspaceID,
            workspaceDocumentIdentityDigest: Phase2AssistantWorkspaceDocumentIdentity.digest(
                documentID: documentID,
                workspaceID: workspaceID
            ),
            conversationID: conversationID, inferenceTurnID: turnID, turnSequence: 1,
            originatingFinalizationRequestID: UUID(), shellProposalID: proposalID,
            shellExecutionID: executionID, runtimeAuthorityRecordID: UUID(),
            shellProposalDigest: String(repeating: "a", count: 64),
            shellExecutionResultDigest:
                Phase2AssistantShellExecutionResultCanonicalizer.digest(result),
            runtimeAuthorityRecordDigest: String(repeating: "c", count: 64),
            productionManifestIdentity: Phase2AIWorkerProductionProtocol.assistantR4.manifestIdentity,
            providerRevision: 7, continuationRequestID: requestID
        )!
    }

    func context(
        coordinate: Phase2AssistantShellContinuationCoordinate,
        documentID: UUID? = nil
    ) -> Phase2AssistantShellContinuationDispatchContext? {
        let documentID = documentID ?? self.documentID
        let document = Phase2ReadDocumentIdentity(instanceID: documentID)
        let workspace = Phase2ReadWorkspaceIdentity(document: document, instanceID: workspaceID)
        return .init(
            documentID: documentID, workspaceID: workspaceID,
            workspaceDocumentIdentityDigest: coordinate.workspaceDocumentIdentityDigest,
            lifecycleRevision: 9,
            providerRevision: 7, originalUserGoal: "Original request",
            groundedContext: groundedContext(workspace: workspace),
            conversationContext: .init(turns: [], omittedTurnCount: 0), limits: .assistantMaximum
        )
    }

    func executionResult(
        replacingStandardOutput standardOutput: String
    ) -> Phase2AIShellOneShotExecutionResult {
        .init(
            id: executionResult.id,
            schemaVersion: executionResult.schemaVersion,
            proposalID: executionResult.proposalID,
            executablePath: executionResult.executablePath,
            arguments: executionResult.arguments,
            workingDirectoryPath: executionResult.workingDirectoryPath,
            timeoutMilliseconds: executionResult.timeoutMilliseconds,
            maximumOutputBytes: executionResult.maximumOutputBytes,
            disposition: executionResult.disposition,
            terminationStatus: executionResult.terminationStatus,
            standardOutput: standardOutput,
            standardError: executionResult.standardError,
            outputWasTruncated: executionResult.outputWasTruncated,
            startedAt: executionResult.startedAt,
            completedAt: executionResult.completedAt,
            failureMessage: executionResult.failureMessage
        )
    }

    private func groundedContext(
        workspace: Phase2ReadWorkspaceIdentity
    ) -> Phase2GroundedContext {
        let record = Phase2GroundedContextRecord(
            evidenceID: evidenceID,
            candidateID: UUID(),
            invocationID: UUID(),
            sequence: 1,
            descriptor: .init(
                registryVersion: .v1,
                id: .workspaceSummary,
                operationVersion: .v1,
                effects: [.a1]
            ),
            producingPrincipal: .app,
            trustClass: .untrustedProjectData,
            precondition: .init(
                workspace: workspace,
                workspaceRevision: 1,
                strictWholeWorkspace: true,
                image: nil,
                dependencies: []
            ),
            citations: [],
            data: .value(.text("grounded")),
            payloadDigest: String(repeating: "a", count: 64)
        )
        let manifest = Phase2GroundedContextManifest(records: [record], omissions: [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try! encoder.encode(manifest)
        let digest = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
        return .make(records: [record], omissions: [], canonicalBytes: bytes, digest: digest)
    }

    func event(_ sequence: UInt64, _ body: Phase2AIWorkerWireEventBody) -> Phase2AIWorkerWireEvent {
        .init(
            wireProtocol: Phase2AIWorkerProductionProtocol.assistantR4.wireIdentity,
            protocolVersion: 6, phase: .shellContinuation,
            sessionID: conversationID, turnID: turnID, requestID: requestID,
            documentID: documentID, workspaceID: workspaceID, lifecycleRevision: 9,
            sequence: sequence, body: body
        )
    }

    var outcome: Phase2InferenceOutcome {
        .init(
            disposition: .completed,
            previewDeltas: [],
            toolProposals: [],
            shellProposals: [],
            debuggerActionProposals: [],
            finalCandidate: .init(kind: .answer, text: "Done", evidenceIDs: [evidenceID]),
            providerUsage: .init(promptTokens: 2, completionTokens: 1, totalTokens: 3),
            violation: nil,
            acceptedEventCount: 3,
            cumulativeEventBytes: 512
        )
    }

    func finished(
        outcome: Phase2InferenceOutcome
    ) -> Phase2ReadyInferenceExecutionResult {
        let configuration = try! Phase2AIProviderConfiguration(
            profileID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            generation: 1,
            endpointOrigin: "http://127.0.0.1:1234",
            model: "fixture",
            maximumTokens: 512,
            requestTimeoutMilliseconds: 1_000,
            resourceTimeoutMilliseconds: 2_000
        )
        return .finished(
            lease: .init(
                providerRevision: 7,
                configuration: configuration,
                observedModelInventorySHA256: String(repeating: "a", count: 64)
            ),
            outcome: outcome
        )
    }
}
