import CryptoKit
import Foundation

enum ReconstructionJobState: String, Codable, CaseIterable, Hashable, Sendable {
    case created, ingesting, indexing, retrieving, awaitingModel
    case executingReads, acceptingEvidence, checkpointing
    case paused, completed, cancelled, failed

    static let activeStates: [ReconstructionJobState] = [
        .created, .ingesting, .indexing, .retrieving, .awaitingModel,
        .executingReads, .acceptingEvidence, .checkpointing
    ]

    var isTerminal: Bool {
        self == .completed || self == .cancelled || self == .failed
    }
}

enum ReconstructionJobStateTransitionError: Error, Equatable {
    case invalidTransition(from: ReconstructionJobState, to: ReconstructionJobState)
    case invalidResumeTarget(expected: ReconstructionJobState?, actual: ReconstructionJobState)
}

enum ReconstructionJobStateMachine {
    private static let forwardTransitions: [ReconstructionJobState: Set<ReconstructionJobState>] = [
        .created: [.ingesting],
        .ingesting: [.indexing],
        .indexing: [.retrieving],
        .retrieving: [.awaitingModel, .completed],
        .awaitingModel: [.executingReads],
        .executingReads: [.acceptingEvidence],
        .acceptingEvidence: [.checkpointing],
        .checkpointing: [.retrieving]
    ]

    static func transition(
        from: ReconstructionJobState,
        to: ReconstructionJobState,
        resumeTarget: ReconstructionJobState?
    ) throws {
        if from == .paused {
            if to == .cancelled || to == .failed {
                guard resumeTarget == nil else {
                    throw ReconstructionJobStateTransitionError.invalidTransition(
                        from: from,
                        to: to
                    )
                }
                return
            }
            guard Self.isActive(to), resumeTarget == to else {
                throw ReconstructionJobStateTransitionError.invalidResumeTarget(
                    expected: resumeTarget,
                    actual: to
                )
            }
            return
        }
        guard Self.isActive(from) else {
            throw ReconstructionJobStateTransitionError.invalidTransition(from: from, to: to)
        }
        if to == .paused {
            guard resumeTarget == from else {
                throw ReconstructionJobStateTransitionError.invalidResumeTarget(
                    expected: from,
                    actual: resumeTarget ?? .paused
                )
            }
            return
        }
        if to == .cancelled || to == .failed {
            guard resumeTarget == nil else {
                throw ReconstructionJobStateTransitionError.invalidTransition(from: from, to: to)
            }
            return
        }
        guard resumeTarget == nil, forwardTransitions[from]?.contains(to) == true else {
            throw ReconstructionJobStateTransitionError.invalidTransition(from: from, to: to)
        }
    }

    private static func isActive(_ state: ReconstructionJobState) -> Bool {
        ReconstructionJobState.activeStates.contains(state)
    }
}

/// The closed, durable reason a Reconstruction job stopped at an otherwise resumable state.
///
/// These values are persistence authority, not presentation strings. Additions therefore require
/// an explicit schema review instead of accepting an arbitrary diagnostic from a live provider.
enum ReconstructionJobPauseCause: String, Codable, CaseIterable, Hashable, Sendable {
    case pausedByUser
    case modelUnavailable
    case inferenceBusy
    case frontierMismatch
    case evidenceStalled
}

/// The complete authority required to resume a paused job without consulting transient runtime
/// state. A pause context can only point at one of the state machine's active states.
struct ReconstructionJobPauseContext: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let cause: ReconstructionJobPauseCause
    let resumeTarget: ReconstructionJobState

    init(
        schemaVersion: Int = Self.schemaVersion,
        cause: ReconstructionJobPauseCause,
        resumeTarget: ReconstructionJobState
    ) throws {
        guard schemaVersion == Self.schemaVersion else {
            throw ReconstructionValidationError.invalidSchemaVersion
        }
        guard ReconstructionJobState.activeStates.contains(resumeTarget) else {
            throw ReconstructionValidationError.invalidReference(
                field: "job pause resume target"
            )
        }
        self.schemaVersion = schemaVersion
        self.cause = cause
        self.resumeTarget = resumeTarget
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case cause
        case resumeTarget
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            cause: container.decode(ReconstructionJobPauseCause.self, forKey: .cause),
            resumeTarget: container.decode(ReconstructionJobState.self, forKey: .resumeTarget)
        )
    }
}

enum ReconstructionTaskKind: String, Codable, CaseIterable, Hashable, Sendable {
    case ingest, classify, discoverRelations, loadBinary, indexImage, enumerateFunctions
    case decompileNative, decompileMacScope, compareDecompilers
    case retrieveEvidence, modelRound, checkpoint, executeSource
}

/// App-owned source tasks remain outside the model-selectable v8/v9 tool registry.
enum ReconstructionSourceExecutionTaskContract {
    static let oracle = "reconstruction.source.oracle.v1"
    static let evaluate = "reconstruction.source.evaluate.v1"
    static let profileID = ReconstructionSourceProfile.scalarU32V1.rawValue

    static func admits(_ task: ReconstructionTaskRecord) -> Bool {
        guard task.identity.kind == .executeSource,
              task.state == .pending || task.state == .running,
              [oracle, evaluate].contains(task.identity.operationContractIdentity),
              case .function(let function)? = task.identity.subject,
              function.image.architecture == .arm64,
              function.image.selectedSliceIndex.map({ $0 >= 0 }) ?? true else { return false }
        return true
    }
}

/// A bounded read-admission request for one already-observed operation. This is not a job
/// persistence schema, an execution capability, or a claim of dependency independence.
struct ReconstructionOperationDescriptor: Hashable, Sendable {
    static let version = 1
    static let maximumEvidenceReferences = 64
    static let maximumDeclaredArtifacts = 16

    struct Observation: Hashable, Sendable {
        let contractID: String
        let evidenceID: UUID
        let payloadSHA256: String
        let suiteSHA256: String
    }

    struct Dependencies: Hashable, Sendable {
        let compilerSHA256: String
        let sdkIdentitySHA256: String
        let harnessSHA256: String
        let compileProfileSHA256: String
        let compileArgumentsSHA256: String
        let executionArgumentsSHA256: String
        /// Explicit declarations only. An empty list does not prove absence of dependencies.
        let declaredArtifacts: [ReconstructionArtifactCoordinate]
    }

