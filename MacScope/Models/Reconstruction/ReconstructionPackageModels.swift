import CryptoKit
import Darwin
import Foundation

struct ReconstructionPackageDescriptor: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let corpusManifestPath: String
    let evidenceManifestPath: String
    let checkpointManifestPath: String
    let corpusManifestSHA256: String
    let evidenceManifestSHA256: String
    let checkpointManifestSHA256: String

    init(
        schemaVersion: Int = Self.schemaVersion,
        corpusManifestPath: String,
        evidenceManifestPath: String,
        checkpointManifestPath: String,
        corpusManifestSHA256: String,
        evidenceManifestSHA256: String,
        checkpointManifestSHA256: String
    ) throws {
        try Task.checkCancellation()
        guard schemaVersion == Self.schemaVersion,
              corpusManifestPath == ReconstructionPackageLayout.corpusManifestPath,
              evidenceManifestPath == ReconstructionPackageLayout.evidenceManifestPath,
              checkpointManifestPath == ReconstructionPackageLayout.checkpointManifestPath else {
            throw ReconstructionPackageValidationError.invalidDescriptor
        }
        try ReconstructionValidation.requireSHA256(
            corpusManifestSHA256,
            field: "package corpus manifest digest"
        )
        try ReconstructionValidation.requireSHA256(
            evidenceManifestSHA256,
            field: "package evidence manifest digest"
        )
        try ReconstructionValidation.requireSHA256(
            checkpointManifestSHA256,
            field: "package checkpoint manifest digest"
        )
        self.schemaVersion = schemaVersion
        self.corpusManifestPath = corpusManifestPath
        self.evidenceManifestPath = evidenceManifestPath
        self.checkpointManifestPath = checkpointManifestPath
        self.corpusManifestSHA256 = corpusManifestSHA256
        self.evidenceManifestSHA256 = evidenceManifestSHA256
        self.checkpointManifestSHA256 = checkpointManifestSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, corpusManifestPath, evidenceManifestPath, checkpointManifestPath
        case corpusManifestSHA256, evidenceManifestSHA256, checkpointManifestSHA256
    }

    init(from decoder: Decoder) throws {
        try Task.checkCancellation()
        let exact = try decoder.container(keyedBy: ReconstructionPackageAnyCodingKey.self)
        let expectedKeys: Set<String> = [
            "schemaVersion",
            "corpusManifestPath",
            "evidenceManifestPath",
            "checkpointManifestPath",
            "corpusManifestSHA256",
            "evidenceManifestSHA256",
            "checkpointManifestSHA256",
        ]
        guard Set(exact.allKeys.map(\.stringValue)) == expectedKeys else {
            throw ReconstructionPackageValidationError.invalidDescriptor
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            corpusManifestPath: container.decode(String.self, forKey: .corpusManifestPath),
            evidenceManifestPath: container.decode(String.self, forKey: .evidenceManifestPath),
            checkpointManifestPath: container.decode(String.self, forKey: .checkpointManifestPath),
            corpusManifestSHA256: container.decode(String.self, forKey: .corpusManifestSHA256),
            evidenceManifestSHA256: container.decode(String.self, forKey: .evidenceManifestSHA256),
            checkpointManifestSHA256: container.decode(String.self, forKey: .checkpointManifestSHA256)
        )
    }
}

private struct ReconstructionPackageAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

protocol ReconstructionAttachmentSourceLifetimeToken: AnyObject, Sendable {}

/// A transient, non-persisted source token that opens the exact attachment through retained
/// descriptor authority. Package-backed sources intentionally use the URL fallback instead.
protocol ReconstructionAttachmentSourceDescriptorToken:
    ReconstructionAttachmentSourceLifetimeToken
{
    func openVerifiedDescriptor() throws -> Int32
}

struct ReconstructionAttachmentSource: Sendable {
    let contentIdentity: ReconstructionContentIdentity
    let verifiedURL: URL
    private let lifetimeToken: (any ReconstructionAttachmentSourceLifetimeToken)?

    init(
        contentIdentity: ReconstructionContentIdentity,
        verifiedURL: URL,
        lifetimeToken: (any ReconstructionAttachmentSourceLifetimeToken)? = nil
    ) {
        self.contentIdentity = contentIdentity
        self.verifiedURL = verifiedURL
        self.lifetimeToken = lifetimeToken
    }

    /// Returns a fresh read-only descriptor. Sidecar-backed sources open descriptor-relatively
    /// through their transient token; all other sources preserve the existing URL behavior.
    func openVerifiedDescriptor() throws -> Int32 {
        if let descriptorToken = lifetimeToken as?
            any ReconstructionAttachmentSourceDescriptorToken
        {
            return try descriptorToken.openVerifiedDescriptor()
        }
        return verifiedURL.withUnsafeFileSystemRepresentation { path in
            path.map {
                Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            } ?? -1
        }
    }

    var hasDescriptorAuthority: Bool {
        lifetimeToken is any ReconstructionAttachmentSourceDescriptorToken
    }
}

enum ReconstructionPackageValidationError: Error, Equatable, LocalizedError {
    case invalidDescriptor
    case noncanonicalManifest(String)
    case manifestDigestMismatch(String)
    case invalidContentPath(String)
    case contentIdentityConflict(String)
    case contentTooLarge(String)
    case stateGraphInvalid(String)

    var errorDescription: String? {
        switch self {
        case .invalidDescriptor:
            "The reconstruction package descriptor is invalid."
        case .noncanonicalManifest(let path):
            "The reconstruction manifest is not strict canonical JSON: \(path)"
        case .manifestDigestMismatch(let path):
            "The reconstruction manifest digest does not match: \(path)"
        case .invalidContentPath(let path):
            "The reconstruction content path is invalid: \(path)"
        case .contentIdentityConflict(let digest):
            "The reconstruction content identity conflicts with another record: \(digest)"
        case .contentTooLarge(let digest):
            "The reconstruction content exceeds the package size limit: \(digest)"
        case .stateGraphInvalid(let reason):
            "The reconstruction package graph is invalid: \(reason)"
        }
    }
}

enum ReconstructionPackageLayout {
    static let rootDirectoryName = "Reconstruction"
    static let corpusDirectoryPath = "Reconstruction/Corpus/sha256"
    static let corpusManifestPath = "Reconstruction/corpus-manifest.json"
    static let evidenceManifestPath = "Reconstruction/evidence-manifest.json"
    static let checkpointManifestPath = "Reconstruction/checkpoint-manifest.json"
    static let maximumManifestBytes = 64 * 1_024 * 1_024
    static let maximumCorpusAttachmentBytes: UInt64 = 1_073_741_824

    static func attachmentPath(for identity: ReconstructionContentIdentity) throws -> String {
        try Task.checkCancellation()
        try ReconstructionValidation.requireSHA256(identity.digest, field: "content digest")
        guard identity.byteCount <= maximumCorpusAttachmentBytes else {
            throw ReconstructionPackageValidationError.contentTooLarge(identity.digest)
        }
        return "\(corpusDirectoryPath)/\(identity.digest.prefix(2))/\(identity.digest)"
    }
}

struct ReconstructionPackageContentRecord: Hashable, Codable, Sendable {
    let contentIdentity: ReconstructionContentIdentity
    let attachmentPath: String

    init(contentIdentity: ReconstructionContentIdentity, attachmentPath: String) throws {
        try Task.checkCancellation()
        let expected = try ReconstructionPackageLayout.attachmentPath(for: contentIdentity)
        guard attachmentPath == expected else {
            throw ReconstructionPackageValidationError.invalidContentPath(attachmentPath)
        }
        self.contentIdentity = contentIdentity
        self.attachmentPath = attachmentPath
    }

    private enum CodingKeys: String, CodingKey { case contentIdentity, attachmentPath }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            contentIdentity: container.decode(ReconstructionContentIdentity.self, forKey: .contentIdentity),
            attachmentPath: container.decode(String.self, forKey: .attachmentPath)
        )
    }
}

struct ReconstructionPackageCorpusManifest: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let contents: [ReconstructionPackageContentRecord]
    let projects: [ReconstructionProjectRecord]
    let corpusManifests: [ReconstructionCorpusManifest]

    init(
        schemaVersion: Int = Self.schemaVersion,
        contents: [ReconstructionPackageContentRecord],
        projects: [ReconstructionProjectRecord],
        corpusManifests: [ReconstructionCorpusManifest]
    ) throws {
        try Task.checkCancellation()
        guard schemaVersion == Self.schemaVersion else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("corpus schema")
        }
        try ReconstructionEvidenceIntegrity.requireDurableCollectionCount(
            contents.count,
            field: "package contents"
        )
        try ReconstructionEvidenceIntegrity.requireDurableCollectionCount(
            projects.count,
            field: "projects"
        )
        try ReconstructionEvidenceIntegrity.requireDurableCollectionCount(
            corpusManifests.count,
            field: "corpus manifests"
        )
        var contentDigests: [String] = []
        contentDigests.reserveCapacity(contents.count)
        for content in contents {
            try Task.checkCancellation()
            contentDigests.append(content.contentIdentity.digest)
        }
        try ReconstructionValidation.requireUnique(
            contentDigests,
            field: "package content digests"
        )
        self.schemaVersion = schemaVersion
        self.contents = contents.sorted { $0.contentIdentity.digest < $1.contentIdentity.digest }
        self.projects = projects.sorted { $0.projectID.uuidString < $1.projectID.uuidString }
        self.corpusManifests = corpusManifests.sorted(
            by: ReconstructionCorpusHistoryIndex.manifestPrecedes
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, contents, projects, corpusManifests
    }

    init(from decoder: Decoder) throws {
        try Task.checkCancellation()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            contents: container.decode([ReconstructionPackageContentRecord].self, forKey: .contents),
            projects: container.decode([ReconstructionProjectRecord].self, forKey: .projects),
            corpusManifests: container.decode([ReconstructionCorpusManifest].self, forKey: .corpusManifests)
        )
    }
}

struct ReconstructionPackageEvidenceManifest: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let evidence: [ReconstructionEvidenceRecord]
    let evidenceRelations: [ReconstructionEvidenceRelation]
    let evidenceGaps: [ReconstructionEvidenceGap]
    let toolReceipts: [ReconstructionToolReceipt]
    let modelReceipts: [ReconstructionModelReceipt]
    let finalResults: [ReconstructionFinalResultRecord]

    init(
        schemaVersion: Int = Self.schemaVersion,
        evidence: [ReconstructionEvidenceRecord],
        evidenceRelations: [ReconstructionEvidenceRelation],
        evidenceGaps: [ReconstructionEvidenceGap],
        toolReceipts: [ReconstructionToolReceipt],
        modelReceipts: [ReconstructionModelReceipt],
        finalResults: [ReconstructionFinalResultRecord] = []
    ) throws {
        try Task.checkCancellation()
        guard schemaVersion == Self.schemaVersion else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("evidence schema")
        }
        try ReconstructionEvidenceIntegrity.requireDurableCollectionCount(
            evidence.count,
            field: "evidence"
        )
        try ReconstructionEvidenceIntegrity.requireDurableCollectionCount(
            evidenceRelations.count,
            field: "evidence relations"
        )
        try ReconstructionEvidenceIntegrity.requireDurableCollectionCount(
            evidenceGaps.count,
            field: "evidence gaps"
        )
        try ReconstructionEvidenceIntegrity.requireDurableCollectionCount(
            toolReceipts.count,
            field: "tool receipts"
        )
        try ReconstructionEvidenceIntegrity.requireDurableCollectionCount(
            modelReceipts.count,
            field: "model receipts"
        )
        try ReconstructionEvidenceIntegrity.requireDurableCollectionCount(
            finalResults.count,
            field: "final results"
        )
        self.schemaVersion = schemaVersion
        self.evidence = evidence.sorted { $0.evidenceID.uuidString < $1.evidenceID.uuidString }
        self.evidenceRelations = evidenceRelations.sorted {
            $0.relationID.uuidString < $1.relationID.uuidString
        }
        self.evidenceGaps = evidenceGaps.sorted { $0.gapID.uuidString < $1.gapID.uuidString }
        self.toolReceipts = toolReceipts.sorted { $0.receiptID.uuidString < $1.receiptID.uuidString }
        self.modelReceipts = modelReceipts.sorted { $0.receiptID.uuidString < $1.receiptID.uuidString }
        self.finalResults = finalResults.sorted { $0.resultID.uuidString < $1.resultID.uuidString }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, evidence, evidenceRelations, evidenceGaps, toolReceipts, modelReceipts
        case finalResults
    }

    init(from decoder: Decoder) throws {
        try Task.checkCancellation()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            evidence: container.decode([ReconstructionEvidenceRecord].self, forKey: .evidence),
            evidenceRelations: container.decode([ReconstructionEvidenceRelation].self, forKey: .evidenceRelations),
            evidenceGaps: container.decode([ReconstructionEvidenceGap].self, forKey: .evidenceGaps),
            toolReceipts: container.decode([ReconstructionToolReceipt].self, forKey: .toolReceipts),
            modelReceipts: container.decode([ReconstructionModelReceipt].self, forKey: .modelReceipts),
            finalResults: try container.decodeIfPresent(
                [ReconstructionFinalResultRecord].self,
                forKey: .finalResults
            ) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(evidenceRelations, forKey: .evidenceRelations)
        try container.encode(evidenceGaps, forKey: .evidenceGaps)
        try container.encode(toolReceipts, forKey: .toolReceipts)
        try container.encode(modelReceipts, forKey: .modelReceipts)
        // The absent key is the canonical representation of an empty legacy collection.
        if !finalResults.isEmpty {
            try container.encode(finalResults, forKey: .finalResults)
        }
    }
}

struct ReconstructionPackageCheckpointManifest: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let jobs: [ReconstructionJobRecord]
    let tasks: [ReconstructionTaskRecord]
    let checkpoints: [ReconstructionCheckpoint]
    let replayRecords: [ReconstructionWorkspaceReplayRecord]?

    init(
        schemaVersion: Int = Self.schemaVersion,
        jobs: [ReconstructionJobRecord],
        tasks: [ReconstructionTaskRecord],
        checkpoints: [ReconstructionCheckpoint],
        replayRecords: [ReconstructionWorkspaceReplayRecord]? = nil
    ) throws {
        try Task.checkCancellation()
        guard schemaVersion == Self.schemaVersion else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("checkpoint schema")
        }
        try ReconstructionEvidenceIntegrity.requireDurableCollectionCount(
            jobs.count,
            field: "jobs"
        )
        try ReconstructionEvidenceIntegrity.requireDurableCollectionCount(
            tasks.count,
            field: "tasks"
        )
        try ReconstructionEvidenceIntegrity.requireDurableCollectionCount(
            checkpoints.count,
            field: "checkpoints"
        )
        self.schemaVersion = schemaVersion
        self.replayRecords = replayRecords
        self.jobs = jobs.sorted { $0.jobID.uuidString < $1.jobID.uuidString }
        self.tasks = tasks.sorted { $0.identity.taskID.uuidString < $1.identity.taskID.uuidString }
        self.checkpoints = checkpoints.sorted {
            if $0.jobID != $1.jobID { return $0.jobID.uuidString < $1.jobID.uuidString }
            return $0.revision < $1.revision
        }
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, jobs, tasks, checkpoints, replayRecords }

    init(from decoder: Decoder) throws {
        try Task.checkCancellation()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            jobs: container.decode([ReconstructionJobRecord].self, forKey: .jobs),
            tasks: container.decode([ReconstructionTaskRecord].self, forKey: .tasks),
            checkpoints: container.decode([ReconstructionCheckpoint].self, forKey: .checkpoints),
            replayRecords: container.decodeIfPresent([ReconstructionWorkspaceReplayRecord].self, forKey: .replayRecords)
        )
    }
}

struct ReconstructionPackageEncodedManifests: Sendable {
    let descriptor: ReconstructionPackageDescriptor
    let corpusData: Data
    let evidenceData: Data
    let checkpointData: Data
    let contents: [ReconstructionPackageContentRecord]
}

struct ReconstructionPackageValidationWork: Equatable, Sendable {
    fileprivate(set) var jobVisits = 0
    fileprivate(set) var checkpointGroupingVisits = 0
    fileprivate(set) var checkpointChainVisits = 0
    fileprivate(set) var taskGroupingVisits = 0
    fileprivate(set) var authoritativeTaskVisits = 0
}

enum ReconstructionPackageCodec {
    static func preflightCanonicalEncodedByteCount<Value: Encodable>(
        _ value: Value
    ) throws -> Int {
        try ReconstructionPackageManifestPreflightEncoder.encodedByteCount(value)
    }

    @discardableResult
    static func validateGraph(_ state: ReconstructionWorkspaceState) throws
        -> ReconstructionPackageValidationWork {
        try validateDurableBounds(state)
        return try validateGraph(
            state,
            declaredContents: contentRecords(in: state),
            durableBoundsAreValidated: true
        )
    }

    static func encode(_ state: ReconstructionWorkspaceState) throws
        -> ReconstructionPackageEncodedManifests {
        try encode(
            state,
            manifestByteLimit: ReconstructionPackageLayout.maximumManifestBytes
        )
    }

