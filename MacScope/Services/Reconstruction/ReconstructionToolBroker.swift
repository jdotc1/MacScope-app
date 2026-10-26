import CryptoKit
import Foundation

/// A demand selects an app-owned exact function; its acknowledgment never represents analysis
/// evidence. The durable planner schedules computation only after accepting the model selection.
enum ReconstructionMacScopeAnalysisDemand {
    static func enumerationTask(
        for function: ReconstructionFunctionCoordinate,
        tasks: [ReconstructionTaskRecord],
        evidenceCut: ReconstructionEvidenceCut
    ) throws -> ReconstructionTaskRecord {
        guard evidenceCut.records.contains(where: {
            $0.subject == .function(function)
                && $0.supersededByEvidenceID == nil
                && evidenceCut.projectedClassificationsByEvidenceID[$0.evidenceID]
                    == .acceptedCurrent
        }) else { throw ReconstructionToolBrokerError.invalidProjectorInput }
        let image = try ReconstructionImageCoordinate(artifact: function.artifact,
            image: function.image, analysisFingerprintSHA256: function.analysisFingerprintSHA256)
        let enumerations = tasks.filter {
            $0.identity.kind == .enumerateFunctions && $0.state == .completed
                && $0.identity.subject == .image(image)
        }
        guard enumerations.count == 1, let enumeration = enumerations.first else {
            throw ReconstructionToolBrokerError.invalidProjectorInput
        }
        return enumeration
    }

    static func acknowledgement(for request: ReconstructionToolRequestEnvelope) throws -> Data {
        guard request.operationID == .analysisMacScopeRefresh,
              let subject = request.subject, case .function = subject,
              request.retrievalQuery == nil,
              request.offset == 0, request.maximumRecords == 1 else {
            throw ReconstructionToolBrokerError.invalidProjectorInput
        }
        struct Acknowledgement: Encodable {
            let schemaVersion = 1
            let status = "scheduleAfterCommit"
            let authority: ReconstructionToolAuthorityCut
            let function: ReconstructionSubjectCoordinate
        }
        return try ReconstructionCanonicalJSON.encode(Acknowledgement(
            authority: request.authority, function: subject))
    }
}

enum ReconstructionToolProjectorFamily: String, CaseIterable, Hashable, Codable, Sendable {
    case corpus, imageFunction, decompiler, evidence, gaps, checkpoint
}

enum ReconstructionToolProjectionOutcome: String, Hashable, Codable, Sendable {
    case success, unavailable, stale, truncated, failed
}

struct ReconstructionProjectedEvidence: Hashable, Encodable, Sendable {
    private static let maximumPayloadBytes = 1_048_576
    private static let maximumCitations = 4_096
    private static let maximumFacets = 1_024
    private static let maximumLocatorBytes = 16_384
    private static let maximumFacetIdentityBytes = 1_024
    private static let maximumDiagnosticBytes = 1_024
    private static let maximumCanonicalBytes = 4_194_304

    let evidenceID: UUID
    let subject: ReconstructionSubjectCoordinate
    let operationID: ReconstructionOperationID
    let payloadKind: ReconstructionEvidencePayloadKind
    let payload: Data
    let facetDependencies: [ReconstructionFacetDependency]
    let citations: [ReconstructionEvidenceCitation]
    let supersedesEvidenceID: UUID?
    let diagnostic: ReconstructionDiagnostic?

    init(
        evidenceID: UUID,
        subject: ReconstructionSubjectCoordinate,
        operationID: ReconstructionOperationID,
        payloadKind: ReconstructionEvidencePayloadKind,
        payload: Data,
        facetDependencies: [ReconstructionFacetDependency],
        citations: [ReconstructionEvidenceCitation],
        supersedesEvidenceID: UUID?,
        diagnostic: ReconstructionDiagnostic?
    ) throws {
        guard payload.count <= Self.maximumPayloadBytes,
              citations.count <= Self.maximumCitations,
              facetDependencies.count <= Self.maximumFacets,
              citations.allSatisfy({
                  ($0.locator?.utf8.count ?? 0) <= Self.maximumLocatorBytes
              }),
              facetDependencies.allSatisfy({
                  $0.facetIdentity.utf8.count <= Self.maximumFacetIdentityBytes
              }),
              (diagnostic?.text.utf8.count ?? 0) <= Self.maximumDiagnosticBytes else {
            throw ReconstructionToolBrokerError.invalidProjectedEvidence
        }
        self.evidenceID = evidenceID
        self.subject = subject
        self.operationID = operationID
        self.payloadKind = payloadKind
        self.payload = payload
        self.facetDependencies = facetDependencies
        self.citations = citations
        self.supersedesEvidenceID = supersedesEvidenceID
        self.diagnostic = diagnostic
        guard try ReconstructionCanonicalJSON.encode(self).count <= Self.maximumCanonicalBytes else {
            throw ReconstructionToolBrokerError.invalidProjectedEvidence
        }
    }
}

struct ReconstructionSummaryDTO: Hashable, Encodable, Sendable {
    let schemaVersion = 1
    let artifactCount: Int
    let functionCount: Int
    let evidenceCount: Int
    init(artifactCount: Int, functionCount: Int, evidenceCount: Int) throws {
        guard artifactCount >= 0, functionCount >= 0, evidenceCount >= 0 else {
            throw ReconstructionToolBrokerError.invalidProjectedPayload
        }
        self.artifactCount = artifactCount
        self.functionCount = functionCount
        self.evidenceCount = evidenceCount
    }
}
struct ReconstructionProjectedRecordDTO: Hashable, Encodable, Sendable {
    let recordID: UUID
    let operationID: ReconstructionOperationID
    let byteCount: UInt64
    let canonicalSHA256: String
    init(
        recordID: UUID,
        operationID: ReconstructionOperationID,
        byteCount: UInt64,
        canonicalSHA256: String
    ) throws {
        guard ReconstructionToolAuthorityCut.isCanonicalSHA256(canonicalSHA256) else {
            throw ReconstructionToolBrokerError.invalidProjectedPayload
        }
        self.recordID = recordID
        self.operationID = operationID
        self.byteCount = byteCount
        self.canonicalSHA256 = canonicalSHA256
    }
}
struct ReconstructionPageDTO: Hashable, Encodable, Sendable {
    let schemaVersion = 1
    let records: [ReconstructionProjectedRecordDTO]
    let totalCount: Int
    init(records: [ReconstructionProjectedRecordDTO], totalCount: Int) throws {
        guard records.count <= 4_096,
              Set(records.map(\.recordID)).count == records.count,
              totalCount >= records.count else {
            throw ReconstructionToolBrokerError.invalidProjectedPayload
        }
        self.records = records
        self.totalCount = totalCount
    }
}
struct ReconstructionDetailDTO: Hashable, Encodable, Sendable {
    let schemaVersion = 1
    let subject: ReconstructionDurableSubject
    let operationID: ReconstructionOperationID
    let canonicalSHA256: String
    let byteCount: UInt64
    init(
        subject: ReconstructionDurableSubject,
        operationID: ReconstructionOperationID,
        canonicalSHA256: String,
        byteCount: UInt64
    ) throws {
        guard ReconstructionToolAuthorityCut.isCanonicalSHA256(canonicalSHA256) else {
            throw ReconstructionToolBrokerError.invalidProjectedPayload
        }
        self.subject = subject
        self.operationID = operationID
        self.canonicalSHA256 = canonicalSHA256
        self.byteCount = byteCount
    }
}
struct ReconstructionDecompilerDTO: Hashable, Encodable, Sendable {
    let schemaVersion = 1
    let pseudocode: String
    init(pseudocode: String) throws {
        guard !pseudocode.isEmpty, pseudocode.utf8.count <= 1_048_576,
              !pseudocode.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw ReconstructionToolBrokerError.invalidProjectedPayload
        }
        self.pseudocode = pseudocode
    }
}
struct ReconstructionEvidenceReadDTO: Hashable, Encodable, Sendable {
    let schemaVersion = 1
    let evidenceIDs: [UUID]
    let frontierSHA256: String
    init(evidenceIDs: [UUID], frontierSHA256: String) throws {
        guard evidenceIDs.count <= 4_096,
              Set(evidenceIDs).count == evidenceIDs.count,
              ReconstructionToolAuthorityCut.isCanonicalSHA256(frontierSHA256) else {
            throw ReconstructionToolBrokerError.invalidProjectedPayload
        }
        self.evidenceIDs = evidenceIDs.sorted { $0.uuidString < $1.uuidString }
        self.frontierSHA256 = frontierSHA256
    }
}
enum ReconstructionCheckpointProjectionState: String, Hashable, Encodable, Sendable {
    case pending, running, completed, failed, blocked, cancelled
}
struct ReconstructionStatusDTO: Hashable, Encodable, Sendable {
    let schemaVersion = 1
    let state: ReconstructionCheckpointProjectionState
    let checkpointRevision: UInt64
}

