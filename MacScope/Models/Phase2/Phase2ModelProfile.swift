import Foundation

enum Phase2ModelProfileValidationError: Error, Equatable, Sendable {
    case invalidVersion
    case invalidIdentifier
    case invalidSHA256Digest
    case invalidContextBudget
    case invalidGenerationSettings
    case invalidStopSequence
    case duplicateStopSequence(String)
    case duplicatePromptModule(String)
}

struct Phase2ModelProfileID: Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) throws {
        guard rawValue.hasPrefix("sha256:"),
              phase2IsSHA256Hex(String(rawValue.dropFirst("sha256:".count)))
        else { throw Phase2ModelProfileValidationError.invalidSHA256Digest }
        self.rawValue = rawValue
    }
}

struct Phase2ModelBackingDigest: Hashable, Sendable {
    enum Storage: Hashable, Sendable {
        case unavailable
        case sha256(String)
    }

    let storage: Storage

    static let unavailable = Self(storage: .unavailable)

    static func sha256(_ value: String) throws -> Self {
        guard phase2IsSHA256Hex(value) else {
            throw Phase2ModelProfileValidationError.invalidSHA256Digest
        }
        return Self(storage: .sha256(value))
    }
}

struct Phase2QualifiedProviderIdentity: Hashable, Sendable {
    let family: String
    let build: String
    let apiCompatibility: String
    let endpointTransport: Phase2EndpointTransportMode

    init(
        family: String,
        build: String,
        apiCompatibility: String,
        endpointTransport: Phase2EndpointTransportMode
    ) throws {
        guard phase2IsCategoricalToken(family, maximumBytes: 128),
              phase2IsOpaqueToken(build, maximumBytes: 256),
              phase2IsCategoricalToken(apiCompatibility, maximumBytes: 128)
        else { throw Phase2ModelProfileValidationError.invalidIdentifier }
        self.family = family
        self.build = build
        self.apiCompatibility = apiCompatibility
        self.endpointTransport = endpointTransport
    }
}

enum Phase2EndpointTransportMode: String, Hashable, Sendable {
    case loopbackHTTP = "loopback-http"
}

struct Phase2ModelArtifactIdentity: Hashable, Sendable {
    let modelKey: String
    let source: String
    let type: Phase2LocalModelType
    let format: Phase2LocalModelFormat
    let quantizationName: String
    let bitsPerWeight: Double?
    let backingDigest: Phase2ModelBackingDigest

    init(
        modelKey: String,
        source: String,
        type: Phase2LocalModelType,
        format: Phase2LocalModelFormat,
        quantizationName: String,
        bitsPerWeight: Double?,
        backingDigest: Phase2ModelBackingDigest
    ) throws {
        guard phase2IsBoundedIdentifier(modelKey, maximumBytes: 512),
              phase2IsModelSource(source),
              phase2IsOpaqueToken(quantizationName, maximumBytes: 128),
              bitsPerWeight.map({ $0.isFinite && $0 > 0 && $0 <= 64 }) ?? true
        else { throw Phase2ModelProfileValidationError.invalidIdentifier }
        self.modelKey = modelKey
        self.source = source
        self.type = type
        self.format = format
        self.quantizationName = quantizationName
        self.bitsPerWeight = bitsPerWeight
        self.backingDigest = backingDigest
    }
}

enum Phase2ReasoningOutputPolicy: String, Hashable, Sendable {
    /// Provider reasoning side channels are ignored and never become evidence.
    case discard
}

struct Phase2ContextProfile: Hashable, Sendable {
    let id: String
    let version: Int
    let maximumInputTokens: Int
    let reservedOutputTokens: Int
    let maximumEvidenceBytes: Int
    let compactionThresholdTokens: Int

    init(
        id: String,
        version: Int,
        maximumInputTokens: Int,
        reservedOutputTokens: Int,
        maximumEvidenceBytes: Int,
        compactionThresholdTokens: Int
    ) throws {
        guard phase2IsCategoricalToken(id), version > 0 else {
            throw Phase2ModelProfileValidationError.invalidVersion
        }
        guard (1...1_048_576).contains(maximumInputTokens),
              (1...8_192).contains(reservedOutputTokens),
              reservedOutputTokens <= maximumInputTokens,
              (1...64_000_000).contains(maximumEvidenceBytes),
              compactionThresholdTokens > 0,
              compactionThresholdTokens < maximumInputTokens,
              compactionThresholdTokens <= maximumInputTokens - reservedOutputTokens
        else { throw Phase2ModelProfileValidationError.invalidContextBudget }
        self.id = id
        self.version = version
        self.maximumInputTokens = maximumInputTokens
        self.reservedOutputTokens = reservedOutputTokens
        self.maximumEvidenceBytes = maximumEvidenceBytes
        self.compactionThresholdTokens = compactionThresholdTokens
    }
}