    let version: Int
    let profileID: String
    let projectID: UUID
    let jobID: UUID
    let function: ReconstructionFunctionCoordinate
    let checkpointID: UUID
    let checkpointRevision: UInt64
    let checkpointSHA256: String
    let corpusManifestSHA256: String
    let evidenceFrontierSHA256: String
    let evidenceIDs: [UUID]
    let observation: Observation
    let dependencies: Dependencies

    /// Called before the owner reads a committed cut. Recognition never enables a new profile.
    func validateShape() throws {
        guard version == Self.version else { throw ReconstructionOperationAdmissionError.unsupportedVersion }
        guard ReconstructionSourceRevision.profileDisposition(for: profileID) == .legacy else {
            throw ReconstructionOperationAdmissionError.unsupportedProfile
        }
        guard observation.contractID == ReconstructionSourceExecutionTaskContract.oracle,
              !evidenceIDs.isEmpty, evidenceIDs.count <= Self.maximumEvidenceReferences,
              Set(evidenceIDs).count == evidenceIDs.count, evidenceIDs.contains(observation.evidenceID),
              dependencies.declaredArtifacts.count <= Self.maximumDeclaredArtifacts,
              Set(dependencies.declaredArtifacts.map(\.occurrenceID)).count == dependencies.declaredArtifacts.count else {
            throw ReconstructionOperationAdmissionError.invalidDescriptor
        }
        do {
            for digest in [checkpointSHA256, corpusManifestSHA256, evidenceFrontierSHA256,
                observation.payloadSHA256, observation.suiteSHA256, dependencies.compilerSHA256,
                dependencies.sdkIdentitySHA256, dependencies.harnessSHA256,
                dependencies.compileProfileSHA256, dependencies.compileArgumentsSHA256,
                dependencies.executionArgumentsSHA256] {
                try ReconstructionValidation.requireSHA256(digest, field: "operation descriptor")
            }
        } catch { throw ReconstructionOperationAdmissionError.invalidDescriptor }
    }
}

enum ReconstructionOperationAdmissionError: Error, Equatable, Sendable {
    case unsupportedVersion, unsupportedProfile, invalidDescriptor
    case staleCut, invalidEvidence, invalidDependencies, invalidObservation
}

enum ReconstructionTaskState: String, Codable, CaseIterable, Hashable, Sendable {
    case pending, running, completed, failed, blocked, cancelled
}

struct ReconstructionJobBudget: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let maxRounds: Int
    let maxTasks: Int
    let maxEvidenceRecords: Int
    let maxEncodedBytes: UInt64

    init(maxRounds: Int, maxTasks: Int, maxEvidenceRecords: Int, maxEncodedBytes: UInt64) throws {
        guard maxRounds > 0, maxTasks > 0, maxEvidenceRecords > 0, maxEncodedBytes > 0 else {
            throw ReconstructionValidationError.invalidByteCount(field: "job budget")
        }
        self.maxRounds = maxRounds
        self.maxTasks = maxTasks
        self.maxEvidenceRecords = maxEvidenceRecords
        self.maxEncodedBytes = maxEncodedBytes
    }
}

struct ReconstructionTaskIdentity: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let taskID: UUID
    let schemaVersion: Int
    let jobID: UUID
    let kind: ReconstructionTaskKind
    let subject: ReconstructionSubjectCoordinate?
    let dependencyTaskIDs: [UUID]
    let operationContractIdentity: String
    let canonicalSHA256: String

    init(
        taskID: UUID,
        schemaVersion: Int = Self.schemaVersion,
        jobID: UUID,
        kind: ReconstructionTaskKind,
        subject: ReconstructionSubjectCoordinate?,
        dependencyTaskIDs: [UUID],
        operationContractIdentity: String,
        canonicalSHA256: String
    ) throws {
        try ReconstructionValidation.requireSchemaVersion(schemaVersion)
        try ReconstructionValidation.requireUnique(dependencyTaskIDs, field: "task dependencies")
        guard !dependencyTaskIDs.contains(taskID) else {
            throw ReconstructionValidationError.invalidReference(field: "task dependency")
        }
        try ReconstructionValidation.requireNonempty(
            operationContractIdentity,
            field: "operation contract identity"
        )
        try ReconstructionValidation.requireSHA256(canonicalSHA256, field: "task digest")
        self.taskID = taskID
        self.schemaVersion = schemaVersion
        self.jobID = jobID
        self.kind = kind
        self.subject = subject
        self.dependencyTaskIDs = ReconstructionValidation.sortedUUIDs(dependencyTaskIDs)
        self.operationContractIdentity = operationContractIdentity
        self.canonicalSHA256 = canonicalSHA256
    }

    static func make(
        taskID: UUID,
        jobID: UUID,
        kind: ReconstructionTaskKind,
        subject: ReconstructionSubjectCoordinate?,
        dependencyTaskIDs: [UUID],
        operationContractIdentity: String
    ) throws -> Self {
        let normalizedDependencies = ReconstructionValidation.sortedUUIDs(dependencyTaskIDs)
        let preimage = CanonicalPreimage(
            taskID: taskID,
            schemaVersion: Self.schemaVersion,
            jobID: jobID,
            kind: kind,
            subject: subject,
            dependencyTaskIDs: normalizedDependencies,
            operationContractIdentity: operationContractIdentity
        )
        let bytes = try ReconstructionCanonicalJSON.encode(preimage)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return try Self(
            taskID: taskID,
            jobID: jobID,
            kind: kind,
            subject: subject,
            dependencyTaskIDs: normalizedDependencies,
            operationContractIdentity: operationContractIdentity,
            canonicalSHA256: digest
        )
    }

    func verifyCanonicalIdentity() throws {
        let bytes = try ReconstructionCanonicalJSON.encode(CanonicalPreimage(
            taskID: taskID,
            schemaVersion: schemaVersion,
            jobID: jobID,
            kind: kind,
            subject: subject,
            dependencyTaskIDs: ReconstructionValidation.sortedUUIDs(dependencyTaskIDs),
            operationContractIdentity: operationContractIdentity
        ))
        let derived = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard derived == canonicalSHA256 else {
            throw ReconstructionValidationError.invalidReference(
                field: "task canonical identity"
            )
        }
    }

    private struct CanonicalPreimage: Encodable {
        let taskID: UUID
        let schemaVersion: Int
        let jobID: UUID
        let kind: ReconstructionTaskKind
        let subject: ReconstructionSubjectCoordinate?
        let dependencyTaskIDs: [UUID]
        let operationContractIdentity: String
    }
}

