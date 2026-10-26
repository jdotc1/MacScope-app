import Foundation

enum ReconstructionEvidenceClassification: String, Codable, CaseIterable, Hashable, Sendable {
    case acceptedCurrent, acceptedHistorical, staleArtifact, staleAnalysis
    case superseded, unavailable, failed, cancelled, truncated
}

enum ReconstructionEvidenceRelationKind: String, Codable, CaseIterable, Hashable, Sendable {
    case derivedFrom, supports, contradicts, summarizes, supersedes, compares, resolvesGap
}

enum ReconstructionEvidencePayloadKind: String, Codable, Hashable, Sendable {
    case structuredJSON, text, binary, comparison, index, diagnostic
}

struct ReconstructionProducerIdentity: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let macScopeBuildIdentity: String
    let macScopeSourceIdentity: String
    let operationIdentity: String
    let registryIdentity: String
    let protocolIdentity: String
    let nativeProviderIdentity: String?
    let nativeCapabilityIdentities: [String]
    let modelKey: String?
    let endpointOrigin: String?
    let observedModelInventorySHA256: String?
    let observedConfigurationSHA256: String?
    let toolchainIdentity: String?
    let canonicalSHA256: String

    init(
        schemaVersion: Int = Self.schemaVersion,
        macScopeBuildIdentity: String,
        macScopeSourceIdentity: String,
        operationIdentity: String,
        registryIdentity: String,
        protocolIdentity: String,
        nativeProviderIdentity: String? = nil,
        nativeCapabilityIdentities: [String] = [],
        modelKey: String? = nil,
        endpointOrigin: String? = nil,
        observedModelInventorySHA256: String? = nil,
        observedConfigurationSHA256: String? = nil,
        toolchainIdentity: String? = nil,
        canonicalSHA256: String
    ) throws {
        try ReconstructionValidation.requireSchemaVersion(schemaVersion)
        for (field, value) in [
            ("MacScope build identity", macScopeBuildIdentity),
            ("MacScope source identity", macScopeSourceIdentity),
            ("operation identity", operationIdentity),
            ("registry identity", registryIdentity),
            ("protocol identity", protocolIdentity)
        ] {
            try ReconstructionValidation.requireNonempty(value, field: field)
        }
        try ReconstructionValidation.requireUnique(
            nativeCapabilityIdentities,
            field: "native capability identities"
        )
        for (field, value) in [
            ("model inventory digest", observedModelInventorySHA256),
            ("configuration digest", observedConfigurationSHA256)
        ] where value != nil {
            try ReconstructionValidation.requireSHA256(value!, field: field)
        }
        try ReconstructionValidation.requireSHA256(canonicalSHA256, field: "producer digest")
        for (field, value) in [
            ("model key", modelKey),
            ("endpoint origin", endpointOrigin),
            ("native provider identity", nativeProviderIdentity),
            ("toolchain identity", toolchainIdentity)
        ] where value?.contains("/Users/") == true || value?.contains("\\Users\\") == true {
            throw ReconstructionValidationError.forbiddenTransientIdentity(field: field)
        }
        self.schemaVersion = schemaVersion
        self.macScopeBuildIdentity = macScopeBuildIdentity
        self.macScopeSourceIdentity = macScopeSourceIdentity
        self.operationIdentity = operationIdentity
        self.registryIdentity = registryIdentity
        self.protocolIdentity = protocolIdentity
        self.nativeProviderIdentity = nativeProviderIdentity
        self.nativeCapabilityIdentities = nativeCapabilityIdentities.sorted()
        self.modelKey = modelKey
        self.endpointOrigin = endpointOrigin
        self.observedModelInventorySHA256 = observedModelInventorySHA256
        self.observedConfigurationSHA256 = observedConfigurationSHA256
        self.toolchainIdentity = toolchainIdentity
        self.canonicalSHA256 = canonicalSHA256
    }
}

struct ReconstructionEvidenceCitation: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let citationID: UUID
    let sourceEvidenceID: UUID?
    let subject: ReconstructionSubjectCoordinate?
    let locator: String?

    init(
        citationID: UUID,
        sourceEvidenceID: UUID?,
        subject: ReconstructionSubjectCoordinate?,
        locator: String?
    ) throws {
        guard sourceEvidenceID != nil || subject != nil || locator != nil else {
            throw ReconstructionValidationError.invalidReference(field: "evidence citation")
        }
        if let locator {
            try ReconstructionValidation.requireNonempty(locator, field: "citation locator")
        }
        self.citationID = citationID
        self.sourceEvidenceID = sourceEvidenceID
        self.subject = subject
        self.locator = locator
    }
}

struct ReconstructionEvidenceRelation: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let relationID: UUID
    let kind: ReconstructionEvidenceRelationKind
    let sourceEvidenceID: UUID
    let targetEvidenceID: UUID
}