enum ReconstructionProjectedPayload: Hashable, Encodable, Sendable {
    case corpusSummary(ReconstructionSummaryDTO)
    case corpusArtifactsPage(ReconstructionPageDTO)
    case corpusArtifactDescribe(ReconstructionDetailDTO)
    case corpusRelationsPage(ReconstructionPageDTO)
    case corpusSearch(ReconstructionPageDTO)
    case imagesPage(ReconstructionPageDTO)
    case functionsPage(ReconstructionPageDTO)
    case functionReview(ReconstructionDetailDTO)
    case decompilerNative(ReconstructionDecompilerDTO)
    case decompilerMacScope(ReconstructionDecompilerDTO)
    case decompilerCompare(ReconstructionDecompilerDTO)
    case evidenceQuery(ReconstructionEvidenceReadDTO)
    case evidenceGet(ReconstructionEvidenceReadDTO)
    case gapsPage(ReconstructionPageDTO)
    case checkpointStatus(ReconstructionStatusDTO)

    var operationID: ReconstructionOperationID {
        switch self {
        case .corpusSummary: .corpusSummary
        case .corpusArtifactsPage: .corpusArtifactsPage
        case .corpusArtifactDescribe: .corpusArtifactDescribe
        case .corpusRelationsPage: .corpusRelationsPage
        case .corpusSearch: .corpusSearch
        case .imagesPage: .imagesPage
        case .functionsPage: .functionsPage
        case .functionReview: .functionReview
        case .decompilerNative: .decompilerNative
        case .decompilerMacScope: .decompilerMacScope
        case .decompilerCompare: .decompilerCompare
        case .evidenceQuery: .evidenceQuery
        case .evidenceGet: .evidenceGet
        case .gapsPage: .gapsPage
        case .checkpointStatus: .checkpointStatus
        }
    }

    var semanticRecordCount: Int {
        switch self {
        case .corpusArtifactsPage(let value), .corpusRelationsPage(let value),
             .corpusSearch(let value), .imagesPage(let value), .functionsPage(let value),
             .gapsPage(let value):
            return value.records.count
        case .evidenceQuery(let value), .evidenceGet(let value):
            return value.evidenceIDs.count
        case .corpusSummary, .corpusArtifactDescribe, .functionReview,
             .decompilerNative, .decompilerMacScope, .decompilerCompare,
             .checkpointStatus:
            return 1
        }
    }

    var canonicalBytes: Data {
        get throws { try ReconstructionCanonicalJSON.encode(self) }
    }

    var isStructurallyBound: Bool {
        switch self {
        case .corpusArtifactsPage(let value), .corpusRelationsPage(let value),
             .corpusSearch(let value), .imagesPage(let value), .functionsPage(let value),
             .gapsPage(let value):
            return value.records.allSatisfy { $0.operationID == operationID }
        case .corpusArtifactDescribe(let value), .functionReview(let value):
            return value.operationID == operationID
        default: return true
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .corpusSummary(let value): try value.encode(to: encoder)
        case .corpusArtifactsPage(let value), .corpusRelationsPage(let value),
             .corpusSearch(let value), .imagesPage(let value), .functionsPage(let value),
             .gapsPage(let value): try value.encode(to: encoder)
        case .corpusArtifactDescribe(let value), .functionReview(let value):
            try value.encode(to: encoder)
        case .decompilerNative(let value), .decompilerMacScope(let value),
             .decompilerCompare(let value): try value.encode(to: encoder)
        case .evidenceQuery(let value), .evidenceGet(let value): try value.encode(to: encoder)
        case .checkpointStatus(let value): try value.encode(to: encoder)
        }
    }
}

/// App-owned, constructor-validated projection material. It is intentionally not Decodable:
/// untrusted or persisted JSON cannot bypass the validating initializer and become a read item.
struct ReconstructionProjectedReadItem: Hashable, Encodable, Sendable {
    let operationID: ReconstructionOperationID
    let payload: ReconstructionProjectedPayload
    let canonicalPayload: Data
    let evidence: ReconstructionProjectedEvidence?

    init(
        payload: ReconstructionProjectedPayload,
        evidence: ReconstructionProjectedEvidence? = nil
    ) throws {
        guard payload.isStructurallyBound,
              evidence?.operationID == nil || evidence?.operationID == payload.operationID else {
            throw ReconstructionToolBrokerError.invalidProjectedReadItem
        }
        self.operationID = payload.operationID
        self.payload = payload
        self.canonicalPayload = try payload.canonicalBytes
        self.evidence = evidence
    }
}

struct ReconstructionToolProjectionResult: Hashable, Sendable {
    let outcome: ReconstructionToolProjectionOutcome
    let payload: Data
    let payloadSHA256: String
    let itemCount: Int
    let diagnostic: ReconstructionDiagnostic?
    let continuationRequest: ReconstructionToolRequest?
    let evidenceCandidates: [ReconstructionEvidenceCandidate]

    init(
        outcome: ReconstructionToolProjectionOutcome,
        payload: Data,
        payloadSHA256: String,
        itemCount: Int,
        diagnostic: ReconstructionDiagnostic?,
        continuationRequest: ReconstructionToolRequest?,
        evidenceCandidates: [ReconstructionEvidenceCandidate] = []
    ) {
        self.outcome = outcome
        self.payload = payload
        self.payloadSHA256 = payloadSHA256
        self.itemCount = itemCount
        self.diagnostic = diagnostic
        self.continuationRequest = continuationRequest
        self.evidenceCandidates = evidenceCandidates
    }

    static func success(
        payload: Data,
        count: Int,
        evidenceCandidates: [ReconstructionEvidenceCandidate] = []
    ) -> Self {
        make(
            outcome: .success,
            payload: payload,
            count: count,
            evidenceCandidates: evidenceCandidates
        )
    }

    static func unavailable(_ diagnostic: String) -> Self {
        make(outcome: .unavailable, diagnostic: diagnostic)
    }

    static func stale(_ diagnostic: String) -> Self {
        make(outcome: .stale, diagnostic: diagnostic)
    }

    static func failed(_ diagnostic: String) -> Self {
        make(outcome: .failed, diagnostic: diagnostic)
    }

