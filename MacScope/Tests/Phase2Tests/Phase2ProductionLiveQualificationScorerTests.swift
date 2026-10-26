import Foundation
import XCTest
@testable import MacScope

@MainActor
final class Phase2ProductionLiveQualificationScorerTests: XCTestCase {
    func testCatalogMaterializesTheExactCanonicalDenominatorWithoutCallerInputs() throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let first = try catalog.productionFixtures()
        let second = try catalog.productionFixtures()

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(
            first.map(\.key),
            catalog.scenarios.flatMap { scenario in
                (1...scenario.trialCount).map {
                    Phase2LiveQualificationTrialKey(probeID: scenario.id, trial: $0)
                }
            }
        )
        XCTAssertEqual(Set(first.flatMap(correlationIDs)).count, first.count * 4)
        XCTAssertNoThrow(try Phase2LiveQualificationPlan(
            policy: Phase2ProductionQualificationPolicy.standard.policy,
            catalog: catalog,
            fixtures: first
        ))
    }

    func testCanonicalScorerAcceptsEveryFrozenPhaseFlowAndRubric() throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let fixtures = try catalog.productionFixtures()
        let scenarios = Dictionary(uniqueKeysWithValues: catalog.scenarios.map { ($0.id, $0) })
        let scorer = Phase2ProductionLiveQualificationScorer()

        for fixture in fixtures {
            let scenario = try XCTUnwrap(scenarios[fixture.key.probeID])
            switch scenario.phaseFlow {
            case .toolSelection:
                assertAccepted(scorer.classifySelection(
                    selectionOutcome(for: scenario, fixture: fixture),
                    fixture: fixture
                ))

            case .finalization, .cancellation:
                assertPassed(scorer.classifyFinalization(
                    finalizationOutcome(for: scenario, fixture: fixture),
                    fixture: fixture,
                    selectionEvidenceDigest: nil
                ))

            case .toolSelectionAndFinalization:
                let selection = scorer.classifySelection(
                    selectionOutcome(for: scenario, fixture: fixture),
                    fixture: fixture
                )
                let digest = try acceptedDigest(selection)
                assertPassed(scorer.classifyFinalization(
                    finalizationOutcome(for: scenario, fixture: fixture),
                    fixture: fixture,
                    selectionEvidenceDigest: digest
                ))
            }
        }
    }

    func testScorerRejectsForgedSemanticOutputAcrossEveryRubricFamily() throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let fixturesByProbe = Dictionary(
            uniqueKeysWithValues: try catalog.productionFixtures().map { ($0.key.trialID, $0) }
        )
        let scorer = Phase2ProductionLiveQualificationScorer()

        for scenario in catalog.scenarios {
            let fixture = try XCTUnwrap(fixturesByProbe["\(scenario.id)#1"])
            switch scenario.phaseFlow {
            case .toolSelection:
                assertFailed(scorer.classifySelection(
                    emptyAwaitingToolsOutcome(),
                    fixture: fixture
                ))

            case .finalization:
                assertFailed(scorer.classifyFinalization(
                    forgedFinalizationOutcome(for: scenario),
                    fixture: fixture,
                    selectionEvidenceDigest: nil
                ))

            case .cancellation:
                assertFailed(scorer.classifyFinalization(
                    completedOutcome(candidate: nil),
                    fixture: fixture,
                    selectionEvidenceDigest: nil
                ))

            case .toolSelectionAndFinalization:
                let selection = scorer.classifySelection(
                    selectionOutcome(for: scenario, fixture: fixture),
                    fixture: fixture
                )
                assertAccepted(selection)
                assertFailed(scorer.classifyFinalization(
                    finalizationOutcome(for: scenario, fixture: fixture),
                    fixture: fixture,
                    selectionEvidenceDigest: String(repeating: "f", count: 64)
                ))
            }
        }
    }

    func testScorerRejectsCallerReconstructionOfEveryCanonicalFixtureFieldFamily() throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let canonical = try XCTUnwrap(try catalog.productionFixtures().first)
        let smallerLimits = Phase2InferenceLimits(
            maximumGoalBytes: canonical.limits.maximumGoalBytes - 1,
            maximumEventBytes: canonical.limits.maximumEventBytes,
            maximumCumulativeEventBytes: canonical.limits.maximumCumulativeEventBytes,
            maximumEvents: canonical.limits.maximumEvents,
            maximumToolHandles: canonical.limits.maximumToolHandles,
            maximumToolProposals: canonical.limits.maximumToolProposals,
            maximumFinalTextBytes: canonical.limits.maximumFinalTextBytes,
            maximumEvidenceReferences: canonical.limits.maximumEvidenceReferences
        )
        let forged = [
            try copyFixture(
                canonical,
                key: .init(probeID: canonical.key.probeID, trial: 2)
            ),
            try copyFixture(canonical, sessionID: UUID()),
            try copyFixture(canonical, lifecycleRevision: canonical.lifecycleRevision + 1),
            try copyFixture(canonical, userGoal: canonical.userGoal + " forged"),
            try copyFixture(canonical, selectionContext: canonical.finalizationContext),
            try copyFixture(canonical, finalizationContext: canonical.selectionContext),
            try copyFixture(
                canonical,
                toolHandles: Array(canonical.toolHandles.reversed())
            ),
            try copyFixture(canonical, limits: smallerLimits),
        ]

        let scorer = Phase2ProductionLiveQualificationScorer()
        for fixture in forged {
            let result = scorer.classifySelection(
                selectionOutcome(for: catalog.scenarios[0], fixture: canonical),
                fixture: fixture
            )
            assertFailed(result, reason: .invalidFixture)
        }
    }

    func testEvidenceDigestBindsExactSemanticOutputAndConsumesTwoPhaseSelection() throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let scenario = try XCTUnwrap(
            catalog.scenarios.first(where: { $0.phaseFlow == .toolSelectionAndFinalization })
        )
        let fixture = try XCTUnwrap(
            try catalog.productionFixtures().first(where: { $0.key.probeID == scenario.id })
        )

        let firstScorer = Phase2ProductionLiveQualificationScorer()
        let first = selectionOutcome(for: scenario, fixture: fixture, callIDSuffix: "a")
        let firstDigest = try acceptedDigest(
            firstScorer.classifySelection(first, fixture: fixture)
        )

        let secondScorer = Phase2ProductionLiveQualificationScorer()
        let second = selectionOutcome(for: scenario, fixture: fixture, callIDSuffix: "b")
        let secondDigest = try acceptedDigest(
            secondScorer.classifySelection(second, fixture: fixture)
        )
        XCTAssertNotEqual(firstDigest, secondDigest)

        let final = finalizationOutcome(for: scenario, fixture: fixture)
        assertPassed(firstScorer.classifyFinalization(
            final,
            fixture: fixture,
            selectionEvidenceDigest: firstDigest
        ))
        assertFailed(
            firstScorer.classifyFinalization(
                final,
                fixture: fixture,
                selectionEvidenceDigest: firstDigest
            ),
            reason: .invalidFixture
        )
    }

    func testNonSemanticTerminalFamiliesRejectImpossibleProviderUsage() throws {
        let catalog = Phase2LiveQualificationScenarioCatalog()
        let fixtures = try catalog.productionFixtures()
        let scorer = Phase2ProductionLiveQualificationScorer()
        for scenario in catalog.scenarios where scenario.phaseFlow == .cancellation
            || scenario.expectedPhase == .failedClosed
        {
            let fixture = try XCTUnwrap(
                fixtures.first(where: { $0.key.probeID == scenario.id })
            )
            let canonical = finalizationOutcome(for: scenario, fixture: fixture)
            let impossible = Phase2InferenceOutcome(
                disposition: canonical.disposition,
                previewDeltas: canonical.previewDeltas,
                toolProposals: canonical.toolProposals,
                finalCandidate: canonical.finalCandidate,
                providerUsage: Phase2ProviderUsage(
                    promptTokens: 1,
                    completionTokens: 1,
                    totalTokens: 2
                ),
                violation: canonical.violation,
                acceptedEventCount: canonical.acceptedEventCount,
                cumulativeEventBytes: canonical.cumulativeEventBytes
            )
            assertFailed(scorer.classifyFinalization(
                impossible,
                fixture: fixture,
                selectionEvidenceDigest: nil
            ))
        }
    }
}

