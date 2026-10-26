import Foundation
import CryptoKit

enum ReconstructionRequestObjectiveError: Error, Equatable {
    case invalidObjective
}

struct ReconstructionRequestObjective: Hashable, Codable, Sendable {
    let jobID: UUID
    let text: String
    let sha256: String
    let sourceProfileID: String?
    static let fixedSourceProfileID = ReconstructionSourceProfile.scalarU32V1.rawValue

    init(jobID: UUID, text: String, sha256: String, sourceProfileID: String? = nil) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 4_096,
              !text.unicodeScalars.contains(where: { $0.value == 0 }),
              sha256 == SHA256.hash(data: Data(text.utf8)).map({ String(format: "%02x", $0) }).joined()
        else { throw ReconstructionRequestObjectiveError.invalidObjective }
        guard sourceProfileID == nil || ReconstructionSourceProfile.admits(sourceProfileID) else {
            throw ReconstructionRequestObjectiveError.invalidObjective
        }
        self.sourceProfileID = sourceProfileID
        self.jobID = jobID
        self.text = text
        self.sha256 = sha256
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(jobID: values.decode(UUID.self, forKey: .jobID),
                      text: values.decode(String.self, forKey: .text),
                      sha256: values.decode(String.self, forKey: .sha256),
                      sourceProfileID: values.decodeIfPresent(String.self, forKey: .sourceProfileID))
    }
}

struct ReconstructionInferenceRoundRequestR2: Hashable, Codable, Sendable {
    let protocolVersion: Int
    let objective: ReconstructionRequestObjective
    let request: ReconstructionInferenceRoundRequest
}

struct ReconstructionFinalSynthesisRequestR2: Hashable, Codable, Sendable {
    let protocolVersion: Int
    let objective: ReconstructionRequestObjective
    let request: ReconstructionFinalSynthesisRequest
}

struct ReconstructionRetrievedContext: Hashable, Codable, Sendable {
    let canonicalBytes: Data
    let canonicalSHA256: String
    let evidenceIDs: [UUID]
    let allowedGapSubjects: [String]
    let allowedGapCategories: [String]
    let allowedGapIDs: [UUID]

    init(
        canonicalBytes: Data,
        canonicalSHA256: String,
        evidenceIDs: [UUID],
        allowedGapSubjects: [String] = [],
        allowedGapCategories: [String] = [],
        allowedGapIDs: [UUID] = []
    ) {
        self.canonicalBytes = canonicalBytes
        self.canonicalSHA256 = canonicalSHA256
        self.evidenceIDs = evidenceIDs
        self.allowedGapSubjects = allowedGapSubjects
        self.allowedGapCategories = allowedGapCategories
        self.allowedGapIDs = allowedGapIDs
    }
}

struct ReconstructionEvidenceGapDeclaration: Hashable, Codable, Sendable {
    let subject: String
    let category: String
    let reason: String
}

/// An explicit model claim that one selected tool execution resolved one durable gap.
///
/// The claim carries IDs only. Receipt authoring independently proves the selected execution
/// produced exactly one accepted-current record with the gap's exact subject and operation.
struct ReconstructionEvidenceGapResolutionClaim: Hashable, Codable, Sendable {
    let gapID: UUID
    let handleID: UUID
    let evidenceID: UUID
}

enum ReconstructionInferenceDisposition: String, Codable, Sendable {
    case `continue`
    case sufficientEvidence
    case blocked
}

struct ReconstructionInferenceRoundRequest: Hashable, Codable, Sendable {
    let protocolVersion: Int
    let jobID: UUID
    let checkpointRevision: UInt64
    let roundID: UUID
    let corpusManifestSHA256: String
    let evidenceFrontierSHA256: String
    let registryManifestSHA256: String
    let context: ReconstructionRetrievedContext
    let handles: [ReconstructionOfferedToolHandle]
    /// Bounded, nonpersisted native semantics projected at this request's authority cut. It is
    /// R2-only, omitted from the encoding when nil (R1 bytes stay identical), and is never
    /// evidence: its fact IDs are disjoint from `context.evidenceIDs` and cannot be cited.
    let transientAnalysis: ReconstructionTransientAnalysis?

    init(
        protocolVersion: Int,
        jobID: UUID,
        checkpointRevision: UInt64,
        roundID: UUID,
        corpusManifestSHA256: String,
        evidenceFrontierSHA256: String,
        registryManifestSHA256: String,
        context: ReconstructionRetrievedContext,
        handles: [ReconstructionOfferedToolHandle],
        transientAnalysis: ReconstructionTransientAnalysis? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.jobID = jobID
        self.checkpointRevision = checkpointRevision
        self.roundID = roundID
        self.corpusManifestSHA256 = corpusManifestSHA256
        self.evidenceFrontierSHA256 = evidenceFrontierSHA256
        self.registryManifestSHA256 = registryManifestSHA256
        self.context = context
        self.handles = handles
        self.transientAnalysis = transientAnalysis
    }
}

