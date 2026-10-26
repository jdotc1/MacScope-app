import Foundation

enum AnalystFindingError: Error, Equatable, LocalizedError {
    case unsupportedSchema(Int), unsupportedRevisionState, invalidContent, wrongOwner, bounds
    case staleDraft, duplicateRequestConflict
    case retracted, invalidStanding, supportNotConfirmed
    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): "Authored finding schema \(version) requires a compatible reader."
        case .unsupportedRevisionState: "This reader cannot preserve the finding's revision or history state."
        case .invalidContent: "The authored finding cannot be represented faithfully."
        case .wrongOwner: "The authored finding belongs to a different document or workspace."
        case .bounds: "Authored findings exceed the document limits. Existing findings are unchanged."
        case .staleDraft: "The draft or its native evidence changed. Obtain a current answer before accepting."
        case .duplicateRequestConflict: "This Assistant request already has a different accepted finding."
        case .retracted: "The finding is retracted. Undo the retraction before editing or reviewing it."
        case .invalidStanding: "The finding's standing does not allow this action."
        case .supportNotConfirmed: "The facts this finding cites are not all live and current, so it cannot be accepted or readmitted yet."
        }
    }
}

/// The original native context schema is reused; its bytes/digest retain their original domain.
/// Decoding validates the typed manifest, not live image/provider authority or a new provenance hash.
struct AnalystFindingContextSnapshot: Codable, Equatable, Sendable {
    let manifest: Phase2GroundedContextManifest
    let canonicalBytes: Data
    let digest: String

    func validate() throws {
        guard manifest.schemaVersion == Phase2GroundedContextManifest.currentSchemaVersion,
              !manifest.records.isEmpty, manifest.records.count <= 3,
              canonicalBytes.count <= 1_048_576, !canonicalBytes.isEmpty,
              digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              Set(manifest.records.map(\.evidenceID)).count == manifest.records.count,
              try JSONDecoder().decode(Phase2GroundedContextManifest.self, from: canonicalBytes) == manifest else {
            throw AnalystFindingError.invalidContent
        }
    }
}

struct AnalystFindingLimitsSnapshot: Codable, Equatable, Sendable {
    let maximumGoalBytes: Int
    let maximumEventBytes: Int
    let maximumCumulativeEventBytes: Int
    let maximumEvents: Int
    let maximumToolHandles: Int
    let maximumToolProposals: Int
    let maximumFinalTextBytes: Int
    let maximumEvidenceReferences: Int
}

struct AnalystFindingToolSnapshot: Codable, Equatable, Sendable {
    let handleID: UUID
    let operationID: String
}

struct AnalystFindingConversationTurnSnapshot: Codable, Equatable, Sendable {
    let conversationID: UUID
    let inferenceTurnID: UUID
    let turnSequence: UInt64
    let user: String
    let assistant: String
    let isLegacy: Bool
}

struct AnalystFindingConversationSnapshot: Codable, Equatable, Sendable {
    let turns: [AnalystFindingConversationTurnSnapshot]
    let omittedTurnCount: Int
}

/// Exact fields of the existing optional native continuation coordinate. This archive never
/// resumes it; the app-side converter round-trips the original native Codable value by equality.
struct AnalystFindingContinuationSnapshot: Codable, Equatable, Sendable {
    let workspaceID: UUID
    let workspaceDocumentIdentityDigest: String
    let conversationID: UUID
    let inferenceTurnID: UUID
    let turnSequence: UInt64
    let originatingFinalizationRequestID: UUID
    let shellProposalID: UUID
    let shellExecutionID: UUID
    let runtimeAuthorityRecordID: UUID
    let shellProposalDigest: String
    let shellExecutionResultDigest: String
    let runtimeAuthorityRecordDigest: String
    let productionManifestIdentity: String
    let providerRevision: UInt64
    let continuationOrdinal: UInt64
    let continuationRequestID: UUID
    let integrityDigest: String
}