    static func truncated(
        payload: Data,
        count: Int,
        continuationRequest: ReconstructionToolRequest,
        evidenceCandidates: [ReconstructionEvidenceCandidate] = []
    ) -> Self {
        make(
            outcome: .truncated,
            payload: payload,
            count: count,
            continuationRequest: continuationRequest,
            evidenceCandidates: evidenceCandidates
        )
    }

    private static func make(
        outcome: ReconstructionToolProjectionOutcome,
        payload: Data = Data("[]".utf8),
        count: Int = 0,
        diagnostic: String? = nil,
        continuationRequest: ReconstructionToolRequest? = nil,
        evidenceCandidates: [ReconstructionEvidenceCandidate] = []
    ) -> Self {
        .init(
            outcome: outcome,
            payload: payload,
            payloadSHA256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
            itemCount: count,
            diagnostic: diagnostic.map { ReconstructionDiagnostic.sanitizing($0) },
            continuationRequest: continuationRequest,
            evidenceCandidates: evidenceCandidates
        )
    }
}

struct ReconstructionToolProjectorInput: Sendable {
    private static let maximumProjectedItems = 100_000
    private static let maximumProjectedItemBytes = 1_048_576
    private static let maximumProjectedBytes = 4_194_304
    private static let maximumAuthorityRecords = 100_000

    let authority: ReconstructionToolAuthorityCut
    let corpusManifest: ReconstructionCorpusManifest
    let evidenceCut: ReconstructionEvidenceCut
    let tasks: [ReconstructionTaskRecord]
    let receipts: [ReconstructionToolReceipt]
    let producersByOperation: [ReconstructionOperationID: ReconstructionProducerIdentity]
    let projectedItemsByOperation: [ReconstructionOperationID: [ReconstructionProjectedReadItem]]
    let staleOperations: Set<ReconstructionOperationID>
    let evidenceAuthorityCutsByOperation: [ReconstructionOperationID: ReconstructionAuthorityCut]

    var canonicalItemsByOperation: [ReconstructionOperationID: [Data]] {
        projectedItemsByOperation.mapValues { $0.map(\.canonicalPayload) }
    }

    init(
        authority: ReconstructionToolAuthorityCut,
        corpusManifest: ReconstructionCorpusManifest,
        evidenceCut: ReconstructionEvidenceCut,
        tasks: [ReconstructionTaskRecord],
        receipts: [ReconstructionToolReceipt],
        producersByOperation: [ReconstructionOperationID: ReconstructionProducerIdentity],
        projectedItemsByOperation: [ReconstructionOperationID: [ReconstructionProjectedReadItem]],
        staleOperations: Set<ReconstructionOperationID>,
        evidenceAuthorityCutsByOperation: [ReconstructionOperationID: ReconstructionAuthorityCut]
    ) throws {
        guard authority.corpusManifestSHA256 == corpusManifest.canonicalSHA256,
              authority.corpusManifestSHA256 == evidenceCut.corpusManifestSHA256,
              authority.evidenceFrontierSHA256 == evidenceCut.frontierSHA256 else {
            throw ReconstructionToolBrokerError.staleCorpus
        }
        guard authority.projectionFrontierSHA256 == (try Self.canonicalProjectionFrontierSHA256(
                  projectedItemsByOperation: projectedItemsByOperation,
                  staleOperations: staleOperations,
                  tasks: tasks,
                  receipts: receipts,
                  producersByOperation: producersByOperation,
                  evidenceAuthorityCutsByOperation: evidenceAuthorityCutsByOperation
              )) else {
            throw ReconstructionToolBrokerError.staleProjection
        }
        guard try ReconstructionCorpusCanonicalizer.canonicalSHA256(of: corpusManifest)
                == corpusManifest.canonicalSHA256 else {
            throw ReconstructionToolBrokerError.invalidCorpusManifest
        }
        guard producersByOperation.count <= ReconstructionOperationID.allCases.count,
              evidenceAuthorityCutsByOperation.count <= ReconstructionOperationID.allCases.count,
              tasks.count <= Self.maximumAuthorityRecords,
              receipts.count <= Self.maximumAuthorityRecords,
              evidenceCut.records.count <= Self.maximumAuthorityRecords,
              evidenceCut.relations.count <= Self.maximumAuthorityRecords,
              evidenceCut.gaps.count <= Self.maximumAuthorityRecords else {
            throw ReconstructionToolBrokerError.invalidProjectorInput
        }
        for (operation, producer) in producersByOperation {
            guard producer.operationIdentity == operation.rawValue,
                  ReconstructionEvidenceIntegrity
                    .producerContainsOnlyDurableBoundedIdentity(producer),
                  try ReconstructionEvidenceIntegrity.canonicalProducerSHA256(producer)
                    == producer.canonicalSHA256 else {
                throw ReconstructionToolBrokerError.invalidProducer
            }
        }
        var authoritySubjectCount = 0
        var authorityFacetCount = 0
        for (operation, cut) in evidenceAuthorityCutsByOperation {
            guard cut.operationID == operation,
                  cut.corpusManifest == corpusManifest,
                  cut.creatingJobID == authority.jobID,
                  cut.checkpointRevision == authority.checkpointRevision,
                  cut.producer == producersByOperation[operation],
                  cut.evidence == evidenceCut.records,
                  cut.authoritativeSubjects.count
                    <= Self.maximumAuthorityRecords - authoritySubjectCount,
                  cut.facetFingerprints.count
                    <= Self.maximumAuthorityRecords - authorityFacetCount else {
                throw ReconstructionToolBrokerError.invalidEvidenceAuthorityCut
            }
            authoritySubjectCount += cut.authoritativeSubjects.count
            authorityFacetCount += cut.facetFingerprints.count
        }
        var totalItemCount = 0
        var totalByteCount = 0
        for (operation, items) in projectedItemsByOperation {
            guard items.count <= Self.maximumProjectedItems - totalItemCount else {
                throw ReconstructionToolBrokerError.invalidProjectorInput
            }
            totalItemCount += items.count
            for item in items {
                guard item.operationID == operation,
                      item.evidence?.operationID == nil
                        || item.evidence?.operationID == operation,
                      item.canonicalPayload.count <= Self.maximumProjectedItemBytes,
                      item.canonicalPayload.count <= Self.maximumProjectedBytes - totalByteCount else {
                    throw ReconstructionToolBrokerError.invalidProjectorInput
                }
                do {
                    _ = try ReconstructionProjectedReadItem(
                        payload: item.payload,
                        evidence: item.evidence
                    )
                } catch {
                    throw ReconstructionToolBrokerError.invalidProjectedReadItem
                }
                totalByteCount += item.canonicalPayload.count
            }
        }
        self.authority = authority
        self.corpusManifest = corpusManifest
        self.evidenceCut = evidenceCut
        self.tasks = tasks
        self.receipts = receipts
        self.producersByOperation = producersByOperation
        self.projectedItemsByOperation = projectedItemsByOperation
        self.staleOperations = staleOperations
        self.evidenceAuthorityCutsByOperation = evidenceAuthorityCutsByOperation
    }