struct Phase2GenerationProfile: Hashable, Sendable {
    let id: String
    let version: Int
    let temperature: Double
    let topP: Double
    let seed: Int?
    let stopSequences: [String]
    let reasoningOutputPolicy: Phase2ReasoningOutputPolicy

    init(
        id: String,
        version: Int,
        temperature: Double,
        topP: Double,
        seed: Int?,
        stopSequences: [String],
        reasoningOutputPolicy: Phase2ReasoningOutputPolicy
    ) throws {
        guard phase2IsCategoricalToken(id), version > 0 else {
            throw Phase2ModelProfileValidationError.invalidVersion
        }
        guard temperature.isFinite, (0...2).contains(temperature),
              !(temperature == 0 && temperature.sign == .minus),
              topP.isFinite, topP > 0, topP <= 1,
              stopSequences.count <= 16
        else { throw Phase2ModelProfileValidationError.invalidGenerationSettings }

        var seen: Set<String> = []
        for sequence in stopSequences {
            guard phase2IsBoundedIdentifier(sequence, maximumBytes: 256) else {
                throw Phase2ModelProfileValidationError.invalidStopSequence
            }
            guard seen.insert(sequence).inserted else {
                throw Phase2ModelProfileValidationError.duplicateStopSequence(sequence)
            }
        }
        self.id = id
        self.version = version
        self.temperature = temperature
        self.topP = topP
        self.seed = seed
        self.stopSequences = stopSequences
        self.reasoningOutputPolicy = reasoningOutputPolicy
    }
}

struct Phase2HardwareTier: Hashable, Sendable {
    let id: String
    let version: Int

    init(id: String, version: Int) throws {
        guard phase2IsCategoricalToken(id), version > 0 else {
            throw Phase2ModelProfileValidationError.invalidVersion
        }
        self.id = id
        self.version = version
    }
}

enum Phase2QualificationWorkflow: String, Hashable, Sendable {
    case groundedReadOnly = "grounded-read-only"
}

enum Phase2QualificationAuthorityCeiling: String, Hashable, Sendable {
    case groundedReadOnly = "grounded-read-only"
}

enum Phase2ToolCallMode: String, Hashable, Sendable {
    case disabled
    case requiredReadOnly = "required-read-only"
}

enum Phase2StructuredOutputMode: String, Hashable, Sendable {
    case disabled
    case jsonSchema = "json-schema"
}

enum Phase2ProtocolComponentAvailability: String, Hashable, Sendable {
    case available
    case unavailable
}

struct Phase2ProtocolComponentIdentity: Hashable, Sendable {
    let id: String
    let version: Int
    let availability: Phase2ProtocolComponentAvailability
    let sha256: String?

    init(id: String, version: Int, sha256: String) throws {
        guard phase2IsCategoricalToken(id), version > 0 else {
            throw Phase2ModelProfileValidationError.invalidVersion
        }
        guard phase2IsSHA256Hex(sha256) else {
            throw Phase2ModelProfileValidationError.invalidSHA256Digest
        }
        self.id = id
        self.version = version
        self.availability = .available
        self.sha256 = sha256
    }

    static func unavailable(id: String, version: Int) throws -> Self {
        guard phase2IsCategoricalToken(id), version > 0 else {
            throw Phase2ModelProfileValidationError.invalidVersion
        }
        return Self(id: id, version: version, availability: .unavailable, sha256: nil)
    }

    private init(
        id: String,
        version: Int,
        availability: Phase2ProtocolComponentAvailability,
        sha256: String?
    ) {
        self.id = id
        self.version = version
        self.availability = availability
        self.sha256 = sha256
    }
}

