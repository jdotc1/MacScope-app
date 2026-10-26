import CryptoKit
import Foundation

enum ReconstructionEvidenceAcceptanceError: Error, Equatable, Sendable {
    case invalidLimits
    case invalidAuthorityCut
    case corpusManifestDigestMismatch
    case producerDigestMismatch
    case duplicateEvidenceID
    case operationMismatch
    case subjectNotAuthoritative
    case artifactNotCurrent
    case facetMismatch
    case producerMismatch
    case forbiddenProducerIdentity
    case checkpointCorrelationMismatch
    case taskCorrelationMismatch
    case receiptCorrelationMismatch
    case payloadByteCountMismatch
    case payloadDigestMismatch
    case payloadLimitExceeded
    case diagnosticLimitExceeded
    case citationLimitExceeded
    case facetLimitExceeded
    case citationLocatorLimitExceeded
    case facetIdentityLimitExceeded
    case metadataLimitExceeded
    case canonicalEvidenceLimitExceeded
    case missingCitation
    case duplicateCitation
    case unresolvedCitation
    case invalidSupersession
}

/// Untrusted evidence at the pure acceptance boundary.
///
/// Construction intentionally performs no canonical validation. The acceptor must be able to
/// receive malformed byte counts, digests, citations, and provenance and reject them fail-closed.
struct ReconstructionEvidenceCandidate: Hashable, Sendable {
    let evidenceID: UUID
    let subject: ReconstructionSubjectCoordinate
    let operationID: ReconstructionOperationID
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
    let supersedesEvidenceID: UUID?
    let diagnostic: ReconstructionDiagnostic?

    init(
        evidenceID: UUID,
        subject: ReconstructionSubjectCoordinate,
        operationID: ReconstructionOperationID,
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
        supersedesEvidenceID: UUID?,
        diagnostic: ReconstructionDiagnostic?
    ) throws {
        self.evidenceID = evidenceID
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
        self.supersedesEvidenceID = supersedesEvidenceID
        self.diagnostic = diagnostic
    }
}

/// Immutable authority supplied by the coordinator for one acceptance decision.
struct ReconstructionAuthorityCut: Sendable {
    let corpusManifest: ReconstructionCorpusManifest
    let authoritativeSubjects: [ReconstructionSubjectCoordinate]
    let facetFingerprints: [String: String]
    let creatingJobID: UUID
    let creatingTaskID: UUID
    let creatingCheckpointID: UUID
    let checkpointRevision: UInt64
    let operationID: ReconstructionOperationID
    let toolReceiptID: UUID?
    let modelReceiptID: UUID?
    let producer: ReconstructionProducerIdentity
    let evidence: [ReconstructionEvidenceRecord]

    init(
        corpusManifest: ReconstructionCorpusManifest,
        authoritativeSubjects: [ReconstructionSubjectCoordinate],
        facetFingerprints: [String: String],
        creatingJobID: UUID,
        creatingTaskID: UUID,
        creatingCheckpointID: UUID,
        checkpointRevision: UInt64,
        operationID: ReconstructionOperationID,
        toolReceiptID: UUID?,
        modelReceiptID: UUID?,
        producer: ReconstructionProducerIdentity,
        evidence: [ReconstructionEvidenceRecord]
    ) {
        self.corpusManifest = corpusManifest
        self.authoritativeSubjects = authoritativeSubjects
        self.facetFingerprints = facetFingerprints
        self.creatingJobID = creatingJobID
        self.creatingTaskID = creatingTaskID
        self.creatingCheckpointID = creatingCheckpointID
        self.checkpointRevision = checkpointRevision
        self.operationID = operationID
        self.toolReceiptID = toolReceiptID
        self.modelReceiptID = modelReceiptID
        self.producer = producer
        self.evidence = evidence
    }
}

protocol ReconstructionEvidenceAccepting: Sendable {
    func validate(
        _ candidate: ReconstructionEvidenceCandidate,
        against cut: ReconstructionAuthorityCut
    ) throws -> ReconstructionEvidenceRecord
}