    static func canonicalProjectionFrontierSHA256(
        projectedItemsByOperation: [ReconstructionOperationID: [ReconstructionProjectedReadItem]],
        staleOperations: Set<ReconstructionOperationID>,
        tasks: [ReconstructionTaskRecord],
        receipts: [ReconstructionToolReceipt],
        producersByOperation: [ReconstructionOperationID: ReconstructionProducerIdentity],
        evidenceAuthorityCutsByOperation: [ReconstructionOperationID: ReconstructionAuthorityCut]
    ) throws -> String {
        struct OperationItems: Encodable {
            let operationID: ReconstructionOperationID
            let items: [ItemSummary]
        }
        struct ItemSummary: Encodable {
            let operationID: ReconstructionOperationID
            let payloadSHA256: String
            let payloadByteCount: Int
            let evidenceID: UUID?
            let evidenceSHA256: String?
        }
        struct Preimage: Encodable {
            let schemaVersion: Int
            let domain: String
            let operations: [OperationItems]
            let staleOperations: [ReconstructionOperationID]
            let tasks: [ReconstructionTaskRecord]
            let receipts: [ReconstructionToolReceipt]
            let producers: [OperationProducer]
            let authorityCuts: [AuthorityCutSummary]
        }
        struct OperationProducer: Encodable {
            let operationID: ReconstructionOperationID
            let producer: ReconstructionProducerIdentity
        }
        struct AuthorityCutSummary: Encodable {
            let operationID: ReconstructionOperationID
            let authoritativeSubjects: [ReconstructionSubjectCoordinate]
            let facetFingerprints: [String: String]
            let creatingJobID: UUID
            let creatingTaskID: UUID
            let creatingCheckpointID: UUID
            let checkpointRevision: UInt64
            let modelReceiptID: UUID?
            let producer: ReconstructionProducerIdentity
            let evidenceFrontierMarker: String
            let evidenceRecordCount: Int
            // toolReceiptID is deliberately absent: it is the handle derived from this
            // frontier and is checked for exact equality during broker preflight.
        }
        guard tasks.count <= Self.maximumAuthorityRecords,
              receipts.count <= Self.maximumAuthorityRecords,
              producersByOperation.count <= ReconstructionOperationID.allCases.count,
              evidenceAuthorityCutsByOperation.count <= ReconstructionOperationID.allCases.count
        else { throw ReconstructionToolBrokerError.invalidProjectorInput }
        guard Set(tasks.map { $0.identity.taskID }).count == tasks.count else {
            throw ReconstructionToolBrokerError.duplicateTask
        }
        guard Set(receipts.map(\.receiptID)).count == receipts.count else {
            throw ReconstructionToolBrokerError.duplicateReceipt
        }
        var authorityBytes = 0
        func account<T: Encodable>(_ value: T) throws {
            let bytes = try ReconstructionCanonicalJSON.encode(value).count
            let (next, overflow) = authorityBytes.addingReportingOverflow(bytes)
            guard !overflow, next <= Self.maximumProjectedBytes else {
                throw ReconstructionToolBrokerError.invalidProjectorInput
            }
            authorityBytes = next
        }
        func producerWithinBounds(_ producer: ReconstructionProducerIdentity) -> Bool {
            let strings = [
                producer.macScopeBuildIdentity, producer.macScopeSourceIdentity,
                producer.operationIdentity, producer.registryIdentity, producer.protocolIdentity,
                producer.nativeProviderIdentity, producer.modelKey, producer.endpointOrigin,
                producer.toolchainIdentity,
            ].compactMap { $0 }
            return producer.nativeCapabilityIdentities.count <= 1_024
                && strings.allSatisfy { $0.utf8.count <= 16_384 }
                && producer.nativeCapabilityIdentities.allSatisfy { $0.utf8.count <= 1_024 }
                && ReconstructionEvidenceIntegrity
                    .producerContainsOnlyDurableBoundedIdentity(producer)
        }
        for (index, task) in tasks.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            guard task.identity.dependencyTaskIDs.count <= 4_096,
                  task.identity.operationContractIdentity.utf8.count <= 1_024,
                  (task.diagnostic?.text.utf8.count ?? 0) <= 1_024 else {
                throw ReconstructionToolBrokerError.invalidProjectorInput
            }
            if let subject = task.identity.subject {
                guard try ReconstructionCanonicalJSON.encode(subject).count <= 16_384 else {
                    throw ReconstructionToolBrokerError.invalidProjectorInput
                }
            }
            try account(task)
        }
        for (index, receipt) in receipts.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            guard receipt.outputEvidenceIDs.count <= 4_096,
                  (receipt.diagnostic?.text.utf8.count ?? 0) <= 1_024,
                  producerWithinBounds(receipt.producer) else {
                throw ReconstructionToolBrokerError.invalidProjectorInput
            }
            try account(receipt)
        }
        for (index, producer) in producersByOperation.values.enumerated() {
            if index.isMultiple(of: 16) { try Task.checkCancellation() }
            guard producerWithinBounds(producer) else {
                throw ReconstructionToolBrokerError.invalidProducer
            }
            try account(producer)
        }
        var authoritySubjectCount = 0
        var authorityFacetCount = 0
        for (index, cut) in evidenceAuthorityCutsByOperation.values.enumerated() {
            if index.isMultiple(of: 16) { try Task.checkCancellation() }
            guard cut.authoritativeSubjects.count
                    <= Self.maximumAuthorityRecords - authoritySubjectCount,
                  cut.facetFingerprints.count
                    <= Self.maximumAuthorityRecords - authorityFacetCount,
                  cut.facetFingerprints.allSatisfy({ key, value in
                      key.utf8.count <= 1_024 && value.utf8.count <= 16_384
                  }) else {
                throw ReconstructionToolBrokerError.invalidEvidenceAuthorityCut
            }
            for subject in cut.authoritativeSubjects {
                guard try ReconstructionCanonicalJSON.encode(subject).count <= 16_384 else {
                    throw ReconstructionToolBrokerError.invalidEvidenceAuthorityCut
                }
            }
            try account(cut.authoritativeSubjects)
            try account(cut.facetFingerprints)
            authoritySubjectCount += cut.authoritativeSubjects.count
            authorityFacetCount += cut.facetFingerprints.count
        }
        var itemCount = 0
        var projectedBytes = 0
        for (operation, items) in projectedItemsByOperation {
            guard items.count <= Self.maximumProjectedItems - itemCount else {
                throw ReconstructionToolBrokerError.invalidProjectorInput
            }
            itemCount += items.count
            for (index, item) in items.enumerated() {
                if index.isMultiple(of: 64) { try Task.checkCancellation() }
                guard item.operationID == operation,
                      item.canonicalPayload.count <= Self.maximumProjectedItemBytes,
                      item.canonicalPayload.count <= Self.maximumProjectedBytes - projectedBytes
                else { throw ReconstructionToolBrokerError.invalidProjectorInput }
                projectedBytes += item.canonicalPayload.count
                if let evidence = item.evidence {
                    let evidenceBytes = try ReconstructionCanonicalJSON.encode(evidence).count
                    guard evidenceBytes <= Self.maximumProjectedBytes - projectedBytes else {
                        throw ReconstructionToolBrokerError.invalidProjectedEvidence
                    }
                    projectedBytes += evidenceBytes
                }
            }
        }
        let operations = try projectedItemsByOperation.map { operation, items in
            let summaries = try items.map { item -> ItemSummary in
                let evidenceDigest = try item.evidence.map {
                    try ReconstructionCanonicalJSON.sha256(of: $0)
                }
                return ItemSummary(
                    operationID: item.operationID,
                    payloadSHA256: Self.sha256(item.canonicalPayload),
                    payloadByteCount: item.canonicalPayload.count,
                    evidenceID: item.evidence?.evidenceID,
                    evidenceSHA256: evidenceDigest
                )
            }
            return OperationItems(operationID: operation, items: summaries)
        }.sorted {
            if $0.operationID.priority != $1.operationID.priority {
                return $0.operationID.priority < $1.operationID.priority
            }
            return $0.operationID.rawValue < $1.operationID.rawValue
        }
        let producers = producersByOperation.map {
            OperationProducer(operationID: $0.key, producer: $0.value)
        }.sorted { $0.operationID.priority < $1.operationID.priority }
        let unsortedCuts: [AuthorityCutSummary] = try evidenceAuthorityCutsByOperation.map { operation, cut in
            let subjects = try cut.authoritativeSubjects.map {
                ($0, try ReconstructionCanonicalJSON.encode($0))
            }.sorted { $0.1.lexicographicallyPrecedes($1.1) }.map(\.0)
            return AuthorityCutSummary(
                operationID: operation,
                authoritativeSubjects: subjects,
                facetFingerprints: cut.facetFingerprints,
                creatingJobID: cut.creatingJobID,
                creatingTaskID: cut.creatingTaskID,
                creatingCheckpointID: cut.creatingCheckpointID,
                checkpointRevision: cut.checkpointRevision,
                modelReceiptID: cut.modelReceiptID,
                producer: cut.producer,
                evidenceFrontierMarker: "bound-by-evidence-frontier.v1",
                evidenceRecordCount: cut.evidence.count
            )
        }
        let cuts = unsortedCuts.sorted(by: {
            $0.operationID.priority < $1.operationID.priority
        })
        let preimage = Preimage(
            schemaVersion: 1,
            domain: "reconstruction.projection-frontier.v1",
            operations: operations,
            staleOperations: staleOperations.sorted {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return $0.rawValue < $1.rawValue
            },
            tasks: tasks.sorted { $0.identity.taskID.uuidString < $1.identity.taskID.uuidString },
            receipts: receipts.sorted { $0.receiptID.uuidString < $1.receiptID.uuidString },
            producers: producers,
            authorityCuts: cuts
        )
        let preimageBytes = try ReconstructionCanonicalJSON.encode(preimage)
        guard preimageBytes.count <= Self.maximumProjectedBytes else {
            throw ReconstructionToolBrokerError.invalidProjectorInput
        }
        return Self.sha256(preimageBytes)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

}