    /// Internal limit injection keeps exact writer-boundary tests small. Production callers use
    /// the fixed package ceiling, and a test limit may only tighten that durable contract.
    static func encode(
        _ state: ReconstructionWorkspaceState,
        manifestByteLimit: Int
    ) throws -> ReconstructionPackageEncodedManifests {
        try Task.checkCancellation()
        guard (1...ReconstructionPackageLayout.maximumManifestBytes)
                .contains(manifestByteLimit) else {
            throw ReconstructionPackageValidationError.stateGraphInvalid(
                "manifest byte limit"
            )
        }
        let normalizedState = try state.normalizedJobRecords().pruningTerminalReplayRecordsForSave()
        try validateDurableBounds(normalizedState)
        for checkpoint in normalizedState.checkpoints {
            try Task.checkCancellation()
            try checkpoint.verifyCanonicalIdentity()
        }
        let contents = try contentRecords(in: normalizedState)
        try validateGraph(
            normalizedState,
            declaredContents: contents,
            durableBoundsAreValidated: true
        )
        try Task.checkCancellation()
        let corpus = try ReconstructionPackageCorpusManifest(
            contents: contents,
            projects: normalizedState.projects,
            corpusManifests: normalizedState.corpusManifests
        )
        let evidence = try ReconstructionPackageEvidenceManifest(
            evidence: normalizedState.evidence,
            evidenceRelations: normalizedState.evidenceRelations,
            evidenceGaps: normalizedState.evidenceGaps,
            toolReceipts: normalizedState.toolReceipts,
            modelReceipts: normalizedState.modelReceipts,
            finalResults: normalizedState.finalResults
        )
        try Task.checkCancellation()
        let checkpoint = try ReconstructionPackageCheckpointManifest(
            jobs: normalizedState.jobs,
            tasks: normalizedState.tasks,
            checkpoints: normalizedState.checkpoints,
            replayRecords: normalizedState.replayRecords
        )
        let corpusData = try encodeCorpusManifest(
            corpus,
            maximumBytes: manifestByteLimit
        )
        try Task.checkCancellation()
        let evidenceData = try encodeEvidenceManifest(
            evidence,
            maximumBytes: manifestByteLimit
        )
        try Task.checkCancellation()
        let checkpointData = try encodeCheckpointManifest(
            checkpoint,
            maximumBytes: manifestByteLimit
        )
        try Task.checkCancellation()
        return ReconstructionPackageEncodedManifests(
            descriptor: try ReconstructionPackageDescriptor(
                corpusManifestPath: ReconstructionPackageLayout.corpusManifestPath,
                evidenceManifestPath: ReconstructionPackageLayout.evidenceManifestPath,
                checkpointManifestPath: ReconstructionPackageLayout.checkpointManifestPath,
                corpusManifestSHA256: sha256(corpusData),
                evidenceManifestSHA256: sha256(evidenceData),
                checkpointManifestSHA256: sha256(checkpointData)
            ),
            corpusData: corpusData,
            evidenceData: evidenceData,
            checkpointData: checkpointData,
            contents: contents
        )
    }

    private static func encodeCorpusManifest(
        _ manifest: ReconstructionPackageCorpusManifest,
        maximumBytes: Int
    ) throws -> Data {
        var writer = ReconstructionPackageManifestWriter(
            maximumBytes: maximumBytes,
            path: ReconstructionPackageLayout.corpusManifestPath
        )
        try writer.appendLiteral("{\"contents\":")
        try writer.appendArray(manifest.contents)
        try writer.appendLiteral(",\"corpusManifests\":")
        try writer.appendArray(manifest.corpusManifests)
        try writer.appendLiteral(",\"projects\":")
        try writer.appendArray(manifest.projects)
        try writer.appendLiteral(",\"schemaVersion\":\(manifest.schemaVersion)}")
        return writer.data
    }

    private static func encodeEvidenceManifest(
        _ manifest: ReconstructionPackageEvidenceManifest,
        maximumBytes: Int
    ) throws -> Data {
        var writer = ReconstructionPackageManifestWriter(
            maximumBytes: maximumBytes,
            path: ReconstructionPackageLayout.evidenceManifestPath
        )
        try writer.appendLiteral("{\"evidence\":")
        try writer.appendArray(manifest.evidence)
        try writer.appendLiteral(",\"evidenceGaps\":")
        try writer.appendArray(manifest.evidenceGaps)
        try writer.appendLiteral(",\"evidenceRelations\":")
        try writer.appendArray(manifest.evidenceRelations)
        if !manifest.finalResults.isEmpty {
            try writer.appendLiteral(",\"finalResults\":")
            try writer.appendArray(manifest.finalResults)
        }
        try writer.appendLiteral(",\"modelReceipts\":")
        try writer.appendArray(manifest.modelReceipts)
        try writer.appendLiteral(",\"schemaVersion\":\(manifest.schemaVersion)")
        try writer.appendLiteral(",\"toolReceipts\":")
        try writer.appendArray(manifest.toolReceipts)
        try writer.appendLiteral("}")
        return writer.data
    }

    private static func encodeCheckpointManifest(
        _ manifest: ReconstructionPackageCheckpointManifest,
        maximumBytes: Int
    ) throws -> Data {
        var writer = ReconstructionPackageManifestWriter(
            maximumBytes: maximumBytes,
            path: ReconstructionPackageLayout.checkpointManifestPath
        )
        try writer.appendLiteral("{\"checkpoints\":")
        try writer.appendArray(manifest.checkpoints)
        try writer.appendLiteral(",\"jobs\":")
        try writer.appendArray(manifest.jobs)
        if let records = manifest.replayRecords {
            try writer.appendLiteral(",\"replayRecords\":")
            try writer.appendArray(records)
        }
        try writer.appendLiteral(",\"schemaVersion\":\(manifest.schemaVersion)")
        try writer.appendLiteral(",\"tasks\":")
        try writer.appendArray(manifest.tasks)
        try writer.appendLiteral("}")
        return writer.data
    }

    static func decode(
        descriptor: ReconstructionPackageDescriptor,
        corpusData: Data,
        evidenceData: Data,
        checkpointData: Data
    ) throws -> ReconstructionWorkspaceState {
        try Task.checkCancellation()
        try requireManifestSize(
            corpusData,
            path: descriptor.corpusManifestPath
        )
        try requireManifestSize(
            evidenceData,
            path: descriptor.evidenceManifestPath
        )
        try requireManifestSize(
            checkpointData,
            path: descriptor.checkpointManifestPath
        )
        try verifyDigest(
            corpusData,
            expected: descriptor.corpusManifestSHA256,
            path: descriptor.corpusManifestPath
        )
        try verifyDigest(
            evidenceData,
            expected: descriptor.evidenceManifestSHA256,
            path: descriptor.evidenceManifestPath
        )
        try verifyDigest(
            checkpointData,
            expected: descriptor.checkpointManifestSHA256,
            path: descriptor.checkpointManifestPath
        )
        let corpus: ReconstructionPackageCorpusManifest = try decodeStrict(
            corpusData,
            path: descriptor.corpusManifestPath
        )
        let evidence: ReconstructionPackageEvidenceManifest = try decodeStrict(
            evidenceData,
            path: descriptor.evidenceManifestPath
        )
        let checkpoint: ReconstructionPackageCheckpointManifest = try decodeStrict(
            checkpointData,
            path: descriptor.checkpointManifestPath
        )
        try Task.checkCancellation()
        let state = try ReconstructionWorkspaceState(
            projects: corpus.projects,
            corpusManifests: corpus.corpusManifests,
            evidence: evidence.evidence,
            evidenceRelations: evidence.evidenceRelations,
            evidenceGaps: evidence.evidenceGaps,
            jobs: checkpoint.jobs,
            tasks: checkpoint.tasks,
            checkpoints: checkpoint.checkpoints,
            toolReceipts: evidence.toolReceipts,
            modelReceipts: evidence.modelReceipts,
            finalResults: evidence.finalResults,
            replayRecords: checkpoint.replayRecords
        )
        let normalizedState = try state.normalizedJobRecords()
        let validatedState = try validatedState(from: normalizedState)
        try validateGraph(validatedState, declaredContents: corpus.contents)
        try Task.checkCancellation()
        return validatedState
    }

    static func contentRecords(in state: ReconstructionWorkspaceState) throws
        -> [ReconstructionPackageContentRecord] {
        var identitiesByDigest: [String: ReconstructionContentIdentity] = [:]
        for manifest in state.corpusManifests {
            try Task.checkCancellation()
            for occurrence in manifest.artifacts {
                try Task.checkCancellation()
                let identity = occurrence.contentIdentity
                try ReconstructionValidation.requireSHA256(identity.digest, field: "content digest")
                guard identity.byteCount > 0 else {
                    throw ReconstructionPackageValidationError.contentIdentityConflict(identity.digest)
                }
                if let existing = identitiesByDigest[identity.digest], existing != identity {
                    throw ReconstructionPackageValidationError.contentIdentityConflict(identity.digest)
                }
                identitiesByDigest[identity.digest] = identity
            }
        }
        let records = try identitiesByDigest.values.map { identity in
            try Task.checkCancellation()
            return try ReconstructionPackageContentRecord(
                contentIdentity: identity,
                attachmentPath: ReconstructionPackageLayout.attachmentPath(for: identity)
            )
        }.sorted { $0.contentIdentity.digest < $1.contentIdentity.digest }
        try Task.checkCancellation()
        return records
    }

