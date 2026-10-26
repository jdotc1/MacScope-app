import Foundation

/// Frozen worker-safe vocabulary shared by inference wire DTOs and durable final-result records.
enum ReconstructionFinalSynthesisKind: String, Codable, Sendable {
    case synthesis
    case insufficientEvidence
}