struct Phase2ModelProtocolManifest: Hashable, Sendable {
    let version: Int
    let promptModules: [Phase2ProtocolComponentIdentity]
    let finalOutputSchema: Phase2ProtocolComponentIdentity
    let groundedContext: Phase2ProtocolComponentIdentity
    let readToolRegistry: Phase2ProtocolComponentIdentity
    let inferenceTransport: Phase2ProtocolComponentIdentity
    let generationPolicy: Phase2ProtocolComponentIdentity
    let protocolProbeCatalog: Phase2ProtocolComponentIdentity?
    let liveQualificationCorpus: Phase2ProtocolComponentIdentity?
    let qualificationPolicy: Phase2ProtocolComponentIdentity
    let workflowAuthorityPolicy: Phase2ProtocolComponentIdentity

    init(
        promptModules: [Phase2ProtocolComponentIdentity],
        finalOutputSchema: Phase2ProtocolComponentIdentity,
        groundedContext: Phase2ProtocolComponentIdentity,
        readToolRegistry: Phase2ProtocolComponentIdentity,
        inferenceTransport: Phase2ProtocolComponentIdentity,
        generationPolicy: Phase2ProtocolComponentIdentity,
        qualificationPolicy: Phase2ProtocolComponentIdentity,
        workflowAuthorityPolicy: Phase2ProtocolComponentIdentity
    ) throws {
        self.version = 1
        self.protocolProbeCatalog = nil
        self.liveQualificationCorpus = nil
        try Self.validatePromptModules(promptModules)
        self.promptModules = promptModules
        self.finalOutputSchema = finalOutputSchema
        self.groundedContext = groundedContext
        self.readToolRegistry = readToolRegistry
        self.inferenceTransport = inferenceTransport
        self.generationPolicy = generationPolicy
        self.qualificationPolicy = qualificationPolicy
        self.workflowAuthorityPolicy = workflowAuthorityPolicy
    }

    init(
        version: Int,
        promptModules: [Phase2ProtocolComponentIdentity],
        finalOutputSchema: Phase2ProtocolComponentIdentity,
        groundedContext: Phase2ProtocolComponentIdentity,
        readToolRegistry: Phase2ProtocolComponentIdentity,
        inferenceTransport: Phase2ProtocolComponentIdentity,
        generationPolicy: Phase2ProtocolComponentIdentity,
        protocolProbeCatalog: Phase2ProtocolComponentIdentity,
        liveQualificationCorpus: Phase2ProtocolComponentIdentity,
        qualificationPolicy: Phase2ProtocolComponentIdentity,
        workflowAuthorityPolicy: Phase2ProtocolComponentIdentity
    ) throws {
        guard version == 2, qualificationPolicy.version == 2 else {
            throw Phase2ModelProfileValidationError.invalidVersion
        }
        try Self.validatePromptModules(promptModules)
        self.version = version
        self.promptModules = promptModules
        self.finalOutputSchema = finalOutputSchema
        self.groundedContext = groundedContext
        self.readToolRegistry = readToolRegistry
        self.inferenceTransport = inferenceTransport
        self.generationPolicy = generationPolicy
        self.protocolProbeCatalog = protocolProbeCatalog
        self.liveQualificationCorpus = liveQualificationCorpus
        self.qualificationPolicy = qualificationPolicy
        self.workflowAuthorityPolicy = workflowAuthorityPolicy
    }

    private static func validatePromptModules(
        _ promptModules: [Phase2ProtocolComponentIdentity]
    ) throws {
        guard !promptModules.isEmpty, promptModules.count <= 32 else {
            throw Phase2ModelProfileValidationError.invalidIdentifier
        }
        var moduleIDs: Set<String> = []
        for module in promptModules where !moduleIDs.insert(module.id).inserted {
            throw Phase2ModelProfileValidationError.duplicatePromptModule(module.id)
        }
    }

    var isCertificationEligible: Bool {
        let identities = promptModules + [
            finalOutputSchema,
            groundedContext,
            readToolRegistry,
            inferenceTransport,
            generationPolicy,
            qualificationPolicy,
            workflowAuthorityPolicy,
        ] + [protocolProbeCatalog, liveQualificationCorpus].compactMap { $0 }
        return identities.allSatisfy { $0.availability == .available && $0.sha256 != nil }
            && (version == 1 || (protocolProbeCatalog != nil && liveQualificationCorpus != nil))
    }
}