    private static func validatedState(
        from state: ReconstructionWorkspaceState
    ) throws -> ReconstructionWorkspaceState {
        try Task.checkCancellation()
        guard state.schemaVersion == ReconstructionWorkspaceState.schemaVersion else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("workspace schema")
        }
        let projects = try state.projects.map { project in
            try Task.checkCancellation()
            guard project.schemaVersion == ReconstructionProjectRecord.schemaVersion else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("project schema")
            }
            return try ReconstructionProjectRecord(
                projectID: project.projectID,
                schemaVersion: project.schemaVersion,
                name: project.name,
                currentCorpusManifestSHA256: project.currentCorpusManifestSHA256
            )
        }
        let corpusManifests = try state.corpusManifests.map { manifest in
            try Task.checkCancellation()
            guard manifest.schemaVersion == ReconstructionCorpusManifest.schemaVersion else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("corpus record schema")
            }
            let artifacts = try manifest.artifacts.map { artifact in
                try Task.checkCancellation()
                return try ReconstructionArtifactOccurrenceRecord(
                    occurrenceID: artifact.occurrenceID,
                    contentIdentity: artifact.contentIdentity,
                    kind: artifact.kind,
                    roles: artifact.roles,
                    executableMode: artifact.executableMode,
                    originalName: artifact.originalName,
                    diagnostic: artifact.diagnostic
                )
            }
            let relations = try manifest.relations.map { relation in
                try Task.checkCancellation()
                return try ReconstructionArtifactRelationRecord(
                    relationID: relation.relationID,
                    kind: relation.kind,
                    sourceOccurrenceID: relation.sourceOccurrenceID,
                    targetOccurrenceID: relation.targetOccurrenceID,
                    unresolvedLocator: relation.unresolvedLocator,
                    evidenceSource: relation.evidenceSource,
                    canonicalSHA256: relation.canonicalSHA256
                )
            }
            return try ReconstructionCorpusManifest(
                schemaVersion: manifest.schemaVersion,
                reconstructionProjectID: manifest.reconstructionProjectID,
                artifacts: artifacts,
                relations: relations,
                canonicalSHA256: manifest.canonicalSHA256
            )
        }
        let evidence = try state.evidence.map { record in
            try Task.checkCancellation()
            guard record.schemaVersion == ReconstructionEvidenceRecord.schemaVersion,
                  record.producer.schemaVersion == ReconstructionProducerIdentity.schemaVersion else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("evidence schema")
            }
            let producer = try validatedProducer(record.producer)
            let dependencies = try record.facetDependencies.map {
                try Task.checkCancellation()
                return try ReconstructionFacetDependency(
                    facetIdentity: $0.facetIdentity,
                    fingerprintSHA256: $0.fingerprintSHA256
                )
            }
            let citations = try record.citations.map {
                try Task.checkCancellation()
                return try ReconstructionEvidenceCitation(
                    citationID: $0.citationID,
                    sourceEvidenceID: $0.sourceEvidenceID,
                    subject: try $0.subject.map(validatedSubject),
                    locator: $0.locator
                )
            }
            return try ReconstructionEvidenceRecord(
                evidenceID: record.evidenceID,
                schemaVersion: record.schemaVersion,
                subject: try validatedSubject(record.subject),
                operationID: record.operationID,
                payloadKind: record.payloadKind,
                payload: record.payload,
                payloadByteCount: record.payloadByteCount,
                payloadSHA256: record.payloadSHA256,
                facetDependencies: dependencies,
                producer: producer,
                citations: citations,
                creatingJobID: record.creatingJobID,
                creatingTaskID: record.creatingTaskID,
                creatingCheckpointID: record.creatingCheckpointID,
                modelReceiptID: record.modelReceiptID,
                toolReceiptID: record.toolReceiptID,
                classification: record.classification,
                supersedesEvidenceID: record.supersedesEvidenceID,
                supersededByEvidenceID: record.supersededByEvidenceID,
                diagnostic: record.diagnostic
            )
        }
        let evidenceGaps = try state.evidenceGaps.map {
            try Task.checkCancellation()
            return try ReconstructionEvidenceGap(
                gapID: $0.gapID,
                subject: try validatedSubject($0.subject),
                operationID: $0.operationID,
                reason: $0.reason,
                canonicalSHA256: $0.canonicalSHA256
            )
        }
        let jobs = try state.jobs.map { job in
            try Task.checkCancellation()
            let currentSchema = job.featureScope == nil
                ? ReconstructionJobRecord.schemaVersion : ReconstructionJobRecord.featureScopeSchemaVersion
            guard job.recordSchemaVersion == currentSchema,
                  let creationOrdinal = job.creationOrdinal else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "job record schema"
                )
            }
            return try ReconstructionJobRecord(
                jobID: job.jobID,
                reconstructionProjectID: job.reconstructionProjectID,
                objective: job.objective,
                objectiveSHA256: job.objectiveSHA256,
                creationCorpusManifestSHA256: job.creationCorpusManifestSHA256,
                state: job.state,
                currentCheckpointID: job.currentCheckpointID,
                terminalReason: job.terminalReason,
                budget: try ReconstructionJobBudget(
                    maxRounds: job.budget.maxRounds,
                    maxTasks: job.budget.maxTasks,
                    maxEvidenceRecords: job.budget.maxEvidenceRecords,
                    maxEncodedBytes: job.budget.maxEncodedBytes
                ),
                creationOrdinal: creationOrdinal,
                pauseContext: job.pauseContext,
                focus: try job.focus.map(validatedSubject),
                sourceProfileID: job.sourceProfileID,
                featureScope: job.featureScope
            )
        }
        let tasks = try state.tasks.map { task in
            try Task.checkCancellation()
            guard task.identity.schemaVersion == ReconstructionTaskIdentity.schemaVersion else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("task schema")
            }
            let identity = try ReconstructionTaskIdentity(
                taskID: task.identity.taskID,
                schemaVersion: task.identity.schemaVersion,
                jobID: task.identity.jobID,
                kind: task.identity.kind,
                subject: try task.identity.subject.map(validatedSubject),
                dependencyTaskIDs: task.identity.dependencyTaskIDs,
                operationContractIdentity: task.identity.operationContractIdentity,
                canonicalSHA256: task.identity.canonicalSHA256
            )
            if let backend = task.decompileBackend {
                guard backend.isValid, task.state == .completed,
                      [.decompileNative, .compareDecompilers].contains(identity.kind) else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid("task decompile backend")
                }
            }
            return ReconstructionTaskRecord(
                identity: identity,
                state: task.state,
                diagnostic: task.diagnostic,
                decompileBackend: task.decompileBackend
            )
        }
        let checkpoints = try state.checkpoints.map { checkpoint in
            try Task.checkCancellation()
            guard checkpoint.schemaVersion == ReconstructionCheckpoint.schemaVersion else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("checkpoint schema")
            }
            try checkpoint.verifyCanonicalIdentity()
            return try ReconstructionCheckpoint(
                checkpointID: checkpoint.checkpointID,
                schemaVersion: checkpoint.schemaVersion,
                jobID: checkpoint.jobID,
                revision: checkpoint.revision,
                parentCheckpointID: checkpoint.parentCheckpointID,
                parentCheckpointSHA256: checkpoint.parentCheckpointSHA256,
                corpusManifestSHA256: checkpoint.corpusManifestSHA256,
                evidenceFrontierSHA256: checkpoint.evidenceFrontierSHA256,
                pendingTaskIDs: checkpoint.pendingTaskIDs,
                runningTaskIDs: checkpoint.runningTaskIDs,
                completedTaskIDs: checkpoint.completedTaskIDs,
                failedTaskIDs: checkpoint.failedTaskIDs,
                blockedTaskIDs: checkpoint.blockedTaskIDs,
                unresolvedEvidenceGapSHA256: checkpoint.unresolvedEvidenceGapSHA256,
                modelReceiptIDs: checkpoint.modelReceiptIDs,
                toolReceiptIDs: checkpoint.toolReceiptIDs,
                coordinatorState: checkpoint.coordinatorState,
                terminalReason: checkpoint.terminalReason,
                canonicalEncodedByteCount: checkpoint.canonicalEncodedByteCount,
                canonicalSHA256: checkpoint.canonicalSHA256
            )
        }
        let toolReceipts = try state.toolReceipts.map { receipt in
            try Task.checkCancellation()
            return try ReconstructionToolReceipt(
                receiptID: receipt.receiptID,
                jobID: receipt.jobID,
                taskID: receipt.taskID,
                checkpointRevision: receipt.checkpointRevision,
                requestIdentitySHA256: receipt.requestIdentitySHA256,
                producer: try validatedProducer(receipt.producer),
                terminalState: receipt.terminalState,
                outputEvidenceIDs: receipt.outputEvidenceIDs,
                diagnostic: receipt.diagnostic,
                canonicalSHA256: receipt.canonicalSHA256,
                evidenceReadAuthority: receipt.evidenceReadAuthority
            )
        }
        let modelReceipts = try state.modelReceipts.map { receipt in
            try Task.checkCancellation()
            return try ReconstructionModelReceipt(
                receiptID: receipt.receiptID,
                jobID: receipt.jobID,
                taskID: receipt.taskID,
                checkpointRevision: receipt.checkpointRevision,
                requestIdentitySHA256: receipt.requestIdentitySHA256,
                producer: try validatedProducer(receipt.producer),
                terminalState: receipt.terminalState,
                selectedHandleIDs: receipt.selectedHandleIDs,
                acceptedEvidenceIDs: receipt.acceptedEvidenceIDs,
                diagnostic: receipt.diagnostic,
                finalResultCommitment: receipt.finalResultCommitment,
                canonicalSHA256: receipt.canonicalSHA256
            )
        }
        let finalResults = try state.finalResults.map { result in
            try Task.checkCancellation()
            return try ReconstructionFinalResultRecord(
                resultID: result.resultID,
                schemaVersion: result.schemaVersion,
                jobID: result.jobID,
                taskID: result.taskID,
                checkpointID: result.checkpointID,
                checkpointRevision: result.checkpointRevision,
                requestID: result.requestID,
                requestIdentitySHA256: result.requestIdentitySHA256,
                kind: result.kind,
                payloadUTF8: result.payloadUTF8,
                payloadByteCount: result.payloadByteCount,
                payloadSHA256: result.payloadSHA256,
                citedEvidenceIDs: result.citedEvidenceIDs,
                producer: try validatedProducer(result.producer),
                modelReceiptID: result.modelReceiptID,
                canonicalSHA256: result.canonicalSHA256
            )
        }
        let evidenceRelations = try state.evidenceRelations.map { relation in
            try Task.checkCancellation()
            return relation
        }
        try Task.checkCancellation()
        return try ReconstructionWorkspaceState(
            schemaVersion: state.schemaVersion,
            projects: projects,
            corpusManifests: corpusManifests,
            evidence: evidence,
            evidenceRelations: evidenceRelations,
            evidenceGaps: evidenceGaps,
            jobs: jobs,
            tasks: tasks,
            checkpoints: checkpoints,
            toolReceipts: toolReceipts,
            modelReceipts: modelReceipts,
            finalResults: finalResults,
            replayRecords: state.replayRecords
        )
    }

    private static func validatedSubject(
        _ subject: ReconstructionSubjectCoordinate
    ) throws -> ReconstructionSubjectCoordinate {
        try Task.checkCancellation()
        switch subject {
        case .artifact(let coordinate):
            return .artifact(coordinate)
        case .image(let coordinate):
            return .image(
                try ReconstructionImageCoordinate(
                    artifact: coordinate.artifact,
                    image: coordinate.image,
                    analysisFingerprintSHA256: coordinate.analysisFingerprintSHA256
                )
            )
        case .function(let coordinate):
            return .function(
                try ReconstructionFunctionCoordinate(
                    artifact: coordinate.artifact,
                    image: coordinate.image,
                    analysisFingerprintSHA256: coordinate.analysisFingerprintSHA256,
                    startAddress: coordinate.startAddress,
                    endAddressExclusive: coordinate.endAddressExclusive,
                    boundarySchemaVersion: coordinate.boundarySchemaVersion,
                    functionUUIDHint: coordinate.functionUUIDHint,
                    symbolHint: coordinate.symbolHint
                )
            )
        }
    }

    private static func validatedProducer(
        _ producer: ReconstructionProducerIdentity
    ) throws -> ReconstructionProducerIdentity {
        try Task.checkCancellation()
        guard producer.schemaVersion == ReconstructionProducerIdentity.schemaVersion else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("producer schema")
        }
        return try ReconstructionProducerIdentity(
            schemaVersion: producer.schemaVersion,
            macScopeBuildIdentity: producer.macScopeBuildIdentity,
            macScopeSourceIdentity: producer.macScopeSourceIdentity,
            operationIdentity: producer.operationIdentity,
            registryIdentity: producer.registryIdentity,
            protocolIdentity: producer.protocolIdentity,
            nativeProviderIdentity: producer.nativeProviderIdentity,
            nativeCapabilityIdentities: producer.nativeCapabilityIdentities,
            modelKey: producer.modelKey,
            endpointOrigin: producer.endpointOrigin,
            observedModelInventorySHA256: producer.observedModelInventorySHA256,
            observedConfigurationSHA256: producer.observedConfigurationSHA256,
            toolchainIdentity: producer.toolchainIdentity,
            canonicalSHA256: producer.canonicalSHA256
        )
    }

    @discardableResult
    /// A persisted scope must still name its own checkpoint, corpus-owned subjects and existing
    /// project evidence; live admission checks currency, this checks durable references.
    static func validateFeatureScope(
        _ scope: ReconstructionFeatureScope,
        job: ReconstructionJobRecord,
        state: ReconstructionWorkspaceState,
        checkpoints: [UUID: ReconstructionCheckpoint],
        corpusHistory: ReconstructionCorpusHistoryIndex
    ) throws {
        func artifact(of subject: ReconstructionSubjectCoordinate) -> ReconstructionArtifactCoordinate {
            switch subject {
            case .artifact(let artifact): artifact
            case .image(let image): image.artifact
            case .function(let function): function.artifact
            }
        }
        let subjects = [ReconstructionSubjectCoordinate.function(scope.feature)]
            + scope.dependencies.compactMap(\.subject)
        guard let checkpoint = checkpoints[scope.admittedAtCheckpointID],
              checkpoint.jobID == job.jobID,
              checkpoint.revision == scope.admittedAtCheckpointRevision,
              checkpoint.canonicalSHA256 == scope.admittedAtCheckpointSHA256,
              checkpoint.evidenceFrontierSHA256 == scope.evidenceFrontierSHA256,
              subjects.allSatisfy({
                  corpusHistory.contains($0, projectID: job.reconstructionProjectID,
                                         manifestSHA256: checkpoint.corpusManifestSHA256)
              }) else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("job feature scope references")
        }
        let projectsByJobID = Dictionary(state.jobs.map { ($0.jobID, $0.reconstructionProjectID) },
                                         uniquingKeysWith: { first, _ in first })
        let evidenceByID = Dictionary(state.evidence.map { ($0.evidenceID, $0) },
                                      uniquingKeysWith: { first, _ in first })
        let scenarioIDs = Set(scope.scenarios.map(\.oracleEvidenceID))
        for evidenceID in scope.acceptedEvidenceIDs {
            guard let record = evidenceByID[evidenceID],
                  projectsByJobID[record.creatingJobID] == job.reconstructionProjectID,
                  (record.subject == .function(scope.feature)
                    || (scope.declaredArtifacts.contains(artifact(of: record.subject))
                        && record.subject == .artifact(artifact(of: record.subject)))),
                  !scenarioIDs.contains(evidenceID)
                    || (record.operationID == "reconstruction.source.oracle" && record.creatingJobID == job.jobID) else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("job feature scope evidence")
            }
        }
        do { try scope.validateScenarioBindings(recordsByID: evidenceByID) }
        catch { throw ReconstructionPackageValidationError.stateGraphInvalid("job feature scope scenario") }
    }

    static func validateGraph(
        _ state: ReconstructionWorkspaceState,
        declaredContents: [ReconstructionPackageContentRecord],
        durableBoundsAreValidated: Bool = false
    ) throws -> ReconstructionPackageValidationWork {
        try Task.checkCancellation()
        if !durableBoundsAreValidated { try validateDurableBounds(state) }
        let expectedContents = try contentRecords(in: state)
        guard expectedContents == declaredContents else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("content manifest disagreement")
        }
        let projects = try uniqueDictionary(
            state.projects,
            keyedBy: \.projectID,
            duplicate: "duplicate project"
        )
        let corpusHistory: ReconstructionCorpusHistoryIndex
        do {
            corpusHistory = try ReconstructionCorpusHistoryIndex(
                projects: state.projects,
                manifests: state.corpusManifests
            )
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch let failure as ReconstructionCorpusHistoryIndex.Failure {
            throw ReconstructionPackageValidationError.stateGraphInvalid(failure.graphReason)
        }

        var work = ReconstructionPackageValidationWork()

        let jobs = try uniqueDictionary(state.jobs, keyedBy: \.jobID, duplicate: "duplicate job")
        let tasks = try uniqueDictionary(
            state.tasks,
            keyedBy: { $0.identity.taskID },
            duplicate: "duplicate task"
        )
        let checkpoints = try uniqueDictionary(
            state.checkpoints,
            keyedBy: \.checkpointID,
            duplicate: "duplicate checkpoint"
        )
        let evidence = try uniqueDictionary(
            state.evidence,
            keyedBy: \.evidenceID,
            duplicate: "duplicate evidence"
        )
        let evidenceGaps = try uniqueDictionary(
            state.evidenceGaps,
            keyedBy: \.gapID,
            duplicate: "duplicate evidence gap"
        )
        let toolReceipts = try uniqueDictionary(
            state.toolReceipts,
            keyedBy: \.receiptID,
            duplicate: "duplicate tool receipt"
        )
        try validateUniqueToolReceiptTaskBindings(state.toolReceipts)
        let modelReceipts = try uniqueDictionary(
            state.modelReceipts,
            keyedBy: \.receiptID,
            duplicate: "duplicate model receipt"
        )
        let finalResults = try uniqueDictionary(
            state.finalResults,
            keyedBy: \.resultID,
            duplicate: "duplicate final result"
        )
        var checkpointsByJobID: [UUID: [UInt64: ReconstructionCheckpoint]] = [:]
        for checkpoint in state.checkpoints {
            try Task.checkCancellation()
            work.checkpointGroupingVisits += 1
            do {
                try checkpoint.verifyCanonicalIdentity()
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "checkpoint identity"
                )
            }
            guard jobs[checkpoint.jobID] != nil else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("orphan checkpoint")
            }
            var jobCheckpoints = checkpointsByJobID[checkpoint.jobID] ?? [:]
            guard jobCheckpoints.updateValue(checkpoint, forKey: checkpoint.revision) == nil else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "checkpoint revision chain"
                )
            }
            checkpointsByJobID[checkpoint.jobID] = jobCheckpoints
        }
        var tasksByJobID: [UUID: [ReconstructionTaskRecord]] = [:]
        for task in state.tasks {
            try Task.checkCancellation()
            work.taskGroupingVisits += 1
            guard jobs[task.identity.jobID] != nil else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("task references")
            }
            tasksByJobID[task.identity.jobID, default: []].append(task)
        }
        for job in state.jobs {
            try Task.checkCancellation()
            work.jobVisits += 1
            let objectiveSHA256 = sha256(Data(job.objective.utf8))
            try Task.checkCancellation()
            guard projects[job.reconstructionProjectID] != nil,
                  corpusHistory.manifest(
                      projectID: job.reconstructionProjectID,
                      canonicalSHA256: job.creationCorpusManifestSHA256
                  ) != nil,
                  job.currentCheckpointID.map({ checkpoints[$0]?.jobID == job.jobID }) ?? true,
                  objectiveSHA256 == job.objectiveSHA256 else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("job references")
            }
            if let focus = job.focus {
                let artifact: ReconstructionArtifactCoordinate
                switch focus {
                case .artifact(let coordinate): artifact = coordinate
                case .function(let coordinate):
                    artifact = coordinate.artifact
                    guard state.evidence.contains(where: { $0.subject == focus }) else {
                        throw ReconstructionPackageValidationError.stateGraphInvalid(
                            "job function focus evidence"
                        )
                    }
                case .image:
                    throw ReconstructionPackageValidationError.stateGraphInvalid("job focus kind")
                }
                guard corpusHistory.contains(focus, projectID: job.reconstructionProjectID,
                    manifestSHA256: job.creationCorpusManifestSHA256),
                    tasksByJobID[job.jobID]?.contains(where: {
                        $0.identity.kind == .ingest && $0.identity.subject == .artifact(artifact)
                            && $0.identity.dependencyTaskIDs.isEmpty
                    }) == true else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid(
                        "job focus selected corpus ownership"
                    )
                }
            }
            if let scope = job.featureScope {
                try validateFeatureScope(scope, job: job, state: state, checkpoints: checkpoints,
                                         corpusHistory: corpusHistory)
            }
        }
        for task in state.tasks {
            try Task.checkCancellation()
            do {
                try task.identity.verifyCanonicalIdentity()
            } catch {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "task canonical identity"
                )
            }
            guard let job = jobs[task.identity.jobID],
                  try task.identity.dependencyTaskIDs.allSatisfy({ dependencyID in
                      try Task.checkCancellation()
                      return tasks[dependencyID]?.identity.jobID == task.identity.jobID
                  }) else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("task references")
            }
            if let subject = task.identity.subject {
                guard corpusHistory.contains(
                    subject,
                    projectID: job.reconstructionProjectID,
                    manifestSHA256: job.creationCorpusManifestSHA256
                ) else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid(
                        "task subject corpus ownership"
                    )
                }
            }
        }
        try validateTaskDependencyDAG(tasks)
        for job in state.jobs {
            try Task.checkCancellation()
            let checkpointsByRevision = checkpointsByJobID[job.jobID] ?? [:]
            let jobTasks = tasksByJobID[job.jobID] ?? []
            try Task.checkCancellation()
            let tail = checkpointsByRevision.isEmpty
                ? nil
                : checkpointsByRevision[UInt64(checkpointsByRevision.count - 1)]
            guard job.currentCheckpointID == tail?.checkpointID else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "job current checkpoint is not the chain tail"
                )
            }
            for index in 0..<checkpointsByRevision.count {
                try Task.checkCancellation()
                guard let checkpoint = checkpointsByRevision[UInt64(index)] else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid(
                        "checkpoint revision chain"
                    )
                }
                work.checkpointChainVisits += 1
                if index == 0 {
                    guard checkpoint.parentCheckpointID == nil,
                          checkpoint.parentCheckpointSHA256 == nil else {
                        throw ReconstructionPackageValidationError.stateGraphInvalid("checkpoint root")
                    }
                } else {
                    guard let prior = checkpointsByRevision[UInt64(index - 1)] else {
                        throw ReconstructionPackageValidationError.stateGraphInvalid(
                            "checkpoint revision chain"
                        )
                    }
                    guard checkpoint.parentCheckpointID == prior.checkpointID,
                          checkpoint.parentCheckpointSHA256 == prior.canonicalSHA256 else {
                        throw ReconstructionPackageValidationError.stateGraphInvalid("checkpoint parent chain")
                    }
                }
                guard try checkpointTaskIDsBelongToJob(
                    checkpoint,
                    jobID: job.jobID,
                    tasks: tasks
                ), checkpoint.corpusManifestSHA256 == job.creationCorpusManifestSHA256 else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid("checkpoint frontier")
                }
                work.authoritativeTaskVisits += try validateTaskFrontier(
                    checkpoint,
                    jobID: job.jobID,
                    tasks: tasks,
                    jobTasks: jobTasks,
                    isAuthoritative: checkpoint.checkpointID == job.currentCheckpointID
                )
            }
            if let tail {
                guard tail.coordinatorState == job.state,
                      tail.terminalReason == job.terminalReason else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid(
                        "job and checkpoint tail disagree"
                    )
                }
            }
            if job.state == .paused {
                guard let pauseContext = job.pauseContext,
                      let tail,
                      tail.revision > 0,
                      checkpointsByRevision[tail.revision - 1]?.coordinatorState
                        == pauseContext.resumeTarget else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid(
                        "job pause context history"
                    )
                }
            }
        }
        try validateCumulativeReceiptFrontiers(
            checkpoints: state.checkpoints,
            toolReceipts: toolReceipts,
            modelReceipts: modelReceipts
        )
        try validateModelTaskReceiptBindings(
            tasks: tasks,
            checkpointsByJobID: checkpointsByJobID,
            toolReceipts: toolReceipts,
            modelReceipts: state.modelReceipts
        )
        try validateSourceRevisionGraph(jobs: jobs, tasks: tasks,
            checkpointsByJobID: checkpointsByJobID, evidence: evidence,
            modelReceipts: modelReceipts, toolReceipts: toolReceipts)
        try validateSourceEvaluationGraph(tasks: tasks, jobs: jobs, checkpointsByJobID: checkpointsByJobID,
            evidence: evidence, toolReceipts: toolReceipts)
        var evidenceProjectIDs: [UUID: UUID] = [:]
        for record in state.evidence {
            try Task.checkCancellation()
            guard let creatingJob = jobs[record.creatingJobID],
                  corpusHistory.contains(
                      record.subject,
                      projectID: creatingJob.reconstructionProjectID,
                      manifestSHA256: creatingJob.creationCorpusManifestSHA256
                  ) else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "evidence subject corpus ownership"
                )
            }
            evidenceProjectIDs[record.evidenceID] = creatingJob.reconstructionProjectID
        }
        for record in state.evidence {
            try Task.checkCancellation()
            guard ReconstructionOperationID(rawValue: record.operationID) != nil else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "evidence operation ID"
                )
            }
            guard record.producer.operationIdentity == record.operationID else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "evidence producer operation identity"
                )
            }
            try validateProducerIntegrity(
                record.producer,
                identityReason: "evidence producer identity",
                digestReason: "evidence producer digest"
            )
            let payloadSHA256 = sha256(record.payload)
            try Task.checkCancellation()
            guard jobs[record.creatingJobID] != nil,
                  tasks[record.creatingTaskID]?.identity.jobID == record.creatingJobID,
                  checkpoints[record.creatingCheckpointID]?.jobID == record.creatingJobID,
                  payloadSHA256 == record.payloadSHA256,
                  UInt64(record.payload.count) == record.payloadByteCount else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("evidence provenance")
            }

            guard record.modelReceiptID != nil || record.toolReceiptID != nil else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "evidence receipt provenance"
                )
            }
            if let receiptID = record.modelReceiptID {
                guard let receipt = modelReceipts[receiptID],
                      receipt.jobID == record.creatingJobID,
                      receipt.taskID == record.creatingTaskID,
                      checkpoints[record.creatingCheckpointID]?.revision
                        == receipt.checkpointRevision,
                      receipt.acceptedEvidenceIDs.contains(record.evidenceID),
                      receipt.producer == record.producer else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid(
                        "evidence receipt provenance"
                    )
                }
            }
            if let receiptID = record.toolReceiptID {
                guard let receipt = toolReceipts[receiptID],
                      receipt.jobID == record.creatingJobID,
                      receipt.taskID == record.creatingTaskID,
                      checkpoints[record.creatingCheckpointID]?.revision
                        == receipt.checkpointRevision,
                      receipt.outputEvidenceIDs.contains(record.evidenceID),
                      receipt.producer == record.producer else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid(
                        "evidence receipt provenance"
                    )
                }
            }

            guard !record.citations.isEmpty else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("evidence citation")
            }
            let recordProjectID = evidenceProjectIDs[record.evidenceID]
            var citationAnchors = Set<ReconstructionEvidenceCitationAnchor>()
            for citation in record.citations {
                try Task.checkCancellation()
                let anchor = ReconstructionEvidenceCitationAnchor(citation)
                guard citation.sourceEvidenceID != nil || citation.subject != nil,
                      citationAnchors.insert(anchor).inserted,
                      citation.sourceEvidenceID.map({ sourceID in
                          sourceID != record.evidenceID
                              && evidence[sourceID] != nil
                              && evidenceProjectIDs[sourceID] == recordProjectID
                      }) ?? true else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid(
                        citation.sourceEvidenceID == nil
                            ? "evidence citation"
                            : "evidence citation project ownership"
                    )
                }
                if let subject = citation.subject {
                    guard corpusHistory.projectID(containing: subject) == recordProjectID else {
                        throw ReconstructionPackageValidationError.stateGraphInvalid(
                            "evidence citation project ownership"
                        )
                    }
                }
            }
        }
        var gapProjectIDs: [UUID: UUID] = [:]
        for gap in state.evidenceGaps {
            try Task.checkCancellation()
            guard let projectID = corpusHistory.projectID(containing: gap.subject) else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "subject artifact coordinate"
                )
            }
            guard ReconstructionOperationID(rawValue: gap.operationID) != nil else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("gap operation ID")
            }
            guard try ReconstructionEvidenceIntegrity.canonicalGapSHA256(gap)
                    == gap.canonicalSHA256 else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("gap digest")
            }
            gapProjectIDs[gap.gapID] = projectID
        }
        do {
            _ = try ReconstructionEvidenceGraphIntegrity.validate(
                records: state.evidence,
                relations: state.evidenceRelations,
                gapIDs: Set(evidenceGaps.keys)
            )
        } catch let error as ReconstructionEvidenceGraphIntegrityError {
            let reason: String
            switch error {
            case .duplicateEvidenceID:
                reason = "duplicate evidence"
            case .duplicateRelationID:
                reason = "duplicate evidence relation"
            case .relationEndpointMissing:
                reason = "evidence relation"
            case .selfRelation:
                reason = "evidence self relation"
            case .cycleDetected:
                reason = "evidence relation cycle"
            case .inconsistentSupersession:
                reason = "evidence supersession"
            }
            throw ReconstructionPackageValidationError.stateGraphInvalid(reason)
        }
        for relation in state.evidenceRelations {
            try Task.checkCancellation()
            let sourceProjectID = evidenceProjectIDs[relation.sourceEvidenceID]
            let targetProjectID = relation.kind == .resolvesGap
                ? gapProjectIDs[relation.targetEvidenceID]
                : evidenceProjectIDs[relation.targetEvidenceID]
            guard sourceProjectID != nil, sourceProjectID == targetProjectID else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "evidence relation project ownership"
                )
            }
        }
        for receipt in state.toolReceipts {
            try Task.checkCancellation()
            if let read = receipt.evidenceReadAuthority {
                try read.validate(receipt: receipt)
                guard read.request.retrievalQuery?.focus == jobs[receipt.jobID]?.focus,
                      read.readEvidenceIDs.allSatisfy({ evidenceID in
                          guard let record = evidence[evidenceID],
                                let query = read.request.retrievalQuery else { return false }
                          return query.includes(subject: record.subject)
                            && query.operationIDs.contains(where: { $0.rawValue == record.operationID })
                      }) else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid("evidence read authority")
                }
            }
            try validateProducerIntegrity(
                receipt.producer,
                identityReason: "tool receipt producer identity",
                digestReason: "tool receipt producer digest"
            )
            guard try ReconstructionReceiptAuthority.toolReceiptHasCanonicalIdentity(receipt) else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "tool receipt digest"
                )
            }
            guard tasks[receipt.taskID]?.identity.jobID == receipt.jobID,
                  try receipt.outputEvidenceIDs.allSatisfy({ evidenceID in
                      try Task.checkCancellation()
                      guard let record = evidence[evidenceID] else { return false }
                      return record.toolReceiptID == receipt.receiptID
                          && record.creatingJobID == receipt.jobID
                          && record.creatingTaskID == receipt.taskID
                  }) else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("tool receipt")
            }
        }
        for receipt in state.modelReceipts {
            try Task.checkCancellation()
            try validateProducerIntegrity(
                receipt.producer,
                identityReason: "model receipt producer identity",
                digestReason: "model receipt producer digest"
            )
            guard try ReconstructionReceiptAuthority.modelReceiptHasCanonicalIdentity(receipt) else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "model receipt digest"
                )
            }
            let acceptedEvidenceIsBound: Bool
            if receipt.finalResultCommitment == nil {
                acceptedEvidenceIsBound = try receipt.acceptedEvidenceIDs.allSatisfy { evidenceID in
                    try Task.checkCancellation()
                    guard let record = evidence[evidenceID] else { return false }
                    return record.modelReceiptID == receipt.receiptID
                        && record.creatingJobID == receipt.jobID
                        && record.creatingTaskID == receipt.taskID
                }
            } else {
                guard let job = jobs[receipt.jobID] else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid("model receipt")
                }
                acceptedEvidenceIsBound = receipt.acceptedEvidenceIDs.allSatisfy { evidenceID in
                    guard let record = evidence[evidenceID] else { return false }
                    return evidenceProjectIDs[evidenceID] == job.reconstructionProjectID
                        && record.classification == .acceptedCurrent
                        && record.supersededByEvidenceID == nil
                }
            }
            guard tasks[receipt.taskID]?.identity.jobID == receipt.jobID,
                  acceptedEvidenceIsBound else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("model receipt")
            }
        }
        var finalResultJobIDs = Set<UUID>()
        var committedFinalResultIDs = Set<UUID>()
        for result in state.finalResults {
            try Task.checkCancellation()
            guard finalResultJobIDs.insert(result.jobID).inserted,
                  try ReconstructionReceiptAuthority.finalResultHasCanonicalIdentity(result),
                  let job = jobs[result.jobID],
                  job.state == .completed,
                  job.currentCheckpointID == result.checkpointID,
                  let task = tasks[result.taskID],
                  task.identity.jobID == result.jobID,
                  task.identity.kind == .modelRound,
                  task.identity.operationContractIdentity == "reconstruction.finalSynthesis.v1",
                  result.producer.operationIdentity
                    == task.identity.operationContractIdentity,
                  task.state == .completed,
                  let checkpoint = checkpoints[result.checkpointID],
                  checkpoint.jobID == result.jobID,
                  checkpoint.revision == result.checkpointRevision,
                  checkpoint.coordinatorState == .completed,
                  checkpoint.completedTaskIDs.contains(result.taskID),
                  checkpoint.modelReceiptIDs.contains(result.modelReceiptID),
                  let receipt = modelReceipts[result.modelReceiptID],
                  receipt.receiptID == result.requestID,
                  receipt.jobID == result.jobID,
                  receipt.taskID == result.taskID,
                  receipt.checkpointRevision == result.checkpointRevision,
                  receipt.requestIdentitySHA256 == result.requestIdentitySHA256,
                  receipt.producer == result.producer,
                  receipt.terminalState == .completed,
                  receipt.selectedHandleIDs.isEmpty,
                  receipt.acceptedEvidenceIDs == result.citedEvidenceIDs,
                  receipt.diagnostic == nil,
                  receipt.finalResultCommitment == (try ReconstructionFinalResultCommitment(
                      resultID: result.resultID,
                      canonicalSHA256: result.canonicalSHA256
                  )),
                  result.citedEvidenceIDs.allSatisfy({ evidenceID in
                      guard let record = evidence[evidenceID] else { return false }
                      return evidenceProjectIDs[evidenceID] == job.reconstructionProjectID
                          && record.classification == .acceptedCurrent
                          && record.supersededByEvidenceID == nil
                  }) else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("final result")
            }
            try validateProducerIntegrity(
                result.producer,
                identityReason: "final result producer identity",
                digestReason: "final result producer digest"
            )
            committedFinalResultIDs.insert(result.resultID)
        }
        let receiptCommittedFinalResultIDs = Set(
            state.modelReceipts.compactMap { $0.finalResultCommitment?.resultID }
        )
        guard committedFinalResultIDs == Set(finalResults.keys),
              receiptCommittedFinalResultIDs == committedFinalResultIDs,
              state.modelReceipts.filter({ $0.finalResultCommitment != nil }).count
                == state.finalResults.count else {
            throw ReconstructionPackageValidationError.stateGraphInvalid(
                "final result commitment"
            )
        }
        try Task.checkCancellation()
        return work
    }

    private static func validateProducerIntegrity(
        _ producer: ReconstructionProducerIdentity,
        identityReason: String,
        digestReason: String
    ) throws {
        guard ReconstructionEvidenceIntegrity
                .producerContainsOnlyDurableBoundedIdentity(producer) else {
            throw ReconstructionPackageValidationError.stateGraphInvalid(identityReason)
        }
        guard try ReconstructionEvidenceIntegrity.canonicalProducerSHA256(producer)
                == producer.canonicalSHA256 else {
            throw ReconstructionPackageValidationError.stateGraphInvalid(digestReason)
        }
    }

    private static func validateDurableBounds(
        _ state: ReconstructionWorkspaceState
    ) throws {
        try ReconstructionEvidenceIntegrity.validateDurableBounds(
            projects: state.projects,
            corpusManifests: state.corpusManifests,
            evidence: state.evidence,
            relations: state.evidenceRelations,
            gaps: state.evidenceGaps,
            jobs: state.jobs,
            tasks: state.tasks,
            checkpoints: state.checkpoints,
            toolReceipts: state.toolReceipts,
            modelReceipts: state.modelReceipts,
            finalResults: state.finalResults
        )
    }

    private static func checkpointTaskIDsBelongToJob(
        _ checkpoint: ReconstructionCheckpoint,
        jobID: UUID,
        tasks: [UUID: ReconstructionTaskRecord]
    ) throws -> Bool {
        func belongs(_ taskIDs: [UUID]) throws -> Bool {
            for taskID in taskIDs {
                try Task.checkCancellation()
                guard tasks[taskID]?.identity.jobID == jobID else { return false }
            }
            return true
        }
        return try belongs(checkpoint.pendingTaskIDs)
            && belongs(checkpoint.runningTaskIDs)
            && belongs(checkpoint.completedTaskIDs)
            && belongs(checkpoint.failedTaskIDs)
            && belongs(checkpoint.blockedTaskIDs)
    }

    private static func validateTaskFrontier(
        _ checkpoint: ReconstructionCheckpoint,
        jobID: UUID,
        tasks: [UUID: ReconstructionTaskRecord],
        jobTasks: [ReconstructionTaskRecord],
        isAuthoritative: Bool
    ) throws -> Int {
        guard isAuthoritative else { return 0 }
        let buckets: [([UUID], Set<ReconstructionTaskState>)] = [
            (checkpoint.pendingTaskIDs, [.pending]),
            (checkpoint.runningTaskIDs, [.running]),
            (checkpoint.completedTaskIDs, [.completed]),
            (checkpoint.failedTaskIDs, [.failed, .cancelled]),
            (checkpoint.blockedTaskIDs, [.blocked]),
        ]
        var observed = Set<UUID>()
        for (taskIDs, allowedStates) in buckets {
            try Task.checkCancellation()
            for taskID in taskIDs {
                try Task.checkCancellation()
                guard observed.insert(taskID).inserted,
                      let task = tasks[taskID],
                      task.identity.jobID == jobID,
                      allowedStates.contains(task.state) else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid(
                        "checkpoint task state disagreement"
                    )
                }
            }
        }
        for task in jobTasks {
            try Task.checkCancellation()
            guard observed.contains(task.identity.taskID) else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "authoritative checkpoint task frontier incomplete"
                )
            }
        }
        guard observed.count == jobTasks.count else {
            throw ReconstructionPackageValidationError.stateGraphInvalid(
                "authoritative checkpoint task frontier incomplete"
            )
        }
        return jobTasks.count
    }

    private static func validateTaskDependencyDAG(
        _ tasks: [UUID: ReconstructionTaskRecord]
    ) throws {
        var remainingDependencyCounts: [UUID: Int] = [:]
        var dependentsByDependency: [UUID: [UUID]] = [:]
        for (taskID, task) in tasks {
            try Task.checkCancellation()
            remainingDependencyCounts[taskID] = task.identity.dependencyTaskIDs.count
            for dependencyID in task.identity.dependencyTaskIDs {
                try Task.checkCancellation()
                guard tasks[dependencyID] != nil else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid(
                        "unknown task dependency"
                    )
                }
                dependentsByDependency[dependencyID, default: []].append(taskID)
            }
        }

        var ready: [UUID] = []
        for (taskID, count) in remainingDependencyCounts {
            try Task.checkCancellation()
            if count == 0 { ready.append(taskID) }
        }
        var nextReadyIndex = 0
        var visitedCount = 0
        while nextReadyIndex < ready.count {
            try Task.checkCancellation()
            let taskID = ready[nextReadyIndex]
            nextReadyIndex += 1
            visitedCount += 1
            for dependentID in dependentsByDependency[taskID] ?? [] {
                try Task.checkCancellation()
                guard let remaining = remainingDependencyCounts[dependentID], remaining > 0 else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid(
                        "unknown task dependency"
                    )
                }
                let successor = remaining - 1
                remainingDependencyCounts[dependentID] = successor
                if successor == 0 { ready.append(dependentID) }
            }
        }
        guard visitedCount == tasks.count else {
            throw ReconstructionPackageValidationError.stateGraphInvalid(
                "task dependency cycle"
            )
        }
    }

    static func validateCumulativeReceiptFrontiers(
        checkpoints: [ReconstructionCheckpoint],
        toolReceipts: [UUID: ReconstructionToolReceipt],
        modelReceipts: [UUID: ReconstructionModelReceipt]
    ) throws {
        var introducedToolReceiptIDs = Set<UUID>()
        var introducedModelReceiptIDs = Set<UUID>()
        var checkpointsByJob: [UUID: [UInt64: ReconstructionCheckpoint]] = [:]
        for checkpoint in checkpoints {
            try Task.checkCancellation()
            var jobCheckpoints = checkpointsByJob[checkpoint.jobID] ?? [:]
            guard jobCheckpoints.updateValue(checkpoint, forKey: checkpoint.revision) == nil else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "checkpoint revision chain"
                )
            }
            checkpointsByJob[checkpoint.jobID] = jobCheckpoints
        }

        for (jobID, jobCheckpoints) in checkpointsByJob {
            try Task.checkCancellation()
            var cumulativeToolReceiptIDs = Set<UUID>()
            var cumulativeModelReceiptIDs = Set<UUID>()
            for revision in 0..<jobCheckpoints.count {
                try Task.checkCancellation()
                guard let checkpoint = jobCheckpoints[UInt64(revision)] else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid(
                        "checkpoint revision chain"
                    )
                }
                let checkpointToolReceiptIDs = Set(checkpoint.toolReceiptIDs)
                let checkpointModelReceiptIDs = Set(checkpoint.modelReceiptIDs)
                guard checkpointToolReceiptIDs.isSuperset(of: cumulativeToolReceiptIDs),
                      checkpointModelReceiptIDs.isSuperset(of: cumulativeModelReceiptIDs) else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid(
                        "checkpoint receipt frontier omission"
                    )
                }

                for receiptID in checkpoint.toolReceiptIDs {
                    try Task.checkCancellation()
                    guard let receipt = toolReceipts[receiptID], receipt.jobID == jobID else {
                        throw ReconstructionPackageValidationError.stateGraphInvalid(
                            "checkpoint tool receipt"
                        )
                    }
                    if receipt.checkpointRevision == checkpoint.revision {
                        guard introducedToolReceiptIDs.insert(receiptID).inserted else {
                            throw ReconstructionPackageValidationError.stateGraphInvalid(
                                "duplicate tool receipt introduction"
                            )
                        }
                        cumulativeToolReceiptIDs.insert(receiptID)
                    } else {
                        guard receipt.checkpointRevision < checkpoint.revision,
                              cumulativeToolReceiptIDs.contains(receiptID) else {
                            throw ReconstructionPackageValidationError.stateGraphInvalid(
                                "tool receipt first introduction"
                            )
                        }
                    }
                }
                for receiptID in checkpoint.modelReceiptIDs {
                    try Task.checkCancellation()
                    guard let receipt = modelReceipts[receiptID], receipt.jobID == jobID else {
                        throw ReconstructionPackageValidationError.stateGraphInvalid(
                            "checkpoint model receipt"
                        )
                    }
                    if receipt.checkpointRevision == checkpoint.revision {
                        guard introducedModelReceiptIDs.insert(receiptID).inserted else {
                            throw ReconstructionPackageValidationError.stateGraphInvalid(
                                "duplicate model receipt introduction"
                            )
                        }
                        cumulativeModelReceiptIDs.insert(receiptID)
                    } else {
                        guard receipt.checkpointRevision < checkpoint.revision,
                              cumulativeModelReceiptIDs.contains(receiptID) else {
                            throw ReconstructionPackageValidationError.stateGraphInvalid(
                                "model receipt first introduction"
                            )
                        }
                    }
                }
            }
        }

        guard introducedToolReceiptIDs == Set(toolReceipts.keys),
              introducedModelReceiptIDs == Set(modelReceipts.keys) else {
            throw ReconstructionPackageValidationError.stateGraphInvalid(
                "unintroduced receipt"
            )
        }
    }

    /// Validates source authority recoverable from the persisted graph. This gate checks
    /// canonical payload integrity and durable ownership. Bound revisions additionally authenticate their retained request and selected
    /// oracle through the persisted receipt graph; nil bindings retain legacy fixture semantics.
    static func validateSourceRevisionGraph(
        jobs: [UUID: ReconstructionJobRecord],
        tasks: [UUID: ReconstructionTaskRecord],
        checkpointsByJobID: [UUID: [UInt64: ReconstructionCheckpoint]],
        evidence: [UUID: ReconstructionEvidenceRecord],
        modelReceipts: [UUID: ReconstructionModelReceipt],
        toolReceipts: [UUID: ReconstructionToolReceipt] = [:]
    ) throws {
        let operation = "reconstruction.source.revision"
        let grouped = Dictionary(grouping: evidence.values.filter { $0.operationID == operation }, by: \.creatingJobID)
        var sourceEvidenceIDs = Set<UUID>()
        var checkpointsByID: [UUID: ReconstructionCheckpoint] = [:]
        for checkpoints in checkpointsByJobID.values {
            for checkpoint in checkpoints.values {
                try Task.checkCancellation()
                checkpointsByID[checkpoint.checkpointID] = checkpoint
            }
        }
        for (jobID, records) in grouped {
            try Task.checkCancellation()
            guard let job = jobs[jobID], records.count <= 2 else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("source revision history")
            }
            let checkpoints = checkpointsByJobID[jobID] ?? [:]
            let ordered = records.sorted { left, right in
                let l = checkpointsByID[left.creatingCheckpointID]?.revision ?? UInt64.max
                let r = checkpointsByID[right.creatingCheckpointID]?.revision ?? UInt64.max
                return l < r
            }
            var prior: ReconstructionSourceRevision?
            var previousCheckpoint: UInt64?
            var previousTask: UUID?
            var previousReceipt: UUID?
            for record in ordered {
                try Task.checkCancellation()
                guard let task = tasks[record.creatingTaskID], task.state == .completed,
                      task.identity.kind == .modelRound, task.identity.jobID == jobID,
                      task.identity.operationContractIdentity == "reconstruction.source.revision.v1",
                      let receiptID = record.modelReceiptID, let receipt = modelReceipts[receiptID],
                      receipt.jobID == jobID, receipt.taskID == task.identity.taskID,
                      receipt.producer == record.producer, receipt.producer.operationIdentity == operation,
                      receipt.terminalState == .completed, receipt.diagnostic == nil,
                      receipt.selectedHandleIDs.isEmpty, receipt.finalResultCommitment == nil,
                      receipt.acceptedEvidenceIDs == [record.evidenceID],
                      let checkpoint = checkpoints[receipt.checkpointRevision],
                      checkpoint.checkpointID == record.creatingCheckpointID,
                      checkpoint.completedTaskIDs.contains(task.identity.taskID),
                      checkpoint.modelReceiptIDs.contains(receiptID),
                      let parentID = checkpoint.parentCheckpointID, let parent = checkpointsByID[parentID],
                      parent.jobID == jobID,
                      parent.canonicalSHA256 == checkpoint.parentCheckpointSHA256,
                      parent.revision < checkpoint.revision,
                      previousCheckpoint.map({ $0 < checkpoint.revision }) ?? true,
                      previousTask != task.identity.taskID, previousReceipt != receiptID,
                      record.payloadKind == .structuredJSON, record.toolReceiptID == nil,
                      record.classification == .acceptedCurrent, record.diagnostic == nil,
                      record.facetDependencies.isEmpty, record.supersedesEvidenceID == nil,
                      record.supersededByEvidenceID == nil,
                      record.payloadByteCount == UInt64(record.payload.count),
                      record.payloadSHA256 == sha256(record.payload),
                      record.payload.count <= ReconstructionSourceRevision.maximumPayloadBytes else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid("source revision ownership")
                }
                do {
                    let decoded = try JSONDecoder().decode(ReconstructionSourceRevision.self, from: record.payload)
                    guard task.identity.subject == .function(decoded.function), record.subject == task.identity.subject,
                          decoded.profileID == (try ReconstructionSourceProfile.retainedSourceProfile(job.sourceProfileID)).rawValue else {
                        throw ReconstructionPackageValidationError.stateGraphInvalid("source revision subject")
                    }
                    let offeredIDs: Set<UUID>
                    if let binding = decoded.requestBinding {
                        offeredIDs = try validateSourceRequestGraph(binding: binding, revision: decoded,
                            job: job, task: task, receipt: receipt, admissionCheckpoint: parent,
                            prior: prior, jobs: jobs, tasks: tasks, checkpointsByID: checkpointsByID,
                            evidence: evidence, toolReceipts: toolReceipts)
                    } else { offeredIDs = Set(decoded.evidenceIDs) }
                    var admissibleIDs = Set<UUID>()
                    for id in offeredIDs {
                        guard id != record.evidenceID, let cited = evidence[id],
                              let citedJob = jobs[cited.creatingJobID],
                              citedJob.reconstructionProjectID == job.reconstructionProjectID,
                              let citedCheckpoint = checkpointsByID[cited.creatingCheckpointID],
                              citedCheckpoint.jobID == cited.creatingJobID,
                              cited.creatingJobID != jobID || citedCheckpoint.revision <= parent.revision else {
                            throw ReconstructionPackageValidationError.stateGraphInvalid("source revision evidence cut")
                        }
                        admissibleIDs.insert(id)
                    }
                    let authority = try ReconstructionSourceRevisionAuthority(projectID: job.reconstructionProjectID,
                        jobID: jobID, function: decoded.function, objectiveSHA256: job.objectiveSHA256,
                        evidenceFrontierSHA256: parent.evidenceFrontierSHA256,
                        oracleSuiteSHA256: decoded.oracleSuiteSHA256, admissibleEvidenceIDs: admissibleIDs,
                        currentRevision: prior, requestBinding: decoded.requestBinding,
                        profileID: ReconstructionSourceProfile.retainedSourceProfile(job.sourceProfileID).rawValue)
                    let revision = try ReconstructionSourceRevisionAdmission.decodeAndValidate(payload: record.payload, authority: authority)
                    guard record.citations.count == revision.evidenceIDs.count,
                          Set(record.citations.compactMap(\.sourceEvidenceID)) == Set(revision.evidenceIDs),
                          Set(record.citations.map(\.citationID)).count == record.citations.count,
                          record.citations.allSatisfy({ $0.sourceEvidenceID != nil && $0.subject == nil && $0.locator == nil }) else {
                        throw ReconstructionPackageValidationError.stateGraphInvalid("source revision citations")
                    }
                    prior = revision
                } catch let cancellation as CancellationError { throw cancellation }
                catch let error as ReconstructionPackageValidationError { throw error }
                catch { throw ReconstructionPackageValidationError.stateGraphInvalid("source revision payload") }
                previousCheckpoint = checkpoint.revision
                previousTask = task.identity.taskID
                previousReceipt = receiptID
                sourceEvidenceIDs.insert(record.evidenceID)
            }
        }
        let completedSourceTaskIDs = Set(modelReceipts.values.filter {
            $0.terminalState == .completed && $0.acceptedEvidenceIDs.count == 1
                && sourceEvidenceIDs.contains($0.acceptedEvidenceIDs[0])
        }.map(\.taskID))
        for task in tasks.values where task.identity.operationContractIdentity == "reconstruction.source.revision.v1" && task.state == .completed {
            guard completedSourceTaskIDs.contains(task.identity.taskID) else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("source revision missing evidence")
            }
        }
    }

    /// Authenticates the retained request against its actual graph owners and every offered
    /// evidence record, including offered evidence the candidate chose not to cite.
    private static func validateSourceRequestGraph(
        binding: ReconstructionSourceRequestBinding, revision: ReconstructionSourceRevision,
        job: ReconstructionJobRecord, task: ReconstructionTaskRecord, receipt: ReconstructionModelReceipt,
        admissionCheckpoint: ReconstructionCheckpoint, prior: ReconstructionSourceRevision?,
        jobs: [UUID: ReconstructionJobRecord], tasks: [UUID: ReconstructionTaskRecord],
        checkpointsByID: [UUID: ReconstructionCheckpoint], evidence: [UUID: ReconstructionEvidenceRecord],
        toolReceipts: [UUID: ReconstructionToolReceipt]
    ) throws -> Set<UUID> {
        guard !binding.canonicalRequestBytes.isEmpty,
              binding.canonicalRequestBytes.count <= ReconstructionSourceRequestBinding.maximumRequestBytes,
              sha256(binding.canonicalRequestBytes) == binding.requestSHA256,
              binding.requestSHA256 == receipt.requestIdentitySHA256,
              binding.taskID == task.identity.taskID,
              binding.checkpointRevision == admissionCheckpoint.revision,
              let request = try JSONSerialization.jsonObject(with: binding.canonicalRequestBytes) as? [String: Any],
              request["corpusManifestSHA256"] as? String == admissionCheckpoint.corpusManifestSHA256,
              let objective = request["objective"] as? [String: Any], objective["text"] as? String == job.objective,
              let context = request["context"] as? [String: Any],
              let ids = context["evidenceIDs"] as? [String], !ids.isEmpty, ids.count <= 64,
              let encodedContext = context["canonicalBytes"] as? String, let contextBytes = Data(base64Encoded: encodedContext),
              contextBytes.count <= ReconstructionSourceRequestBinding.maximumContextBytes,
              let envelope = try JSONSerialization.jsonObject(with: contextBytes) as? [String: Any],
              JSONSerialization.isValidJSONObject(envelope) else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("source request graph binding")
        }
        let offered: Set<UUID>
        if envelope["domain"] as? String == "reconstruction.source-context.v10" {
            offered = try validateSourceContextV10(contextBytes: contextBytes, ids: ids, revision: revision,
                prior: prior, job: job, admissionCheckpoint: admissionCheckpoint, jobs: jobs,
                checkpointsByID: checkpointsByID, evidence: evidence)
        } else {
            offered = try validateSourceBaseContext(contextBytes: contextBytes, ids: ids, job: job,
                admissionCheckpoint: admissionCheckpoint, jobs: jobs,
                checkpointsByID: checkpointsByID, evidence: evidence)
        }
        let oracleRecords = offered.compactMap { evidence[$0] }.filter {
            $0.operationID == "reconstruction.source.oracle" && $0.creatingJobID == job.jobID
                && $0.subject == .function(revision.function)
        }
        guard oracleRecords.count == 1, let record = oracleRecords.first,
              let receiptID = record.toolReceiptID, let oracleReceipt = toolReceipts[receiptID],
              let oracleTask = tasks[record.creatingTaskID], oracleTask.state == .completed,
              oracleTask.identity.kind == .executeSource, oracleTask.identity.jobID == job.jobID,
              oracleTask.identity.subject == record.subject,
              oracleTask.identity.operationContractIdentity == "reconstruction.source.oracle.v1",
              let checkpoint = checkpointsByID[record.creatingCheckpointID],
              checkpoint.jobID == job.jobID, checkpoint.revision <= admissionCheckpoint.revision,
              checkpoint.completedTaskIDs.contains(oracleTask.identity.taskID), checkpoint.toolReceiptIDs.contains(receiptID),
              oracleReceipt.taskID == oracleTask.identity.taskID, oracleReceipt.jobID == job.jobID,
              oracleReceipt.checkpointRevision == checkpoint.revision, oracleReceipt.terminalState == .completed,
              oracleReceipt.diagnostic == nil, oracleReceipt.outputEvidenceIDs == [record.evidenceID],
              oracleReceipt.evidenceReadAuthority == nil, record.modelReceiptID == nil,
              oracleReceipt.producer == record.producer, record.producer.operationIdentity == "reconstruction.source.oracle",
              record.producer.modelKey == nil, record.producer.endpointOrigin == nil,
              record.payload.count <= ReconstructionSourceOracle.maximumPayloadBytes,
              record.payloadKind == .structuredJSON else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("source selected oracle ownership")
        }
        let oracle = try JSONDecoder().decode(ReconstructionSourceOracle.self, from: record.payload)
        let harness = try ReconstructionSourceBehaviorHarness.forProfile(oracle.profileID)
        guard var preimage = try JSONSerialization.jsonObject(with: record.payload) as? [String: Any] else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("source selected oracle payload")
        }
        preimage.removeValue(forKey: "suiteSHA256")
        for digest in [oracle.execution.originalImageSHA256, oracle.execution.originalExecutableSHA256,
            oracle.execution.harnessSHA256, oracle.execution.compilerSHA256, oracle.execution.sdkIdentitySHA256,
            oracle.execution.compileProfileSHA256, oracle.execution.compileArgumentsSHA256,
            oracle.execution.executionArgumentsSHA256, oracle.execution.producerSHA256]
            + [oracle.execution.originalSourceSHA256].compactMap({ $0 }) {
            try ReconstructionValidation.requireSHA256(digest, field: "source selected oracle execution")
        }
        guard checkpointsByID.values.filter({ $0.jobID == job.jobID && $0.completedTaskIDs.contains(oracleTask.identity.taskID) })
                .map(\.revision).min() == checkpoint.revision else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("source selected oracle completion")
        }
        guard try ReconstructionCanonicalJSON.encode(oracle) == record.payload,
              oracle.version == ReconstructionSourceOracle.version, ReconstructionSourceProfile.admits(oracle.profileID),
              oracle.profileID == revision.profileID, oracle.profileID == (try ReconstructionSourceProfile.retainedSourceProfile(job.sourceProfileID)).rawValue,
              oracle.projectID == job.reconstructionProjectID, oracle.jobID == job.jobID, oracle.function == revision.function,
              oracle.suiteSHA256 == revision.oracleSuiteSHA256,
              oracle.suiteSHA256 == sha256(try JSONSerialization.data(withJSONObject: preimage, options: [.sortedKeys, .withoutEscapingSlashes])),
              oracle.execution.originalImageSHA256 == revision.function.artifact.contentIdentity.digest,
              oracle.execution.originalExecutableSHA256 == revision.function.artifact.contentIdentity.digest,
              oracle.execution.producerSHA256 == record.producer.canonicalSHA256,
              !oracle.evidenceIDs.isEmpty, oracle.evidenceIDs.count <= 64,
              oracle.evidenceIDs == ReconstructionValidation.sortedUUIDs(oracle.evidenceIDs),
              Set(oracle.evidenceIDs).count == oracle.evidenceIDs.count,
              record.citations.count == oracle.evidenceIDs.count,
              Set(record.citations.compactMap(\.sourceEvidenceID)) == Set(oracle.evidenceIDs),
              record.citations.allSatisfy({ $0.sourceEvidenceID != nil && $0.subject == nil && $0.locator == nil }),
              oracle.execution.harnessSHA256 == sha256(harness.sourceUTF8), oracle.inputs == harness.inputs,
              oracle.outputs == (try harness.decodeObservedOutputs(oracle.execution.standardOutput)),
              oracle.execution.exitCode == 0, oracle.execution.observedProcessAbsent,
              oracle.execution.processIdentifier > 0, !oracle.execution.sampledProcessIDs.isEmpty,
              oracle.execution.sampledProcessIDs.count <= 1_024,
              oracle.execution.sampledProcessIDs.allSatisfy({ $0 > 0 }),
              Set(oracle.execution.sampledProcessIDs).count == oracle.execution.sampledProcessIDs.count,
              oracle.execution.sampledProcessIDs.contains(oracle.execution.processIdentifier) else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("source selected oracle payload")
        }
        for id in oracle.evidenceIDs {
            guard id != record.evidenceID, let cited = evidence[id], let citedJob = jobs[cited.creatingJobID],
                  citedJob.reconstructionProjectID == job.reconstructionProjectID,
                  let citedCheckpoint = checkpointsByID[cited.creatingCheckpointID],
                  citedCheckpoint.jobID == cited.creatingJobID,
                  cited.creatingJobID != job.jobID || citedCheckpoint.revision <= checkpoint.revision else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("source selected oracle citations")
            }
        }
        let authority = ReconstructionSourceRevisionAuthority(projectID: job.reconstructionProjectID,
            jobID: job.jobID, function: revision.function, objectiveSHA256: job.objectiveSHA256,
            evidenceFrontierSHA256: admissionCheckpoint.evidenceFrontierSHA256,
            oracleSuiteSHA256: oracle.suiteSHA256, admissibleEvidenceIDs: offered, currentRevision: prior,
            profileID: revision.profileID)
        let authenticated = try ReconstructionSourceRevisionAdmission.makeRequestBinding(
            canonicalRequestBytes: binding.canonicalRequestBytes, requestSHA256: receipt.requestIdentitySHA256,
            authority: authority, expectedTaskID: task.identity.taskID, expectedRoundID: binding.roundID,
            expectedCheckpointRevision: admissionCheckpoint.revision)
        guard authenticated == binding else { throw ReconstructionPackageValidationError.stateGraphInvalid("source request graph binding") }
        return offered
    }

    // Neutral persisted presentation DTOs keep the package consumer independent of runtime
    // compilers. Canonical equality rejects unknown keys and alternate nested encodings.
    private struct SourceContextOracle: Codable {
        let evidenceID: UUID; let payloadSHA256: String; let suiteSHA256: String
        let function: ReconstructionFunctionCoordinate; let profileID: String
        let inputs: [UInt32]; let outputs: [UInt32]
    }
    private struct SourceContextParent: Codable {
        let evidenceID: UUID; let payloadSHA256: String; let revisionSHA256: String
        let sourceSHA256: String; let sourceText: String
    }
    private struct SourceContextDiagnostic: Codable {
        let evidenceID: UUID; let payloadSHA256: String; let operationID: String
        let checkpointRevision: UInt64; let revisionSHA256: String; let sourceSHA256: String
        let diagnostic: String
    }
    private struct SourceContextEnvelope: Codable {
        let schemaVersion: Int; let domain: String
        let corpusManifestSHA256: String; let evidenceFrontierSHA256: String
        let evidenceIDs: [UUID]; let baseContext: Data; let baseContextSHA256: String
        let oracle: SourceContextOracle; let parent: SourceContextParent?
        let diagnostics: [SourceContextDiagnostic]
    }
    private struct SourceDiagnosticPayload: Codable {
        let version: Int; let profileID: String; let function: ReconstructionFunctionCoordinate
        let revisionSHA256: String; let sourceSHA256: String; let diagnostic: String
    }

    private static func validateSourceContextV10(contextBytes: Data, ids: [String],
        revision: ReconstructionSourceRevision, prior: ReconstructionSourceRevision?,
        job: ReconstructionJobRecord, admissionCheckpoint: ReconstructionCheckpoint,
        jobs: [UUID: ReconstructionJobRecord], checkpointsByID: [UUID: ReconstructionCheckpoint],
        evidence: [UUID: ReconstructionEvidenceRecord]) throws -> Set<UUID> {
        let envelope = try JSONDecoder().decode(SourceContextEnvelope.self, from: contextBytes)
        guard try ReconstructionCanonicalJSON.encode(envelope) == contextBytes,
              envelope.schemaVersion == 10, envelope.domain == "reconstruction.source-context.v10",
              envelope.corpusManifestSHA256 == admissionCheckpoint.corpusManifestSHA256,
              envelope.evidenceFrontierSHA256 == admissionCheckpoint.evidenceFrontierSHA256,
              envelope.evidenceIDs.map(\.uuidString) == ids,
              envelope.evidenceIDs == ReconstructionValidation.sortedUUIDs(envelope.evidenceIDs),
              Set(envelope.evidenceIDs).count == envelope.evidenceIDs.count,
              envelope.baseContext.count <= 16_384,
              sha256(envelope.baseContext) == envelope.baseContextSHA256,
              let base = try JSONSerialization.jsonObject(with: envelope.baseContext) as? [String: Any],
              let baseIDs = base["evidenceIDs"] as? [String] else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("source compact context identity")
        }
        var offered = try validateSourceBaseContext(contextBytes: envelope.baseContext, ids: baseIDs,
            job: job, admissionCheckpoint: admissionCheckpoint, jobs: jobs,
            checkpointsByID: checkpointsByID, evidence: evidence, allowLegacyRawRecords: false)
        func retained(_ id: UUID, _ payloadSHA256: String) throws -> ReconstructionEvidenceRecord {
            guard let record = evidence[id], let owner = jobs[record.creatingJobID],
                  owner.reconstructionProjectID == job.reconstructionProjectID,
                  let checkpoint = checkpointsByID[record.creatingCheckpointID],
                  checkpoint.jobID == record.creatingJobID,
                  record.creatingJobID != job.jobID || checkpoint.revision <= admissionCheckpoint.revision,
                  record.payloadSHA256 == payloadSHA256, sha256(record.payload) == payloadSHA256,
                  record.payloadByteCount == UInt64(record.payload.count), record.payloadKind == .structuredJSON else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("source compact offered evidence")
            }
            return record
        }
        let oracleRecord = try retained(envelope.oracle.evidenceID, envelope.oracle.payloadSHA256)
        guard oracleRecord.payload.count <= ReconstructionSourceOracle.maximumPayloadBytes else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("source compact oracle bounds")
        }
        let oracle = try JSONDecoder().decode(ReconstructionSourceOracle.self, from: oracleRecord.payload)
        guard oracleRecord.operationID == "reconstruction.source.oracle", oracleRecord.creatingJobID == job.jobID,
              oracleRecord.subject == .function(revision.function),
              envelope.oracle.suiteSHA256 == oracle.suiteSHA256, oracle.suiteSHA256 == revision.oracleSuiteSHA256,
              envelope.oracle.function == oracle.function, oracle.function == revision.function,
              envelope.oracle.profileID == oracle.profileID,
              envelope.oracle.inputs == oracle.inputs, envelope.oracle.outputs == oracle.outputs else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("source compact oracle presentation")
        }
        offered.insert(oracleRecord.evidenceID)
        var parentRecord: ReconstructionEvidenceRecord?
        if let parent = envelope.parent {
            let record = try retained(parent.evidenceID, parent.payloadSHA256)
            guard let prior, record.operationID == "reconstruction.source.revision",
                  record.creatingJobID == job.jobID, record.subject == .function(revision.function),
                  record.payload.count <= ReconstructionSourceRevision.maximumPayloadBytes,
                  prior.sourceUTF8.count <= 4_096,
                  parent.revisionSHA256 == prior.revisionSHA256, parent.sourceSHA256 == prior.sourceSHA256,
                  Data(parent.sourceText.utf8) == prior.sourceUTF8,
                  try ReconstructionCanonicalJSON.encode(prior) == record.payload else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("source compact parent presentation")
            }
            parentRecord = record; offered.insert(record.evidenceID)
        } else if prior != nil {
            throw ReconstructionPackageValidationError.stateGraphInvalid("source compact missing parent")
        }
        guard envelope.diagnostics.count <= 2, parentRecord != nil || envelope.diagnostics.isEmpty,
              Set(envelope.diagnostics.map(\.operationID)).count == envelope.diagnostics.count,
              Set(envelope.diagnostics.map(\.evidenceID)).count == envelope.diagnostics.count else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("source compact diagnostic set")
        }
        if let parent = envelope.parent {
            var expectedDiagnostics = Set<UUID>()
            var candidatesByOperation: [String: [(UUID, UInt64)]] = [:]
            for candidate in evidence.values where candidate.creatingJobID == job.jobID
                && candidate.subject == .function(revision.function) {
                guard [.acceptedCurrent, .failed, .truncated].contains(candidate.classification),
                      let cp = checkpointsByID[candidate.creatingCheckpointID], cp.jobID == job.jobID,
                      cp.revision <= admissionCheckpoint.revision else { continue }
                let sameParent: Bool
                if candidate.operationID == "reconstruction.source.evaluate" {
                    sameParent = (try? JSONDecoder().decode(ReconstructionSourceEvaluation.self,
                        from: candidate.payload))?.revisionSHA256 == parent.revisionSHA256
                } else if ["reconstruction.source.build", "reconstruction.source.behavior"].contains(candidate.operationID) {
                    sameParent = (try? JSONDecoder().decode(SourceDiagnosticPayload.self,
                        from: candidate.payload))?.revisionSHA256 == parent.revisionSHA256
                } else { continue }
                if sameParent { candidatesByOperation[candidate.operationID, default: []].append((candidate.evidenceID, cp.revision)) }
            }
            let operations = candidatesByOperation["reconstruction.source.evaluate"] == nil
                ? ["reconstruction.source.build", "reconstruction.source.behavior"] : ["reconstruction.source.evaluate"]
            for operation in operations {
                guard let candidates = candidatesByOperation[operation], let newest = candidates.map({ $0.1 }).max() else { continue }
                let latest = candidates.filter { $0.1 == newest }
                guard latest.count == 1, let selected = latest.first else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid("source compact ambiguous diagnostic")
                }
                expectedDiagnostics.insert(selected.0)
            }
            guard expectedDiagnostics == Set(envelope.diagnostics.map(\.evidenceID)) else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("source compact missing diagnostic")
            }
        }
        for summary in envelope.diagnostics {
            let record = try retained(summary.evidenceID, summary.payloadSHA256)
            guard let parent = envelope.parent, let prior, let parentRecord,
                  record.creatingJobID == job.jobID, record.subject == .function(revision.function),
                  record.operationID == summary.operationID,
                  let checkpoint = checkpointsByID[record.creatingCheckpointID],
                  checkpoint.revision == summary.checkpointRevision,
                  let parentCheckpoint = checkpointsByID[parentRecord.creatingCheckpointID],
                  summary.operationID != "reconstruction.source.evaluate" || summary.checkpointRevision > parentCheckpoint.revision,
                  summary.revisionSHA256 == parent.revisionSHA256, summary.sourceSHA256 == parent.sourceSHA256,
                  !summary.diagnostic.isEmpty, summary.diagnostic.utf8.count <= 2_048,
                  !summary.diagnostic.utf8.contains(0) else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("source compact diagnostic ownership")
            }
            if summary.operationID == "reconstruction.source.evaluate" {
                guard envelope.diagnostics.count == 1 else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid("source compact aggregate diagnostics")
                }
                let evaluation = try ReconstructionSourceEvaluationCodec.decodeAndValidateCanonical(payload: record.payload)
                guard evaluation.projectID == job.reconstructionProjectID, evaluation.jobID == job.jobID,
                      evaluation.function == revision.function, evaluation.taskID == record.creatingTaskID,
                      evaluation.checkpointRevision == summary.checkpointRevision,
                      evaluation.revisionSHA256 == parent.revisionSHA256, evaluation.sourceSHA256 == parent.sourceSHA256,
                      evaluation.sourceEvidenceID == parent.evidenceID, evaluation.sourcePayloadSHA256 == parent.payloadSHA256,
                      evaluation.sourceRequestSHA256 == prior.requestBinding?.requestSHA256,
                      evaluation.oracleEvidenceID == oracleRecord.evidenceID,
                      evaluation.oraclePayloadSHA256 == oracleRecord.payloadSHA256,
                      evaluation.oracleSuiteSHA256 == oracle.suiteSHA256,
                      evaluation.producerSHA256 == record.producer.canonicalSHA256,
                      record.producer.operationIdentity == summary.operationID,
                      summary.diagnostic == sourceAggregateDiagnosticText(evaluation, oracle: envelope.oracle) else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid("source compact aggregate presentation")
                }
            } else {
                guard ["reconstruction.source.build", "reconstruction.source.behavior"].contains(summary.operationID),
                      record.payload.count <= 8_192 else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid("source compact diagnostic operation")
                }
                let payload = try JSONDecoder().decode(SourceDiagnosticPayload.self, from: record.payload)
                guard try ReconstructionCanonicalJSON.encode(payload) == record.payload,
                      payload.version == 1, payload.profileID == revision.profileID,
                      payload.function == revision.function, payload.revisionSHA256 == parent.revisionSHA256,
                      payload.sourceSHA256 == parent.sourceSHA256, payload.diagnostic == summary.diagnostic else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid("source compact diagnostic presentation")
                }
            }
            // A retained older diagnostic cannot replace the newest observation at this cut.
            let newer = evidence.values.contains { candidate in
                guard [.acceptedCurrent, .failed, .truncated].contains(candidate.classification),
                      candidate.creatingJobID == job.jobID, candidate.subject == record.subject,
                      candidate.operationID == record.operationID,
                      let cp = checkpointsByID[candidate.creatingCheckpointID],
                      cp.revision <= admissionCheckpoint.revision, cp.revision >= summary.checkpointRevision,
                      candidate.evidenceID != record.evidenceID else { return false }
                if summary.operationID == "reconstruction.source.evaluate" {
                    return (try? JSONDecoder().decode(ReconstructionSourceEvaluation.self, from: candidate.payload))?.revisionSHA256 == parent.revisionSHA256
                }
                return (try? JSONDecoder().decode(SourceDiagnosticPayload.self, from: candidate.payload))?.revisionSHA256 == parent.revisionSHA256
            }
            guard !newer else { throw ReconstructionPackageValidationError.stateGraphInvalid("source compact diagnostic selection") }
            offered.insert(record.evidenceID)
        }
        guard offered == Set(envelope.evidenceIDs) else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("source compact offered set")
        }
        return offered
    }

    private static func sourceAggregateDiagnosticText(_ evaluation: ReconstructionSourceEvaluation, oracle: SourceContextOracle) -> String {
        let outcome = evaluation.capturedOutcome
        var headline = "Evaluation: " + outcome.status.rawValue
        if let failure = outcome.failureDetail { headline += "\nFailure: " + failure }
        headline = boundedDiagnosticText(headline, maximumBytes: 320)
        let phases = outcome.phases
        guard !phases.isEmpty else { return boundedDiagnosticText(headline, maximumBytes: 2_048) }
        let phaseBudget = (2_048 - headline.utf8.count - phases.count) / phases.count
        let rows = phases.map { phase -> String in
            let label: String
            switch phase.operation.rawValue {
            case "inspect": label = "Inspection"
            case "compile": label = "Compiler"
            case "behavior": label = "Behavior"
            default: label = phase.operation.rawValue
            }
            var text = label + ": " + phase.status.rawValue
            if let terminal = phase.terminal {
                text += " terminal=" + terminal.kind.rawValue
                if let status = terminal.status { text += "(\(status))" }
            }
            if let failure = phase.failure { text += "\nFailure: " + failure }
            let hasObservedBehavior = phase.operation == .behavior && outcome.observations.count == oracle.outputs.count
            if hasObservedBehavior {
                let observed = outcome.observations.map(\.output)
                let mismatches = observed.indices.filter { observed[$0] != oracle.outputs[$0] }
                text += "\nObserved \(observed.count) cases; \(mismatches.count) mismatches."
                for index in mismatches {
                    text += "\ninput=\(oracle.inputs[index]) expected=\(oracle.outputs[index]) observed=\(observed[index])"
                }
            }
            if !hasObservedBehavior && !phase.diagnostics.isEmpty {
                if let diagnostic = String(data: phase.diagnostics, encoding: .utf8) { text += "\n" + diagnostic }
                else { text += "\nNon-UTF-8 diagnostics SHA256=" + sha256(phase.diagnostics) }
            }
            return boundedDiagnosticText(text, maximumBytes: phaseBudget)
        }
        return ([headline] + rows).joined(separator: "\n")
    }

    private static func boundedDiagnosticText(_ text: String, maximumBytes: Int) -> String {
        let safe = text.replacingOccurrences(of: "\0", with: "\\0")
        guard safe.utf8.count > maximumBytes else { return safe }
        let marker = " [diagnostic text omitted]"
        var prefix = "", bytes = 0
        for character in safe {
            let size = String(character).utf8.count
            guard bytes + size + marker.utf8.count <= maximumBytes else { break }
            prefix.append(character); bytes += size
        }
        return prefix + marker
    }

    private struct SourceRetrievedRecord: Codable {
        let record: ReconstructionEvidenceRecord
        let classification: ReconstructionEvidenceClassification
        let checkpointRevision: UInt64
    }

    private static func validateSourceBaseContext(contextBytes: Data, ids: [String],
        job: ReconstructionJobRecord, admissionCheckpoint: ReconstructionCheckpoint,
        jobs: [UUID: ReconstructionJobRecord], checkpointsByID: [UUID: ReconstructionCheckpoint],
        evidence: [UUID: ReconstructionEvidenceRecord], allowLegacyRawRecords: Bool = true) throws -> Set<UUID> {
        guard let envelope = try JSONSerialization.jsonObject(with: contextBytes) as? [String: Any],
              try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes]) == contextBytes,
              Set(envelope.keys) == Set(["schemaVersion", "domain", "corpusManifestSHA256", "evidenceFrontierSHA256",
                  "retrievalPacket", "retrievalPacketSHA256", "evidenceIDs", "allowedGapSubjects", "allowedGapCategories", "allowedGapIDs"]),
              (envelope["schemaVersion"] as? NSNumber)?.stringValue == "8",
              envelope["domain"] as? String == "reconstruction.context.v8",
              envelope["corpusManifestSHA256"] as? String == admissionCheckpoint.corpusManifestSHA256,
              envelope["evidenceFrontierSHA256"] as? String == admissionCheckpoint.evidenceFrontierSHA256,
              envelope["evidenceIDs"] as? [String] == ids,
              envelope["allowedGapSubjects"] as? [String] == [],
              envelope["allowedGapCategories"] as? [String] == [],
              envelope["allowedGapIDs"] as? [String] == [],
              let encodedPacket = envelope["retrievalPacket"] as? String, let packetBytes = Data(base64Encoded: encodedPacket),
              packetBytes.count <= ReconstructionSourceRequestBinding.maximumContextBytes,
              envelope["retrievalPacketSHA256"] as? String == sha256(packetBytes),
              let packet = try JSONSerialization.jsonObject(with: packetBytes) as? [String: Any],
              Set(["schemaVersion", "domain", "corpusManifestSHA256", "evidenceFrontierSHA256", "queryIdentitySHA256", "records", "hasMore"]).isSubset(of: Set(packet.keys)),
              Set(packet.keys).isSubset(of: Set(["schemaVersion", "domain", "corpusManifestSHA256", "evidenceFrontierSHA256", "queryIdentitySHA256", "records", "hasMore", "requestCursor", "nextCursor"])),
              let querySHA256 = packet["queryIdentitySHA256"] as? String,
              let hasMore = packet["hasMore"] as? Bool, hasMore == (packet["nextCursor"] is [String: Any]),
              packet["domain"] as? String == "reconstruction.evidence-retrieval-packet.v1",
              (packet["schemaVersion"] as? NSNumber)?.stringValue == "1",
              packet["corpusManifestSHA256"] as? String == admissionCheckpoint.corpusManifestSHA256,
              packet["evidenceFrontierSHA256"] as? String == admissionCheckpoint.evidenceFrontierSHA256,
              let records = packet["records"] as? [[String: Any]], records.count == ids.count,
              try JSONSerialization.data(withJSONObject: packet, options: [.sortedKeys, .withoutEscapingSlashes]) == packetBytes else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("source request graph binding")
        }
        guard let envelopeVersion = envelope["schemaVersion"], let packetVersion = packet["schemaVersion"],
              try JSONSerialization.data(withJSONObject: [envelopeVersion]) == Data("[8]".utf8),
              try JSONSerialization.data(withJSONObject: [packetVersion]) == Data("[1]".utf8),
              let hasMoreValue = packet["hasMore"],
              try JSONSerialization.data(withJSONObject: [hasMoreValue]) == Data((hasMore ? "[true]" : "[false]").utf8) else {
            throw ReconstructionPackageValidationError.stateGraphInvalid("source request graph binding")
        }
        try ReconstructionValidation.requireSHA256(querySHA256, field: "source request query")
        var offered = Set<UUID>()
        for (idText, object) in zip(ids, records) {
            try Task.checkCancellation()
            guard let id = UUID(uuidString: idText), offered.insert(id).inserted,
                  let actual = evidence[id], let creatingJob = jobs[actual.creatingJobID],
                  creatingJob.reconstructionProjectID == job.reconstructionProjectID,
                  let checkpoint = checkpointsByID[actual.creatingCheckpointID],
                  checkpoint.jobID == actual.creatingJobID,
                  actual.creatingJobID != job.jobID || checkpoint.revision <= admissionCheckpoint.revision else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("source offered evidence ownership")
            }
            let objectBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            let recordObject: [String: Any]
            if let inner = object["record"] as? [String: Any] {
                let wrapper = try JSONDecoder().decode(SourceRetrievedRecord.self, from: objectBytes)
                guard try ReconstructionCanonicalJSON.encode(wrapper) == objectBytes,
                      wrapper.classification == .acceptedCurrent,
                      wrapper.checkpointRevision == checkpoint.revision,
                      ReconstructionOperationID.allCases.contains(where: {
                          !$0.isDurableSourceOperation && $0.rawValue == wrapper.record.operationID
                      }) else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid("source offered record projection")
                }
                recordObject = inner
            } else {
                guard allowLegacyRawRecords else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid("source offered record projection")
                }
                recordObject = object
            }
            let bytes = try JSONSerialization.data(withJSONObject: recordObject, options: [.sortedKeys, .withoutEscapingSlashes])
            let offeredRecord = try JSONDecoder().decode(ReconstructionEvidenceRecord.self, from: bytes)
            guard offeredRecord.evidenceID == id, offeredRecord.classification == .acceptedCurrent,
                  offeredRecord.supersededByEvidenceID == nil,
                  offeredRecord.payloadSHA256 == sha256(offeredRecord.payload),
                  offeredRecord.payloadByteCount == UInt64(offeredRecord.payload.count),
                  try ReconstructionCanonicalJSON.encode(offeredRecord) == bytes else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("source offered evidence identity")
            }
            var retained = recordObject
            guard var current = try JSONSerialization.jsonObject(with: ReconstructionCanonicalJSON.encode(actual)) as? [String: Any] else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("source offered evidence identity")
            }
            // Later supersession changes classification, not the immutable original observation.
            for key in ["classification", "supersededByEvidenceID", "diagnostic"] {
                retained.removeValue(forKey: key); current.removeValue(forKey: key)
            }
            guard try JSONSerialization.data(withJSONObject: retained, options: [.sortedKeys, .withoutEscapingSlashes])
                    == JSONSerialization.data(withJSONObject: current, options: [.sortedKeys, .withoutEscapingSlashes]) else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("source offered evidence identity")
            }
        }
        return offered
    }

    /// An imported aggregate evaluation must be owned by one completed executeSource task.
    /// The neutral codec proves content shape only; the durable graph proves its actual owners.
    static func validateSourceEvaluationGraph(
        tasks: [UUID: ReconstructionTaskRecord], jobs: [UUID: ReconstructionJobRecord],
        checkpointsByJobID: [UUID: [UInt64: ReconstructionCheckpoint]],
        evidence: [UUID: ReconstructionEvidenceRecord], toolReceipts: [UUID: ReconstructionToolReceipt]
    ) throws {
        var checkpointsByID: [UUID: ReconstructionCheckpoint] = [:]
        for checkpoints in checkpointsByJobID.values {
            for checkpoint in checkpoints.values {
                try Task.checkCancellation()
                checkpointsByID[checkpoint.checkpointID] = checkpoint
            }
        }
        var evaluatedTaskIDs = Set<UUID>()
        var evaluationsByJobID: [UUID: [ReconstructionSourceEvaluation]] = [:]
        for record in evidence.values where record.operationID == "reconstruction.source.evaluate" {
            try Task.checkCancellation()
            do {
                let value = try ReconstructionSourceEvaluationCodec.decodeAndValidateCanonical(payload: record.payload)
                guard let job = jobs[record.creatingJobID], value.jobID == job.jobID,
                      value.projectID == job.reconstructionProjectID,
                      let task = tasks[record.creatingTaskID], task.identity.taskID == value.taskID,
                      task.identity.jobID == job.jobID, task.identity.kind == .executeSource,
                      task.identity.operationContractIdentity == "reconstruction.source.evaluate.v1",
                      task.identity.subject == .function(value.function), task.state == .completed,
                      evaluatedTaskIDs.insert(task.identity.taskID).inserted,
                      let receiptID = record.toolReceiptID, let receipt = toolReceipts[receiptID],
                      receipt.jobID == job.jobID, receipt.taskID == task.identity.taskID,
                      receipt.terminalState == .completed, receipt.diagnostic == nil,
                      receipt.outputEvidenceIDs == [record.evidenceID], receipt.evidenceReadAuthority == nil,
                      receipt.requestIdentitySHA256 == value.evaluationRequestSHA256,
                      receipt.producer == record.producer, value.producerSHA256 == record.producer.canonicalSHA256,
                      record.producer.operationIdentity == "reconstruction.source.evaluate",
                      record.producer.modelKey == nil, record.producer.endpointOrigin == nil,
                      let checkpoint = checkpointsByID[record.creatingCheckpointID], checkpoint.jobID == job.jobID,
                      checkpoint.revision == receipt.checkpointRevision, checkpoint.revision == value.checkpointRevision,
                      checkpoint.completedTaskIDs.contains(task.identity.taskID), checkpoint.toolReceiptIDs.contains(receiptID),
                      checkpointsByJobID[job.jobID]?.values.filter({ $0.completedTaskIDs.contains(task.identity.taskID) })
                        .map(\.revision).min() == checkpoint.revision,
                      record.subject == .function(value.function), record.modelReceiptID == nil,
                      record.payloadKind == .structuredJSON, record.payloadByteCount == UInt64(record.payload.count),
                      record.payloadSHA256 == sha256(record.payload), record.classification == .acceptedCurrent,
                      record.facetDependencies.isEmpty, record.diagnostic == nil,
                      record.supersedesEvidenceID == nil, record.supersededByEvidenceID == nil,
                      let sourceRecord = evidence[value.sourceEvidenceID], sourceRecord.operationID == "reconstruction.source.revision",
                      sourceRecord.creatingJobID == job.jobID, sourceRecord.subject == record.subject,
                      sourceRecord.payloadSHA256 == value.sourcePayloadSHA256,
                      let sourceCheckpoint = checkpointsByID[sourceRecord.creatingCheckpointID],
                      sourceCheckpoint.jobID == job.jobID, sourceCheckpoint.revision < checkpoint.revision,
                      let oracleRecord = evidence[value.oracleEvidenceID], oracleRecord.operationID == "reconstruction.source.oracle",
                      oracleRecord.creatingJobID == job.jobID, oracleRecord.subject == record.subject,
                      oracleRecord.payloadSHA256 == value.oraclePayloadSHA256,
                      let oracleCheckpoint = checkpointsByID[oracleRecord.creatingCheckpointID],
                      oracleCheckpoint.jobID == job.jobID, oracleCheckpoint.revision < checkpoint.revision else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid("source evaluation graph ownership")
                }
                // Source/oracle authority has already been authenticated by validateSourceRevisionGraph.
                let revision = try JSONDecoder().decode(ReconstructionSourceRevision.self, from: sourceRecord.payload)
                let oracle = try JSONDecoder().decode(ReconstructionSourceOracle.self, from: oracleRecord.payload)
                guard let binding = revision.requestBinding,
                      value.profileID == (try ReconstructionSourceProfile.retainedSourceProfile(job.sourceProfileID)).rawValue, value.profileID == revision.profileID,
                      value.profileID == oracle.profileID,
                      revision.revisionSHA256 == value.revisionSHA256, revision.sourceSHA256 == value.sourceSHA256,
                      binding.requestSHA256 == value.sourceRequestSHA256,
                      revision.function == value.function, revision.oracleSuiteSHA256 == value.oracleSuiteSHA256,
                      oracle.function == value.function, oracle.suiteSHA256 == value.oracleSuiteSHA256,
                      value.capturedOutcome.harnessSHA256 == oracle.execution.harnessSHA256,
                      let request = try JSONSerialization.jsonObject(with: binding.canonicalRequestBytes) as? [String: Any],
                      let context = request["context"] as? [String: Any],
                      let offeredIDs = context["evidenceIDs"] as? [String], offeredIDs.contains(value.oracleEvidenceID.uuidString),
                      record.citations.count == 2,
                      Set(record.citations.compactMap(\.sourceEvidenceID)) == Set([value.sourceEvidenceID, value.oracleEvidenceID]),
                      Set(record.citations.map(\.citationID)).count == 2,
                      record.citations.allSatisfy({ $0.subject == nil && $0.locator == nil }) else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid("source evaluation source oracle binding")
                }
                let outcome = value.capturedOutcome
                guard ![ReconstructionSourceEvaluation.Status.cancelled, .transportFailed, .invalidAuthority, .changedInputs].contains(outcome.status) else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid("source evaluation nonterminal evidence")
                }
                if !outcome.observations.isEmpty {
                    guard outcome.observations.map(\.input) == oracle.inputs else {
                        throw ReconstructionPackageValidationError.stateGraphInvalid("source evaluation oracle observations")
                    }
                    let mismatches = zip(outcome.observations, oracle.outputs).enumerated().compactMap { index, pair -> ReconstructionSourceEvaluation.Mismatch? in
                        pair.0.output == pair.1 ? nil : .init(index: index, input: pair.0.input, expected: pair.1, actual: pair.0.output)
                    }
                    guard outcome.mismatches == mismatches,
                          (outcome.status == .accepted) == mismatches.isEmpty else {
                        throw ReconstructionPackageValidationError.stateGraphInvalid("source evaluation oracle observations")
                    }
                }
                evaluationsByJobID[job.jobID, default: []].append(value)
            } catch let cancellation as CancellationError { throw cancellation }
            catch let error as ReconstructionPackageValidationError { throw error }
            catch { throw ReconstructionPackageValidationError.stateGraphInvalid("source evaluation payload") }
        }
        for task in tasks.values where task.identity.operationContractIdentity == "reconstruction.source.evaluate.v1" && task.state == .completed {
            guard evaluatedTaskIDs.contains(task.identity.taskID) else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("source evaluation missing evidence")
            }
        }
        let revisionsByJobID = Dictionary(grouping: evidence.values.filter {
            $0.operationID == "reconstruction.source.revision"
        }, by: \.creatingJobID)
        let executionJobIDs = Set(tasks.values.filter {
            $0.identity.kind == .executeSource && ["reconstruction.source.oracle.v1", "reconstruction.source.evaluate.v1"]
                .contains($0.identity.operationContractIdentity)
        }.map { $0.identity.jobID })
        for job in jobs.values where job.state == .completed {
            try Task.checkCancellation()
            let sourceRecords = revisionsByJobID[job.jobID] ?? []
            let hasBoundRevision = try sourceRecords.contains {
                try JSONDecoder().decode(ReconstructionSourceRevision.self, from: $0.payload).requestBinding != nil
            }
            // Retained nil-binding model-only fixtures never claimed source execution.
            guard job.sourceProfileID != nil || executionJobIDs.contains(job.jobID) || hasBoundRevision else { continue }
            guard let terminalID = job.currentCheckpointID, let terminal = checkpointsByID[terminalID],
                  terminal.jobID == job.jobID, terminal.coordinatorState == .completed,
                  let latestSource = sourceRecords.max(by: {
                      (checkpointsByID[$0.creatingCheckpointID]?.revision ?? 0)
                          < (checkpointsByID[$1.creatingCheckpointID]?.revision ?? 0)
                  }), let latestSourceCheckpoint = checkpointsByID[latestSource.creatingCheckpointID],
                  latestSourceCheckpoint.revision < terminal.revision,
                  let latestEvaluationRevision = evaluationsByJobID[job.jobID]?.map(\.checkpointRevision).max() else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("completed source job acceptance")
            }
            let latestEvaluations = (evaluationsByJobID[job.jobID] ?? []).filter {
                $0.checkpointRevision == latestEvaluationRevision
            }
            guard latestEvaluationRevision <= terminal.revision, latestEvaluations.count == 1,
                  let accepted = latestEvaluations.first, accepted.capturedOutcome.status == .accepted,
                  accepted.sourceEvidenceID == latestSource.evidenceID else {
                throw ReconstructionPackageValidationError.stateGraphInvalid("completed source job acceptance")
            }
        }
    }

    /// A tool execution is terminal exactly once for its durable task. Receipt IDs are opaque
    /// execution identities, so uniqueness by receipt ID alone cannot prevent two contradictory
    /// terminal outcomes from claiming the same task during package import or crash recovery.
    static func validateUniqueToolReceiptTaskBindings(
        _ toolReceipts: [ReconstructionToolReceipt]
    ) throws {
        var receiptIDsByTaskID: [UUID: UUID] = [:]
        for receipt in toolReceipts {
            try Task.checkCancellation()
            guard receiptIDsByTaskID.updateValue(
                receipt.receiptID,
                forKey: receipt.taskID
            ) == nil else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "duplicate tool receipt task binding"
                )
            }
        }
    }

    /// Reconstructs the receipt authority of each production model leaf from durable graph data.
    ///
    /// A receipt ID alone is insufficient: it must have been introduced at the checkpoint that
    /// records the model task's completion. Ordinary rounds additionally bind every selected
    /// opaque handle to the exact tool receipt from their paired retrieval task. Failed,
    /// cancelled, and blocked model tasks intentionally need no receipt; terminal-bearing failure
    /// paths may retain distinct failed attempt receipts before one successful completion.
    static func validateModelTaskReceiptBindings(
        tasks: [UUID: ReconstructionTaskRecord],
        checkpointsByJobID: [UUID: [UInt64: ReconstructionCheckpoint]],
        toolReceipts: [UUID: ReconstructionToolReceipt],
        modelReceipts: [ReconstructionModelReceipt]
    ) throws {
        let ordinaryModelContract = "reconstruction.modelRound.v1"
        let finalSynthesisContract = "reconstruction.finalSynthesis.v1"
        let sourceContract = "reconstruction.source.revision.v1"
        let evidenceQueryContract = "reconstruction.evidence.query"

        var firstCompletedRevisionByTaskID: [UUID: UInt64] = [:]
        for jobCheckpoints in checkpointsByJobID.values {
            try Task.checkCancellation()
            for revision in jobCheckpoints.keys.sorted() {
                try Task.checkCancellation()
                guard let checkpoint = jobCheckpoints[revision] else { continue }
                for taskID in checkpoint.completedTaskIDs {
                    try Task.checkCancellation()
                    if firstCompletedRevisionByTaskID[taskID] == nil {
                        firstCompletedRevisionByTaskID[taskID] = revision
                    }
                }
            }
        }

        var receiptsByTaskID: [UUID: ReconstructionModelReceipt] = [:]
        var attemptRevisionsByTaskID: [UUID: Set<UInt64>] = [:]
        for receipt in modelReceipts {
            try Task.checkCancellation()
            guard attemptRevisionsByTaskID[receipt.taskID, default: []]
                    .insert(receipt.checkpointRevision).inserted else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "duplicate model receipt task binding"
                )
            }
            if receipt.terminalState == .completed {
                guard receiptsByTaskID.updateValue(receipt, forKey: receipt.taskID) == nil else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid("duplicate model receipt task binding")
                }
            }
        }
        for receipt in modelReceipts where receipt.terminalState != .completed {
            if let completion = receiptsByTaskID[receipt.taskID],
               receipt.checkpointRevision >= completion.checkpointRevision {
                throw ReconstructionPackageValidationError.stateGraphInvalid("duplicate model receipt task binding")
            }
        }

        for task in tasks.values {
            try Task.checkCancellation()
            guard task.identity.kind == .modelRound else { continue }
            let contract = task.identity.operationContractIdentity
            guard contract == ordinaryModelContract || contract == finalSynthesisContract
                    || contract == sourceContract else {
                continue
            }
            guard task.state == .completed else { continue }
            guard let receipt = receiptsByTaskID[task.identity.taskID],
                  receipt.jobID == task.identity.jobID,
                  receipt.terminalState == .completed,
                  receipt.producer.operationIdentity == (contract == sourceContract
                    ? "reconstruction.source.revision" : contract),
                  let checkpoint = checkpointsByJobID[receipt.jobID]?[receipt.checkpointRevision],
                  checkpoint.completedTaskIDs.contains(task.identity.taskID),
                  checkpoint.modelReceiptIDs.contains(receipt.receiptID) else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "completed model task receipt binding"
                )
            }
            guard firstCompletedRevisionByTaskID[task.identity.taskID]
                    == receipt.checkpointRevision else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "model receipt task completion revision"
                )
            }

            if contract == sourceContract {
                guard receipt.finalResultCommitment == nil, receipt.selectedHandleIDs.isEmpty,
                      receipt.acceptedEvidenceIDs.count == 1, receipt.diagnostic == nil else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid("source model receipt commitment")
                }
                continue
            }

            if contract == finalSynthesisContract {
                guard receipt.finalResultCommitment != nil else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid(
                        "final model receipt commitment"
                    )
                }
                continue
            }

            guard receipt.finalResultCommitment == nil,
                  task.identity.dependencyTaskIDs.count == 1,
                  let retrieveTaskID = task.identity.dependencyTaskIDs.first,
                  let retrieveTask = tasks[retrieveTaskID],
                  retrieveTask.identity.jobID == task.identity.jobID,
                  retrieveTask.identity.kind == .retrieveEvidence,
                  retrieveTask.identity.operationContractIdentity == evidenceQueryContract,
                  retrieveTask.state == .completed else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(
                    "ordinary model receipt commitment"
                )
            }
            var refreshReceiptCount = 0
            for selectedHandleID in receipt.selectedHandleIDs {
                try Task.checkCancellation()
                guard let toolReceiptID = UUID(uuidString: selectedHandleID),
                      let toolReceipt = toolReceipts[toolReceiptID],
                      toolReceipt.jobID == receipt.jobID,
                      toolReceipt.taskID == retrieveTask.identity.taskID,
                      toolReceipt.checkpointRevision == receipt.checkpointRevision else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid(
                        "model selected handle receipt binding"
                    )
                }
                if toolReceipt.producer.operationIdentity == "reconstruction.analysis.macscope.refresh" {
                    refreshReceiptCount += 1
                    guard refreshReceiptCount == 1, retrieveTask.identity.subject == nil,
                          toolReceipt.terminalState == .completed, toolReceipt.diagnostic == nil,
                          toolReceipt.outputEvidenceIDs.isEmpty,
                          hasCommittedRefreshSuccessor(model: task, checkpoint: checkpoint,
                            tasks: tasks) else {
                        throw ReconstructionPackageValidationError.stateGraphInvalid(
                            "model selected handle receipt binding")
                    }
                } else if toolReceipt.producer.operationIdentity
                    != retrieveTask.identity.operationContractIdentity {
                    throw ReconstructionPackageValidationError.stateGraphInvalid(
                        "model selected handle receipt binding")
                }
                guard firstCompletedRevisionByTaskID[retrieveTask.identity.taskID]
                        == toolReceipt.checkpointRevision else {
                    throw ReconstructionPackageValidationError.stateGraphInvalid(
                        "tool receipt task completion revision"
                    )
                }
            }
        }
    }

    /// The receipt author validates the canonical request and acknowledgment before commit.
    /// Persistence retains only their digest, so require the corresponding closed durable DAG,
    /// not a generic alternate producer identity. Inspect the historical selection checkpoint:
    /// these tasks may have completed by the time a later package is recaptured.
    private static func hasCommittedRefreshSuccessor(
        model: ReconstructionTaskRecord, checkpoint: ReconstructionCheckpoint,
        tasks: [UUID: ReconstructionTaskRecord]
    ) -> Bool {
        let checkpointLeaves = tasks.values.filter {
            $0.identity.jobID == model.identity.jobID && $0.identity.kind == .checkpoint
                && $0.identity.subject == nil
                && $0.identity.operationContractIdentity == "reconstruction.checkpoint.v1"
                && $0.identity.dependencyTaskIDs == [model.identity.taskID]
                && checkpoint.completedTaskIDs.contains($0.identity.taskID)
        }
        guard checkpointLeaves.count == 1, let leaf = checkpointLeaves.first else { return false }
        let refreshes = tasks.values.filter {
            $0.identity.jobID == model.identity.jobID && $0.identity.kind == .decompileMacScope
                && $0.identity.operationContractIdentity == "reconstruction.decompileMacScope.v1"
                && $0.identity.dependencyTaskIDs.count == 2
                && $0.identity.dependencyTaskIDs.contains(leaf.identity.taskID)
        }
        guard refreshes.count == 1, let refresh = refreshes.first,
              checkpoint.pendingTaskIDs.contains(refresh.identity.taskID),
              case .function(let function)? = refresh.identity.subject,
              let enumerationID = refresh.identity.dependencyTaskIDs.first(where: { $0 != leaf.identity.taskID }),
              let enumeration = tasks[enumerationID],
              enumeration.identity.jobID == model.identity.jobID,
              enumeration.identity.kind == .enumerateFunctions,
              enumeration.identity.operationContractIdentity == "reconstruction.enumerateFunctions.v1",
              checkpoint.completedTaskIDs.contains(enumerationID),
              case .image(let image)? = enumeration.identity.subject,
              image.artifact == function.artifact, image.image == function.image,
              image.analysisFingerprintSHA256 == function.analysisFingerprintSHA256 else { return false }
        let successors = tasks.values.filter {
            $0.identity.jobID == model.identity.jobID && $0.identity.kind == .retrieveEvidence
                && $0.identity.subject == nil
                && $0.identity.operationContractIdentity == "reconstruction.evidence.query"
                && Set($0.identity.dependencyTaskIDs) == Set([leaf.identity.taskID, refresh.identity.taskID])
                && $0.identity.dependencyTaskIDs.count == 2
                && checkpoint.pendingTaskIDs.contains($0.identity.taskID)
        }
        guard successors.count == 1, let retrieve = successors.first else { return false }
        let models = tasks.values.filter {
            $0.identity.jobID == model.identity.jobID && $0.identity.kind == .modelRound
                && $0.identity.subject == nil && $0.identity.operationContractIdentity == "reconstruction.modelRound.v1"
                && $0.identity.dependencyTaskIDs == [retrieve.identity.taskID]
                && checkpoint.pendingTaskIDs.contains($0.identity.taskID)
        }
        guard models.count == 1, let successorModel = models.first else { return false }
        return tasks.values.filter {
            $0.identity.jobID == model.identity.jobID && $0.identity.kind == .checkpoint
                && $0.identity.subject == nil && $0.identity.operationContractIdentity == "reconstruction.checkpoint.v1"
                && $0.identity.dependencyTaskIDs == [successorModel.identity.taskID]
                && checkpoint.pendingTaskIDs.contains($0.identity.taskID)
        }.count == 1
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func uniqueDictionary<Value, Key: Hashable>(
        _ values: [Value],
        keyedBy key: (Value) -> Key,
        duplicate: String
    ) throws -> [Key: Value] {
        var result: [Key: Value] = [:]
        for value in values {
            try Task.checkCancellation()
            guard result.updateValue(value, forKey: key(value)) == nil else {
                throw ReconstructionPackageValidationError.stateGraphInvalid(duplicate)
            }
        }
        return result
    }

    private static func verifyDigest(_ data: Data, expected: String, path: String) throws {
        try Task.checkCancellation()
        let digest = sha256(data)
        try Task.checkCancellation()
        guard digest == expected else {
            throw ReconstructionPackageValidationError.manifestDigestMismatch(path)
        }
    }

    private static func requireManifestSize(_ data: Data, path: String) throws {
        try Task.checkCancellation()
        guard data.count <= ReconstructionPackageLayout.maximumManifestBytes else {
            throw ReconstructionPackageValidationError.noncanonicalManifest(path)
        }
    }

    private static func decodeStrict<T: Codable>(_ data: Data, path: String) throws -> T {
        try requireManifestSize(data, path: path)
        let value = try JSONDecoder().decode(T.self, from: data)
        try Task.checkCancellation()
        let canonical = try ReconstructionCanonicalJSON.encode(value)
        try Task.checkCancellation()
        guard canonical == data else {
            throw ReconstructionPackageValidationError.noncanonicalManifest(path)
        }
        return value
    }
}

