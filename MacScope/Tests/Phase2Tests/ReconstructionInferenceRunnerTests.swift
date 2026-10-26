import XCTest

@testable import MacScope

final class ReconstructionInferenceRunnerTests: XCTestCase {
    @MainActor
    func testReadyCoordinatorDoesNotConstructReconstructionProviderWithoutFreshLease() async {
        let controller = Phase2LocalAIProviderController(endpoint: nil)
        var constructionCount = 0
        let coordinator = Phase2ReadyInferenceCoordinator(
            controller: controller,
            reconstructionProviderFactory: { _ in
                constructionCount += 1
                return ScriptedRunnerProvider()
            }
        )

        let result = await coordinator.run(request: runnerRoundRequest())

        XCTAssertEqual(result, .notReady(.endpointMissing))
        XCTAssertEqual(constructionCount, 0)
    }

    func testRoundRequiresOneCandidateOneUsageAndTerminalReceipt() async throws {
        let request = runnerRoundRequest()
        let requestID = runnerID(90)
        let candidate = ReconstructionInferenceRoundCandidate(
            jobID: request.jobID,
            checkpointRevision: request.checkpointRevision,
            roundID: request.roundID,
            selectedHandleIDs: [],
            disposition: .sufficientEvidence,
            unresolvedGaps: []
        )
        let usage = Phase2AIWorkerWireUsage(
            promptTokens: 4,
            completionTokens: 2,
            totalTokens: 6
        )
        let provider = ScriptedRunnerProvider(roundBodies: [
            .roundCandidate(candidate), .usage(usage), .completed,
        ])

        let result = try await ReconstructionInferenceRunner().run(
            requestID: requestID,
            request: request,
            provider: provider
        )

        XCTAssertEqual(result.candidate, candidate)
        XCTAssertEqual(result.usage, usage)
        XCTAssertEqual(result.terminalReceipt.requestID, requestID)
        XCTAssertEqual(result.terminalReceipt.status, .completed)
    }

    func testDuplicateCandidateFailsClosed() async throws {
        let request = runnerRoundRequest()
        let candidate = ReconstructionInferenceRoundCandidate(
            jobID: request.jobID,
            checkpointRevision: request.checkpointRevision,
            roundID: request.roundID,
            selectedHandleIDs: [],
            disposition: .continue,
            unresolvedGaps: []
        )
        let provider = ScriptedRunnerProvider(roundBodies: [
            .roundCandidate(candidate),
            .roundCandidate(candidate),
            .usage(.init(promptTokens: 1, completionTokens: 1, totalTokens: 2)),
            .completed,
        ])

        do {
            _ = try await ReconstructionInferenceRunner().run(
                requestID: runnerID(91), request: request, provider: provider
            )
            XCTFail("Expected duplicate candidate rejection")
        } catch {
            XCTAssertEqual(error as? ReconstructionInferenceRunnerError, .duplicateCandidate)
        }
    }

    func testFinalSynthesisCannotCiteEvidenceOutsideDurableRequestCut() async throws {
        let request = runnerFinalRequest()
        let provider = ScriptedRunnerProvider(finalBodies: [
            .finalCandidate(.init(
                kind: .synthesis,
                text: "unsupported",
                evidenceIDs: [runnerID(999)]
            )),
            .usage(.init(promptTokens: 1, completionTokens: 1, totalTokens: 2)),
            .completed,
        ])

        do {
            _ = try await ReconstructionInferenceRunner().synthesize(
                requestID: runnerID(92), request: request, provider: provider
            )
            XCTFail("Expected final evidence fence rejection")
        } catch {
            let terminal = try XCTUnwrap(
                error as? ReconstructionInferenceRunnerTerminalFailure
            )
            XCTAssertEqual(terminal.failure, .runner(.invalidFinalEvidence))
            XCTAssertEqual(terminal.terminalReceipt.requestID, runnerID(92))
        }
    }

    func testFinalSynthesisRequiresNonemptyBoundedProseAndDurableCitations() async throws {
        let request = runnerFinalRequest()
        let cases: [(String, ReconstructionFinalSynthesisCandidate)] = [
            ("empty prose", .init(
                kind: .synthesis,
                text: "",
                evidenceIDs: [request.acceptedEvidenceIDs[0]]
            )),
            ("missing citations", .init(
                kind: .synthesis,
                text: "Grounded result.",
                evidenceIDs: []
            )),
            ("over-limit prose", .init(
                kind: .synthesis,
                text: String(repeating: "a", count: 60_001),
                evidenceIDs: [request.acceptedEvidenceIDs[0]]
            )),
        ]

        for (name, candidate) in cases {
            let provider = ScriptedRunnerProvider(finalBodies: finalBodies(candidate))
            do {
                _ = try await ReconstructionInferenceRunner().synthesize(
                    requestID: runnerID(93), request: request, provider: provider
                )
                XCTFail("Expected \(name) to fail closed")
            } catch {
                let terminal = try XCTUnwrap(
                    error as? ReconstructionInferenceRunnerTerminalFailure,
                    name
                )
                XCTAssertEqual(terminal.failure, .runner(.invalidFinalCandidate), name)
            }
        }
    }

