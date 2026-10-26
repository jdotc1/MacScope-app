import Foundation

enum ReconstructionAIWorkerPhase: String, Codable, Sendable {
    case sourceRevision
    case round
    case finalSynthesis
}

enum ReconstructionAIWorkerDecodedRequest: Hashable, Sendable {
    case sourceRevision(requestID: UUID, request: ReconstructionSourceRevisionRequest)
    case round(requestID: UUID, request: ReconstructionInferenceRoundRequest)
    case finalSynthesis(requestID: UUID, request: ReconstructionFinalSynthesisRequest)
    case roundR2(requestID: UUID, request: ReconstructionInferenceRoundRequestR2)
    case finalSynthesisR2(requestID: UUID, request: ReconstructionFinalSynthesisRequestR2)
}

enum ReconstructionAIWorkerEventBody: Equatable, Sendable {
    case sourceCandidate(ReconstructionSourceRevisionCandidate)
    case roundCandidate(ReconstructionInferenceRoundCandidate)
    case finalCandidate(ReconstructionFinalSynthesisCandidate)
    case usage(Phase2AIWorkerWireUsage)
    case completed
}

struct ReconstructionAIWorkerEvent: Equatable, Sendable {
    let requestID: UUID
    let sequence: UInt64
    let body: ReconstructionAIWorkerEventBody
}

enum ReconstructionAIWorkerAuthority: Hashable, Sendable {
    case sourceRevision(ReconstructionSourceRevisionRequest)
    case round(ReconstructionInferenceRoundRequest)
    case finalSynthesis(ReconstructionFinalSynthesisRequest)
    case roundR2(ReconstructionInferenceRoundRequestR2)
    case finalSynthesisR2(ReconstructionFinalSynthesisRequestR2)
}

enum ReconstructionAIWorkerWireError: Error, Equatable, Sendable {
    case invalidEnvelope
    case unsupportedProtocol
    case invalidAuthority
    case boundsExceeded
}