private struct ReconstructionPackageManifestWriter {
    private(set) var data = Data()
    private let maximumBytes: Int
    private let path: String

    init(maximumBytes: Int, path: String) {
        self.maximumBytes = maximumBytes
        self.path = path
    }

    mutating func appendLiteral(_ literal: String) throws {
        try append(Data(literal.utf8))
    }

    mutating func appendArray<Element: Encodable>(_ values: [Element]) throws {
        try appendLiteral("[")
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            if index > 0 { try appendLiteral(",") }
            try appendCanonical(value)
        }
        try appendLiteral("]")
    }

    private mutating func appendCanonical<Value: Encodable>(_ value: Value) throws {
        do {
            try ReconstructionPackageManifestPreflightEncoder.validate(
                value,
                maximumBytes: maximumBytes - data.count
            )
        } catch is ReconstructionPackageManifestPreflightError {
            throw ReconstructionPackageValidationError.noncanonicalManifest(path)
        }
        try Task.checkCancellation()
        let encoded = try ReconstructionCanonicalJSON.encode(value)
        try Task.checkCancellation()
        try append(encoded)
    }

    private mutating func append(_ bytes: Data) throws {
        try Task.checkCancellation()
        guard bytes.count <= maximumBytes - data.count else {
            throw ReconstructionPackageValidationError.noncanonicalManifest(path)
        }
        data.append(bytes)
        try Task.checkCancellation()
    }
}