    func testInsufficientEvidenceRequiresNonemptyBoundedReasonAndNoCitations() async throws {
        let request = runnerFinalRequest()
        let cases: [(String, ReconstructionFinalSynthesisCandidate)] = [
            ("empty reason", .init(
                kind: .insufficientEvidence,
                text: "",
                evidenceIDs: []
            )),
            ("arbitrary citation", .init(
                kind: .insufficientEvidence,
                text: "More durable evidence is required.",
                evidenceIDs: [request.acceptedEvidenceIDs[0]]
            )),
            ("over-limit reason", .init(
                kind: .insufficientEvidence,
                text: String(repeating: "a", count: 4_097),
                evidenceIDs: []
            )),
        ]

        for (name, candidate) in cases {
            let provider = ScriptedRunnerProvider(finalBodies: finalBodies(candidate))
            do {
                _ = try await ReconstructionInferenceRunner().synthesize(
                    requestID: runnerID(94), request: request, provider: provider
                )
                XCTFail("Expected \(name) to fail closed")
            } catch {
                let terminal = try XCTUnwrap(
                    error as? ReconstructionInferenceRunnerTerminalFailure,
                    name
                )
                XCTAssertEqual(terminal.failure, .runner(.invalidFinalCandidate), name)
            }
        }
    }

    func testFinalSynthesisCanonicalizesValidReversedCitationsWithoutChangingTerminalPayload() async throws {
        let accepted = [runnerID(10), runnerID(11), runnerID(12)]
        let request = runnerFinalRequest(acceptedEvidenceIDs: accepted)
        let candidate = ReconstructionFinalSynthesisCandidate(
            kind: .synthesis, text: "Grounded result in provider citation order.",
            evidenceIDs: [runnerID(12), runnerID(11), runnerID(10)])
        let requestID = runnerID(97)
        let result = try await ReconstructionInferenceRunner().synthesize(
            requestID: requestID, request: request,
            provider: ScriptedRunnerProvider(finalBodies: finalBodies(candidate)))

        XCTAssertEqual(result.candidate.evidenceIDs, [runnerID(10), runnerID(11), runnerID(12)])
        XCTAssertEqual(result.candidate.kind, .synthesis)
        XCTAssertEqual(result.candidate.text, "Grounded result in provider citation order.")
        XCTAssertEqual(result.usage, .init(promptTokens: 1, completionTokens: 1, totalTokens: 2))
        XCTAssertEqual(result.terminalReceipt, .init(requestID: requestID, jobID: request.jobID,
            checkpointRevision: request.checkpointRevision, roundID: nil, status: .completed))
    }

    func testFinalSynthesisRejectsInvalidCitationsBeforeCanonicalization() async throws {
        let excessive = (10...4_106).map(runnerID)
        let cases: [(String, [UUID], [UUID])] = [
            ("duplicates", [runnerID(10), runnerID(11)], [runnerID(11), runnerID(10), runnerID(11)]),
            ("unknown", [runnerID(10), runnerID(11)], [runnerID(999), runnerID(10)]),
            ("excessive unique accepted citations", excessive, Array(excessive.reversed())),
        ]
        for (name, accepted, citations) in cases {
            let request = runnerFinalRequest(acceptedEvidenceIDs: accepted)
            let candidate = ReconstructionFinalSynthesisCandidate(
                kind: .synthesis, text: "Invalid citation set.", evidenceIDs: citations)
            do {
                _ = try await ReconstructionInferenceRunner().synthesize(
                    requestID: runnerID(98), request: request,
                    provider: ScriptedRunnerProvider(finalBodies: finalBodies(candidate)))
                XCTFail("Expected invalid final evidence: \(name)")
            } catch {
                let terminal = try XCTUnwrap(error as? ReconstructionInferenceRunnerTerminalFailure)
                XCTAssertEqual(terminal.failure, .runner(.invalidFinalEvidence), name)
                XCTAssertEqual(terminal.terminalReceipt, .init(requestID: runnerID(98), jobID: request.jobID,
                    checkpointRevision: request.checkpointRevision, roundID: nil, status: .completed), name)
            }
        }
    }