/// Pure, fail-closed conversion from untrusted candidate bytes to a durable evidence record.
struct ReconstructionEvidenceAcceptor: ReconstructionEvidenceAccepting, Sendable {
    private enum HardLimit {
        static let maximumCitationCount = 100_000
        static let maximumFacetCount = 100_000
        static let maximumCitationLocatorUTF8Bytes = 16 * 1_024
        static let maximumFacetIdentityUTF8Bytes = 16 * 1_024
        static let maximumMetadataUTF8Bytes = ReconstructionPackageLayout.maximumManifestBytes
        static let maximumCanonicalEvidenceBytes = ReconstructionPackageLayout.maximumManifestBytes
        static let maximumAuthorityCollectionCount = 100_000
    }

    struct Limits: Sendable {
        static let standard = Limits(
            maximumCitationCount: 4_096,
            maximumFacetCount: 1_024,
            maximumCitationLocatorUTF8Bytes: 16 * 1_024,
            maximumFacetIdentityUTF8Bytes: 1_024,
            maximumMetadataUTF8Bytes: 16 * 1_024 * 1_024,
            maximumCanonicalEvidenceBytes: ReconstructionPackageLayout.maximumManifestBytes
        )

        let maximumCitationCount: Int
        let maximumFacetCount: Int
        let maximumCitationLocatorUTF8Bytes: Int
        let maximumFacetIdentityUTF8Bytes: Int
        let maximumMetadataUTF8Bytes: Int
        let maximumCanonicalEvidenceBytes: Int

        init(
            maximumCitationCount: Int,
            maximumFacetCount: Int,
            maximumCitationLocatorUTF8Bytes: Int,
            maximumFacetIdentityUTF8Bytes: Int,
            maximumMetadataUTF8Bytes: Int,
            maximumCanonicalEvidenceBytes: Int
        ) {
            self.maximumCitationCount = maximumCitationCount
            self.maximumFacetCount = maximumFacetCount
            self.maximumCitationLocatorUTF8Bytes = maximumCitationLocatorUTF8Bytes
            self.maximumFacetIdentityUTF8Bytes = maximumFacetIdentityUTF8Bytes
            self.maximumMetadataUTF8Bytes = maximumMetadataUTF8Bytes
            self.maximumCanonicalEvidenceBytes = maximumCanonicalEvidenceBytes
        }
    }

    let maximumPayloadBytes: Int
    let maximumDiagnosticUTF8Bytes: Int
    let limits: Limits

    init(
        maximumPayloadBytes: Int,
        maximumDiagnosticUTF8Bytes: Int,
        limits: Limits = .standard
    ) {
        self.maximumPayloadBytes = maximumPayloadBytes
        self.maximumDiagnosticUTF8Bytes = maximumDiagnosticUTF8Bytes
        self.limits = limits
    }