enum ReconstructionTransientAnalysisError: Error, Equatable, Sendable {
    case invalidTransientAnalysis
}

/// Why an admitted native publication was not presented at the current authority cut.
enum ReconstructionTransientNativeOmissionReason: String, Hashable, Codable, Sendable,
    CaseIterable
{
    /// The fact was valid but the bounded transient byte budget was exhausted.
    case budget
    /// Changed bytes, an uncommitted/abandoned task, a newer publication, or a moved cut.
    case stale
    /// The native result names a different image (including a sibling at the same VA).
    case mismatchedImage
    /// A committed native task exists but no admitted publication is available now.
    case unavailable
}

struct ReconstructionTransientNativeOmission: Hashable, Codable, Sendable {
    let subjectSHA256: String
    let publicationGeneration: UInt64?
    let reason: ReconstructionTransientNativeOmissionReason
}

/// One bounded native fact. `factID` is a transient presentation handle, never an evidence ID.
struct ReconstructionTransientNativeFact: Hashable, Codable, Sendable {
    static let maximumPseudocodeUTF8Bytes = 16_384
    static let maximumNameUTF8Bytes = 256
    static let maximumListedNames = 32

    let factID: UUID
    let subject: ReconstructionFunctionCoordinate
    let sourceTaskID: UUID
    let providerIdentitySHA256: String
    let nativeRequestID: UUID
    let nativeRequestSHA256: String
    let analysisInputFingerprintSHA256: String
    let nativeImageID: String
    let nativeImageUUID: UUID
    let publicationGeneration: UInt64
    let functionName: String
    let pseudocodeLanguage: String?
    let pseudocode: String?
    let pseudocodeWasTruncated: Bool
    let callTargets: [String]
    let variableNames: [String]
    let blockCount: Int
    let callCount: Int
    let variableCount: Int
    let warningCodes: [String]
}

/// Transient native/comparison projection bound to one exact authority cut.
struct ReconstructionTransientAnalysis: Hashable, Codable, Sendable {
    static let schemaVersion = 1
    static let domain = "reconstruction.transient-native.v1"
    static let maximumFacts = 8
    static let maximumOmissions = 64
    static let maximumBudgetBytes = 32_768

    let schemaVersion: Int
    let domain: String
    let jobID: UUID
    let checkpointRevision: UInt64
    let corpusManifestSHA256: String
    let evidenceFrontierSHA256: String
    let budgetBytes: Int
    let usedBytes: Int
    let facts: [ReconstructionTransientNativeFact]
    let omissions: [ReconstructionTransientNativeOmission]

    /// Structural admission shared by the app and the worker wire codec.
    func validate(for request: ReconstructionInferenceRoundRequest) throws {
        func digest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
        }
        func bounded(_ value: String, _ maximum: Int) -> Bool {
            value.utf8.count <= maximum && !value.unicodeScalars.contains { $0.value == 0 }
        }
        let factIDs = Set(facts.map(\.factID))
        guard schemaVersion == Self.schemaVersion, domain == Self.domain,
              jobID == request.jobID, checkpointRevision == request.checkpointRevision,
              corpusManifestSHA256 == request.corpusManifestSHA256,
              evidenceFrontierSHA256 == request.evidenceFrontierSHA256,
              (0...Self.maximumBudgetBytes).contains(budgetBytes),
              (0...budgetBytes).contains(usedBytes),
              facts.count <= Self.maximumFacts, omissions.count <= Self.maximumOmissions,
              !(facts.isEmpty && omissions.isEmpty),
              factIDs.count == facts.count,
              factIDs.isDisjoint(with: request.context.evidenceIDs),
              omissions.allSatisfy({ digest($0.subjectSHA256) }) else {
            throw ReconstructionTransientAnalysisError.invalidTransientAnalysis
        }
        for fact in facts {
            guard digest(fact.providerIdentitySHA256), digest(fact.nativeRequestSHA256),
                  digest(fact.analysisInputFingerprintSHA256),
                  fact.analysisInputFingerprintSHA256 == fact.subject.analysisFingerprintSHA256,
                  fact.publicationGeneration > 0,
                  bounded(fact.functionName, ReconstructionTransientNativeFact.maximumNameUTF8Bytes),
                  bounded(fact.nativeImageID, ReconstructionTransientNativeFact.maximumNameUTF8Bytes),
                  bounded(fact.pseudocodeLanguage ?? "", 64),
                  bounded(fact.pseudocode ?? "",
                          ReconstructionTransientNativeFact.maximumPseudocodeUTF8Bytes),
                  fact.callTargets.count <= ReconstructionTransientNativeFact.maximumListedNames,
                  fact.variableNames.count <= ReconstructionTransientNativeFact.maximumListedNames,
                  fact.warningCodes.count <= ReconstructionTransientNativeFact.maximumListedNames,
                  (fact.callTargets + fact.variableNames + fact.warningCodes).allSatisfy({
                      bounded($0, ReconstructionTransientNativeFact.maximumNameUTF8Bytes)
                  }),
                  fact.blockCount >= 0, fact.callCount >= 0, fact.variableCount >= 0 else {
                throw ReconstructionTransientAnalysisError.invalidTransientAnalysis
            }
        }
    }
}