struct AnalystFindingRequestSnapshot: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let phase: String
    let sessionID: UUID
    let turnID: UUID
    let requestID: UUID
    let documentInstanceID: UUID
    let workspaceDocumentInstanceID: UUID
    let workspaceInstanceID: UUID
    let lifecycleRevision: UInt64
    let userGoal: String
    let groundedContext: AnalystFindingContextSnapshot
    let toolHandles: [AnalystFindingToolSnapshot]
    let conversationContext: AnalystFindingConversationSnapshot?
    let shellContinuationCoordinate: AnalystFindingContinuationSnapshot?
    let limits: AnalystFindingLimitsSnapshot
    let maximumOutputTokens: Int?
}

/// Authored interpretation and its native source provenance remain separate values. Acceptance
/// does not claim source freshness, an independent provider receipt, review, or a scheduler task.
struct AnalystFindingContentSnapshot: Codable, Equatable, Sendable {
    let originalRequest: AnalystFindingRequestSnapshot
    let candidateKind: String
    let candidateText: String
    let evidenceIDs: [UUID]
    let runnerReportedProviderRevision: UInt64
    let recompiledContext: AnalystFindingContextSnapshot

    func validate() throws {
        try originalRequest.groundedContext.validate()
        try recompiledContext.validate()
        guard candidateKind == "answer", !candidateText.isEmpty,
              candidateText.utf8.count <= 65_536, runnerReportedProviderRevision > 0,
              (1...3).contains(evidenceIDs.count), Set(evidenceIDs).count == evidenceIDs.count,
              originalRequest.phase == "finalization", originalRequest.protocolVersion > 0,
              originalRequest.documentInstanceID == originalRequest.workspaceDocumentInstanceID else {
            throw AnalystFindingError.invalidContent
        }
        let source = originalRequest.groundedContext.manifest
        let compiled = recompiledContext.manifest
        guard source.records.allSatisfy({
            $0.precondition.workspace.document.instanceID == originalRequest.documentInstanceID
                && $0.precondition.workspace.instanceID == originalRequest.workspaceInstanceID
                && $0.precondition.workspaceRevision == originalRequest.lifecycleRevision
        }) else { throw AnalystFindingError.invalidContent }
        guard compiled.omissions.isEmpty, Set(compiled.records.map(\.evidenceID)) == Set(evidenceIDs) else {
            throw AnalystFindingError.invalidContent
        }
        for id in evidenceIDs {
            guard !source.omissions.contains(where: { $0.evidenceID == id }),
                  let record = compiled.records.first(where: { $0.evidenceID == id }),
                  let original = source.records.first(where: { $0.evidenceID == id }), record == original,
                  record.precondition.workspace.document.instanceID == originalRequest.documentInstanceID,
                  record.precondition.workspace.instanceID == originalRequest.workspaceInstanceID,
                  record.precondition.workspaceRevision == originalRequest.lifecycleRevision else {
                throw AnalystFindingError.invalidContent
            }
        }
    }
}

struct AnalystFindingRecord: Codable, Equatable, Identifiable, Sendable {
    static let maximumCitations = 64
    let id: UUID
    let workspaceID: UUID
    let documentID: UUID
    let createdAt: Date
    let contentRevision: UInt64
    let reviewRevision: UInt64
    let content: AnalystFindingContentSnapshot
    // Legacy fields remain initial-only. Version 2 stores complete typed authored history.
    let lifecycle: AnalystFindingLifecycle?
    let review: String?
    let transitionHistory: [String]
    /// Contract facts this finding rests on. Absent in every finding written before reader feature
    /// `analyst.findings.v2`; an absent or empty list is stored as nil so both compare equal.
    let citesFacts: [FactCitation]?