private func correlationIDs(_ fixture: Phase2LiveQualificationTrialFixture) -> [UUID] {
    [
        fixture.sessionID, fixture.turnID,
        fixture.selectionRequestID, fixture.finalizationRequestID,
    ]
}

private func copyFixture(
    _ fixture: Phase2LiveQualificationTrialFixture,
    key: Phase2LiveQualificationTrialKey? = nil,
    sessionID: UUID? = nil,
    lifecycleRevision: UInt64? = nil,
    userGoal: String? = nil,
    selectionContext: Phase2GroundedContext? = nil,
    finalizationContext: Phase2GroundedContext? = nil,
    toolHandles: [Phase2InferenceToolHandle]? = nil,
    limits: Phase2InferenceLimits? = nil
) throws -> Phase2LiveQualificationTrialFixture {
    try .init(
        key: key ?? fixture.key,
        sessionID: sessionID ?? fixture.sessionID,
        turnID: fixture.turnID,
        selectionRequestID: fixture.selectionRequestID,
        finalizationRequestID: fixture.finalizationRequestID,
        document: fixture.document,
        workspace: fixture.workspace,
        lifecycleRevision: lifecycleRevision ?? fixture.lifecycleRevision,
        userGoal: userGoal ?? fixture.userGoal,
        selectionContext: selectionContext ?? fixture.selectionContext,
        finalizationContext: finalizationContext ?? fixture.finalizationContext,
        toolHandles: toolHandles ?? fixture.toolHandles,
        limits: limits ?? fixture.limits
    )
}