    func testValidFinalCandidateShapesRemainAccepted() async throws {
        let request = runnerFinalRequest()
        let candidates: [ReconstructionFinalSynthesisCandidate] = [
            .init(
                kind: .synthesis,
                text: "Grounded result.",
                evidenceIDs: [request.acceptedEvidenceIDs[0]]
            ),
            .init(
                kind: .insufficientEvidence,
                text: "More durable evidence is required.",
                evidenceIDs: []
            ),
        ]

        for (index, candidate) in candidates.enumerated() {
            let result = try await ReconstructionInferenceRunner().synthesize(
                requestID: runnerID(95 + index),
                request: request,
                provider: ScriptedRunnerProvider(finalBodies: finalBodies(candidate))
            )
            XCTAssertEqual(result.candidate, candidate)
        }
    }
}

private func finalBodies(
    _ candidate: ReconstructionFinalSynthesisCandidate
) -> [ReconstructionAIWorkerEventBody] {
    [
        .finalCandidate(candidate),
        .usage(.init(promptTokens: 1, completionTokens: 1, totalTokens: 2)),
        .completed,
    ]
}

private actor ScriptedRunnerProvider: ReconstructionInferenceProviding {
    let roundBodies: [ReconstructionAIWorkerEventBody]
    let finalBodies: [ReconstructionAIWorkerEventBody]

    init(
        roundBodies: [ReconstructionAIWorkerEventBody] = [],
        finalBodies: [ReconstructionAIWorkerEventBody] = []
    ) {
        self.roundBodies = roundBodies
        self.finalBodies = finalBodies
    }

    func runRound(
        requestID: UUID,
        request: ReconstructionInferenceRoundRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt {
        for (index, body) in roundBodies.enumerated() {
            try await emit(.init(
                requestID: requestID,
                sequence: UInt64(index + 1),
                body: body
            ))
        }
        return .init(
            requestID: requestID,
            jobID: request.jobID,
            checkpointRevision: request.checkpointRevision,
            roundID: request.roundID,
            status: .completed
        )
    }

    func runFinalSynthesis(
        requestID: UUID,
        request: ReconstructionFinalSynthesisRequest,
        emit: @escaping @Sendable (ReconstructionAIWorkerEvent) async throws -> Void
    ) async throws -> ReconstructionTerminalReceipt {
        for (index, body) in finalBodies.enumerated() {
            try await emit(.init(
                requestID: requestID,
                sequence: UInt64(index + 1),
                body: body
            ))
        }
        return .init(
            requestID: requestID,
            jobID: request.jobID,
            checkpointRevision: request.checkpointRevision,
            roundID: nil,
            status: .completed
        )
    }

    func cancel(requestID: UUID) async {}
}

private func runnerRoundRequest() -> ReconstructionInferenceRoundRequest {
    .init(
        protocolVersion: Phase2ReconstructionAIWorkerWireCodec.protocolVersion,
        jobID: runnerID(1),
        checkpointRevision: 3,
        roundID: runnerID(2),
        corpusManifestSHA256: runnerDigest(1),
        evidenceFrontierSHA256: runnerDigest(2),
        registryManifestSHA256: Phase2ReconstructionProtocolArtifacts.make()
            .toolRegistry.identity.sha256,
        context: runnerContext(),
        handles: [.init(handleID: runnerID(3), operationID: .corpusSummary)]
    )
}

private func runnerFinalRequest(acceptedEvidenceIDs: [UUID] = [runnerID(10)]) -> ReconstructionFinalSynthesisRequest {
    .init(
        jobID: runnerID(1),
        checkpointRevision: 3,
        corpusManifestSHA256: runnerDigest(1),
        evidenceFrontierSHA256: runnerDigest(2),
        acceptedEvidenceIDs: acceptedEvidenceIDs,
        context: runnerContext(evidenceIDs: acceptedEvidenceIDs)
    )
}

private func runnerContext(evidenceIDs: [UUID] = []) -> ReconstructionRetrievedContext {
    let bytes = Data(#"{"context":"durable"}"#.utf8)
    return .init(
        canonicalBytes: bytes,
        canonicalSHA256: ReconstructionPackageCodec.sha256(bytes),
        evidenceIDs: evidenceIDs
    )
}

private func runnerID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "51000000-0000-4000-8000-%012d", value))!
}

private func runnerDigest(_ value: Int) -> String { String(format: "%064x", value) }