struct ReconstructionInferenceRoundCandidate: Hashable, Codable, Sendable {
    let jobID: UUID
    let checkpointRevision: UInt64
    let roundID: UUID
    let selectedHandleIDs: [UUID]
    let disposition: ReconstructionInferenceDisposition
    let unresolvedGaps: [ReconstructionEvidenceGapDeclaration]
    let resolvedGaps: [ReconstructionEvidenceGapResolutionClaim]

    init(
        jobID: UUID,
        checkpointRevision: UInt64,
        roundID: UUID,
        selectedHandleIDs: [UUID],
        disposition: ReconstructionInferenceDisposition,
        unresolvedGaps: [ReconstructionEvidenceGapDeclaration],
        resolvedGaps: [ReconstructionEvidenceGapResolutionClaim] = []
    ) {
        self.jobID = jobID
        self.checkpointRevision = checkpointRevision
        self.roundID = roundID
        self.selectedHandleIDs = selectedHandleIDs
        self.disposition = disposition
        self.unresolvedGaps = unresolvedGaps
        self.resolvedGaps = resolvedGaps.sorted {
            if $0.gapID != $1.gapID {
                return $0.gapID.uuidString.lowercased() < $1.gapID.uuidString.lowercased()
            }
            if $0.handleID != $1.handleID {
                return $0.handleID.uuidString.lowercased() < $1.handleID.uuidString.lowercased()
            }
            return $0.evidenceID.uuidString.lowercased()
                < $1.evidenceID.uuidString.lowercased()
        }
    }
}

struct ReconstructionFinalSynthesisRequest: Hashable, Codable, Sendable {
    let jobID: UUID
    let checkpointRevision: UInt64
    let corpusManifestSHA256: String
    let evidenceFrontierSHA256: String
    let acceptedEvidenceIDs: [UUID]
    let context: ReconstructionRetrievedContext
}

struct ReconstructionFinalSynthesisCandidate: Hashable, Codable, Sendable {
    let kind: ReconstructionFinalSynthesisKind
    let text: String
    let evidenceIDs: [UUID]
}

enum ReconstructionAIWorkerRequest: Hashable, Sendable {
    case sourceRevision(ReconstructionSourceRevisionRequest)
    case round(ReconstructionInferenceRoundRequest)
    case finalSynthesis(ReconstructionFinalSynthesisRequest)
    case roundR2(ReconstructionInferenceRoundRequestR2)
    case finalSynthesisR2(ReconstructionFinalSynthesisRequestR2)

    var semanticRequest: Self {
        switch self {
        case .round, .finalSynthesis, .sourceRevision: self
        case .roundR2(let value): .round(value.request)
        case .finalSynthesisR2(let value): .finalSynthesis(value.request)
        }
    }

    var protocolBundle: Phase2AIWorkerProductionProtocolBundle {
        get throws {
            switch self {
            case .round, .finalSynthesis: return Phase2AIWorkerProductionProtocol.reconstructionR1
            case .roundR2, .finalSynthesisR2: return Phase2AIWorkerProductionProtocol.reconstructionR2
            case .sourceRevision(let request):
                let profile = try ReconstructionSourceProfile.enabled(request.profileID)
                guard ReconstructionSourceProfile.inferenceProfile(protocolVersion: request.protocolVersion) == profile else {
                    throw ReconstructionSourceProfile.Failure.unsupportedVersion
                }
                switch profile {
                case .scalarU32V1: return Phase2AIWorkerProductionProtocol.reconstructionSourceV10
                case .adler32RecordV1: throw ReconstructionSourceProfile.Failure.disabledProfile
                }
            }
        }
    }
}

enum ReconstructionTerminalStatus: String, Codable, Sendable {
    case completed
    case cancelled
    case failed
}

struct ReconstructionTerminalReceipt: Hashable, Codable, Sendable {
    let requestID: UUID
    let jobID: UUID
    let checkpointRevision: UInt64
    let roundID: UUID?
    let status: ReconstructionTerminalStatus
    var providerFailureReason: Phase2AIWorkerTerminal.Reason? = nil
}