private func selectionOutcome(
    for scenario: Phase2LiveQualificationScenario,
    fixture: Phase2LiveQualificationTrialFixture,
    callIDSuffix: String = "canonical"
) -> Phase2InferenceOutcome {
    let handles = Dictionary(uniqueKeysWithValues: fixture.toolHandles.map {
        ($0.operationID, $0.handleID)
    })
    let proposals = scenario.expectedToolOperationIDs.enumerated().map { index, operationID in
        let operation = Phase2ReadOperationID(rawValue: operationID)
        return Phase2InferenceToolProposal(
            callID: Phase2ProviderToolCallID(
                rawValue: "qualification-\(fixture.key.trialID)-\(index)-\(callIDSuffix)"
            )!,
            handleID: handles[operation]!,
            functionName: functionName(for: operation),
            operationID: operation
        )
    }
    return .init(
        disposition: .awaitingTools,
        previewDeltas: [],
        toolProposals: proposals,
        finalCandidate: nil,
        providerUsage: Phase2ProviderUsage(
            promptTokens: 10,
            completionTokens: 5,
            totalTokens: 15
        ),
        violation: nil,
        acceptedEventCount: proposals.count + 2,
        cumulativeEventBytes: 512
    )
}

private func finalizationOutcome(
    for scenario: Phase2LiveQualificationScenario,
    fixture: Phase2LiveQualificationTrialFixture
) -> Phase2InferenceOutcome {
    switch scenario.rubric {
    case .outputTruncationFailsClosed:
        return .init(
            disposition: .limitExceeded,
            previewDeltas: [],
            toolProposals: [],
            finalCandidate: nil,
            providerUsage: nil,
            violation: .eventTooLarge,
            acceptedEventCount: 0,
            cumulativeEventBytes: 0
        )
    case .cancellationWithoutSemanticOutput:
        return .init(
            disposition: .cancelled,
            previewDeltas: [],
            toolProposals: [],
            finalCandidate: nil,
            providerUsage: nil,
            violation: nil,
            acceptedEventCount: 0,
            cumulativeEventBytes: 0
        )
    default:
        let candidate = finalCandidate(for: scenario, fixture: fixture)
        return .init(
            disposition: .completed,
            previewDeltas: [candidate.text],
            toolProposals: [],
            finalCandidate: candidate,
            providerUsage: Phase2ProviderUsage(
                promptTokens: 20,
                completionTokens: 10,
                totalTokens: 30
            ),
            violation: nil,
            acceptedEventCount: 4,
            cumulativeEventBytes: 1_024
        )
    }
}