/// Immutable description of one exact support recipe. Runtime endpoint UUIDs, provider
/// generations, loaded-instance IDs, readiness, and qualification outcomes do not belong here.
struct Phase2ModelProfile: Hashable, Sendable {
    let version: Int
    let provider: Phase2QualifiedProviderIdentity
    let artifact: Phase2ModelArtifactIdentity
    let loadedConfiguration: Phase2LocalModelInstanceConfiguration
    let context: Phase2ContextProfile
    let generation: Phase2GenerationProfile
    let hardwareTier: Phase2HardwareTier
    let workflow: Phase2QualificationWorkflow
    let authorityCeiling: Phase2QualificationAuthorityCeiling
    let toolCallMode: Phase2ToolCallMode
    let structuredOutputMode: Phase2StructuredOutputMode
    let protocolManifest: Phase2ModelProtocolManifest

    init(
        version: Int,
        provider: Phase2QualifiedProviderIdentity,
        artifact: Phase2ModelArtifactIdentity,
        loadedConfiguration: Phase2LocalModelInstanceConfiguration,
        context: Phase2ContextProfile,
        generation: Phase2GenerationProfile,
        hardwareTier: Phase2HardwareTier,
        workflow: Phase2QualificationWorkflow,
        authorityCeiling: Phase2QualificationAuthorityCeiling,
        toolCallMode: Phase2ToolCallMode,
        structuredOutputMode: Phase2StructuredOutputMode,
        protocolManifest: Phase2ModelProtocolManifest
    ) throws {
        guard version > 0 else { throw Phase2ModelProfileValidationError.invalidVersion }
        guard artifact.type == .language,
              loadedConfiguration.effectiveContextLength >= context.maximumInputTokens,
              (1...1_048_576).contains(loadedConfiguration.effectiveContextLength),
              loadedConfiguration.evaluationBatchSize.map({ (1...1_048_576).contains($0) }) ?? true,
              loadedConfiguration.parallelPredictions.map({ (1...1_024).contains($0) }) ?? true,
              loadedConfiguration.expertCount.map({ (1...1_048_576).contains($0) }) ?? true
        else { throw Phase2ModelProfileValidationError.invalidContextBudget }
        self.version = version
        self.provider = provider
        self.artifact = artifact
        self.loadedConfiguration = loadedConfiguration
        self.context = context
        self.generation = generation
        self.hardwareTier = hardwareTier
        self.workflow = workflow
        self.authorityCeiling = authorityCeiling
        self.toolCallMode = toolCallMode
        self.structuredOutputMode = structuredOutputMode
        self.protocolManifest = protocolManifest
    }
}

func phase2IsBoundedIdentifier(_ value: String, maximumBytes: Int = 128) -> Bool {
    let bytes = value.utf8
    return !bytes.isEmpty
        && bytes.count <= maximumBytes
        && Array(bytes) == Array(value.precomposedStringWithCanonicalMapping.utf8)
        && !bytes.contains(where: { $0 <= 0x1F || $0 == 0x7F })
}

func phase2IsCategoricalToken(_ value: String, maximumBytes: Int = 128) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= maximumBytes,
          (0x61...0x7A).contains(bytes.first!)
    else { return false }
    return bytes.allSatisfy { byte in
        (0x61...0x7A).contains(byte)
            || (0x30...0x39).contains(byte)
            || byte == 0x2D
            || byte == 0x2E
            || byte == 0x5F
    }
}

func phase2IsModelSource(_ value: String) -> Bool {
    let bytes = value.utf8
    guard phase2IsBoundedIdentifier(value, maximumBytes: 256),
          bytes.first != 0x2F,
          bytes.last != 0x2F,
          bytes.allSatisfy({ byte in
              (0x41...0x5A).contains(byte)
                  || (0x61...0x7A).contains(byte)
                  || (0x30...0x39).contains(byte)
                  || byte == 0x2D
                  || byte == 0x2E
                  || byte == 0x2F
                  || byte == 0x5F
          })
    else { return false }
    return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".."
    }
}

func phase2IsOpaqueToken(_ value: String, maximumBytes: Int = 128) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= maximumBytes else { return false }
    return bytes.allSatisfy { byte in
        (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte)
            || (0x30...0x39).contains(byte)
            || byte == 0x2D
            || byte == 0x2E
            || byte == 0x5F
            || byte == 0x2B
            || byte == 0x40
    }
}

func phase2IsSHA256Hex(_ value: String) -> Bool {
    value.utf8.count == 64
        && value.utf8.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
        }
}

func phase2UnicodeScalarOrder(_ lhs: String, _ rhs: String) -> Bool {
    lhs.unicodeScalars.map(\.value).lexicographicallyPrecedes(
        rhs.unicodeScalars.map(\.value)
    )
}