    init(id: UUID, workspaceID: UUID, documentID: UUID, createdAt: Date,
         contentRevision: UInt64 = 1, reviewRevision: UInt64 = 0,
         content: AnalystFindingContentSnapshot, review: String? = nil, transitionHistory: [String] = [],
         lifecycle: AnalystFindingLifecycle? = nil, citesFacts: [FactCitation]? = nil) {
        self.id = id; self.workspaceID = workspaceID; self.documentID = documentID; self.createdAt = createdAt
        self.contentRevision = contentRevision; self.reviewRevision = reviewRevision; self.content = content
        self.review = review; self.transitionHistory = transitionHistory; self.lifecycle = lifecycle
        self.citesFacts = (citesFacts?.isEmpty ?? true) ? nil : citesFacts
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, workspaceID, documentID, createdAt, contentRevision, reviewRevision, content, review, transitionHistory
        case schemaVersion, lifecycle, citesFacts
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let all = try decoder.container(keyedBy: AnalystFindingAnyKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw AnalystFindingError.unsupportedRevisionState
        }
        let contentRevision = try values.decode(UInt64.self, forKey: .contentRevision)
        let reviewRevision = try values.decode(UInt64.self, forKey: .reviewRevision)
        let version = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version == 1 || version == 2 else { throw AnalystFindingError.unsupportedSchema(version) }
        let lifecycle: AnalystFindingLifecycle?
        if version == 1 {
            guard contentRevision == 1, reviewRevision == 0, !values.contains(.lifecycle) else {
                throw AnalystFindingError.unsupportedRevisionState
            }
            lifecycle = nil
        } else {
            lifecycle = try values.decode(AnalystFindingLifecycle.self, forKey: .lifecycle)
        }
        if values.contains(.review), try !values.decodeNil(forKey: .review) { throw AnalystFindingError.unsupportedRevisionState }
        if values.contains(.transitionHistory) {
            let history = try values.nestedUnkeyedContainer(forKey: .transitionHistory)
            guard history.isAtEnd else { throw AnalystFindingError.unsupportedRevisionState }
        }
        self.init(id: try values.decode(UUID.self, forKey: .id),
            workspaceID: try values.decode(UUID.self, forKey: .workspaceID),
            documentID: try values.decode(UUID.self, forKey: .documentID),
            createdAt: Date(timeIntervalSinceReferenceDate: try values.decode(Double.self, forKey: .createdAt)),
            contentRevision: contentRevision, reviewRevision: reviewRevision,
            content: try values.decode(AnalystFindingContentSnapshot.self, forKey: .content), lifecycle: lifecycle,
            citesFacts: try values.decodeIfPresent([FactCitation].self, forKey: .citesFacts))
        try validateRevisionState()
    }

    /// The cited facts, empty for findings written before citations existed.
    var citations: [FactCitation] { citesFacts ?? [] }

    /// True when the record needs a reader that understands `analyst.findings.v2`: it cites facts or its
    /// history holds a retract, stale or readmit operation.
    var usesV2Extensions: Bool {
        if !citations.isEmpty { return true }
        guard let lifecycle else { return false }
        return lifecycle.history.contains { [.retract, .stale, .readmit].contains($0.operation.kind) }
    }

    func validateRevisionState() throws {
        guard review == nil, transitionHistory.isEmpty else { throw AnalystFindingError.unsupportedRevisionState }
        try FactCitation.validate(citations)
        if let lifecycle {
            try lifecycle.validate(initialText: content.candidateText, identity: revisionIdentity)
            guard contentRevision == lifecycle.state.contentRevision, reviewRevision == lifecycle.state.reviewRevision else {
                throw AnalystFindingError.unsupportedRevisionState
            }
        } else {
            guard contentRevision == 1, reviewRevision == 0 else { throw AnalystFindingError.unsupportedRevisionState }
        }
    }

