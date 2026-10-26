import Foundation
import XCTest
@testable import MacScope

@MainActor
final class Phase2AssistantRequestRejectionTests: XCTestCase {
    func testRunnerAndMapperPreserveRejectionStageWithoutDispatchOrPayloadClaims() async throws {
        for selection in [true, false] {
            let store = WorkspaceStore(workspaceName: "Admission stage",
                snapshot: .init(binaries: [], analysisBySlot: [:]), engine: AnalysisEngine(), autosaveScheduler: nil)
            let coordinator = DecliningCoordinator()
            let result = await Phase2AssistantSessionRunner().run(intent: .askMacScope,
                userGoal: "Summarize native workspace evidence.", store: store, coordinator: coordinator,
                contextOptions: .init(includeApplicationGraphContext: false, useProviderVisibleToolSelection: selection))
            let expected: Phase2AssistantRequestRejection.Stage = selection ? .toolSelectionAdmission : .finalizationAdmission
            XCTAssertEqual(result.failure, .inferenceInvalidRequest)
            XCTAssertEqual(result.requestRejection?.stage, expected)
            XCTAssertEqual(coordinator.phases, [selection ? .toolSelection : .finalization])
            guard case .failed(_, let detail) = Phase2AssistantDisplayMapper.state(for: result) else {
                return XCTFail("Rejection must remain a failed Assistant result")
            }
            XCTAssertTrue(detail.contains(expected.rawValue))
            XCTAssertFalse(detail.contains("before provider dispatch"))
        }

        let privateID = UUID()
        let outcome = Phase2InferenceOutcome(disposition: .protocolViolation, previewDeltas: [], toolProposals: [],
            finalCandidate: nil, providerUsage: nil, violation: .unknownToolHandle(privateID),
            acceptedEventCount: 0, cumulativeEventBytes: 0)
        let rejection = Phase2AssistantRequestRejection.outcome(stage: .toolSelectionOutcome, outcome)
        XCTAssertTrue(rejection.reasonCode.contains("unknownToolHandle"))
        XCTAssertFalse(rejection.reasonCode.contains(privateID.uuidString))
        let privateFunction = "private-function-(do-not-copy)"
        let functionMismatch = Phase2InferenceOutcome(disposition: .protocolViolation,
            previewDeltas: [], toolProposals: [], finalCandidate: nil, providerUsage: nil,
            violation: .toolFunctionMismatch(privateFunction, .workspaceSummary),
            acceptedEventCount: 0, cumulativeEventBytes: 0)
        let functionTag = Phase2AssistantRequestRejection.outcome(stage: .toolSelectionOutcome, functionMismatch)
        XCTAssertTrue(functionTag.reasonCode.contains("toolFunctionMismatch"))
        XCTAssertFalse(functionTag.reasonCode.contains(privateFunction))
        XCTAssertFalse(functionTag.reasonCode.contains("workspace.summary"))
        XCTAssertFalse(Phase2AssistantRequestRejection.toolPlan(
            Phase2AssistantToolSelectionPlanError.invalidHandle(privateID)).reasonCode.contains(privateID.uuidString))
        let result = Phase2AssistantSessionResult(intent: .askMacScope, request: nil, groundedContext: nil,
            readExecution: nil, readExecutions: [], inferenceOutcome: nil,
            failure: .inferenceInvalidRequest, requestRejection: rejection)
        guard case .failed(_, let detail) = Phase2AssistantDisplayMapper.state(for: result) else {
            return XCTFail("Selection outcome rejection must remain visible")
        }
        XCTAssertTrue(detail.contains("tool-selection outcome"))
        XCTAssertFalse(detail.contains("before provider dispatch"))
        XCTAssertFalse(detail.contains(privateID.uuidString))
        let legacy = Phase2AssistantSessionResult(intent: .askMacScope, request: nil, groundedContext: nil,
            readExecution: nil, readExecutions: [], inferenceOutcome: nil, failure: .inferenceInvalidRequest)
        guard case .failed(_, let fallback) = Phase2AssistantDisplayMapper.state(for: legacy) else {
            return XCTFail("Legacy rejection must retain its failure classification")
        }
        XCTAssertTrue(fallback.contains("stage was not retained"))
        XCTAssertFalse(fallback.contains("before provider dispatch"))
    }

    private final class DecliningCoordinator: Phase2AssistantInferenceCoordinating {
        var phases: [Phase2InferencePhase] = []
        func run(request: Phase2InferenceRequest) async -> Phase2ReadyInferenceExecutionResult {
            phases.append(request.phase)
            return .invalidRequest
        }
    }
}