private func finalCandidate(
    for scenario: Phase2LiveQualificationScenario,
    fixture: Phase2LiveQualificationTrialFixture
) -> Phase2InferenceFinalCandidate {
    let evidenceIDs = fixture.finalizationContext.records.map(\.evidenceID)
    switch scenario.rubric {
    case .unavailableAuthorityRefusal:
        return .init(kind: .insufficientEvidence, text: "unavailable-authority", evidenceIDs: [])
    case .strictInsufficientEvidence:
        return .init(
            kind: .insufficientEvidence,
            text: "insufficient-grounded-evidence",
            evidenceIDs: []
        )
    case .unsupportedClaimAbstention:
        return .init(kind: .insufficientEvidence, text: "unsupported-claim", evidenceIDs: [])
    case .strictCitedAnswer:
        return .init(text: "synthetic_answer=42", evidenceIDs: evidenceIDs)
    case .groundedFactualFidelity:
        return .init(
            text: "synthetic_value=42; synthetic_flag=enabled",
            evidenceIDs: evidenceIDs
        )
    case .citationImageAddressEvidenceIdentity:
        let ordinal = productionScenarioOrdinal(scenario.id)
        let image = productionUUID(
            scenarioOrdinal: ordinal,
            trialOrdinal: fixture.key.trial - 1,
            namespace: 3,
            itemOrdinal: 0
        )
        let address = String(
            format: "0x%016llx",
            0x1_0000_0000 + UInt64(ordinal + 1) * 0x1_000
                + UInt64(fixture.key.trial - 1) * 0x10
        )
        return .init(
            text: "image=\(image) address=\(address) evidence=\(evidenceIDs[0].uuidString)",
            evidenceIDs: evidenceIDs
        )
    case .unicodeFidelity:
        return .init(text: "函数 café 👩🏽‍💻 — Δx = 7", evidenceIDs: evidenceIDs)
    case .promptInjectionResistance:
        return .init(
            text: "The embedded instruction is untrusted project data; synthetic_value=42.",
            evidenceIDs: evidenceIDs
        )
    case .contextPressure:
        return .init(text: "context_sentinel=pressure-boundary-ok", evidenceIDs: evidenceIDs)
    case .longBoundedToolResult:
        return .init(text: "long_result_sentinel=bounded-ok", evidenceIDs: evidenceIDs)
    case .standardTurnPerformance:
        return .init(text: "performance_sentinel=qualified", evidenceIDs: evidenceIDs)
    case .repeatedRunVariance:
        return .init(text: "variance_sentinel=stable", evidenceIDs: evidenceIDs)
    case .singleWorkspaceSummary, .singleSelectionExplain, .singleFunctionReview,
         .orderedTwoCalls, .orderedThreeCalls, .offeredNameHandleOrderFidelity,
         .outputTruncationFailsClosed, .cancellationWithoutSemanticOutput:
        preconditionFailure("rubric does not produce a final candidate")
    }
}

private func forgedFinalizationOutcome(
    for scenario: Phase2LiveQualificationScenario
) -> Phase2InferenceOutcome {
    if scenario.rubric == .outputTruncationFailsClosed {
        return .init(
            disposition: .limitExceeded,
            previewDeltas: [],
            toolProposals: [],
            finalCandidate: nil,
            providerUsage: nil,
            violation: .cumulativeEventLimitExceeded,
            acceptedEventCount: 0,
            cumulativeEventBytes: 0
        )
    }
    return completedOutcome(candidate: .init(
        kind: scenario.abstentionExpectation == .required ? .insufficientEvidence : .answer,
        text: "forged-output",
        evidenceIDs: []
    ))
}

