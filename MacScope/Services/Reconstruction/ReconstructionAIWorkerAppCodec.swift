import Foundation

struct ReconstructionAIWorkerAppCodec: Sendable {
    private let wire = Phase2ReconstructionAIWorkerWireCodec()

    func encode(
        _ request: ReconstructionAIWorkerRequest,
        requestID: UUID
    ) throws -> Data {
        switch request {
        case .sourceRevision(let value): return try wire.encodeSourceRequest(value, requestID: requestID)
        case .roundR2(let value): return try wire.encodeRoundRequestR2(value, requestID: requestID)
        case .finalSynthesisR2(let value): return try wire.encodeFinalRequestR2(value, requestID: requestID)
        case .round(let value): return try wire.encodeRoundRequest(value, requestID: requestID)
        case .finalSynthesis(let value):
            return try wire.encodeFinalRequest(value, requestID: requestID)
        }
    }

    func decodeEvent(
        _ data: Data,
        authority: ReconstructionAIWorkerAuthority
    ) throws -> ReconstructionAIWorkerEvent {
        try wire.decodeEvent(data, authority: authority)
    }
}