    func revising(with lifecycle: AnalystFindingLifecycle) -> Self {
        .init(id: id, workspaceID: workspaceID, documentID: documentID, createdAt: createdAt,
              contentRevision: lifecycle.state.contentRevision, reviewRevision: lifecycle.state.reviewRevision,
              content: content, lifecycle: lifecycle, citesFacts: citesFacts)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        if let lifecycle {
            try values.encode(2, forKey: .schemaVersion)
            try values.encode(lifecycle, forKey: .lifecycle)
        }
        try values.encode(id, forKey: .id)
        try values.encode(workspaceID, forKey: .workspaceID)
        try values.encode(documentID, forKey: .documentID)
        // Independent of the enclosing manifest's millisecond Date strategy.
        try values.encode(createdAt.timeIntervalSinceReferenceDate, forKey: .createdAt)
        try values.encode(contentRevision, forKey: .contentRevision)
        try values.encode(reviewRevision, forKey: .reviewRevision)
        try values.encode(content, forKey: .content)
        try values.encodeIfPresent(review, forKey: .review)
        try values.encode(transitionHistory, forKey: .transitionHistory)
        // Written only when present, so a finding without citations keeps its exact pre-v2 bytes.
        if let citesFacts { try values.encode(citesFacts, forKey: .citesFacts) }
    }
}

struct AnalystFindingEnvelope: Codable, Equatable, Sendable {
    static let maximumRecords = 256
    static let maximumEncodedBytes = 24 * 1_024 * 1_024
    static let maximumRecordBytes = 8 * 1_024 * 1_024
    static let empty = Self(records: [])
    let schemaVersion: Int
    private(set) var records: [AnalystFindingRecord]
    var isEmpty: Bool { records.isEmpty }
    /// True when any record cites facts or carries a retract, stale or readmit operation. Such an
    /// envelope is readable only by a build that declares reader feature `analyst.findings.v2`.
    var usesV2Extensions: Bool { records.contains(where: \.usesV2Extensions) }

    init(schemaVersion: Int? = nil, records: [AnalystFindingRecord]) {
        self.schemaVersion = schemaVersion ?? (records.contains { $0.lifecycle != nil } ? 2 : 1); self.records = records
    }
    private enum CodingKeys: String, CodingKey { case schemaVersion, records }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let all = try decoder.container(keyedBy: AnalystFindingAnyKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["schemaVersion", "records"]) else {
            throw AnalystFindingError.invalidContent
        }
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 || version == 2 else { throw AnalystFindingError.unsupportedSchema(version) }
        self.init(schemaVersion: version, records: try values.decode([AnalystFindingRecord].self, forKey: .records))
        try validateVersionDispatch()
    }
    func validate(workspaceID: UUID, documentID: UUID) throws {
        try validateVersionDispatch()
        guard records.count <= Self.maximumRecords else { throw AnalystFindingError.bounds }
        var ids = Set<UUID>(), requests = Set<UUID>()
        for record in records {
            guard record.workspaceID == workspaceID, record.documentID == documentID else { throw AnalystFindingError.wrongOwner }
            try record.validateRevisionState()
            guard record.createdAt.timeIntervalSinceReferenceDate.isFinite, ids.insert(record.id).inserted,
                  requests.insert(record.content.originalRequest.requestID).inserted else { throw AnalystFindingError.invalidContent }
            try record.content.validate()
            guard try JSONEncoder().encode(record).count <= Self.maximumRecordBytes else { throw AnalystFindingError.bounds }
        }
        guard try JSONEncoder().encode(self).count <= Self.maximumEncodedBytes else { throw AnalystFindingError.bounds }
    }
    private func validateVersionDispatch() throws {
        guard schemaVersion == 1 || schemaVersion == 2 else { throw AnalystFindingError.unsupportedSchema(schemaVersion) }
        guard (schemaVersion == 2) == records.contains(where: { $0.lifecycle != nil }) else {
            throw AnalystFindingError.unsupportedRevisionState
        }
    }
    mutating func replace(_ record: AnalystFindingRecord, workspaceID: UUID, documentID: UUID) throws {
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { throw AnalystFindingError.wrongOwner }
        var next = records
        next[index] = record
        let candidate = Self(records: next)
        try candidate.validate(workspaceID: workspaceID, documentID: documentID)
        self = candidate
    }
    mutating func append(_ record: AnalystFindingRecord, workspaceID: UUID, documentID: UUID) throws {
        var candidate = self
        candidate.records.append(record)
        try candidate.validate(workspaceID: workspaceID, documentID: documentID)
        self = candidate
    }
}

private struct AnalystFindingAnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