struct ReconstructionTaskRecord: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let identity: ReconstructionTaskIdentity
    let state: ReconstructionTaskState
    let diagnostic: ReconstructionDiagnostic?
    /// D13: which decompiler produced a completed decompile/compare task (`native` or the MacIR
    /// fallback), with the fallback reason, the same contract as MCP `decompile` (#268). Absent on
    /// every other task and on records written before D13 (omitted from canonical JSON when nil).
    var decompileBackend: ReconstructionDecompileBackendRecord? = nil
}

/// `backend` / `fallbackReason` of a completed `decompileNative` or `compareDecompilers` task.
/// Values match `ScriptingDecompileBackend` (`native`, `macir`, `native-unavailable`,
/// `native-failed: <code>`).
struct ReconstructionDecompileBackendRecord: Hashable, Codable, Sendable {
    static let native = "native"
    static let macIR = "macir"
    static let nativeUnavailable = "native-unavailable"
    static func nativeFailed(_ code: String) -> String { "native-failed: \(code)" }

    let backend: String
    let fallbackReason: String?

    static let nativeBackend = ReconstructionDecompileBackendRecord(backend: native, fallbackReason: nil)
    static func macIRFallback(_ reason: String) -> ReconstructionDecompileBackendRecord {
        .init(backend: macIR, fallbackReason: ReconstructionDiagnostic.sanitizing(
            reason.isEmpty ? nativeUnavailable : reason, maxUTF8Bytes: 256).text)
    }

    var isValid: Bool {
        (backend == Self.native && fallbackReason == nil)
            || (backend == Self.macIR && fallbackReason.map { !$0.isEmpty && $0.utf8.count <= 256 } == true)
    }
}

enum ReconstructionReceiptTerminalState: String, Codable, Hashable, Sendable {
    case completed, failed, cancelled, truncated
}

struct ReconstructionToolReceipt: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let receiptID: UUID
    let jobID: UUID
    let taskID: UUID
    let checkpointRevision: UInt64
    let requestIdentitySHA256: String
    let producer: ReconstructionProducerIdentity
    let terminalState: ReconstructionReceiptTerminalState
    let outputEvidenceIDs: [UUID]
    let diagnostic: ReconstructionDiagnostic?
    let canonicalSHA256: String
    let evidenceReadAuthority: ReconstructionEvidenceReadAuthority?

    init(
        receiptID: UUID,
        jobID: UUID,
        taskID: UUID,
        checkpointRevision: UInt64,
        requestIdentitySHA256: String,
        producer: ReconstructionProducerIdentity,
        terminalState: ReconstructionReceiptTerminalState,
        outputEvidenceIDs: [UUID],
        diagnostic: ReconstructionDiagnostic?,
        canonicalSHA256: String,
        evidenceReadAuthority: ReconstructionEvidenceReadAuthority? = nil
    ) throws {
        try ReconstructionValidation.requireSHA256(
            requestIdentitySHA256,
            field: "tool request identity"
        )
        try ReconstructionValidation.requireSHA256(canonicalSHA256, field: "tool receipt digest")
        try ReconstructionValidation.requireUnique(outputEvidenceIDs, field: "tool output evidence IDs")
        self.receiptID = receiptID
        self.jobID = jobID
        self.taskID = taskID
        self.checkpointRevision = checkpointRevision
        self.requestIdentitySHA256 = requestIdentitySHA256
        self.producer = producer
        self.terminalState = terminalState
        self.outputEvidenceIDs = ReconstructionValidation.sortedUUIDs(outputEvidenceIDs)
        self.diagnostic = diagnostic
        self.canonicalSHA256 = canonicalSHA256
        self.evidenceReadAuthority = evidenceReadAuthority
        try evidenceReadAuthority?.validate()
    }
}

struct ReconstructionModelReceipt: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let receiptID: UUID
    let jobID: UUID
    let taskID: UUID
    let checkpointRevision: UInt64
    let requestIdentitySHA256: String
    let producer: ReconstructionProducerIdentity
    let terminalState: ReconstructionReceiptTerminalState
    let selectedHandleIDs: [String]
    let acceptedEvidenceIDs: [UUID]
    let diagnostic: ReconstructionDiagnostic?
    /// Present only for a terminal final-synthesis receipt. The successor checkpoint commits the
    /// receipt ID, and this commitment makes that receipt commit the exact retained result bytes.
    let finalResultCommitment: ReconstructionFinalResultCommitment?
    let canonicalSHA256: String

    init(
        receiptID: UUID,
        jobID: UUID,
        taskID: UUID,
        checkpointRevision: UInt64,
        requestIdentitySHA256: String,
        producer: ReconstructionProducerIdentity,
        terminalState: ReconstructionReceiptTerminalState,
        selectedHandleIDs: [String],
        acceptedEvidenceIDs: [UUID],
        diagnostic: ReconstructionDiagnostic?,
        finalResultCommitment: ReconstructionFinalResultCommitment? = nil,
        canonicalSHA256: String
    ) throws {
        try ReconstructionValidation.requireSHA256(
            requestIdentitySHA256,
            field: "model request identity"
        )
        try ReconstructionValidation.requireSHA256(canonicalSHA256, field: "model receipt digest")
        try ReconstructionValidation.requireUnique(selectedHandleIDs, field: "selected handle IDs")
        try ReconstructionValidation.requireUnique(
            acceptedEvidenceIDs,
            field: "accepted evidence IDs"
        )
        for handleID in selectedHandleIDs {
            try ReconstructionValidation.requireNonempty(handleID, field: "selected handle ID")
        }
        self.receiptID = receiptID
        self.jobID = jobID
        self.taskID = taskID
        self.checkpointRevision = checkpointRevision
        self.requestIdentitySHA256 = requestIdentitySHA256
        self.producer = producer
        self.terminalState = terminalState
        self.selectedHandleIDs = selectedHandleIDs
        self.acceptedEvidenceIDs = ReconstructionValidation.sortedUUIDs(acceptedEvidenceIDs)
        self.diagnostic = diagnostic
        self.finalResultCommitment = finalResultCommitment
        self.canonicalSHA256 = canonicalSHA256
    }

    private enum CodingKeys: String, CodingKey {
        case receiptID, jobID, taskID, checkpointRevision, requestIdentitySHA256, producer
        case terminalState, selectedHandleIDs, acceptedEvidenceIDs, diagnostic, canonicalSHA256
        case finalResultCommitment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            receiptID: container.decode(UUID.self, forKey: .receiptID),
            jobID: container.decode(UUID.self, forKey: .jobID),
            taskID: container.decode(UUID.self, forKey: .taskID),
            checkpointRevision: container.decode(UInt64.self, forKey: .checkpointRevision),
            requestIdentitySHA256: container.decode(
                String.self,
                forKey: .requestIdentitySHA256
            ),
            producer: container.decode(ReconstructionProducerIdentity.self, forKey: .producer),
            terminalState: container.decode(
                ReconstructionReceiptTerminalState.self,
                forKey: .terminalState
            ),
            selectedHandleIDs: container.decode([String].self, forKey: .selectedHandleIDs),
            acceptedEvidenceIDs: container.decode([UUID].self, forKey: .acceptedEvidenceIDs),
            diagnostic: try container.decodeIfPresent(
                ReconstructionDiagnostic.self,
                forKey: .diagnostic
            ),
            finalResultCommitment: try container.decodeIfPresent(
                ReconstructionFinalResultCommitment.self,
                forKey: .finalResultCommitment
            ),
            canonicalSHA256: container.decode(String.self, forKey: .canonicalSHA256)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(receiptID, forKey: .receiptID)
        try container.encode(jobID, forKey: .jobID)
        try container.encode(taskID, forKey: .taskID)
        try container.encode(checkpointRevision, forKey: .checkpointRevision)
        try container.encode(requestIdentitySHA256, forKey: .requestIdentitySHA256)
        try container.encode(producer, forKey: .producer)
        try container.encode(terminalState, forKey: .terminalState)
        try container.encode(selectedHandleIDs, forKey: .selectedHandleIDs)
        try container.encode(acceptedEvidenceIDs, forKey: .acceptedEvidenceIDs)
        try container.encodeIfPresent(diagnostic, forKey: .diagnostic)
        try container.encodeIfPresent(finalResultCommitment, forKey: .finalResultCommitment)
        try container.encode(canonicalSHA256, forKey: .canonicalSHA256)
    }
}

