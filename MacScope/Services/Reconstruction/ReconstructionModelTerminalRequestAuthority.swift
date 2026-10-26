import Foundation

enum ReconstructionModelTerminalRequestAuthorityError: Error, Equatable, Sendable {
    case terminalRequestMismatch
}

/// Runner-sealed request authority retained across the ready-provider boundary.
///
/// Pre-admission failures intentionally never construct this value. Receipt authoring receives the
/// exact request bytes' semantic value and revalidates the terminal identity rather than trusting a
/// freely supplied terminal receipt ID.
struct ReconstructionModelTerminalRequestAuthority: Hashable, Sendable {
    let expectedRequestID: UUID
    let request: ReconstructionAIWorkerRequest
    let requestIdentitySHA256: String
    let terminalReceipt: ReconstructionTerminalReceipt
    let replayReceipt: ReconstructionModelReplayReceipt?

    static func make(
        expectedRequestID: UUID,
        request: ReconstructionAIWorkerRequest,
        terminalReceipt: ReconstructionTerminalReceipt,
        replayReceipt: ReconstructionModelReplayReceipt? = nil
    ) throws -> Self {
        let requestIdentitySHA256: String
        let jobID: UUID
        let checkpointRevision: UInt64
        let roundID: UUID?
        switch request {
        case .sourceRevision(let value):
            _ = try Phase2ReconstructionAIWorkerWireCodec().encodeSourceRequest(value, requestID: expectedRequestID)
            requestIdentitySHA256 = try ReconstructionCanonicalJSON.sha256(of: value)
            jobID = value.jobID
            checkpointRevision = value.checkpointRevision
            roundID = value.roundID
        case .round(let value):
            requestIdentitySHA256 = try ReconstructionCanonicalJSON.sha256(of: value)
            jobID = value.jobID
            checkpointRevision = value.checkpointRevision
            roundID = value.roundID
        case .finalSynthesis(let value):
            requestIdentitySHA256 = try ReconstructionCanonicalJSON.sha256(of: value)
            jobID = value.jobID
            checkpointRevision = value.checkpointRevision
            roundID = nil
        case .roundR2(let value):
            _ = try Phase2ReconstructionAIWorkerWireCodec().encodeRoundRequestR2(value, requestID: expectedRequestID)
            requestIdentitySHA256 = try ReconstructionCanonicalJSON.sha256(of: value)
            jobID = value.request.jobID
            checkpointRevision = value.request.checkpointRevision
            roundID = value.request.roundID
        case .finalSynthesisR2(let value):
            _ = try Phase2ReconstructionAIWorkerWireCodec().encodeFinalRequestR2(value, requestID: expectedRequestID)
            requestIdentitySHA256 = try ReconstructionCanonicalJSON.sha256(of: value)
            jobID = value.request.jobID
            checkpointRevision = value.request.checkpointRevision
            roundID = nil
        }
        guard terminalReceipt.requestID == expectedRequestID,
              terminalReceipt.jobID == jobID,
              terminalReceipt.checkpointRevision == checkpointRevision,
              terminalReceipt.roundID == roundID else {
            throw ReconstructionModelTerminalRequestAuthorityError.terminalRequestMismatch
        }
        return Self(
            expectedRequestID: expectedRequestID,
            request: request,
            requestIdentitySHA256: requestIdentitySHA256,
            terminalReceipt: terminalReceipt,
            replayReceipt: replayReceipt
        )
    }

    private init(
        expectedRequestID: UUID,
        request: ReconstructionAIWorkerRequest,
        requestIdentitySHA256: String,
        terminalReceipt: ReconstructionTerminalReceipt,
        replayReceipt: ReconstructionModelReplayReceipt?
    ) {
        self.expectedRequestID = expectedRequestID
        self.request = request
        self.requestIdentitySHA256 = requestIdentitySHA256
        self.terminalReceipt = terminalReceipt
        self.replayReceipt = replayReceipt
    }
}
