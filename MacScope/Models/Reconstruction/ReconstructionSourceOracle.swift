import Foundation

/// Immutable app-owned observation of the original program, never a model-authored formula.
struct ReconstructionSourceOracle: Codable, Hashable, Sendable {
    static let version = 1
    static let profileID = ReconstructionSourceProfile.scalarU32V1.rawValue
    static let maximumPayloadBytes = 65_536

    struct Execution: Codable, Hashable, Sendable {
        let originalImageSHA256: String
        let originalExecutableSHA256: String
        /// Optional qualification provenance; original source need not exist in a user workspace.
        let originalSourceSHA256: String?
        let harnessSHA256: String
        let compilerSHA256: String
        let sdkIdentitySHA256: String
        let compileProfileSHA256: String
        let compileArgumentsSHA256: String
        let executionArgumentsSHA256: String
        let producerSHA256: String
        let standardOutput: Data
        let sessionID: UUID
        let requestID: UUID
        let processIdentifier: Int32
        let sampledProcessIDs: [Int32]
        let exitCode: Int32
        let observedProcessAbsent: Bool
    }

    let version: Int
    let profileID: String
    let projectID: UUID
    let jobID: UUID
    let function: ReconstructionFunctionCoordinate
    let inputs: [UInt32]
    let outputs: [UInt32]
    let execution: Execution
    let evidenceIDs: [UUID]
    let suiteSHA256: String
}

/// Captured by the app owner from original execution and committed state, never decoded from a
/// source revision or model response. Equality to this cut is required even after payload rehashing.
struct ReconstructionSourceOracleAuthority: Sendable {
    let projectID: UUID
    let jobID: UUID
    let function: ReconstructionFunctionCoordinate
    let execution: ReconstructionSourceOracle.Execution
    let evidenceIDs: [UUID]
    let profileID: String

    init(projectID: UUID, jobID: UUID, function: ReconstructionFunctionCoordinate,
         execution: ReconstructionSourceOracle.Execution, evidenceIDs: [UUID],
         profileID: String = ReconstructionSourceProfile.scalarU32V1.rawValue) {
        self.projectID = projectID; self.jobID = jobID; self.function = function
        self.execution = execution; self.evidenceIDs = evidenceIDs; self.profileID = profileID
    }
}