protocol ReconstructionToolProjecting: Sendable {
    var family: ReconstructionToolProjectorFamily { get }
    var operations: Set<ReconstructionOperationID> { get }

    func project(
        request: ReconstructionToolRequestEnvelope,
        input: ReconstructionToolProjectorInput
    ) async throws -> ReconstructionToolProjectionResult
}

struct ReconstructionToolExecution: Hashable, Sendable {
    let handleID: UUID
    let operationID: ReconstructionOperationID
    let result: ReconstructionToolProjectionResult
    let acceptedEvidence: [ReconstructionEvidenceRecord]
    let receipt: ReconstructionToolReceipt
    let resolvedGapIDs: [UUID]

    init(
        handleID: UUID,
        operationID: ReconstructionOperationID,
        result: ReconstructionToolProjectionResult,
        acceptedEvidence: [ReconstructionEvidenceRecord],
        receipt: ReconstructionToolReceipt,
        resolvedGapIDs: [UUID] = []
    ) {
        self.handleID = handleID
        self.operationID = operationID
        self.result = result
        self.acceptedEvidence = acceptedEvidence
        self.receipt = receipt
        self.resolvedGapIDs = ReconstructionValidation.sortedUUIDs(resolvedGapIDs)
    }
}

enum ReconstructionToolBrokerError: Error, Equatable, Sendable {
    case unknownHandle
    case duplicateHandle
    case nonCanonicalRequest
    case invalidRequestDigest
    case staleCorpus
    case staleEvidence
    case crossJob
    case crossCheckpoint
    case crossRound
    case duplicateOperation
    case operationMismatch
    case invalidHandleIdentity
    case invalidProjectorRoute
    case invalidProducer
    case invalidProjectorInput
    case invalidCorpusManifest
    case invalidEvidenceAuthorityCut
    case invalidSelectionBounds
    case unknownTask
    case duplicateTask
    case crossJobTask
    case taskOperationMismatch
    case taskSubjectMismatch
    case invalidProjectedReadItem
    case invalidProjectedPayload
    case invalidProjectedEvidence
    case staleProjection
    case invalidTaskState
    case invalidTaskKind
    case duplicateReceipt
    case invalidReceipt
    case alreadyTerminal
    case duplicateEvidenceID
    case conflictingSupersession
    case evidenceBudgetExceeded
    case invalidEvidenceCursor
}

struct ReconstructionToolBroker: Sendable {
    private static let maximumSelectedHandles = ReconstructionOperationID.allCases.count
    private static let maximumCandidateCitations = 4_096
    private static let maximumCandidateFacets = 1_024
    private static let maximumCandidatesPerResult = 16
    private static let maximumCandidatesPerExecution = 240
    private static let maximumResolvedGaps = 64
    private let projectors: [any ReconstructionToolProjecting]
    private let evidenceAcceptor: any ReconstructionEvidenceAccepting
    private let registry = ReconstructionToolRegistry()

    init(
        projectors: [any ReconstructionToolProjecting],
        evidenceAcceptor: any ReconstructionEvidenceAccepting = ReconstructionEvidenceAcceptor(
            maximumPayloadBytes: 1_048_576,
            maximumDiagnosticUTF8Bytes: 1_024
        )
    ) {
        self.projectors = projectors
        self.evidenceAcceptor = evidenceAcceptor
    }