private enum ReconstructionPackageManifestPreflightError: Error {
    case limitExceeded
}

private final class ReconstructionPackageManifestByteCounter {
    private let maximumBytes: Int
    private(set) var remainingBytes: Int
    private var exceededLimit = false
    private var observedCancellation = false

    var encodedByteCount: Int {
        maximumBytes - remainingBytes
    }

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
        remainingBytes = maximumBytes
        if maximumBytes < 0 { exceededLimit = true }
    }

    func consume(_ byteCount: Int) {
        guard !exceededLimit else { return }
        guard byteCount >= 0, byteCount <= remainingBytes else {
            exceededLimit = true
            remainingBytes = 0
            return
        }
        remainingBytes -= byteCount
    }

    func consumeJSONString(_ value: String) {
        consume(2)
        for (index, scalar) in value.unicodeScalars.enumerated() {
            if index.isMultiple(of: 4_096), Task.isCancelled {
                observedCancellation = true
                return
            }
            let byteCount: Int
            switch scalar.value {
            case 0x22, 0x5c:
                byteCount = 2
            case 0x08, 0x09, 0x0a, 0x0c, 0x0d:
                byteCount = 2
            case 0x00...0x1f:
                byteCount = 6
            case 0x00...0x7f:
                byteCount = 1
            case 0x80...0x7ff:
                byteCount = 2
            case 0x800...0xffff:
                byteCount = 3
            default:
                byteCount = 4
            }
            consume(byteCount)
            if exceededLimit { return }
        }
    }

    func consumeBase64Data(_ value: Data) {
        consume(2)
        let completeGroups = value.count / 3
        guard completeGroups <= (Int.max - 4) / 4 else {
            exceededLimit = true
            remainingBytes = 0
            return
        }
        consume(completeGroups * 4 + (value.count.isMultiple(of: 3) ? 0 : 4))
    }

    func validate() throws {
        if observedCancellation { throw CancellationError() }
        try Task.checkCancellation()
        if exceededLimit {
            throw ReconstructionPackageManifestPreflightError.limitExceeded
        }
    }
}

