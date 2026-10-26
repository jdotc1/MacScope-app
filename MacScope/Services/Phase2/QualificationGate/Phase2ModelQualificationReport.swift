import Foundation
@testable import MacScope


struct Phase2ModelQualificationReportID: Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) throws {
        guard rawValue.hasPrefix("sha256:"),
              phase2IsSHA256Hex(String(rawValue.dropFirst("sha256:".count)))
        else { throw Phase2ModelProfileValidationError.invalidSHA256Digest }
        self.rawValue = rawValue
    }
}

/// CoreTests-only, immutable, bounded qualification artifact. Keeping this type beside the closed
/// Gate composer lets the signed app expose evidence without gaining report/certification authority.
struct Phase2ModelQualificationReport: Hashable, Sendable {
    let version: Int
    let reportID: Phase2ModelQualificationReportID
    let expectedProfileID: Phase2ModelProfileID
    let claimedProfileID: Phase2ModelProfileID
    let expectedPolicyIdentity: Phase2ProtocolComponentIdentity
    let claimedPolicyIdentity: Phase2ProtocolComponentIdentity
    let evaluationContext: Phase2ModelQualificationEvaluationContext
    let protocolManifestDigest: String
    let corpusDigest: String
    let protocolProbeCatalogIdentity: Phase2ProtocolComponentIdentity?
    let liveQualificationCorpusIdentity: Phase2ProtocolComponentIdentity?
    let metricSemanticsIdentity: Phase2ProtocolComponentIdentity?
    let modelSource: String?
    let modelRevisionIdentity: Phase2ProtocolComponentIdentity?
    let productionDefinitionIdentity: Phase2ProtocolComponentIdentity?
    let environmentIdentity: Phase2ProtocolComponentIdentity?
    let runtimeProvenanceIdentity: Phase2ProtocolComponentIdentity?
    let measurementEvidenceIdentity: Phase2ProtocolComponentIdentity?
    let workflow: Phase2QualificationWorkflow
    let authorityCeiling: Phase2QualificationAuthorityCeiling
    let hardwareTier: Phase2HardwareTier
    let macScopeBuild: String
    let toolchainBuild: String
    let operatingSystemBuild: String
    let architecture: String
    let startedAtEpochMilliseconds: Int64
    let endedAtEpochMilliseconds: Int64
    let terminationStatus: Phase2QualificationRunTerminationStatus
    let measurements: Phase2QualificationMeasurements
    let attemptMeasurements: [Phase2QualificationAttemptMeasurements]
    let retryAttemptCount: Int
    let verdict: Phase2ModelQualificationVerdict
    let declaredTrialCount: Int
    let observedTrialCount: Int
    let observedAttemptCount: Int
    let passedTrialCount: Int
    let failedTrialCount: Int
    let passedAttemptCount: Int
    let failedAttemptCount: Int
    let failedProbeIDs: [String]
    let missingTrialIDs: [String]
    let inconclusiveReasonCodes: [String]
    let observations: [Phase2QualificationProbeObservation]

    var supportStatus: Phase2ModelQualificationStatus? { verdict.supportStatus }
}
