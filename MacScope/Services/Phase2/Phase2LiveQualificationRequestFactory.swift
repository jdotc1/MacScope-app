import Foundation

struct Phase2LiveQualificationRequestFactory: Sendable {
    func selectionRequest(
        for fixture: Phase2LiveQualificationTrialFixture
    ) throws -> Phase2InferenceRequest {
        let request = Phase2InferenceRequest(
            protocolVersion: .init(
                rawValue: Phase2AIWorkerProductionProtocol.inferenceVersion
            ),
            phase: .toolSelection,
            sessionID: fixture.sessionID,
            turnID: fixture.turnID,
            requestID: fixture.selectionRequestID,
            document: fixture.document,
            workspace: fixture.workspace,
            lifecycleRevision: fixture.lifecycleRevision,
            userGoal: fixture.userGoal,
            groundedContext: fixture.selectionContext,
            toolHandles: fixture.toolHandles,
            limits: fixture.limits
        )
        guard request.phase == .toolSelection, !request.toolHandles.isEmpty else {
            throw Phase2LiveQualificationTrialFixture.ValidationError.invalidToolHandles
        }
        return request
    }

    func finalizationRequest(
        for fixture: Phase2LiveQualificationTrialFixture
    ) throws -> Phase2InferenceRequest {
        Phase2InferenceRequest(
            protocolVersion: .init(
                rawValue: Phase2AIWorkerProductionProtocol.inferenceVersion
            ),
            phase: .finalization,
            sessionID: fixture.sessionID,
            turnID: fixture.turnID,
            requestID: fixture.finalizationRequestID,
            document: fixture.document,
            workspace: fixture.workspace,
            lifecycleRevision: fixture.lifecycleRevision,
            userGoal: fixture.userGoal,
            groundedContext: fixture.finalizationContext,
            toolHandles: [],
            limits: fixture.limits
        )
    }
}