struct ReconstructionFinalResultCommitment: Hashable, Codable, Sendable {
    let resultID: UUID
    let canonicalSHA256: String

    init(resultID: UUID, canonicalSHA256: String) throws {
        try ReconstructionValidation.requireSHA256(
            canonicalSHA256,
            field: "final result commitment digest"
        )
        self.resultID = resultID
        self.canonicalSHA256 = canonicalSHA256
    }
}

/// The first-class durable semantic produced by the final model leaf.
///
/// This is deliberately not an evidence record: final prose has no honest binary coordinate and
/// therefore must not fabricate an evidence subject. Its cited evidence remains explicit instead.
struct ReconstructionFinalResultRecord: Hashable, Codable, Sendable {
    static let schemaVersion = 1
    static let maximumPayloadBytes = 1_048_576

    let resultID: UUID
    let schemaVersion: Int
    let jobID: UUID
    let taskID: UUID
    let checkpointID: UUID
    let checkpointRevision: UInt64
    let requestID: UUID
    let requestIdentitySHA256: String
    let kind: ReconstructionFinalSynthesisKind
    let payloadUTF8: Data
    let payloadByteCount: UInt64
    let payloadSHA256: String
    let citedEvidenceIDs: [UUID]
    let producer: ReconstructionProducerIdentity
    let modelReceiptID: UUID
    let canonicalSHA256: String

    init(
        resultID: UUID,
        schemaVersion: Int = Self.schemaVersion,
        jobID: UUID,
        taskID: UUID,
        checkpointID: UUID,
        checkpointRevision: UInt64,
        requestID: UUID,
        requestIdentitySHA256: String,
        kind: ReconstructionFinalSynthesisKind,
        payloadUTF8: Data,
        payloadByteCount: UInt64,
        payloadSHA256: String,
        citedEvidenceIDs: [UUID],
        producer: ReconstructionProducerIdentity,
        modelReceiptID: UUID,
        canonicalSHA256: String
    ) throws {
        try ReconstructionValidation.requireSchemaVersion(schemaVersion)
        try ReconstructionValidation.requireSHA256(
            requestIdentitySHA256,
            field: "final result request identity"
        )
        try ReconstructionValidation.requireSHA256(
            payloadSHA256,
            field: "final result payload digest"
        )
        try ReconstructionValidation.requireSHA256(
            canonicalSHA256,
            field: "final result digest"
        )
        guard !payloadUTF8.isEmpty,
              payloadUTF8.count <= Self.maximumPayloadBytes,
              payloadByteCount == UInt64(payloadUTF8.count),
              String(data: payloadUTF8, encoding: .utf8) != nil else {
            throw ReconstructionValidationError.invalidByteCount(field: "final result payload")
        }
        try ReconstructionValidation.requireUnique(
            citedEvidenceIDs,
            field: "final result cited evidence IDs"
        )
        guard requestID == modelReceiptID else {
            throw ReconstructionValidationError.invalidReference(
                field: "final result model receipt"
            )
        }
        self.resultID = resultID
        self.schemaVersion = schemaVersion
        self.jobID = jobID
        self.taskID = taskID
        self.checkpointID = checkpointID
        self.checkpointRevision = checkpointRevision
        self.requestID = requestID
        self.requestIdentitySHA256 = requestIdentitySHA256
        self.kind = kind
        self.payloadUTF8 = payloadUTF8
        self.payloadByteCount = payloadByteCount
        self.payloadSHA256 = payloadSHA256
        self.citedEvidenceIDs = ReconstructionValidation.sortedUUIDs(citedEvidenceIDs)
        self.producer = producer
        self.modelReceiptID = modelReceiptID
        self.canonicalSHA256 = canonicalSHA256
    }
}

enum ReconstructionCheckpointIdentityError: Error, Equatable {
    case encodedByteCountMismatch(expected: UInt64, actual: UInt64)
    case sha256Mismatch(expected: String, actual: String)
}

struct ReconstructionCheckpoint: Hashable, Codable, Sendable {
    static let schemaVersion = 1

    let checkpointID: UUID
    let schemaVersion: Int
    let jobID: UUID
    let revision: UInt64
    let parentCheckpointID: UUID?
    let parentCheckpointSHA256: String?
    let corpusManifestSHA256: String
    let evidenceFrontierSHA256: String
    let pendingTaskIDs: [UUID]
    let runningTaskIDs: [UUID]
    let completedTaskIDs: [UUID]
    let failedTaskIDs: [UUID]
    let blockedTaskIDs: [UUID]
    let unresolvedEvidenceGapSHA256: String
    let modelReceiptIDs: [UUID]
    let toolReceiptIDs: [UUID]
    let coordinatorState: ReconstructionJobState
    let terminalReason: ReconstructionDiagnostic?
    let canonicalEncodedByteCount: UInt64
    let canonicalSHA256: String