    func execute(
        selectedHandleIDs: [UUID],
        offeredHandles: [ReconstructionToolHandle],
        input: ReconstructionToolProjectorInput,
        resolvedGapIDsByHandleID: [UUID: [UUID]] = [:]
    ) async throws -> [ReconstructionToolExecution] {
        var resolvedGapCount = 0
        var resolvedGapIDs: Set<UUID> = []
        for values in resolvedGapIDsByHandleID.values {
            guard values.count <= Self.maximumResolvedGaps - resolvedGapCount,
                  Set(values).count == values.count else {
                throw ReconstructionToolBrokerError.invalidSelectionBounds
            }
            resolvedGapCount += values.count
            resolvedGapIDs.formUnion(values)
        }
        guard selectedHandleIDs.count <= Self.maximumSelectedHandles,
              offeredHandles.count <= Self.maximumSelectedHandles,
              Set(resolvedGapIDsByHandleID.keys).isSubset(of: Set(selectedHandleIDs)),
              resolvedGapIDs.count == resolvedGapCount else {
            throw ReconstructionToolBrokerError.invalidSelectionBounds
        }
        guard !selectedHandleIDs.isEmpty else { return [] }
        try Task.checkCancellation()
        guard Set(selectedHandleIDs).count == selectedHandleIDs.count else {
            throw ReconstructionToolBrokerError.duplicateHandle
        }
        var offeredByID: [UUID: ReconstructionToolHandle] = [:]
        for (index, handle) in offeredHandles.enumerated() {
            if index.isMultiple(of: 16) { try Task.checkCancellation() }
            guard offeredByID.updateValue(handle, forKey: handle.handleID) == nil else {
                throw ReconstructionToolBrokerError.duplicateHandle
            }
        }
        var tasksByID: [UUID: ReconstructionTaskRecord] = [:]
        tasksByID.reserveCapacity(input.tasks.count)
        for (index, task) in input.tasks.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard tasksByID.updateValue(task, forKey: task.identity.taskID) == nil else {
                throw ReconstructionToolBrokerError.duplicateTask
            }
        }
        var receiptsByID: [UUID: ReconstructionToolReceipt] = [:]
        var evidenceRecordsByID: [UUID: ReconstructionEvidenceRecord] = [:]
        evidenceRecordsByID.reserveCapacity(input.evidenceCut.records.count)
        for (index, record) in input.evidenceCut.records.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard evidenceRecordsByID.updateValue(record, forKey: record.evidenceID) == nil else {
                throw ReconstructionToolBrokerError.invalidProjectorInput
            }
        }
        for (index, receipt) in input.receipts.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard receiptsByID.updateValue(receipt, forKey: receipt.receiptID) == nil else {
                throw ReconstructionToolBrokerError.duplicateReceipt
            }
            guard try receiptIsAuthentic(
                receipt,
                evidenceRecordsByID: evidenceRecordsByID,
                input: input
            ) else {
                throw ReconstructionToolBrokerError.invalidReceipt
            }
        }

        var selected: [(
            ReconstructionToolHandle,
            ReconstructionToolRequestEnvelope,
            any ReconstructionToolProjecting,
            ReconstructionProducerIdentity
        )] = []
        var operations: Set<ReconstructionOperationID> = []
        for (index, handleID) in selectedHandleIDs.enumerated() {
            if index.isMultiple(of: 16) { try Task.checkCancellation() }
            guard let handle = offeredByID[handleID] else {
                throw ReconstructionToolBrokerError.unknownHandle
            }
            guard operations.insert(handle.operationID).inserted else {
                throw ReconstructionToolBrokerError.duplicateOperation
            }
            guard handle.jobID == input.authority.jobID else {
                throw ReconstructionToolBrokerError.crossJob
            }
            guard handle.checkpointRevision == input.authority.checkpointRevision else {
                throw ReconstructionToolBrokerError.crossCheckpoint
            }
            guard handle.roundID == input.authority.roundID else {
                throw ReconstructionToolBrokerError.crossRound
            }
            let envelope: ReconstructionToolRequestEnvelope
            do {
                envelope = try registry.decodeCanonicalRequest(handle)
            } catch let error as ReconstructionToolRegistryError {
                switch error {
                case .nonCanonicalRequest:
                    throw ReconstructionToolBrokerError.nonCanonicalRequest
                case .invalidRequestDigest:
                    throw ReconstructionToolBrokerError.invalidRequestDigest
                case .requestOperationMismatch:
                    throw ReconstructionToolBrokerError.operationMismatch
                case .invalidHandleIdentity:
                    throw ReconstructionToolBrokerError.invalidHandleIdentity
                case .authorityMismatch:
                    if handle.jobID != input.authority.jobID {
                        throw ReconstructionToolBrokerError.crossJob
                    }
                    if handle.checkpointRevision != input.authority.checkpointRevision {
                        throw ReconstructionToolBrokerError.crossCheckpoint
                    }
                    throw ReconstructionToolBrokerError.crossRound
                default:
                    throw ReconstructionToolBrokerError.nonCanonicalRequest
                }
            }
            guard envelope.authority.corpusManifestSHA256
                    == input.authority.corpusManifestSHA256 else {
                throw ReconstructionToolBrokerError.staleCorpus
            }
            guard envelope.authority.evidenceFrontierSHA256
                    == input.authority.evidenceFrontierSHA256 else {
                throw ReconstructionToolBrokerError.staleEvidence
            }
            guard envelope.authority.projectionFrontierSHA256
                    == input.authority.projectionFrontierSHA256 else {
                throw ReconstructionToolBrokerError.staleProjection
            }
            if let query = envelope.retrievalQuery, let cursor = query.cursor {
                guard try cursorMatchesEvidenceCut(
                    cursor,
                    query: query,
                    evidenceRecordsByID: evidenceRecordsByID,
                    input: input
                ) else {
                    throw ReconstructionToolBrokerError.invalidEvidenceCursor
                }
            }
            if let receipt = receiptsByID[handle.handleID] {
                guard receipt.jobID == input.authority.jobID,
                      receipt.taskID == envelope.taskID,
                      receipt.checkpointRevision == input.authority.checkpointRevision,
                      receipt.requestIdentitySHA256 == handle.requestSHA256,
                      receipt.producer == input.producersByOperation[handle.operationID] else {
                    throw ReconstructionToolBrokerError.invalidReceipt
                }
                throw ReconstructionToolBrokerError.alreadyTerminal
            }
            guard let task = tasksByID[envelope.taskID] else {
                throw ReconstructionToolBrokerError.unknownTask
            }
            guard task.identity.jobID == input.authority.jobID else {
                throw ReconstructionToolBrokerError.crossJobTask
            }
            let isAnalysisDemand = handle.operationID == .analysisMacScopeRefresh
            guard task.identity.operationContractIdentity == handle.operationID.rawValue
                || (isAnalysisDemand && task.identity.operationContractIdentity
                    == ReconstructionOperationID.evidenceQuery.rawValue) else {
                throw ReconstructionToolBrokerError.taskOperationMismatch
            }
            guard task.identity.subject == envelope.subject
                || (isAnalysisDemand && task.identity.subject == nil) else {
                throw ReconstructionToolBrokerError.taskSubjectMismatch
            }
            guard task.identity.kind == .retrieveEvidence else {
                throw ReconstructionToolBrokerError.invalidTaskKind
            }
            guard task.state == .running else {
                throw ReconstructionToolBrokerError.invalidTaskState
            }
            if isAnalysisDemand {
                guard case .function(let function)? = envelope.subject else {
                    throw ReconstructionToolBrokerError.taskSubjectMismatch
                }
                _ = try ReconstructionMacScopeAnalysisDemand.enumerationTask(
                    for: function, tasks: input.tasks, evidenceCut: input.evidenceCut)
            }
            guard let producer = input.producersByOperation[handle.operationID] else {
                throw ReconstructionToolBrokerError.invalidProducer
            }
            if let cut = input.evidenceAuthorityCutsByOperation[handle.operationID] {
                guard cut.creatingTaskID == envelope.taskID,
                      cut.toolReceiptID == handle.handleID,
                      cut.modelReceiptID == nil,
                      cut.evidence == input.evidenceCut.records,
                      cut.producer == producer else {
                    throw ReconstructionToolBrokerError.invalidEvidenceAuthorityCut
                }
            }
            let matchingProjectors = projectors.filter {
                $0.operations.contains(handle.operationID)
            }
            guard matchingProjectors.count == 1, let projector = matchingProjectors.first else {
                throw ReconstructionToolBrokerError.invalidProjectorRoute
            }
            selected.append((handle, envelope, projector, producer))
        }
        selected.sort {
            if $0.0.operationID.priority != $1.0.operationID.priority {
                return $0.0.operationID.priority < $1.0.operationID.priority
            }
            if $0.0.operationID.rawValue != $1.0.operationID.rawValue {
                return $0.0.operationID.rawValue < $1.0.operationID.rawValue
            }
            return $0.0.handleID.uuidString < $1.0.handleID.uuidString
        }

        var projected: [(ReconstructionToolHandle, ReconstructionToolRequestEnvelope,
                         ReconstructionProducerIdentity, ReconstructionToolProjectionResult)] = []
        projected.reserveCapacity(selected.count)
        for (handle, envelope, projector, producer) in selected {
            try Task.checkCancellation()
            var result: ReconstructionToolProjectionResult
            do {
                result = try await projector.project(request: envelope, input: input)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result = .failed("Read projector failed.")
            }
            try Task.checkCancellation()
            if try !validate(result: result, request: envelope) {
                result = .failed("Read projector returned an invalid result.")
            }
            projected.append((handle, envelope, producer, result))
        }

        var evidenceIDs: Set<UUID> = []
        var supersededEvidenceIDs: Set<UUID> = []
        var totalCandidateCount = 0
        for (resultIndex, projectedResult) in projected.enumerated() {
            if resultIndex.isMultiple(of: 8) { try Task.checkCancellation() }
            let result = projectedResult.3
            guard result.evidenceCandidates.count
                    <= Self.maximumCandidatesPerExecution - totalCandidateCount else {
                throw ReconstructionToolBrokerError.invalidProjectorInput
            }
            totalCandidateCount += result.evidenceCandidates.count
            for (candidateIndex, candidate) in result.evidenceCandidates.enumerated() {
                if candidateIndex.isMultiple(of: 64) { try Task.checkCancellation() }
                guard evidenceIDs.insert(candidate.evidenceID).inserted else {
                    throw ReconstructionToolBrokerError.duplicateEvidenceID
                }
                if let predecessor = candidate.supersedesEvidenceID,
                   !supersededEvidenceIDs.insert(predecessor).inserted {
                    throw ReconstructionToolBrokerError.conflictingSupersession
                }
            }
        }

        var executions: [ReconstructionToolExecution] = []
        executions.reserveCapacity(projected.count)
        for (handle, envelope, producer, projectedResult) in projected {
            try Task.checkCancellation()
            var result = projectedResult
            var acceptedEvidence: [ReconstructionEvidenceRecord] = []
            if !result.evidenceCandidates.isEmpty {
                do {
                    acceptedEvidence = try acceptEvidence(
                        result.evidenceCandidates,
                        handle: handle,
                        request: envelope,
                        producer: producer,
                        input: input
                    )
                    try validateAcceptedEvidenceBudget(
                        acceptedEvidence,
                        maximumBytes: envelope.maximumEncodedBytes
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    result = .failed("Projected evidence failed validation.")
                    acceptedEvidence = []
                }
            }
            let receipt = try makeReceipt(
                handle: handle,
                request: envelope,
                result: result,
                producer: producer,
                acceptedEvidence: acceptedEvidence,
                input: input
            )
            executions.append(.init(
                handleID: handle.handleID,
                operationID: handle.operationID,
                result: result,
                acceptedEvidence: acceptedEvidence,
                receipt: receipt,
                resolvedGapIDs: resolvedGapIDsByHandleID[handle.handleID] ?? []
            ))
        }
        return executions
    }

    private func validateAcceptedEvidenceBudget(
        _ accepted: [ReconstructionEvidenceRecord],
        maximumBytes: Int
    ) throws {
        var aggregateBytes = 0
        for (index, record) in accepted.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            let encoded = try ReconstructionCanonicalJSON.encode(record)
            let (next, overflow) = aggregateBytes.addingReportingOverflow(encoded.count)
            guard !overflow, next <= maximumBytes else {
                throw ReconstructionToolBrokerError.evidenceBudgetExceeded
            }
            aggregateBytes = next
        }
    }

    private func cursorMatchesEvidenceCut(
        _ cursor: ReconstructionRetrievalCursor,
        query: ReconstructionRetrievalQuery,
        evidenceRecordsByID: [UUID: ReconstructionEvidenceRecord],
        input: ReconstructionToolProjectorInput
    ) throws -> Bool {
        struct SubjectIdentityPreimage: Encodable {
            let schemaVersion: Int
            let domain: String
            let subject: ReconstructionDurableSubject
        }
        guard let record = evidenceRecordsByID[cursor.evidenceID],
        let classification = input.evidenceCut
            .projectedClassificationsByEvidenceID[record.evidenceID],
        let revision = input.evidenceCut.checkpointRevisionsByID[record.creatingCheckpointID],
        let operation = ReconstructionOperationID(rawValue: record.operationID) else { return false }
        let structuralSubject: ReconstructionDurableSubject
        switch record.subject {
        case .artifact, .image:
            structuralSubject = record.subject
        case .function(let function):
            structuralSubject = .function(try ReconstructionFunctionCoordinate(
                artifact: function.artifact,
                image: function.image,
                analysisFingerprintSHA256: function.analysisFingerprintSHA256,
                startAddress: function.startAddress,
                endAddressExclusive: function.endAddressExclusive,
                boundarySchemaVersion: function.boundarySchemaVersion,
                functionUUIDHint: nil,
                symbolHint: nil
            ))
        }
        let canonicalSubject = try ReconstructionCanonicalJSON.encode(SubjectIdentityPreimage(
            schemaVersion: 1,
            domain: "reconstruction.durable-subject.v1",
            subject: structuralSubject
        ))
        let specificity: Int
        switch record.subject {
        case .function: specificity = 0
        case .image: specificity = 1
        case .artifact: specificity = 2
        }
        return query.operationIDs.contains(operation)
            && query.classifications.contains(classification)
            && query.includes(subject: record.subject)
            && cursor.currentBucket == (classification == .acceptedCurrent ? 0 : 1)
            && cursor.subjectSpecificity == specificity
            && cursor.operationPriority == operation.priority
            && cursor.canonicalSubjectIdentity == Data(SHA256.hash(data: canonicalSubject))
            && cursor.checkpointRevision == revision
    }

    private func validate(
        result: ReconstructionToolProjectionResult,
        request: ReconstructionToolRequestEnvelope
    ) throws -> Bool {
        guard result.evidenceCandidates.count <= request.maximumRecords,
              result.evidenceCandidates.count <= Self.maximumCandidatesPerResult else {
            return false
        }
        var candidatePayloadBytes = 0
        var candidateCitationCount = 0
        var candidateFacetCount = 0
        var candidateMetadataBytes = 0
        for (index, candidate) in result.evidenceCandidates.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            guard candidate.payload.count
                    <= request.maximumEncodedBytes - candidatePayloadBytes,
                  candidate.citations.count
                    <= Self.maximumCandidateCitations - candidateCitationCount,
                  candidate.facetDependencies.count
                    <= Self.maximumCandidateFacets - candidateFacetCount else {
                return false
            }
            candidatePayloadBytes += candidate.payload.count
            candidateCitationCount += candidate.citations.count
            candidateFacetCount += candidate.facetDependencies.count
            let metadata = candidate.citations.compactMap(\.locator)
                + candidate.facetDependencies.map(\.facetIdentity)
                + [candidate.diagnostic?.text].compactMap { $0 }
            for value in metadata {
                guard value.utf8.count
                        <= request.maximumEncodedBytes - candidateMetadataBytes else {
                    return false
                }
                candidateMetadataBytes += value.utf8.count
            }
        }
        // Evidence pages may be flagged oversize (one record above the page budget, up to the hard
        // cap) or carry a typed recordTooLarge marker with no records. The receipt author
        // independently recompiles the exact packet before accepting either.
        struct EvidencePageFlags: Decodable {
            let oversizePage: Bool?
            let recordTooLarge: ReconstructionRetrievalRecordTooLarge?
        }
        let pageFlags = request.operationID == .evidenceQuery
            ? try? JSONDecoder().decode(EvidencePageFlags.self, from: result.payload) : nil
        let oversizePage = pageFlags?.oversizePage == true && result.itemCount == 1
        let markerPage = pageFlags?.recordTooLarge != nil && result.itemCount == 0
        guard result.itemCount >= 0,
              result.itemCount <= request.maximumRecords,
              result.payload.count <= (oversizePage
                ? ReconstructionRetrievalPacket.oversizePageHardCapBytes : request.maximumEncodedBytes),
              ReconstructionToolAuthorityCut.isCanonicalSHA256(result.payloadSHA256),
              Self.sha256(result.payload) == result.payloadSHA256,
              Self.isCanonicalJSON(result.payload) else {
            return false
        }
        if request.operationID == .evidenceQuery,
           let query = request.retrievalQuery, query.focus != nil,
           result.outcome == .success || result.outcome == .truncated {
            // Reuse the retrieval record DTO at the broker boundary. The production receipt
            // author independently recompiles the complete packet before accepting its receipt.
            struct RetrievalPacketMembership: Decodable {
                let schemaVersion: Int
                let domain: String
                let corpusManifestSHA256: String
                let evidenceFrontierSHA256: String
                let queryIdentitySHA256: String
                let records: [ReconstructionRetrievedEvidenceRecord]
            }
            guard let packet = try? JSONDecoder().decode(
                RetrievalPacketMembership.self, from: result.payload
            ), packet.schemaVersion == 1,
               packet.domain == "reconstruction.evidence-retrieval-packet.v1",
               packet.corpusManifestSHA256 == request.authority.corpusManifestSHA256,
               packet.evidenceFrontierSHA256 == request.authority.evidenceFrontierSHA256,
               packet.queryIdentitySHA256 == (try ReconstructionToolRegistry
                    .canonicalRetrievalQueryIdentitySHA256(query)),
               packet.records.count == result.itemCount,
               packet.records.allSatisfy({ retrieved in
                   query.includes(subject: retrieved.record.subject)
                       && query.operationIDs.contains(where: {
                           $0.rawValue == retrieved.record.operationID
                       })
                       && query.classifications.contains(retrieved.classification)
               }) else { return false }
        }
        if request.operationID == .analysisMacScopeRefresh {
            guard result.outcome == .success, result.itemCount == 1,
                  result.evidenceCandidates.isEmpty,
                  result.payload == (try ReconstructionMacScopeAnalysisDemand
                    .acknowledgement(for: request)) else { return false }
        }
        switch result.outcome {
        case .success:
            return result.diagnostic == nil && result.continuationRequest == nil
        case .truncated:
            guard result.itemCount > 0 || markerPage,
                  result.diagnostic == nil,
                  let continuation = result.continuationRequest else {
                return false
            }
            return validContinuation(continuation, after: request)
        case .unavailable, .stale, .failed:
            return result.payload == Data("[]".utf8)
                && result.itemCount == 0
                && result.diagnostic != nil
                && result.continuationRequest == nil
                && result.evidenceCandidates.isEmpty
        }
    }

    private func validContinuation(
        _ continuation: ReconstructionToolRequest,
        after request: ReconstructionToolRequestEnvelope
    ) -> Bool {
        guard continuation.operationID == request.operationID,
              continuation.taskID == request.taskID,
              continuation.subject == request.subject,
              continuation.offset <= ReconstructionToolRegistry.maximumOffset,
              continuation.maximumRecords == request.maximumRecords,
              continuation.maximumEncodedBytes == request.maximumEncodedBytes else {
            return false
        }
        if request.operationID != .evidenceQuery {
            return continuation.offset > request.offset
                && continuation.retrievalQuery == request.retrievalQuery
        }
        guard let current = request.retrievalQuery,
              let next = continuation.retrievalQuery else {
            return false
        }
        return next.corpusManifestSHA256 == current.corpusManifestSHA256
            && continuation.offset == 1
            && next.subject == current.subject
            && next.focus == current.focus
            && next.operationIDs == current.operationIDs
            && next.classifications == current.classifications
            && next.maximumRecords == current.maximumRecords
            && next.maximumEncodedBytes == current.maximumEncodedBytes
            && next.cursor != nil
            && next.cursor != current.cursor
            && next.cursor?.corpusManifestSHA256 == request.authority.corpusManifestSHA256
            && next.cursor?.evidenceFrontierSHA256 == request.authority.evidenceFrontierSHA256
    }

    private func acceptEvidence(
        _ candidates: [ReconstructionEvidenceCandidate],
        handle: ReconstructionToolHandle,
        request: ReconstructionToolRequestEnvelope,
        producer: ReconstructionProducerIdentity,
        input: ReconstructionToolProjectorInput
    ) throws -> [ReconstructionEvidenceRecord] {
        guard let cut = input.evidenceAuthorityCutsByOperation[handle.operationID],
              cut.operationID == handle.operationID,
              cut.creatingJobID == input.authority.jobID,
              cut.creatingTaskID == request.taskID,
              cut.checkpointRevision == input.authority.checkpointRevision,
              cut.corpusManifest == input.corpusManifest,
              cut.evidence == input.evidenceCut.records,
              cut.toolReceiptID == handle.handleID,
              cut.modelReceiptID == nil,
              cut.producer == producer else {
            throw ReconstructionToolBrokerError.invalidEvidenceAuthorityCut
        }
        var evidenceIDs: Set<UUID> = []
        var accepted: [ReconstructionEvidenceRecord] = []
        accepted.reserveCapacity(candidates.count)
        for (index, candidate) in candidates.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            guard evidenceIDs.insert(candidate.evidenceID).inserted else {
                throw ReconstructionToolBrokerError.invalidProjectorInput
            }
            accepted.append(try evidenceAcceptor.validate(candidate, against: cut))
        }
        return accepted.sorted { $0.evidenceID.uuidString < $1.evidenceID.uuidString }
    }

    private func makeReceipt(
        handle: ReconstructionToolHandle,
        request: ReconstructionToolRequestEnvelope,
        result: ReconstructionToolProjectionResult,
        producer: ReconstructionProducerIdentity,
        acceptedEvidence: [ReconstructionEvidenceRecord],
        input: ReconstructionToolProjectorInput
    ) throws -> ReconstructionToolReceipt {
        let terminalState: ReconstructionReceiptTerminalState
        switch result.outcome {
        case .truncated: terminalState = .truncated
        case .failed: terminalState = .failed
        case .success, .unavailable, .stale: terminalState = .completed
        }
        let outputEvidenceIDs = acceptedEvidence.map(\.evidenceID).sorted {
            $0.uuidString < $1.uuidString
        }
        return try ReconstructionReceiptAuthority.makeToolReceipt(
            receiptID: handle.handleID,
            jobID: input.authority.jobID,
            taskID: request.taskID,
            checkpointRevision: input.authority.checkpointRevision,
            requestIdentitySHA256: handle.requestSHA256,
            producer: producer,
            terminalState: terminalState,
            outputEvidenceIDs: outputEvidenceIDs,
            diagnostic: result.diagnostic
        )
    }

    private func receiptIsAuthentic(
        _ receipt: ReconstructionToolReceipt,
        evidenceRecordsByID: [UUID: ReconstructionEvidenceRecord],
        input: ReconstructionToolProjectorInput
    ) throws -> Bool {
        let producerDigest = try ReconstructionEvidenceIntegrity.canonicalProducerSHA256(
            receipt.producer
        )
        guard try ReconstructionReceiptAuthority.toolReceiptHasCanonicalIdentity(receipt)
            && ReconstructionEvidenceIntegrity.producerContainsOnlyDurableBoundedIdentity(
                receipt.producer
            )
            && producerDigest == receipt.producer.canonicalSHA256 else { return false }
        for evidenceID in receipt.outputEvidenceIDs {
            guard let record = evidenceRecordsByID[evidenceID],
                  record.toolReceiptID == receipt.receiptID,
                  record.creatingJobID == receipt.jobID,
                  record.creatingTaskID == receipt.taskID,
                  record.producer == receipt.producer,
                  input.evidenceCut.checkpointRevisionsByID[record.creatingCheckpointID]
                    == receipt.checkpointRevision else { return false }
        }
        return true
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isCanonicalJSON(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ), let canonical = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        ) else {
            return false
        }
        return canonical == data
    }
}
