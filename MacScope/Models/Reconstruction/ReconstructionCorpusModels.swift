import Foundation

enum ReconstructionArtifactKind: String, Codable, CaseIterable, Hashable, Sendable {
    case machOImage, applicationBundle, frameworkBundle, dynamicLibrary
    case staticLibrary, objectFile, archive, debugCompanion
    case source, header, moduleInterface, buildManifest
    case resource, diagnostic, log, directory, symbolicLink, opaque
}

enum ReconstructionArtifactRole: String, Codable, CaseIterable, Hashable, Sendable {
    case primaryTarget, dependency, debugInformation, referenceSource
    case referenceHeader, buildInput, testInput, resource
    case diagnosticEvidence, auxiliary
}

enum ReconstructionArtifactRelationKind: String, Codable, CaseIterable, Hashable, Sendable {
    case contains, dependsOn, debugCompanionOf, sourceFor, headerFor
    case resourceOf, variantOf, references, symbolicLinkTarget, unresolvedDependency
}

enum ReconstructionRelationEvidenceSource: String, Codable, Hashable, Sendable {
    case userSelection, containerManifest, loader, dependencyCommand
    case debugMetadata, sourceMetadata, model, tool
}

struct ReconstructionArtifactOccurrenceRecord: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let occurrenceID: ReconstructionArtifactOccurrenceID
    let contentIdentity: ReconstructionContentIdentity
    let kind: ReconstructionArtifactKind
    let roles: [ReconstructionArtifactRole]
    let executableMode: Bool
    let originalName: String?
    let diagnostic: ReconstructionDiagnostic?

    init(
        occurrenceID: ReconstructionArtifactOccurrenceID,
        contentIdentity: ReconstructionContentIdentity,
        kind: ReconstructionArtifactKind,
        roles: [ReconstructionArtifactRole],
        executableMode: Bool,
        originalName: String?,
        diagnostic: ReconstructionDiagnostic?
    ) throws {
        guard !roles.isEmpty else {
            throw ReconstructionValidationError.invalidReference(field: "artifact roles")
        }
        try ReconstructionValidation.requireUnique(roles, field: "artifact roles")
        if let originalName {
            try ReconstructionValidation.requireNonempty(originalName, field: "artifact name")
        }
        self.occurrenceID = occurrenceID
        self.contentIdentity = contentIdentity
        self.kind = kind
        self.roles = roles
        self.executableMode = executableMode
        self.originalName = originalName
        self.diagnostic = diagnostic
    }
}

struct ReconstructionArtifactRelationRecord: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let relationID: UUID
    let kind: ReconstructionArtifactRelationKind
    let sourceOccurrenceID: ReconstructionArtifactOccurrenceID
    let targetOccurrenceID: ReconstructionArtifactOccurrenceID?
    let unresolvedLocator: String?
    let evidenceSource: ReconstructionRelationEvidenceSource
    let canonicalSHA256: String

    init(
        relationID: UUID,
        kind: ReconstructionArtifactRelationKind,
        sourceOccurrenceID: ReconstructionArtifactOccurrenceID,
        targetOccurrenceID: ReconstructionArtifactOccurrenceID?,
        unresolvedLocator: String?,
        evidenceSource: ReconstructionRelationEvidenceSource,
        canonicalSHA256: String
    ) throws {
        let isUnresolved = kind == .unresolvedDependency
        guard isUnresolved == (targetOccurrenceID == nil),
              isUnresolved == (unresolvedLocator != nil) else {
            throw ReconstructionValidationError.invalidReference(field: "artifact relation target")
        }
        if let unresolvedLocator {
            try ReconstructionValidation.requireNonempty(
                unresolvedLocator,
                field: "unresolved dependency locator"
            )
        }
        try ReconstructionValidation.requireSHA256(canonicalSHA256, field: "relation digest")
        self.relationID = relationID
        self.kind = kind
        self.sourceOccurrenceID = sourceOccurrenceID
        self.targetOccurrenceID = targetOccurrenceID
        self.unresolvedLocator = unresolvedLocator
        self.evidenceSource = evidenceSource
        self.canonicalSHA256 = canonicalSHA256
    }
}

struct ReconstructionCorpusManifest: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let reconstructionProjectID: UUID
    let artifacts: [ReconstructionArtifactOccurrenceRecord]
    let relations: [ReconstructionArtifactRelationRecord]
    let canonicalSHA256: String

    init(
        schemaVersion: Int = Self.schemaVersion,
        reconstructionProjectID: UUID,
        artifacts: [ReconstructionArtifactOccurrenceRecord],
        relations: [ReconstructionArtifactRelationRecord],
        canonicalSHA256: String
    ) throws {
        try ReconstructionValidation.requireSchemaVersion(schemaVersion)
        try ReconstructionValidation.requireUnique(
            artifacts.map(\.occurrenceID),
            field: "artifact occurrence IDs"
        )
        try ReconstructionValidation.requireUnique(relations.map(\.relationID), field: "relation IDs")
        try ReconstructionValidation.requireSHA256(canonicalSHA256, field: "corpus manifest digest")
        self.schemaVersion = schemaVersion
        self.reconstructionProjectID = reconstructionProjectID
        self.artifacts = artifacts.sorted {
            $0.occurrenceID.rawValue.uuidString < $1.occurrenceID.rawValue.uuidString
        }
        self.relations = relations.sorted { $0.relationID.uuidString < $1.relationID.uuidString }
        self.canonicalSHA256 = canonicalSHA256
    }
}