    private struct CanonicalPreimage: Encodable {
        let checkpointID: UUID
        let schemaVersion: Int
        let jobID: UUID
        let revision: UInt64
        let parentCheckpointID: UUID?
        let parentCheckpointSHA256: String?
        let corpusManifestSHA256: String
        let evidenceFrontierSHA256: String
        let pendingTaskIDs: [UUID]
        let runningTaskIDs: [UUID]
        let completedTaskIDs: [UUID]
        let failedTaskIDs: [UUID]
        let blockedTaskIDs: [UUID]
        let unresolvedEvidenceGapSHA256: String
        let modelReceiptIDs: [UUID]
        let toolReceiptIDs: [UUID]
        let coordinatorState: ReconstructionJobState
        let terminalReason: ReconstructionDiagnostic?
    }

    init(
        checkpointID: UUID,
        schemaVersion: Int = Self.schemaVersion,
        jobID: UUID,
        revision: UInt64,
        parentCheckpointID: UUID?,
        parentCheckpointSHA256: String?,
        corpusManifestSHA256: String,
        evidenceFrontierSHA256: String,
        pendingTaskIDs: [UUID],
        runningTaskIDs: [UUID],
        completedTaskIDs: [UUID],
        failedTaskIDs: [UUID],
        blockedTaskIDs: [UUID],
        unresolvedEvidenceGapSHA256: String,
        modelReceiptIDs: [UUID],
        toolReceiptIDs: [UUID],
        coordinatorState: ReconstructionJobState,
        terminalReason: ReconstructionDiagnostic?,
        canonicalEncodedByteCount: UInt64,
        canonicalSHA256: String
    ) throws {
        try ReconstructionValidation.requireSchemaVersion(schemaVersion)
        guard (revision == 0) == (parentCheckpointID == nil && parentCheckpointSHA256 == nil),
              (parentCheckpointID == nil) == (parentCheckpointSHA256 == nil) else {
            throw ReconstructionValidationError.invalidReference(field: "checkpoint parent")
        }
        for (field, digest) in [
            ("checkpoint parent digest", parentCheckpointSHA256),
            ("corpus manifest digest", Optional(corpusManifestSHA256)),
            ("evidence frontier digest", Optional(evidenceFrontierSHA256)),
            ("unresolved evidence gap digest", Optional(unresolvedEvidenceGapSHA256)),
            ("checkpoint digest", Optional(canonicalSHA256))
        ] where digest != nil {
            try ReconstructionValidation.requireSHA256(digest!, field: field)
        }
        let stateGroups = [
            pendingTaskIDs, runningTaskIDs, completedTaskIDs, failedTaskIDs, blockedTaskIDs
        ]
        for (index, group) in stateGroups.enumerated() {
            try ReconstructionValidation.requireUnique(group, field: "checkpoint task group \(index)")
        }
        let allTaskIDs = stateGroups.flatMap { $0 }
        try ReconstructionValidation.requireUnique(allTaskIDs, field: "checkpoint task frontier")
        try ReconstructionValidation.requireUnique(modelReceiptIDs, field: "model receipt IDs")
        try ReconstructionValidation.requireUnique(toolReceiptIDs, field: "tool receipt IDs")
        guard canonicalEncodedByteCount > 0 else {
            throw ReconstructionValidationError.invalidByteCount(field: "checkpoint encoded byte count")
        }
        self.checkpointID = checkpointID
        self.schemaVersion = schemaVersion
        self.jobID = jobID
        self.revision = revision
        self.parentCheckpointID = parentCheckpointID
        self.parentCheckpointSHA256 = parentCheckpointSHA256
        self.corpusManifestSHA256 = corpusManifestSHA256
        self.evidenceFrontierSHA256 = evidenceFrontierSHA256
        self.pendingTaskIDs = ReconstructionValidation.sortedUUIDs(pendingTaskIDs)
        self.runningTaskIDs = ReconstructionValidation.sortedUUIDs(runningTaskIDs)
        self.completedTaskIDs = ReconstructionValidation.sortedUUIDs(completedTaskIDs)
        self.failedTaskIDs = ReconstructionValidation.sortedUUIDs(failedTaskIDs)
        self.blockedTaskIDs = ReconstructionValidation.sortedUUIDs(blockedTaskIDs)
        self.unresolvedEvidenceGapSHA256 = unresolvedEvidenceGapSHA256
        self.modelReceiptIDs = ReconstructionValidation.sortedUUIDs(modelReceiptIDs)
        self.toolReceiptIDs = ReconstructionValidation.sortedUUIDs(toolReceiptIDs)
        self.coordinatorState = coordinatorState
        self.terminalReason = terminalReason
        self.canonicalEncodedByteCount = canonicalEncodedByteCount
        self.canonicalSHA256 = canonicalSHA256
    }