    func validate(
        _ candidate: ReconstructionEvidenceCandidate,
        against cut: ReconstructionAuthorityCut
    ) throws -> ReconstructionEvidenceRecord {
        try Task.checkCancellation()
        guard limitsAreValid else {
            throw ReconstructionEvidenceAcceptanceError.invalidLimits
        }
        guard candidate.operationID == cut.operationID,
              candidate.producer.operationIdentity == candidate.operationID.rawValue else {
            throw ReconstructionEvidenceAcceptanceError.operationMismatch
        }
        guard Self.producerContainsOnlyDurableBoundedIdentity(candidate.producer),
              Self.producerContainsOnlyDurableBoundedIdentity(cut.producer) else {
            throw ReconstructionEvidenceAcceptanceError.forbiddenProducerIdentity
        }
        try validateCandidateBounds(candidate, against: cut)
        try Task.checkCancellation()
        try validateAuthorityCut(cut)
        try Task.checkCancellation()
        guard try Self.canonicalCorpusManifestSHA256(cut.corpusManifest)
                == cut.corpusManifest.canonicalSHA256 else {
            throw ReconstructionEvidenceAcceptanceError.corpusManifestDigestMismatch
        }
        try Task.checkCancellation()
        guard !cut.evidence.contains(where: { $0.evidenceID == candidate.evidenceID }) else {
            throw ReconstructionEvidenceAcceptanceError.duplicateEvidenceID
        }
        guard cut.authoritativeSubjects.contains(candidate.subject) else {
            throw ReconstructionEvidenceAcceptanceError.subjectNotAuthoritative
        }
        guard Self.artifactIsCurrent(for: candidate.subject, in: cut.corpusManifest) else {
            throw ReconstructionEvidenceAcceptanceError.artifactNotCurrent
        }
        try validateFacets(candidate.facetDependencies, against: cut.facetFingerprints)
        guard try Self.canonicalProducerSHA256(candidate.producer)
                == candidate.producer.canonicalSHA256,
              try Self.canonicalProducerSHA256(cut.producer)
                == cut.producer.canonicalSHA256 else {
            throw ReconstructionEvidenceAcceptanceError.producerDigestMismatch
        }
        guard candidate.producer == cut.producer else {
            throw ReconstructionEvidenceAcceptanceError.producerMismatch
        }
        guard candidate.creatingCheckpointID == cut.creatingCheckpointID else {
            throw ReconstructionEvidenceAcceptanceError.checkpointCorrelationMismatch
        }
        guard candidate.creatingJobID == cut.creatingJobID,
              candidate.creatingTaskID == cut.creatingTaskID else {
            throw ReconstructionEvidenceAcceptanceError.taskCorrelationMismatch
        }
        guard cut.toolReceiptID != nil || cut.modelReceiptID != nil,
              candidate.toolReceiptID == cut.toolReceiptID,
              candidate.modelReceiptID == cut.modelReceiptID else {
            throw ReconstructionEvidenceAcceptanceError.receiptCorrelationMismatch
        }
        try Task.checkCancellation()
        guard Self.sha256(candidate.payload) == candidate.payloadSHA256 else {
            throw ReconstructionEvidenceAcceptanceError.payloadDigestMismatch
        }
        try Task.checkCancellation()
        try validateCitations(candidate.citations, against: cut)
        try validateSupersession(candidate, against: cut)

        try Task.checkCancellation()
        let facets = candidate.facetDependencies.sorted {
            $0.facetIdentity < $1.facetIdentity
        }
        try Task.checkCancellation()
        let citations = candidate.citations.sorted {
            $0.citationID.uuidString < $1.citationID.uuidString
        }
        try Task.checkCancellation()
        let record = try ReconstructionEvidenceRecord(
            evidenceID: candidate.evidenceID,
            subject: candidate.subject,
            operationID: candidate.operationID.rawValue,
            payloadKind: candidate.payloadKind,
            payload: candidate.payload,
            payloadByteCount: candidate.payloadByteCount,
            payloadSHA256: candidate.payloadSHA256,
            facetDependencies: facets,
            producer: candidate.producer,
            citations: citations,
            creatingJobID: candidate.creatingJobID,
            creatingTaskID: candidate.creatingTaskID,
            creatingCheckpointID: candidate.creatingCheckpointID,
            modelReceiptID: candidate.modelReceiptID,
            toolReceiptID: candidate.toolReceiptID,
            classification: .acceptedCurrent,
            supersedesEvidenceID: candidate.supersedesEvidenceID,
            supersededByEvidenceID: nil,
            diagnostic: candidate.diagnostic
        )
        try Task.checkCancellation()
        let canonicalEvidence = try ReconstructionCanonicalJSON.encode(record)
        try Task.checkCancellation()
        guard canonicalEvidence.count <= limits.maximumCanonicalEvidenceBytes else {
            throw ReconstructionEvidenceAcceptanceError.canonicalEvidenceLimitExceeded
        }
        try Task.checkCancellation()
        return record
    }

    private var limitsAreValid: Bool {
        maximumPayloadBytes > 0
            && maximumDiagnosticUTF8Bytes > 0
            && (1...HardLimit.maximumCitationCount).contains(limits.maximumCitationCount)
            && (1...HardLimit.maximumFacetCount).contains(limits.maximumFacetCount)
            && (1...HardLimit.maximumCitationLocatorUTF8Bytes).contains(
                limits.maximumCitationLocatorUTF8Bytes
            )
            && (1...HardLimit.maximumFacetIdentityUTF8Bytes).contains(
                limits.maximumFacetIdentityUTF8Bytes
            )
            && (1...HardLimit.maximumMetadataUTF8Bytes).contains(
                limits.maximumMetadataUTF8Bytes
            )
            && (1...HardLimit.maximumCanonicalEvidenceBytes).contains(
                limits.maximumCanonicalEvidenceBytes
            )
    }

