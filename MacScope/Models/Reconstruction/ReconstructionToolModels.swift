import Foundation

struct ReconstructionToolHandle: Hashable, Codable, Sendable {
    let handleID: UUID
    let operationID: ReconstructionOperationID
    let canonicalRequest: Data
    let requestSHA256: String
    let jobID: UUID
    let checkpointRevision: UInt64
    let roundID: UUID
}

struct ReconstructionOfferedToolHandle: Hashable, Codable, Sendable {
    let handleID: UUID
    let operationID: ReconstructionOperationID
}