    static func make(
        checkpointID: UUID,
        schemaVersion: Int = Self.schemaVersion,
        jobID: UUID,
        revision: UInt64,
        parentCheckpointID: UUID?,
        parentCheckpointSHA256: String?,
        corpusManifestSHA256: String,
        evidenceFrontierSHA256: String,
        pendingTaskIDs: [UUID],
        runningTaskIDs: [UUID],
        completedTaskIDs: [UUID],
        failedTaskIDs: [UUID],
        blockedTaskIDs: [UUID],
        unresolvedEvidenceGapSHA256: String,
        modelReceiptIDs: [UUID],
        toolReceiptIDs: [UUID],
        coordinatorState: ReconstructionJobState,
        terminalReason: ReconstructionDiagnostic?
    ) throws -> Self {
        let normalized = try Self(
            checkpointID: checkpointID,
            schemaVersion: schemaVersion,
            jobID: jobID,
            revision: revision,
            parentCheckpointID: parentCheckpointID,
            parentCheckpointSHA256: parentCheckpointSHA256,
            corpusManifestSHA256: corpusManifestSHA256,
            evidenceFrontierSHA256: evidenceFrontierSHA256,
            pendingTaskIDs: pendingTaskIDs,
            runningTaskIDs: runningTaskIDs,
            completedTaskIDs: completedTaskIDs,
            failedTaskIDs: failedTaskIDs,
            blockedTaskIDs: blockedTaskIDs,
            unresolvedEvidenceGapSHA256: unresolvedEvidenceGapSHA256,
            modelReceiptIDs: modelReceiptIDs,
            toolReceiptIDs: toolReceiptIDs,
            coordinatorState: coordinatorState,
            terminalReason: terminalReason,
            canonicalEncodedByteCount: 1,
            canonicalSHA256: String(repeating: "0", count: 64)
        )
        let bytes = try normalized.canonicalPreimageBytes()
        return try Self(
            checkpointID: normalized.checkpointID,
            schemaVersion: normalized.schemaVersion,
            jobID: normalized.jobID,
            revision: normalized.revision,
            parentCheckpointID: normalized.parentCheckpointID,
            parentCheckpointSHA256: normalized.parentCheckpointSHA256,
            corpusManifestSHA256: normalized.corpusManifestSHA256,
            evidenceFrontierSHA256: normalized.evidenceFrontierSHA256,
            pendingTaskIDs: normalized.pendingTaskIDs,
            runningTaskIDs: normalized.runningTaskIDs,
            completedTaskIDs: normalized.completedTaskIDs,
            failedTaskIDs: normalized.failedTaskIDs,
            blockedTaskIDs: normalized.blockedTaskIDs,
            unresolvedEvidenceGapSHA256: normalized.unresolvedEvidenceGapSHA256,
            modelReceiptIDs: normalized.modelReceiptIDs,
            toolReceiptIDs: normalized.toolReceiptIDs,
            coordinatorState: normalized.coordinatorState,
            terminalReason: normalized.terminalReason,
            canonicalEncodedByteCount: UInt64(bytes.count),
            canonicalSHA256: Self.sha256(bytes)
        )
    }

    func verifyCanonicalIdentity() throws {
        let bytes = try canonicalPreimageBytes()
        let actualByteCount = UInt64(bytes.count)
        guard canonicalEncodedByteCount == actualByteCount else {
            throw ReconstructionCheckpointIdentityError.encodedByteCountMismatch(
                expected: actualByteCount,
                actual: canonicalEncodedByteCount
            )
        }
        let actualSHA256 = Self.sha256(bytes)
        guard canonicalSHA256 == actualSHA256 else {
            throw ReconstructionCheckpointIdentityError.sha256Mismatch(
                expected: actualSHA256,
                actual: canonicalSHA256
            )
        }
    }

    private func canonicalPreimageBytes() throws -> Data {
        try ReconstructionCanonicalJSON.encode(
            CanonicalPreimage(
                checkpointID: checkpointID,
                schemaVersion: schemaVersion,
                jobID: jobID,
                revision: revision,
                parentCheckpointID: parentCheckpointID,
                parentCheckpointSHA256: parentCheckpointSHA256,
                corpusManifestSHA256: corpusManifestSHA256,
                evidenceFrontierSHA256: evidenceFrontierSHA256,
                pendingTaskIDs: pendingTaskIDs,
                runningTaskIDs: runningTaskIDs,
                completedTaskIDs: completedTaskIDs,
                failedTaskIDs: failedTaskIDs,
                blockedTaskIDs: blockedTaskIDs,
                unresolvedEvidenceGapSHA256: unresolvedEvidenceGapSHA256,
                modelReceiptIDs: modelReceiptIDs,
                toolReceiptIDs: toolReceiptIDs,
                coordinatorState: coordinatorState,
                terminalReason: terminalReason
            )
        )
    }

    private static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

struct ReconstructionJobRecord: Hashable, Codable, Sendable {
    /// Current schema for every job without an admitted feature scope.
    static let schemaVersion = 5
    /// Used only when `featureScope` is present, so scope-less jobs keep schema-5 bytes and older
    /// readers refuse a scoped job explicitly instead of dropping its scope.
    static let featureScopeSchemaVersion = 6

    let recordSchemaVersion: Int
    let creationOrdinal: UInt64?
    let jobID: UUID
    let reconstructionProjectID: UUID
    let objective: String
    let objectiveSHA256: String
    let creationCorpusManifestSHA256: String
    let state: ReconstructionJobState
    let currentCheckpointID: UUID?
    let terminalReason: ReconstructionDiagnostic?
    let budget: ReconstructionJobBudget
    let pauseContext: ReconstructionJobPauseContext?
    let focus: ReconstructionSubjectCoordinate?
    /// Explicit app-selected source intent; never inferred from objective text or transient state.
    let sourceProfileID: String?
    /// U06 admitted feature scope. Set once by `ReconstructionDatabaseOwner.admitFeatureScope`.
    let featureScope: ReconstructionFeatureScope?

    init(
        jobID: UUID,
        reconstructionProjectID: UUID,
        objective: String,
        objectiveSHA256: String,
        creationCorpusManifestSHA256: String,
        state: ReconstructionJobState,
        currentCheckpointID: UUID?,
        terminalReason: ReconstructionDiagnostic?,
        budget: ReconstructionJobBudget,
        creationOrdinal: UInt64 = 1,
        pauseContext: ReconstructionJobPauseContext? = nil,
        focus: ReconstructionSubjectCoordinate? = nil,
        sourceProfileID: String? = nil,
        featureScope: ReconstructionFeatureScope? = nil
    ) throws {
        try self.init(
            recordSchemaVersion: featureScope == nil ? Self.schemaVersion : Self.featureScopeSchemaVersion,
            creationOrdinal: creationOrdinal,
            jobID: jobID,
            reconstructionProjectID: reconstructionProjectID,
            objective: objective,
            objectiveSHA256: objectiveSHA256,
            creationCorpusManifestSHA256: creationCorpusManifestSHA256,
            state: state,
            currentCheckpointID: currentCheckpointID,
            terminalReason: terminalReason,
            budget: budget,
            pauseContext: pauseContext,
            focus: focus,
            sourceProfileID: sourceProfileID,
            featureScope: featureScope
        )
    }