    /// Bounds attacker-controlled variable metadata before allocating uniqueness sets,
    /// sorting, hashing payloads, or producing canonical JSON.
    private func validateCandidateBounds(
        _ candidate: ReconstructionEvidenceCandidate,
        against cut: ReconstructionAuthorityCut
    ) throws {
        guard candidate.citations.count <= limits.maximumCitationCount else {
            throw ReconstructionEvidenceAcceptanceError.citationLimitExceeded
        }
        guard candidate.facetDependencies.count <= limits.maximumFacetCount,
              cut.facetFingerprints.count <= limits.maximumFacetCount else {
            throw ReconstructionEvidenceAcceptanceError.facetLimitExceeded
        }
        guard candidate.payload.count <= maximumPayloadBytes else {
            throw ReconstructionEvidenceAcceptanceError.payloadLimitExceeded
        }
        guard !candidate.payload.isEmpty,
              candidate.payloadByteCount == UInt64(candidate.payload.count) else {
            throw ReconstructionEvidenceAcceptanceError.payloadByteCountMismatch
        }
        guard Self.isCanonicalSHA256(candidate.payloadSHA256) else {
            throw ReconstructionEvidenceAcceptanceError.payloadDigestMismatch
        }
        let payloadBase64Bytes = try canonicalBase64ByteCount(for: candidate.payload.count)
        if let diagnostic = candidate.diagnostic,
           diagnostic.text.utf8.count > maximumDiagnosticUTF8Bytes {
            throw ReconstructionEvidenceAcceptanceError.diagnosticLimitExceeded
        }

        var remainingMetadataBytes = limits.maximumMetadataUTF8Bytes
        for value in ReconstructionEvidenceIntegrity.producerIdentityValues(candidate.producer) {
            try consumeMetadata(value.utf8.count, from: &remainingMetadataBytes)
        }
        try consumeSubjectMetadata(candidate.subject, from: &remainingMetadataBytes)
        if let diagnostic = candidate.diagnostic {
            try consumeMetadata(diagnostic.text.utf8.count, from: &remainingMetadataBytes)
        }
        for (index, dependency) in candidate.facetDependencies.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let byteCount = dependency.facetIdentity.utf8.count
            guard byteCount <= limits.maximumFacetIdentityUTF8Bytes else {
                throw ReconstructionEvidenceAcceptanceError.facetIdentityLimitExceeded
            }
            try consumeMetadata(byteCount, from: &remainingMetadataBytes)
        }
        for (index, facetIdentity) in cut.facetFingerprints.keys.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard facetIdentity.utf8.count <= limits.maximumFacetIdentityUTF8Bytes else {
                throw ReconstructionEvidenceAcceptanceError.facetIdentityLimitExceeded
            }
        }
        for (index, citation) in candidate.citations.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if let locator = citation.locator {
                let byteCount = locator.utf8.count
                guard byteCount <= limits.maximumCitationLocatorUTF8Bytes else {
                    throw ReconstructionEvidenceAcceptanceError.citationLocatorLimitExceeded
                }
                try consumeMetadata(byteCount, from: &remainingMetadataBytes)
            }
            if let subject = citation.subject {
                try consumeSubjectMetadata(subject, from: &remainingMetadataBytes)
            }
        }
        let admittedMetadataBytes = limits.maximumMetadataUTF8Bytes - remainingMetadataBytes
        guard admittedMetadataBytes <= limits.maximumCanonicalEvidenceBytes,
              payloadBase64Bytes
                <= limits.maximumCanonicalEvidenceBytes - admittedMetadataBytes else {
            throw ReconstructionEvidenceAcceptanceError.canonicalEvidenceLimitExceeded
        }
        try Task.checkCancellation()
    }

    private func canonicalBase64ByteCount(for payloadByteCount: Int) throws -> Int {
        let fullGroups = payloadByteCount / 3
        let trailingBytes = payloadByteCount % 3
        guard fullGroups <= limits.maximumCanonicalEvidenceBytes / 4 else {
            throw ReconstructionEvidenceAcceptanceError.canonicalEvidenceLimitExceeded
        }
        let encodedBytes = fullGroups * 4 + (trailingBytes == 0 ? 0 : 4)
        guard encodedBytes <= limits.maximumCanonicalEvidenceBytes else {
            throw ReconstructionEvidenceAcceptanceError.canonicalEvidenceLimitExceeded
        }
        return encodedBytes
    }

    private func consumeMetadata(_ byteCount: Int, from remainingBytes: inout Int) throws {
        guard byteCount <= remainingBytes else {
            throw ReconstructionEvidenceAcceptanceError.metadataLimitExceeded
        }
        remainingBytes -= byteCount
    }

    private func consumeSubjectMetadata(
        _ subject: ReconstructionSubjectCoordinate,
        from remainingBytes: inout Int
    ) throws {
        guard case .function(let function) = subject,
              let symbolHint = function.symbolHint else { return }
        try consumeMetadata(symbolHint.utf8.count, from: &remainingBytes)
    }

    private func validateAuthorityCut(_ cut: ReconstructionAuthorityCut) throws {
        guard cut.authoritativeSubjects.count <= HardLimit.maximumAuthorityCollectionCount,
              cut.evidence.count <= HardLimit.maximumAuthorityCollectionCount else {
            throw ReconstructionEvidenceAcceptanceError.invalidAuthorityCut
        }
        var subjects = Set<ReconstructionSubjectCoordinate>()
        subjects.reserveCapacity(cut.authoritativeSubjects.count)
        for (index, subject) in cut.authoritativeSubjects.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard subjects.insert(subject).inserted else {
                throw ReconstructionEvidenceAcceptanceError.invalidAuthorityCut
            }
        }
        var evidenceIDs = Set<UUID>()
        evidenceIDs.reserveCapacity(cut.evidence.count)
        for (index, record) in cut.evidence.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard evidenceIDs.insert(record.evidenceID).inserted else {
                throw ReconstructionEvidenceAcceptanceError.invalidAuthorityCut
            }
        }
        for (index, facet) in cut.facetFingerprints.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard !facet.key.isEmpty, Self.isCanonicalSHA256(facet.value) else {
                throw ReconstructionEvidenceAcceptanceError.invalidAuthorityCut
            }
        }
        try Task.checkCancellation()
    }

    private func validateFacets(
        _ dependencies: [ReconstructionFacetDependency],
        against fingerprints: [String: String]
    ) throws {
        guard dependencies.count == fingerprints.count else {
            throw ReconstructionEvidenceAcceptanceError.facetMismatch
        }
        var observedIdentities = Set<String>()
        observedIdentities.reserveCapacity(dependencies.count)
        for (index, dependency) in dependencies.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard observedIdentities.insert(dependency.facetIdentity).inserted,
                  fingerprints[dependency.facetIdentity] == dependency.fingerprintSHA256 else {
                throw ReconstructionEvidenceAcceptanceError.facetMismatch
            }
        }
        try Task.checkCancellation()
    }

    private func validateCitations(
        _ citations: [ReconstructionEvidenceCitation],
        against cut: ReconstructionAuthorityCut
    ) throws {
        guard !citations.isEmpty else {
            throw ReconstructionEvidenceAcceptanceError.missingCitation
        }
        var citationIDs = Set<UUID>()
        citationIDs.reserveCapacity(citations.count)
        var anchors = Set<ReconstructionEvidenceCitationAnchor>()
        anchors.reserveCapacity(citations.count)
        var evidenceIDs = Set<UUID>()
        evidenceIDs.reserveCapacity(cut.evidence.count)
        for (index, record) in cut.evidence.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            evidenceIDs.insert(record.evidenceID)
        }
        var subjects = Set<ReconstructionSubjectCoordinate>()
        subjects.reserveCapacity(cut.authoritativeSubjects.count)
        for (index, subject) in cut.authoritativeSubjects.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            subjects.insert(subject)
        }
        for (index, citation) in citations.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard citationIDs.insert(citation.citationID).inserted,
                  anchors.insert(ReconstructionEvidenceCitationAnchor(citation)).inserted else {
                throw ReconstructionEvidenceAcceptanceError.duplicateCitation
            }
            var hasDurableAnchor = false
            if let sourceEvidenceID = citation.sourceEvidenceID {
                guard evidenceIDs.contains(sourceEvidenceID) else {
                    throw ReconstructionEvidenceAcceptanceError.unresolvedCitation
                }
                hasDurableAnchor = true
            }
            if let subject = citation.subject {
                guard subjects.contains(subject),
                      Self.artifactIsCurrent(for: subject, in: cut.corpusManifest) else {
                    throw ReconstructionEvidenceAcceptanceError.unresolvedCitation
                }
                hasDurableAnchor = true
            }
            // A free-form locator may refine a durable anchor, but is never authority by itself.
            guard hasDurableAnchor else {
                throw ReconstructionEvidenceAcceptanceError.unresolvedCitation
            }
        }
        try Task.checkCancellation()
    }

    private func validateSupersession(
        _ candidate: ReconstructionEvidenceCandidate,
        against cut: ReconstructionAuthorityCut
    ) throws {
        guard let predecessorID = candidate.supersedesEvidenceID else { return }
        guard predecessorID != candidate.evidenceID else {
            throw ReconstructionEvidenceAcceptanceError.invalidSupersession
        }
        var predecessor: ReconstructionEvidenceRecord?
        var predecessorIsAlreadyClaimed = false
        for (index, record) in cut.evidence.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if record.evidenceID == predecessorID { predecessor = record }
            if record.supersedesEvidenceID == predecessorID {
                predecessorIsAlreadyClaimed = true
            }
        }
        guard let predecessor,
              predecessor.subject == candidate.subject,
              predecessor.operationID == candidate.operationID.rawValue,
              (predecessor.supersededByEvidenceID == nil
                || predecessor.supersededByEvidenceID == candidate.evidenceID),
              predecessor.classification != .superseded,
              !predecessorIsAlreadyClaimed else {
            throw ReconstructionEvidenceAcceptanceError.invalidSupersession
        }
        try Task.checkCancellation()
    }

    private static func artifactIsCurrent(
        for subject: ReconstructionSubjectCoordinate,
        in manifest: ReconstructionCorpusManifest
    ) -> Bool {
        let artifact: ReconstructionArtifactCoordinate
        switch subject {
        case .artifact(let coordinate): artifact = coordinate
        case .image(let coordinate): artifact = coordinate.artifact
        case .function(let coordinate): artifact = coordinate.artifact
        }
        return manifest.artifacts.contains {
            $0.occurrenceID == artifact.occurrenceID
                && $0.contentIdentity == artifact.contentIdentity
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isCanonicalSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func canonicalCorpusManifestSHA256(
        _ manifest: ReconstructionCorpusManifest
    ) throws -> String {
        struct Preimage: Encodable {
            let schemaVersion: Int
            let reconstructionProjectID: UUID
            let artifacts: [ReconstructionArtifactOccurrenceRecord]
            let relations: [ReconstructionArtifactRelationRecord]
        }
        try Task.checkCancellation()
        let digest = try ReconstructionCanonicalJSON.sha256(of: Preimage(
            schemaVersion: manifest.schemaVersion,
            reconstructionProjectID: manifest.reconstructionProjectID,
            artifacts: manifest.artifacts,
            relations: manifest.relations
        ))
        try Task.checkCancellation()
        return digest
    }

    private static func canonicalProducerSHA256(
        _ producer: ReconstructionProducerIdentity
    ) throws -> String {
        try ReconstructionEvidenceIntegrity.canonicalProducerSHA256(producer)
    }

    private static func producerContainsOnlyDurableBoundedIdentity(
        _ producer: ReconstructionProducerIdentity
    ) -> Bool {
        ReconstructionEvidenceIntegrity.producerContainsOnlyDurableBoundedIdentity(producer)
    }
}