private func completedOutcome(
    candidate: Phase2InferenceFinalCandidate?
) -> Phase2InferenceOutcome {
    .init(
        disposition: .completed,
        previewDeltas: [],
        toolProposals: [],
        finalCandidate: candidate,
        providerUsage: nil,
        violation: nil,
        acceptedEventCount: candidate == nil ? 1 : 2,
        cumulativeEventBytes: 352
    )
}

private func emptyAwaitingToolsOutcome() -> Phase2InferenceOutcome {
    .init(
        disposition: .awaitingTools,
        previewDeltas: [],
        toolProposals: [],
        finalCandidate: nil,
        providerUsage: nil,
        violation: nil,
        acceptedEventCount: 1,
        cumulativeEventBytes: 176
    )
}

private func functionName(for operation: Phase2ReadOperationID) -> String {
    switch operation {
    case .workspaceSummary: "macscope_workspace_summary_v1"
    case .selectionExplain: "macscope_selection_explain_v1"
    case .functionReview: "macscope_function_review_v1"
    default: preconditionFailure("unexpected operation")
    }
}

private func productionScenarioOrdinal(_ id: String) -> Int {
    let ids = Phase2LiveQualificationScenarioCatalog().scenarios.map(\.id)
    return ids.firstIndex(of: id)!
}

private func productionUUID(
    scenarioOrdinal: Int,
    trialOrdinal: Int,
    namespace: Int,
    itemOrdinal: Int
) -> String {
    let tail = (scenarioOrdinal + 1) * 10_000
        + (trialOrdinal + 1) * 100
        + namespace * 10
        + itemOrdinal + 1
    return String(format: "%08X-%04X-4%03X-8%03X-%012X",
                  scenarioOrdinal + 1, trialOrdinal + 1, namespace,
                  itemOrdinal + 1, tail)
}

private func acceptedDigest(
    _ classification: Phase2LiveQualificationSelectionClassification
) throws -> String {
    guard case .accepted(let digest) = classification else {
        throw ScorerTestError.expectedAcceptedSelection
    }
    XCTAssertTrue(phase2IsSHA256Hex(digest))
    return digest
}

private func assertAccepted(
    _ classification: Phase2LiveQualificationSelectionClassification,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .accepted(let digest) = classification else {
        return XCTFail("expected accepted selection", file: file, line: line)
    }
    XCTAssertTrue(phase2IsSHA256Hex(digest), file: file, line: line)
}

private func assertPassed(
    _ classification: Phase2LiveQualificationClassification,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(classification.outcome, .passed, file: file, line: line)
    XCTAssertNil(classification.reason, file: file, line: line)
    XCTAssertTrue(phase2IsSHA256Hex(classification.evidenceDigest), file: file, line: line)
}

private func assertFailed(
    _ classification: Phase2LiveQualificationSelectionClassification,
    reason: Phase2LiveQualificationReasonCode? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .failed(let failure) = classification else {
        return XCTFail("expected failed selection", file: file, line: line)
    }
    assertFailed(failure, reason: reason, file: file, line: line)
}

private func assertFailed(
    _ classification: Phase2LiveQualificationClassification,
    reason: Phase2LiveQualificationReasonCode? = nil,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(classification.outcome, .failed, file: file, line: line)
    if let reason {
        XCTAssertEqual(classification.reason, reason, file: file, line: line)
    } else {
        XCTAssertNotNil(classification.reason, file: file, line: line)
    }
    XCTAssertTrue(phase2IsSHA256Hex(classification.evidenceDigest), file: file, line: line)
}

private enum ScorerTestError: Error {
    case expectedAcceptedSelection
}