    private init(
        recordSchemaVersion: Int,
        creationOrdinal: UInt64?,
        jobID: UUID,
        reconstructionProjectID: UUID,
        objective: String,
        objectiveSHA256: String,
        creationCorpusManifestSHA256: String,
        state: ReconstructionJobState,
        currentCheckpointID: UUID?,
        terminalReason: ReconstructionDiagnostic?,
        budget: ReconstructionJobBudget,
        pauseContext: ReconstructionJobPauseContext?,
        focus: ReconstructionSubjectCoordinate?,
        sourceProfileID: String?,
        featureScope: ReconstructionFeatureScope?
    ) throws {
        try ReconstructionValidation.requireNonempty(objective, field: "job objective")
        try ReconstructionValidation.requireSHA256(objectiveSHA256, field: "objective digest")
        try ReconstructionValidation.requireSHA256(
            creationCorpusManifestSHA256,
            field: "creation corpus manifest digest"
        )
        guard state.isTerminal == (terminalReason != nil) || state == .completed else {
            throw ReconstructionValidationError.invalidReference(field: "job terminal reason")
        }
        guard (1...Self.featureScopeSchemaVersion).contains(recordSchemaVersion) else {
            throw ReconstructionValidationError.invalidReference(field: "job record schema")
        }
        switch recordSchemaVersion {
        case 1:
            guard creationOrdinal == nil, pauseContext == nil else {
                throw ReconstructionValidationError.invalidReference(
                    field: "schema-v1 job record shape"
                )
            }
        case 2:
            guard let creationOrdinal, creationOrdinal > 0, pauseContext == nil else {
                throw ReconstructionValidationError.invalidReference(
                    field: "schema-v2 job record shape"
                )
            }
        case 3, 4, 5, 6:
            guard let creationOrdinal, creationOrdinal > 0 else {
                throw ReconstructionValidationError.invalidReference(
                    field: "job creation ordinal"
                )
            }
            guard (state == .paused) == (pauseContext != nil) else {
                throw ReconstructionValidationError.invalidReference(
                    field: "job pause context"
                )
            }
        default:
            preconditionFailure("validated job schema fell outside its closed range")
        }
        guard recordSchemaVersion >= 4 || focus == nil else {
            throw ReconstructionValidationError.invalidReference(field: "legacy job focus")
        }
        if case .image = focus {
            throw ReconstructionValidationError.invalidReference(field: "job focus")
        }
        guard recordSchemaVersion >= 5 || sourceProfileID == nil,
              sourceProfileID == nil || ReconstructionSourceProfile.admits(sourceProfileID) else {
            throw ReconstructionValidationError.invalidReference(field: "job source profile")
        }
        guard (recordSchemaVersion == Self.featureScopeSchemaVersion) == (featureScope != nil) else {
            throw ReconstructionValidationError.invalidReference(field: "job feature scope schema")
        }
        if let featureScope {
            guard featureScope.jobID == jobID,
                  featureScope.projectID == reconstructionProjectID,
                  featureScope.observationContract.sourceProfileID == sourceProfileID,
                  focus == nil || focus == .function(featureScope.feature)
                    || focus == .artifact(featureScope.feature.artifact) else {
                throw ReconstructionValidationError.invalidReference(field: "job feature scope")
            }
        }
        self.recordSchemaVersion = recordSchemaVersion
        self.creationOrdinal = creationOrdinal
        self.jobID = jobID
        self.reconstructionProjectID = reconstructionProjectID
        self.objective = objective
        self.objectiveSHA256 = objectiveSHA256
        self.creationCorpusManifestSHA256 = creationCorpusManifestSHA256
        self.state = state
        self.currentCheckpointID = currentCheckpointID
        self.terminalReason = terminalReason
        self.budget = budget
        self.pauseContext = pauseContext
        self.focus = focus
        self.sourceProfileID = sourceProfileID
        self.featureScope = featureScope
    }

    /// The same job with a newly admitted scope. Admission is set-once; a different scope is refused.
    func admitting(_ scope: ReconstructionFeatureScope) throws -> Self {
        guard featureScope == nil || featureScope == scope, let creationOrdinal else {
            throw ReconstructionValidationError.invalidReference(field: "job feature scope")
        }
        return try Self(
            jobID: jobID,
            reconstructionProjectID: reconstructionProjectID,
            objective: objective,
            objectiveSHA256: objectiveSHA256,
            creationCorpusManifestSHA256: creationCorpusManifestSHA256,
            state: state,
            currentCheckpointID: currentCheckpointID,
            terminalReason: terminalReason,
            budget: budget,
            creationOrdinal: creationOrdinal,
            pauseContext: pauseContext,
            focus: focus,
            sourceProfileID: sourceProfileID,
            featureScope: scope
        )
    }

    /// The schema-5 record this job had before its scope was admitted (reconciliation only).
    func removingFeatureScope() throws -> Self {
        guard featureScope != nil, let creationOrdinal else { return self }
        return try Self(
            jobID: jobID,
            reconstructionProjectID: reconstructionProjectID,
            objective: objective,
            objectiveSHA256: objectiveSHA256,
            creationCorpusManifestSHA256: creationCorpusManifestSHA256,
            state: state,
            currentCheckpointID: currentCheckpointID,
            terminalReason: terminalReason,
            budget: budget,
            creationOrdinal: creationOrdinal,
            pauseContext: pauseContext,
            focus: focus,
            sourceProfileID: sourceProfileID
        )
    }

    func upgraded(creationOrdinal: UInt64) throws -> Self {
        guard recordSchemaVersion >= 3 || state != .paused else {
            throw ReconstructionValidationError.invalidReference(
                field: "legacy paused job pause context"
            )
        }
        return try Self(
            jobID: jobID,
            reconstructionProjectID: reconstructionProjectID,
            objective: objective,
            objectiveSHA256: objectiveSHA256,
            creationCorpusManifestSHA256: creationCorpusManifestSHA256,
            state: state,
            currentCheckpointID: currentCheckpointID,
            terminalReason: terminalReason,
            budget: budget,
            creationOrdinal: creationOrdinal,
            pauseContext: pauseContext,
            focus: focus,
            sourceProfileID: sourceProfileID,
            featureScope: featureScope
        )
    }

    /// Normalizes a strictly decoded schema-v2 job at an explicit persistence/package boundary.
    /// Schema-v1 ordering is intentionally normalized by `ReconstructionWorkspaceState`, which is
    /// the only layer with enough context to assign a deterministic dense creation ordinal.
    func normalizedToCurrentSchema() throws -> Self {
        guard recordSchemaVersion < Self.schemaVersion else { return self }
        guard let creationOrdinal else {
            throw ReconstructionValidationError.invalidReference(
                field: "legacy job creation order"
            )
        }
        return try upgraded(creationOrdinal: creationOrdinal)
    }