struct ReconstructionFacetDependency: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let facetIdentity: String
    let fingerprintSHA256: String

    init(facetIdentity: String, fingerprintSHA256: String) throws {
        try ReconstructionValidation.requireNonempty(facetIdentity, field: "facet identity")
        try ReconstructionValidation.requireSHA256(fingerprintSHA256, field: "facet fingerprint")
        self.facetIdentity = facetIdentity
        self.fingerprintSHA256 = fingerprintSHA256
    }
}

struct ReconstructionEvidenceRecord: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let evidenceID: UUID
    let schemaVersion: Int
    let subject: ReconstructionSubjectCoordinate
    let operationID: String
    let payloadKind: ReconstructionEvidencePayloadKind
    let payload: Data
    let payloadByteCount: UInt64
    let payloadSHA256: String
    let facetDependencies: [ReconstructionFacetDependency]
    let producer: ReconstructionProducerIdentity
    let citations: [ReconstructionEvidenceCitation]
    let creatingJobID: UUID
    let creatingTaskID: UUID
    let creatingCheckpointID: UUID
    let modelReceiptID: UUID?
    let toolReceiptID: UUID?
    let classification: ReconstructionEvidenceClassification
    let supersedesEvidenceID: UUID?
    let supersededByEvidenceID: UUID?
    let diagnostic: ReconstructionDiagnostic?

    init(
        evidenceID: UUID,
        schemaVersion: Int = Self.schemaVersion,
        subject: ReconstructionSubjectCoordinate,
        operationID: String,
        payloadKind: ReconstructionEvidencePayloadKind,
        payload: Data,
        payloadByteCount: UInt64,
        payloadSHA256: String,
        facetDependencies: [ReconstructionFacetDependency],
        producer: ReconstructionProducerIdentity,
        citations: [ReconstructionEvidenceCitation],
        creatingJobID: UUID,
        creatingTaskID: UUID,
        creatingCheckpointID: UUID,
        modelReceiptID: UUID?,
        toolReceiptID: UUID?,
        classification: ReconstructionEvidenceClassification,
        supersedesEvidenceID: UUID?,
        supersededByEvidenceID: UUID?,
        diagnostic: ReconstructionDiagnostic?
    ) throws {
        try ReconstructionValidation.requireSchemaVersion(schemaVersion)
        try ReconstructionValidation.requireNonempty(operationID, field: "evidence operation ID")
        guard payloadByteCount == UInt64(payload.count), payloadByteCount > 0 else {
            throw ReconstructionValidationError.invalidByteCount(field: "evidence payload byte count")
        }
        try ReconstructionValidation.requireSHA256(payloadSHA256, field: "evidence payload digest")
        try ReconstructionValidation.requireUnique(
            facetDependencies.map(\.facetIdentity),
            field: "facet dependency identities"
        )
        try ReconstructionValidation.requireUnique(citations.map(\.citationID), field: "citation IDs")
        guard supersedesEvidenceID != evidenceID, supersededByEvidenceID != evidenceID else {
            throw ReconstructionValidationError.invalidReference(field: "evidence supersession")
        }
        self.evidenceID = evidenceID
        self.schemaVersion = schemaVersion
        self.subject = subject
        self.operationID = operationID
        self.payloadKind = payloadKind
        self.payload = payload
        self.payloadByteCount = payloadByteCount
        self.payloadSHA256 = payloadSHA256
        self.facetDependencies = facetDependencies
        self.producer = producer
        self.citations = citations
        self.creatingJobID = creatingJobID
        self.creatingTaskID = creatingTaskID
        self.creatingCheckpointID = creatingCheckpointID
        self.modelReceiptID = modelReceiptID
        self.toolReceiptID = toolReceiptID
        self.classification = classification
        self.supersedesEvidenceID = supersedesEvidenceID
        self.supersededByEvidenceID = supersededByEvidenceID
        self.diagnostic = diagnostic
    }
}

struct ReconstructionEvidenceGap: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let gapID: UUID
    let subject: ReconstructionSubjectCoordinate
    let operationID: String
    let reason: ReconstructionDiagnostic
    let canonicalSHA256: String

    init(
        gapID: UUID,
        subject: ReconstructionSubjectCoordinate,
        operationID: String,
        reason: ReconstructionDiagnostic,
        canonicalSHA256: String
    ) throws {
        try ReconstructionValidation.requireNonempty(operationID, field: "gap operation ID")
        try ReconstructionValidation.requireSHA256(canonicalSHA256, field: "gap digest")
        self.gapID = gapID
        self.subject = subject
        self.operationID = operationID
        self.reason = reason
        self.canonicalSHA256 = canonicalSHA256
    }
}