private struct ReconstructionPackageManifestPreflightEncoder: Encoder {
    let counter: ReconstructionPackageManifestByteCounter
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any] = [:]

    static func validate<Value: Encodable>(
        _ value: Value,
        maximumBytes: Int
    ) throws {
        let counter = ReconstructionPackageManifestByteCounter(maximumBytes: maximumBytes)
        try reconstructionPackagePreflightEncode(
            value,
            counter: counter,
            codingPath: []
        )
        try counter.validate()
    }

    static func encodedByteCount<Value: Encodable>(_ value: Value) throws -> Int {
        let counter = ReconstructionPackageManifestByteCounter(maximumBytes: .max)
        try reconstructionPackagePreflightEncode(
            value,
            counter: counter,
            codingPath: []
        )
        try counter.validate()
        return counter.encodedByteCount
    }

    func container<Key: CodingKey>(
        keyedBy type: Key.Type
    ) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(
            ReconstructionPackageManifestKeyedContainer<Key>(
                counter: counter,
                codingPath: codingPath
            )
        )
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        ReconstructionPackageManifestUnkeyedContainer(
            counter: counter,
            codingPath: codingPath
        )
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        ReconstructionPackageManifestSingleValueContainer(
            counter: counter,
            codingPath: codingPath
        )
    }
}