    private enum CodingKeys: String, CodingKey {
        case recordSchemaVersion
        case creationOrdinal
        case jobID
        case reconstructionProjectID
        case objective
        case objectiveSHA256
        case creationCorpusManifestSHA256
        case state
        case currentCheckpointID
        case terminalReason
        case budget
        case pauseContext
        case focus
        case sourceProfileID
        case featureScope
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasSchemaVersion = container.contains(.recordSchemaVersion)
        let hasCreationOrdinal = container.contains(.creationOrdinal)
        guard hasSchemaVersion == hasCreationOrdinal else {
            throw DecodingError.dataCorruptedError(
                forKey: hasSchemaVersion ? .recordSchemaVersion : .creationOrdinal,
                in: container,
                debugDescription: "job record schema and creation ordinal must appear together"
            )
        }
        let decodedSchemaVersion: Int
        let decodedOrdinal: UInt64?
        let decodedPauseContext: ReconstructionJobPauseContext?
        if hasSchemaVersion {
            decodedSchemaVersion = try container.decode(Int.self, forKey: .recordSchemaVersion)
            guard (2...Self.featureScopeSchemaVersion).contains(decodedSchemaVersion) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .recordSchemaVersion,
                    in: container,
                    debugDescription: "unsupported job record schema \(decodedSchemaVersion)"
                )
            }
            let ordinal = try container.decode(UInt64.self, forKey: .creationOrdinal)
            guard ordinal > 0 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .creationOrdinal,
                    in: container,
                    debugDescription: "job creation ordinal must be greater than zero"
                )
            }
            decodedOrdinal = ordinal
            if decodedSchemaVersion == 2 {
                guard !container.contains(.pauseContext) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .pauseContext,
                        in: container,
                        debugDescription: "schema-v2 job cannot carry pause context"
                    )
                }
                decodedPauseContext = nil
            } else if container.contains(.pauseContext) {
                guard try !container.decodeNil(forKey: .pauseContext) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .pauseContext,
                        in: container,
                        debugDescription: "job pause context cannot be null"
                    )
                }
                decodedPauseContext = try container.decode(
                    ReconstructionJobPauseContext.self,
                    forKey: .pauseContext
                )
            } else {
                decodedPauseContext = nil
            }
        } else {
            decodedSchemaVersion = 1
            decodedOrdinal = nil
            guard !container.contains(.pauseContext) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .pauseContext,
                    in: container,
                    debugDescription: "schema-v1 job cannot carry pause context"
                )
            }
            decodedPauseContext = nil
        }
        guard decodedSchemaVersion >= 4 || !container.contains(.focus) else {
            throw DecodingError.dataCorruptedError(
                forKey: .focus, in: container,
                debugDescription: "legacy job cannot carry focus"
            )
        }
        if container.contains(.focus), try container.decodeNil(forKey: .focus) {
            throw DecodingError.dataCorruptedError(
                forKey: .focus, in: container, debugDescription: "job focus cannot be null"
            )
        }
        guard decodedSchemaVersion >= 5 || !container.contains(.sourceProfileID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sourceProfileID, in: container,
                debugDescription: "legacy job cannot carry source profile"
            )
        }
        if container.contains(.sourceProfileID), try container.decodeNil(forKey: .sourceProfileID) {
            throw DecodingError.dataCorruptedError(
                forKey: .sourceProfileID, in: container, debugDescription: "job source profile cannot be null"
            )
        }
        guard decodedSchemaVersion >= Self.featureScopeSchemaVersion || !container.contains(.featureScope) else {
            throw DecodingError.dataCorruptedError(
                forKey: .featureScope, in: container,
                debugDescription: "schema-5 job cannot carry a feature scope"
            )
        }
        if container.contains(.featureScope), try container.decodeNil(forKey: .featureScope) {
            throw DecodingError.dataCorruptedError(
                forKey: .featureScope, in: container, debugDescription: "job feature scope cannot be null"
            )
        }
        try self.init(
            recordSchemaVersion: decodedSchemaVersion,
            creationOrdinal: decodedOrdinal,
            jobID: container.decode(UUID.self, forKey: .jobID),
            reconstructionProjectID: container.decode(UUID.self, forKey: .reconstructionProjectID),
            objective: container.decode(String.self, forKey: .objective),
            objectiveSHA256: container.decode(String.self, forKey: .objectiveSHA256),
            creationCorpusManifestSHA256: container.decode(
                String.self,
                forKey: .creationCorpusManifestSHA256
            ),
            state: container.decode(ReconstructionJobState.self, forKey: .state),
            currentCheckpointID: container.decodeIfPresent(UUID.self, forKey: .currentCheckpointID),
            terminalReason: container.decodeIfPresent(
                ReconstructionDiagnostic.self,
                forKey: .terminalReason
            ),
            budget: container.decode(ReconstructionJobBudget.self, forKey: .budget),
            pauseContext: decodedPauseContext,
            focus: container.decodeIfPresent(ReconstructionSubjectCoordinate.self, forKey: .focus),
            sourceProfileID: container.decodeIfPresent(String.self, forKey: .sourceProfileID),
            featureScope: container.decodeIfPresent(ReconstructionFeatureScope.self, forKey: .featureScope)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if recordSchemaVersion >= 2, let creationOrdinal {
            try container.encode(recordSchemaVersion, forKey: .recordSchemaVersion)
            try container.encode(creationOrdinal, forKey: .creationOrdinal)
        }
        try container.encode(jobID, forKey: .jobID)
        try container.encode(reconstructionProjectID, forKey: .reconstructionProjectID)
        try container.encode(objective, forKey: .objective)
        try container.encode(objectiveSHA256, forKey: .objectiveSHA256)
        try container.encode(
            creationCorpusManifestSHA256,
            forKey: .creationCorpusManifestSHA256
        )
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(currentCheckpointID, forKey: .currentCheckpointID)
        try container.encodeIfPresent(terminalReason, forKey: .terminalReason)
        try container.encode(budget, forKey: .budget)
        if recordSchemaVersion >= 3 {
            try container.encodeIfPresent(pauseContext, forKey: .pauseContext)
        }
        if recordSchemaVersion >= 4 {
            try container.encodeIfPresent(focus, forKey: .focus)
        }
        if recordSchemaVersion >= 5 {
            try container.encodeIfPresent(sourceProfileID, forKey: .sourceProfileID)
        }
        if recordSchemaVersion >= Self.featureScopeSchemaVersion {
            try container.encodeIfPresent(featureScope, forKey: .featureScope)
        }
    }
}
