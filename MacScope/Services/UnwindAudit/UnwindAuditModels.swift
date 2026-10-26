import Foundation

/// Each admission contract has its own identity. Existing callers retain v1.
enum UnwindAuditModel: String, Sendable {
    case boundedLoops = "arm64-bounded-loops-cfa-register-v1"
    case boundedLoopCalls = "arm64-bounded-loop-calls-cfa-register-v2"
}

struct UnwindAuditLimits: Hashable, Codable, Sendable {
    var maxInstructions: Int = 16_384
    var maxObservations: Int = 256
    var maxEvidence: Int = 32
    var maxSteps: Int = 4_096
    var maxPaths: Int = 64
}

struct UnwindAuditEvidence: Hashable, Codable, Sendable {
    var code: String
    var message: String
    var address: UInt64? = nil
    var expected: String? = nil
    var observed: String? = nil
}

struct UnwindAuditFinding: Hashable, Codable, Sendable {
    var identity: MachOSliceArtifactIdentity
    var function: FunctionVersionFingerprint
    var endAddress: UInt64
    var verdict: String
    var coverage: String
    var mode: String
    var scope: String
    var encoding: UInt32? = nil
    var reasonCodes: [String] = []
    var checkedPCs: [UInt64] = []
    var evidence: [UnwindAuditEvidence] = []
    var limitations: [String] = []
    var instructionCount: Int = 0
}

enum UnwindAuditReportError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case invalidConfiguration
    case invalidModel
    case duplicateFunctionID(String)
    case invalidFinding(String)
    case identityMismatch(String)
    case addressOutsideFunction(String, UInt64)
}

/// A saved audit retains the slice identity and the limits of every finding.
/// Decoding validates structure; it does not re-read or re-hash the source image.
struct UnwindAuditReport: Hashable, Codable, Sendable {
    var schemaVersion: Int = 1
    var identity: MachOSliceArtifactIdentity
    var analysisModelVersion: String = "arm64-bounded-loops-cfa-register-v1"
    var configuration: UnwindAuditLimits = .init()
    var findings: [UnwindAuditFinding]

    init(
        schemaVersion: Int = 1,
        identity: MachOSliceArtifactIdentity,
        analysisModelVersion: String = "arm64-bounded-loops-cfa-register-v1",
        configuration: UnwindAuditLimits = .init(),
        findings: [UnwindAuditFinding]
    ) {
        self.schemaVersion = schemaVersion
        self.identity = identity
        self.analysisModelVersion = analysisModelVersion
        self.configuration = configuration
        self.findings = findings
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, identity, analysisModelVersion, configuration, findings
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        identity = try values.decode(MachOSliceArtifactIdentity.self, forKey: .identity)
        analysisModelVersion = try values.decode(String.self, forKey: .analysisModelVersion)
        configuration = try values.decode(UnwindAuditLimits.self, forKey: .configuration)
        findings = try values.decode([UnwindAuditFinding].self, forKey: .findings)
        try validate()
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw UnwindAuditReportError.unsupportedSchema(schemaVersion) }
        guard !analysisModelVersion.isEmpty else { throw UnwindAuditReportError.invalidModel }
        guard configuration.maxInstructions > 0, configuration.maxObservations > 0,
              configuration.maxEvidence > 0, configuration.maxSteps > 0,
              configuration.maxPaths > 0 else { throw UnwindAuditReportError.invalidConfiguration }
        var ids = Set<String>()
        for finding in findings {
            let id = finding.function.id
            guard ids.insert(id).inserted else { throw UnwindAuditReportError.duplicateFunctionID(id) }
            guard finding.identity == identity else { throw UnwindAuditReportError.identityMismatch(id) }
            let start = finding.function.address
            guard !id.isEmpty, start < finding.endAddress,
                  finding.function.size == finding.endAddress - start,
                  finding.instructionCount >= 0,
                  ["agreement", "inconsistency", "unresolved"].contains(finding.verdict),
                  !finding.coverage.isEmpty, !finding.mode.isEmpty, !finding.scope.isEmpty else {
                throw UnwindAuditReportError.invalidFinding(id)
            }
            for address in finding.checkedPCs + finding.evidence.compactMap(\.address) {
                guard address >= start, address < finding.endAddress else {
                    throw UnwindAuditReportError.addressOutsideFunction(id, address)
                }
            }
        }
    }
}