private func reconstructionPackagePreflightEncode<Value: Encodable>(
    _ value: Value,
    counter: ReconstructionPackageManifestByteCounter,
    codingPath: [CodingKey]
) throws {
    if let data = value as? Data {
        counter.consumeBase64Data(data)
    } else {
        try value.encode(to: ReconstructionPackageManifestPreflightEncoder(
            counter: counter,
            codingPath: codingPath
        ))
    }
    try counter.validate()
}

private struct ReconstructionPackageManifestKeyedContainer<Key: CodingKey>:
    KeyedEncodingContainerProtocol {
    let counter: ReconstructionPackageManifestByteCounter
    let codingPath: [CodingKey]
    private var encodedCount = 0

    init(counter: ReconstructionPackageManifestByteCounter, codingPath: [CodingKey]) {
        self.counter = counter
        self.codingPath = codingPath
        counter.consume(2)
    }

    private mutating func prepare(_ key: Key) {
        if encodedCount > 0 { counter.consume(1) }
        counter.consumeJSONString(key.stringValue)
        counter.consume(1)
        encodedCount += 1
    }

    mutating func encodeNil(forKey key: Key) throws {
        prepare(key)
        counter.consume(4)
        try counter.validate()
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        prepare(key)
        counter.consume(value ? 4 : 5)
        try counter.validate()
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        prepare(key)
        counter.consumeJSONString(value)
        try counter.validate()
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
        prepare(key)
        counter.consume(try ReconstructionCanonicalJSON.encode(value).count)
        try counter.validate()
    }

    mutating func encode(_ value: Float, forKey key: Key) throws {
        prepare(key)
        counter.consume(try ReconstructionCanonicalJSON.encode(value).count)
        try counter.validate()
    }

    mutating func encode(_ value: Int, forKey key: Key) throws {
        try encodeInteger(value, forKey: key)
    }

    mutating func encode(_ value: Int8, forKey key: Key) throws {
        try encodeInteger(value, forKey: key)
    }

    mutating func encode(_ value: Int16, forKey key: Key) throws {
        try encodeInteger(value, forKey: key)
    }

    mutating func encode(_ value: Int32, forKey key: Key) throws {
        try encodeInteger(value, forKey: key)
    }

    mutating func encode(_ value: Int64, forKey key: Key) throws {
        try encodeInteger(value, forKey: key)
    }

    mutating func encode(_ value: UInt, forKey key: Key) throws {
        try encodeInteger(value, forKey: key)
    }

    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        try encodeInteger(value, forKey: key)
    }

    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        try encodeInteger(value, forKey: key)
    }

    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        try encodeInteger(value, forKey: key)
    }

    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        try encodeInteger(value, forKey: key)
    }

    mutating func encode<Value: Encodable>(_ value: Value, forKey key: Key) throws {
        prepare(key)
        try reconstructionPackagePreflightEncode(
            value,
            counter: counter,
            codingPath: codingPath + [key]
        )
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        prepare(key)
        return ReconstructionPackageManifestPreflightEncoder(
            counter: counter,
            codingPath: codingPath + [key]
        ).container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        prepare(key)
        return ReconstructionPackageManifestPreflightEncoder(
            counter: counter,
            codingPath: codingPath + [key]
        ).unkeyedContainer()
    }

    mutating func superEncoder() -> Encoder {
        ReconstructionPackageManifestPreflightEncoder(
            counter: counter,
            codingPath: codingPath
        )
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        prepare(key)
        return ReconstructionPackageManifestPreflightEncoder(
            counter: counter,
            codingPath: codingPath + [key]
        )
    }

    private mutating func encodeInteger<Integer: BinaryInteger>(
        _ value: Integer,
        forKey key: Key
    ) throws {
        prepare(key)
        counter.consume(String(value).utf8.count)
        try counter.validate()
    }
}

private struct ReconstructionPackageManifestUnkeyedContainer: UnkeyedEncodingContainer {
    let counter: ReconstructionPackageManifestByteCounter
    let codingPath: [CodingKey]
    private(set) var count = 0

    init(counter: ReconstructionPackageManifestByteCounter, codingPath: [CodingKey]) {
        self.counter = counter
        self.codingPath = codingPath
        counter.consume(2)
    }

    private mutating func prepare() {
        if count > 0 { counter.consume(1) }
        count += 1
    }

    mutating func encodeNil() throws {
        prepare()
        counter.consume(4)
        try counter.validate()
    }

    mutating func encode(_ value: Bool) throws {
        prepare()
        counter.consume(value ? 4 : 5)
        try counter.validate()
    }

    mutating func encode(_ value: String) throws {
        prepare()
        counter.consumeJSONString(value)
        try counter.validate()
    }

    mutating func encode(_ value: Double) throws {
        prepare()
        counter.consume(try ReconstructionCanonicalJSON.encode(value).count)
        try counter.validate()
    }

    mutating func encode(_ value: Float) throws {
        prepare()
        counter.consume(try ReconstructionCanonicalJSON.encode(value).count)
        try counter.validate()
    }

    mutating func encode(_ value: Int) throws { try encodeInteger(value) }
    mutating func encode(_ value: Int8) throws { try encodeInteger(value) }
    mutating func encode(_ value: Int16) throws { try encodeInteger(value) }
    mutating func encode(_ value: Int32) throws { try encodeInteger(value) }
    mutating func encode(_ value: Int64) throws { try encodeInteger(value) }
    mutating func encode(_ value: UInt) throws { try encodeInteger(value) }
    mutating func encode(_ value: UInt8) throws { try encodeInteger(value) }
    mutating func encode(_ value: UInt16) throws { try encodeInteger(value) }
    mutating func encode(_ value: UInt32) throws { try encodeInteger(value) }
    mutating func encode(_ value: UInt64) throws { try encodeInteger(value) }

    mutating func encode<Value: Encodable>(_ value: Value) throws {
        prepare()
        try reconstructionPackagePreflightEncode(
            value,
            counter: counter,
            codingPath: codingPath
        )
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        prepare()
        return ReconstructionPackageManifestPreflightEncoder(
            counter: counter,
            codingPath: codingPath
        ).container(keyedBy: keyType)
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        prepare()
        return ReconstructionPackageManifestPreflightEncoder(
            counter: counter,
            codingPath: codingPath
        ).unkeyedContainer()
    }

    mutating func superEncoder() -> Encoder {
        prepare()
        return ReconstructionPackageManifestPreflightEncoder(
            counter: counter,
            codingPath: codingPath
        )
    }

    private mutating func encodeInteger<Integer: BinaryInteger>(_ value: Integer) throws {
        prepare()
        counter.consume(String(value).utf8.count)
        try counter.validate()
    }
}

private struct ReconstructionPackageManifestSingleValueContainer:
    SingleValueEncodingContainer {
    let counter: ReconstructionPackageManifestByteCounter
    let codingPath: [CodingKey]

    func encodeNil() throws {
        counter.consume(4)
        try counter.validate()
    }

    func encode(_ value: Bool) throws {
        counter.consume(value ? 4 : 5)
        try counter.validate()
    }

    func encode(_ value: String) throws {
        counter.consumeJSONString(value)
        try counter.validate()
    }

    func encode(_ value: Double) throws {
        counter.consume(try ReconstructionCanonicalJSON.encode(value).count)
        try counter.validate()
    }

    func encode(_ value: Float) throws {
        counter.consume(try ReconstructionCanonicalJSON.encode(value).count)
        try counter.validate()
    }

    func encode(_ value: Int) throws { try encodeInteger(value) }
    func encode(_ value: Int8) throws { try encodeInteger(value) }
    func encode(_ value: Int16) throws { try encodeInteger(value) }
    func encode(_ value: Int32) throws { try encodeInteger(value) }
    func encode(_ value: Int64) throws { try encodeInteger(value) }
    func encode(_ value: UInt) throws { try encodeInteger(value) }
    func encode(_ value: UInt8) throws { try encodeInteger(value) }
    func encode(_ value: UInt16) throws { try encodeInteger(value) }
    func encode(_ value: UInt32) throws { try encodeInteger(value) }
    func encode(_ value: UInt64) throws { try encodeInteger(value) }

    func encode<Value: Encodable>(_ value: Value) throws {
        try reconstructionPackagePreflightEncode(
            value,
            counter: counter,
            codingPath: codingPath
        )
    }

    private func encodeInteger<Integer: BinaryInteger>(_ value: Integer) throws {
        counter.consume(String(value).utf8.count)
        try counter.validate()
    }
}
