import Darwin
import Foundation
import CryptoKit
import SwiftUI

struct WorkspacePackageAssistantSessionRecord: Codable, Equatable, Identifiable {
    static let schemaVersion = 3
    static let providerToolCountRange = 0...64

    var id: UUID
    var sequence: Int
    var conversationID: UUID
    var turnSequence: Int
    var inferenceTurnID: UUID
    var isLegacy: Bool
    var intentID: String
    var userGoal: String
    var status: String
    var promptText: String
    var answerText: String?
    var transcriptText: String
    var contextDigest: String?
    var canonicalByteCount: Int?
    var providerToolCount: Int
    var recordSchemaVersion: Int
    var createdAt: Date
    var completedAt: Date?
    var continuationCheckpoint: Phase2AssistantContinuationCheckpointRecord?
    var contentSHA256: String

    private enum CodingKeys: String, CodingKey {
        case id
        case sequence
        case conversationID
        case turnSequence
        case inferenceTurnID
        case isLegacy
        case intentID
        case userGoal
        case status
        case promptText
        case answerText
        case transcriptText
        case contextDigest
        case canonicalByteCount
        case providerToolCount
        case recordSchemaVersion
        case createdAt
        case completedAt
        case continuationCheckpoint
        case contentSHA256
    }

    init(
        id: UUID,
        sequence: Int,
        conversationID: UUID? = nil,
        turnSequence: Int = 1,
        inferenceTurnID: UUID? = nil,
        isLegacy: Bool = false,
        intentID: String,
        userGoal: String,
        status: String,
        promptText: String,
        answerText: String?,
        transcriptText: String,
        contextDigest: String?,
        canonicalByteCount: Int?,
        providerToolCount: Int,
        recordSchemaVersion: Int = Self.schemaVersion,
        createdAt: Date,
        completedAt: Date?,
        continuationCheckpoint: Phase2AssistantContinuationCheckpointRecord? = nil,
        contentSHA256: String
    ) {
        self.id = id
        self.sequence = sequence
        self.conversationID = conversationID ?? id
        self.turnSequence = turnSequence
        self.inferenceTurnID = inferenceTurnID ?? id
        self.isLegacy = isLegacy
        self.intentID = intentID
        self.userGoal = userGoal
        self.status = status
        self.promptText = promptText
        self.answerText = answerText
        self.transcriptText = transcriptText
        self.contextDigest = contextDigest
        self.canonicalByteCount = canonicalByteCount
        self.providerToolCount = providerToolCount
        self.recordSchemaVersion = recordSchemaVersion
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.continuationCheckpoint = continuationCheckpoint
        self.contentSHA256 = contentSHA256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .recordSchemaVersion) ?? 1
        guard (1...Self.schemaVersion).contains(decodedVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .recordSchemaVersion,
                in: container,
                debugDescription: "Unsupported Assistant record schema version \(decodedVersion)."
            )
        }
        id = try container.decode(UUID.self, forKey: .id)
        sequence = try container.decode(Int.self, forKey: .sequence)
        if decodedVersion == 1 {
            conversationID = id
            turnSequence = 1
            inferenceTurnID = id
            isLegacy = true
        } else {
            conversationID = try container.decode(UUID.self, forKey: .conversationID)
            turnSequence = try container.decode(Int.self, forKey: .turnSequence)
            inferenceTurnID = try container.decode(UUID.self, forKey: .inferenceTurnID)
            isLegacy = try container.decode(Bool.self, forKey: .isLegacy)
        }
        intentID = try container.decode(String.self, forKey: .intentID)
        userGoal = try container.decode(String.self, forKey: .userGoal)
        status = try container.decode(String.self, forKey: .status)
        promptText = try container.decode(String.self, forKey: .promptText)
        answerText = try container.decodeIfPresent(String.self, forKey: .answerText)
        transcriptText = try container.decode(String.self, forKey: .transcriptText)
        contextDigest = try container.decodeIfPresent(String.self, forKey: .contextDigest)
        canonicalByteCount = try container.decodeIfPresent(Int.self, forKey: .canonicalByteCount)
        providerToolCount = try container.decode(Int.self, forKey: .providerToolCount)
        recordSchemaVersion = decodedVersion
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        continuationCheckpoint = decodedVersion >= 3
            ? try container.decodeIfPresent(Phase2AssistantContinuationCheckpointRecord.self, forKey: .continuationCheckpoint)
            : nil
        contentSHA256 = try container.decode(String.self, forKey: .contentSHA256)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(conversationID, forKey: .conversationID)
        try container.encode(turnSequence, forKey: .turnSequence)
        try container.encode(inferenceTurnID, forKey: .inferenceTurnID)
        try container.encode(isLegacy, forKey: .isLegacy)
        try container.encode(intentID, forKey: .intentID)
        try container.encode(userGoal, forKey: .userGoal)
        try container.encode(status, forKey: .status)
        try container.encode(promptText, forKey: .promptText)
        try container.encodeIfPresent(answerText, forKey: .answerText)
        try container.encode(transcriptText, forKey: .transcriptText)
        try container.encodeIfPresent(contextDigest, forKey: .contextDigest)
        try container.encodeIfPresent(canonicalByteCount, forKey: .canonicalByteCount)
        try container.encode(providerToolCount, forKey: .providerToolCount)
        try container.encode(Self.schemaVersion, forKey: .recordSchemaVersion)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
        try container.encodeIfPresent(continuationCheckpoint, forKey: .continuationCheckpoint)
        try container.encode(contentSHA256, forKey: .contentSHA256)
    }

    func normalizedForCurrentEncoding(workspaceUUID: UUID, documentID: UUID) -> Self {
        guard recordSchemaVersion < Self.schemaVersion else {
            return self
        }
        var normalized = self
        normalized.recordSchemaVersion = Self.schemaVersion
        normalized.isLegacy = true
        normalized.contentSHA256 = normalized.calculatedContentSHA256(
            workspaceUUID: workspaceUUID,
            documentID: documentID
        )
        return normalized
    }

    func calculatedContentSHA256(workspaceUUID: UUID, documentID: UUID) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var canonical = [
            "schema=\(recordSchemaVersion)", "id=\(id.uuidString)",
            "workspace=\(workspaceUUID.uuidString)", "document=\(documentID.uuidString)",
            "sequence=\(sequence)",
        ]
        if recordSchemaVersion >= 2 {
            canonical.append(contentsOf: [
                "conversation=\(conversationID.uuidString)", "turnSequence=\(turnSequence)",
                "inferenceTurn=\(inferenceTurnID.uuidString)", "legacy=\(isLegacy ? 1 : 0)",
            ])
        }
        canonical.append(contentsOf: [
            "intent=\(intentID)", "status=\(status)", "providerToolCount=\(providerToolCount)",
            "canonicalByteCount=\(canonicalByteCount.map(String.init) ?? "null")",
            "contextDigest=\(contextDigest ?? "null")", "createdAt=\(formatter.string(from: createdAt))",
            "completedAt=\(completedAt.map(formatter.string(from:)) ?? "null")",
            "goal=\(userGoal)", "prompt=\(promptText)", "answer=\(answerText ?? "null")",
            "transcript=\(transcriptText)",
        ])
        if recordSchemaVersion >= 3 {
            canonical.append("continuationCheckpoint=\(continuationCheckpoint?.canonicalJSON ?? "null")")
        }
        return SHA256.hash(data: Data(canonical.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Persistence-owned, versioned representation of a same-turn shell continuation checkpoint.
/// The runtime domain model adapts to this record at the database boundary; keeping this DTO
/// independent prevents persisted workspaces from depending on transient provider protocol types.
struct Phase2AssistantContinuationCheckpointRecord: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    var logicalState: String
    var initialRequestID: UUID
    var initialTerminalEventDigest: String
    var shellProposalID: UUID
    var shellProposalJSON: String
    var shellProposalSHA256: String
    var humanDecision: String?
    var approvalConsumedAt: Date?
    var approvalState: String?
    var shellExecutionID: UUID?
    var completedExecutionReference: String?
    var shellExecutionSHA256: String?
    var runtimeAuthorityRecordID: UUID?
    var runtimeAuthoritySHA256: String?
    var continuationCoordinate: Phase2AssistantContinuationCoordinateRecord?
    var continuationOrdinal: Int?
    var continuationRequestID: UUID?
    var continuationDispatchState: String?
    var continuationTerminalEventDigest: String?
    var finalProvenanceJSON: String?
    var recordSchemaVersion: Int = Self.schemaVersion

    var canonicalJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? String(decoding: encoder.encode(self), as: UTF8.self)) ?? ""
    }

    var isStructurallyValid: Bool {
        let validStates: Set<String> = [
            "awaitingShellReview", "executingShell", "awaitingShellContinuation",
            "continuingShell", "completed", "failed", "cancelled",
        ]
        let authorityIDs = [shellProposalID, shellExecutionID, continuationRequestID].compactMap { $0 }
        guard recordSchemaVersion == Self.schemaVersion,
              validStates.contains(logicalState),
              Self.isNonzero(initialRequestID),
              Self.isNonzero(shellProposalID),
              Self.isLowercaseSHA256(initialTerminalEventDigest),
              !shellProposalJSON.isEmpty,
              Self.isLowercaseSHA256(shellProposalSHA256),
              shellExecutionSHA256.map(Self.isLowercaseSHA256) ?? true,
              runtimeAuthoritySHA256.map(Self.isLowercaseSHA256) ?? true,
              continuationTerminalEventDigest.map(Self.isLowercaseSHA256) ?? true,
              authorityIDs.allSatisfy(Self.isNonzero),
              Set(authorityIDs).count == authorityIDs.count,
              shellExecutionID != nil || (
                  completedExecutionReference == nil && shellExecutionSHA256 == nil &&
                  runtimeAuthorityRecordID == nil && runtimeAuthoritySHA256 == nil &&
                  continuationCoordinate == nil && continuationOrdinal == nil &&
                  continuationRequestID == nil
              ),
              completedExecutionReference == nil || completedExecutionReference == shellExecutionID?.uuidString,
              continuationOrdinal == nil || continuationOrdinal == 1,
              continuationRequestID == nil || continuationOrdinal == 1,
              continuationCoordinate == nil || continuationCoordinate?.isStructurallyValid == true
        else { return false }

        guard let continuationCoordinate else {
            return continuationOrdinal == nil && continuationRequestID == nil
        }
        return continuationCoordinate.originatingFinalizationRequestID == initialRequestID &&
            continuationCoordinate.shellProposalID == shellProposalID &&
            continuationCoordinate.shellExecutionID == shellExecutionID &&
            continuationCoordinate.runtimeAuthorityRecordID == runtimeAuthorityRecordID &&
            continuationCoordinate.shellProposalDigest == shellProposalSHA256 &&
            continuationCoordinate.shellExecutionResultDigest == shellExecutionSHA256 &&
            continuationCoordinate.runtimeAuthorityRecordDigest == runtimeAuthoritySHA256 &&
            continuationCoordinate.continuationOrdinal == continuationOrdinal &&
            continuationCoordinate.continuationRequestID == continuationRequestID
    }

    func isStructurallyValid(
        workspaceID: UUID,
        conversationID: UUID,
        inferenceTurnID: UUID,
        turnSequence: Int
    ) -> Bool {
        guard isStructurallyValid else { return false }
        guard let continuationCoordinate else { return true }
        return continuationCoordinate.workspaceID == workspaceID &&
            continuationCoordinate.conversationID == conversationID &&
            continuationCoordinate.inferenceTurnID == inferenceTurnID &&
            continuationCoordinate.turnSequence == turnSequence
    }

    private static func isNonzero(_ id: UUID) -> Bool {
        id != UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }

    fileprivate static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains(Int($0.value)) || (97...102).contains(Int($0.value))
        }
    }
}

/// Exact persistence projection of the frozen domain continuation coordinate.
struct Phase2AssistantContinuationCoordinateRecord: Codable, Equatable, Sendable {
    var workspaceID: UUID
    var workspaceDocumentIdentityDigest: String
    var conversationID: UUID
    var inferenceTurnID: UUID
    var turnSequence: Int
    var originatingFinalizationRequestID: UUID
    var shellProposalID: UUID
    var shellExecutionID: UUID
    var runtimeAuthorityRecordID: UUID
    var shellProposalDigest: String
    var shellExecutionResultDigest: String
    var runtimeAuthorityRecordDigest: String
    var productionManifestIdentity: String
    var providerRevision: String
    var continuationOrdinal: Int
    var continuationRequestID: UUID
    var integrityDigest: String

    var isStructurallyValid: Bool {
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let authorityIDs = [shellProposalID, shellExecutionID, continuationRequestID]
        guard workspaceID != zero, conversationID != zero, inferenceTurnID != zero,
              originatingFinalizationRequestID != zero, runtimeAuthorityRecordID != zero,
              authorityIDs.allSatisfy({ $0 != zero }), Set(authorityIDs).count == authorityIDs.count,
              turnSequence > 0, continuationOrdinal == 1,
              Phase2AssistantContinuationCheckpointRecord.isLowercaseSHA256(workspaceDocumentIdentityDigest),
              Phase2AssistantContinuationCheckpointRecord.isLowercaseSHA256(shellProposalDigest),
              Phase2AssistantContinuationCheckpointRecord.isLowercaseSHA256(shellExecutionResultDigest),
              Phase2AssistantContinuationCheckpointRecord.isLowercaseSHA256(runtimeAuthorityRecordDigest),
              productionManifestIdentity.hasPrefix("sha256:"),
              Phase2AssistantContinuationCheckpointRecord.isLowercaseSHA256(
                  String(productionManifestIdentity.dropFirst(7))
              ),
              UInt64(providerRevision).map({ $0 > 0 }) == true,
              Phase2AssistantContinuationCheckpointRecord.isLowercaseSHA256(integrityDigest)
        else { return false }
        return integrityDigest == calculatedIntegrityDigest
    }

    private var calculatedIntegrityDigest: String {
        var data = Data()
        [
            "phase2-assistant-shell-continuation-coordinate-v1",
            workspaceID.uuidString.lowercased(), workspaceDocumentIdentityDigest,
            conversationID.uuidString.lowercased(), inferenceTurnID.uuidString.lowercased(),
            String(turnSequence), originatingFinalizationRequestID.uuidString.lowercased(),
            shellProposalID.uuidString.lowercased(), shellExecutionID.uuidString.lowercased(),
            runtimeAuthorityRecordID.uuidString.lowercased(), shellProposalDigest,
            shellExecutionResultDigest, runtimeAuthorityRecordDigest, productionManifestIdentity,
            providerRevision, String(continuationOrdinal), continuationRequestID.uuidString.lowercased(),
        ].forEach { field in
            let bytes = Data(field.utf8)
            var count = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct WorkspacePackageRuntimeAuthorityRecord: Codable, Equatable, Identifiable {
    static let schemaVersion = 1

    var id: UUID
    var sessionID: UUID
    var surfaces: Set<Phase2RuntimeAuthoritySurface>
    var terminalBackend: Phase2TerminalEmulationBackend
    var ptyReusePolicy: Phase2TerminalPTYReusePolicy
    var debuggerAuthorityPolicy: Phase2DebuggerAuthorityToolPolicy
    var providerVisibleShellExecutionEnabled: Bool
    var recordSchemaVersion: Int
    var createdAt: Date

    init(
        id: UUID,
        sessionID: UUID,
        surfaces: Set<Phase2RuntimeAuthoritySurface>,
        terminalBackend: Phase2TerminalEmulationBackend,
        ptyReusePolicy: Phase2TerminalPTYReusePolicy,
        debuggerAuthorityPolicy: Phase2DebuggerAuthorityToolPolicy,
        providerVisibleShellExecutionEnabled: Bool,
        recordSchemaVersion: Int = Self.schemaVersion,
        createdAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.surfaces = surfaces
        self.terminalBackend = terminalBackend
        self.ptyReusePolicy = ptyReusePolicy
        self.debuggerAuthorityPolicy = debuggerAuthorityPolicy
        self.providerVisibleShellExecutionEnabled = providerVisibleShellExecutionEnabled
        self.recordSchemaVersion = recordSchemaVersion
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, sessionID, surfaces, terminalBackend, ptyReusePolicy
        case debuggerAuthorityPolicy, providerVisibleShellExecutionEnabled
        case recordSchemaVersion, createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sessionID, forKey: .sessionID)
        // JSONEncoder.sortedKeys does not sort Set-backed arrays. Observation digests
        // must remain stable across decode/re-encode of the same persisted authority.
        try container.encode(surfaces.sorted { $0.rawValue < $1.rawValue }, forKey: .surfaces)
        try container.encode(terminalBackend, forKey: .terminalBackend)
        try container.encode(ptyReusePolicy, forKey: .ptyReusePolicy)
        try container.encode(debuggerAuthorityPolicy, forKey: .debuggerAuthorityPolicy)
        try container.encode(providerVisibleShellExecutionEnabled, forKey: .providerVisibleShellExecutionEnabled)
        try container.encode(recordSchemaVersion, forKey: .recordSchemaVersion)
        try container.encode(createdAt, forKey: .createdAt)
    }

    var authorityRecord: Phase2TerminalRuntimeAuthorityRecord {
        Phase2TerminalRuntimeAuthorityRecord(
            id: id,
            schemaVersion: recordSchemaVersion,
            sessionID: sessionID,
            surfaces: surfaces,
            terminalBackend: terminalBackend,
            ptyReusePolicy: ptyReusePolicy,
            debuggerAuthorityPolicy: debuggerAuthorityPolicy,
            providerVisibleShellExecutionEnabled: providerVisibleShellExecutionEnabled,
            createdAt: createdAt
        )
    }
}

struct WorkspacePackageBinary: Codable, Equatable, Identifiable {
    var id: UUID
    var displayName: String
    var originalPath: String
    var originalPathBookmark: Data?
    var attachmentRelativePath: String
    var kind: String
    var architecture: String
    var fileHash: String
    var fileSize: Int64
    /// Loader-authored format metadata. Optional so packages written before
    /// metadata persistence keep their established encoding and decode as absent.
    var metadata: BinaryMetadataSummary?
    /// The persisted universal-slice pick for a fat/universal Mach-O (the user's dialog choice,
    /// or nil for the default selection rule). Optional so pre-existing v1 packages — which never
    /// wrote this key — decode it as nil, so no package-format bump is required. Restored on open
    /// so a reopened universal-binary
    /// document reanalyzes the SAME slice instead of silently reverting to the default arch.
    var selectedSliceIndex: Int?
    /// Loader-observed container and actual selection; absent in older packages.
    var machOSelectedSliceFact: MachOSelectedSliceFact?
    /// Exact selected member when `originalPath` names an outer Unix archive. The attachment is
    /// the selected member payload; the outer path/bookmark remains the filesystem authority.
    var elfArchiveMemberIdentity: ELFArchiveMemberSelection?
    /// Durable workspace-local image identity. Primary is omitted so legacy v1 binary JSON stays
    /// byte-identical; a missing key decodes to the legacy primary slot.
    var slot: ImageSlot

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case originalPath
        case originalPathBookmark
        case attachmentRelativePath
        case kind
        case architecture
        case fileHash
        case fileSize
        case metadata
        case selectedSliceIndex
        case machOSelectedSliceFact
        case elfArchiveMemberIdentity
        case slot
    }

    init(
        id: UUID,
        displayName: String,
        originalPath: String,
        originalPathBookmark: Data? = nil,
        attachmentRelativePath: String,
        kind: String,
        architecture: String,
        fileHash: String,
        fileSize: Int64,
        metadata: BinaryMetadataSummary? = nil,
        selectedSliceIndex: Int? = nil,
        machOSelectedSliceFact: MachOSelectedSliceFact? = nil,
        elfArchiveMemberIdentity: ELFArchiveMemberSelection? = nil,
        slot: ImageSlot = .primary
    ) {
        self.id = id
        self.displayName = displayName
        self.originalPath = originalPath
        self.originalPathBookmark = originalPathBookmark
        self.attachmentRelativePath = attachmentRelativePath
        self.kind = kind
        self.architecture = architecture
        self.fileHash = fileHash
        self.fileSize = fileSize
        self.metadata = metadata
        self.selectedSliceIndex = selectedSliceIndex
        self.machOSelectedSliceFact = machOSelectedSliceFact
        self.elfArchiveMemberIdentity = elfArchiveMemberIdentity
        self.slot = slot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let archiveMemberIdentity = try container.decodeIfPresent(
            ELFArchiveMemberSelection.self,
            forKey: .elfArchiveMemberIdentity
        )
        let selectedSliceIndex = try container.decodeIfPresent(Int.self, forKey: .selectedSliceIndex)
        let machOSelectedSliceFact = try container.decodeIfPresent(
            MachOSelectedSliceFact.self, forKey: .machOSelectedSliceFact
        )
        if let archiveMemberIdentity,
           (!BinaryImage.isValidArchiveMemberIdentity(archiveMemberIdentity) || selectedSliceIndex != nil || machOSelectedSliceFact != nil) {
            throw DecodingError.dataCorruptedError(
                forKey: .elfArchiveMemberIdentity,
                in: container,
                debugDescription: "ELF archive member identity is malformed or outside its container."
            )
        }
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            displayName: try container.decode(String.self, forKey: .displayName),
            originalPath: try container.decode(String.self, forKey: .originalPath),
            originalPathBookmark: try container.decodeIfPresent(Data.self, forKey: .originalPathBookmark),
            attachmentRelativePath: try container.decode(String.self, forKey: .attachmentRelativePath),
            kind: try container.decode(String.self, forKey: .kind),
            architecture: try container.decode(String.self, forKey: .architecture),
            fileHash: try container.decode(String.self, forKey: .fileHash),
            fileSize: try container.decode(Int64.self, forKey: .fileSize),
            metadata: try container.decodeIfPresent(BinaryMetadataSummary.self, forKey: .metadata),
            selectedSliceIndex: selectedSliceIndex,
            machOSelectedSliceFact: machOSelectedSliceFact,
            elfArchiveMemberIdentity: archiveMemberIdentity,
            slot: try container.decodeIfPresent(ImageSlot.self, forKey: .slot) ?? .primary
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(originalPath, forKey: .originalPath)
        try container.encodeIfPresent(originalPathBookmark, forKey: .originalPathBookmark)
        try container.encode(attachmentRelativePath, forKey: .attachmentRelativePath)
        try container.encode(kind, forKey: .kind)
        try container.encode(architecture, forKey: .architecture)
        try container.encode(fileHash, forKey: .fileHash)
        try container.encode(fileSize, forKey: .fileSize)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encodeIfPresent(selectedSliceIndex, forKey: .selectedSliceIndex)
        try container.encodeIfPresent(machOSelectedSliceFact, forKey: .machOSelectedSliceFact)
        try container.encodeIfPresent(elfArchiveMemberIdentity, forKey: .elfArchiveMemberIdentity)
        if slot != .primary {
            try container.encode(slot, forKey: .slot)
        }
    }
}

struct WorkspacePackageSession: Codable, Equatable {
    var selectedSidebarItemID: String?
    var selectedAddress: UInt64?
    var selectedTool: WorkspaceTool
    var editorMode: EditorMode
    var isInspectorPresented: Bool
    var sidebarSearchText: String
    var updatedAt: Date
    var focusedImageSlot: ImageSlot = .primary
    var phase2ShellSession: WorkspacePackagePhase2ShellSession?

    private enum CodingKeys: String, CodingKey {
        case selectedSidebarItemID
        case selectedAddress
        case selectedTool
        case editorMode
        case isInspectorPresented
        case sidebarSearchText
        case updatedAt
        case focusedImageSlot
        case phase2ShellSession
    }

    init(
        selectedSidebarItemID: String?,
        selectedAddress: UInt64?,
        selectedTool: WorkspaceTool,
        editorMode: EditorMode,
        isInspectorPresented: Bool,
        sidebarSearchText: String,
        updatedAt: Date,
        focusedImageSlot: ImageSlot = .primary,
        phase2ShellSession: WorkspacePackagePhase2ShellSession? = nil
    ) {
        self.selectedSidebarItemID = selectedSidebarItemID
        self.selectedAddress = selectedAddress
        self.selectedTool = selectedTool
        self.editorMode = editorMode
        self.isInspectorPresented = isInspectorPresented
        self.sidebarSearchText = sidebarSearchText
        self.updatedAt = updatedAt
        self.focusedImageSlot = focusedImageSlot
        self.phase2ShellSession = phase2ShellSession
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            selectedSidebarItemID: try container.decodeIfPresent(String.self, forKey: .selectedSidebarItemID),
            selectedAddress: try container.decodeIfPresent(UInt64.self, forKey: .selectedAddress),
            selectedTool: try container.decode(WorkspaceTool.self, forKey: .selectedTool),
            editorMode: try container.decode(EditorMode.self, forKey: .editorMode),
            isInspectorPresented: try container.decode(Bool.self, forKey: .isInspectorPresented),
            sidebarSearchText: try container.decode(String.self, forKey: .sidebarSearchText),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            focusedImageSlot: try container.decodeIfPresent(ImageSlot.self, forKey: .focusedImageSlot) ?? .primary,
            phase2ShellSession: try container.decodeIfPresent(
                WorkspacePackagePhase2ShellSession.self,
                forKey: .phase2ShellSession
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(selectedSidebarItemID, forKey: .selectedSidebarItemID)
        try container.encodeIfPresent(selectedAddress, forKey: .selectedAddress)
        try container.encode(selectedTool, forKey: .selectedTool)
        try container.encode(editorMode, forKey: .editorMode)
        try container.encode(isInspectorPresented, forKey: .isInspectorPresented)
        try container.encode(sidebarSearchText, forKey: .sidebarSearchText)
        try container.encode(updatedAt, forKey: .updatedAt)
        if focusedImageSlot != .primary {
            try container.encode(focusedImageSlot, forKey: .focusedImageSlot)
        }
        try container.encodeIfPresent(phase2ShellSession, forKey: .phase2ShellSession)
    }
}

struct WorkspacePackagePhase2ShellSession: Codable, Equatable {
    static let schemaVersion = 4

    var schemaVersion: Int
    var sessionID: UUID
    var launchPlan: WorkspacePackagePhase2ShellLaunchPlan?
    var terminalOutcome: WorkspacePackagePhase2ShellTerminalOutcome
    var transcriptEvents: [WorkspacePackagePhase2ShellTranscriptEvent]
    var terminalBackend: Phase2TerminalEmulationBackend
    var ptyReusePolicy: Phase2TerminalPTYReusePolicy
    var debuggerAuthorityPolicy: Phase2DebuggerAuthorityToolPolicy
    var runningRequestID: UUID?
    var runningProcessIdentifier: Int32?
    var nextTranscriptSequence: UInt64?
    /// Public, non-authorizing broker identity used to attempt recovery after reopen.
    /// The bearer capability remains exclusively in Keychain and is never package data.
    var durableBrokerIdentity: WorkspacePackagePhase2DurableShellBrokerIdentity?

    init(
        schemaVersion: Int = Self.schemaVersion,
        sessionID: UUID,
        launchPlan: WorkspacePackagePhase2ShellLaunchPlan?,
        terminalOutcome: WorkspacePackagePhase2ShellTerminalOutcome,
        transcriptEvents: [WorkspacePackagePhase2ShellTranscriptEvent],
        terminalBackend: Phase2TerminalEmulationBackend = .transcriptFallback,
        ptyReusePolicy: Phase2TerminalPTYReusePolicy = .disabled,
        debuggerAuthorityPolicy: Phase2DebuggerAuthorityToolPolicy = .disabled,
        runningRequestID: UUID? = nil,
        runningProcessIdentifier: Int32? = nil,
        nextTranscriptSequence: UInt64? = nil,
        durableBrokerIdentity: WorkspacePackagePhase2DurableShellBrokerIdentity? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.launchPlan = launchPlan
        self.terminalOutcome = terminalOutcome
        self.transcriptEvents = transcriptEvents
        self.terminalBackend = terminalBackend
        self.ptyReusePolicy = ptyReusePolicy
        self.debuggerAuthorityPolicy = debuggerAuthorityPolicy
        self.runningRequestID = runningRequestID
        self.runningProcessIdentifier = runningProcessIdentifier
        self.nextTranscriptSequence = nextTranscriptSequence
        self.durableBrokerIdentity = durableBrokerIdentity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchema = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? 1
        guard (1...Self.schemaVersion).contains(decodedSchema) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported Phase 2 shell-session schema version \(decodedSchema)."
            )
        }
        self.init(
            schemaVersion: Self.schemaVersion,
            sessionID: try container.decode(UUID.self, forKey: .sessionID),
            launchPlan: try container.decodeIfPresent(
                WorkspacePackagePhase2ShellLaunchPlan.self,
                forKey: .launchPlan
            ),
            terminalOutcome: try container.decode(
                WorkspacePackagePhase2ShellTerminalOutcome.self,
                forKey: .terminalOutcome
            ),
            transcriptEvents: try container.decodeIfPresent(
                [WorkspacePackagePhase2ShellTranscriptEvent].self,
                forKey: .transcriptEvents
            ) ?? [],
            terminalBackend: try container.decodeIfPresent(
                Phase2TerminalEmulationBackend.self,
                forKey: .terminalBackend
            ) ?? .transcriptFallback,
            ptyReusePolicy: try container.decodeIfPresent(
                Phase2TerminalPTYReusePolicy.self,
                forKey: .ptyReusePolicy
            ) ?? .disabled,
            debuggerAuthorityPolicy: try container.decodeIfPresent(
                Phase2DebuggerAuthorityToolPolicy.self,
                forKey: .debuggerAuthorityPolicy
            ) ?? .disabled,
            runningRequestID: try container.decodeIfPresent(
                UUID.self,
                forKey: .runningRequestID
            ),
            runningProcessIdentifier: try container.decodeIfPresent(
                Int32.self,
                forKey: .runningProcessIdentifier
            ),
            nextTranscriptSequence: try container.decodeIfPresent(
                UInt64.self,
                forKey: .nextTranscriptSequence
            ),
            durableBrokerIdentity: decodedSchema >= 4
                ? try container.decodeIfPresent(
                    WorkspacePackagePhase2DurableShellBrokerIdentity.self,
                    forKey: .durableBrokerIdentity
                )
                : nil
        )

        if let durableBrokerIdentity,
           (!durableBrokerIdentity.isStructurallyValid
            || durableBrokerIdentity.sessionID != sessionID
            || durableBrokerIdentity.requestID != runningRequestID
            || durableBrokerIdentity.processIdentifier != runningProcessIdentifier
            || nextTranscriptSequence == nil
            || nextTranscriptSequence == 0
            || terminalBackend != .ghosttyLib
            || ptyReusePolicy != .shellBrokerSession) {
            throw DecodingError.dataCorruptedError(
                forKey: .durableBrokerIdentity,
                in: container,
                debugDescription: "Phase 2 durable shell recovery identity does not match its session envelope."
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sessionID
        case launchPlan
        case terminalOutcome
        case transcriptEvents
        case terminalBackend
        case ptyReusePolicy
        case debuggerAuthorityPolicy
        case runningRequestID
        case runningProcessIdentifier
        case nextTranscriptSequence
        case durableBrokerIdentity
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(launchPlan, forKey: .launchPlan)
        try container.encode(terminalOutcome, forKey: .terminalOutcome)
        try container.encode(transcriptEvents, forKey: .transcriptEvents)
        try container.encode(terminalBackend, forKey: .terminalBackend)
        try container.encode(ptyReusePolicy, forKey: .ptyReusePolicy)
        try container.encode(debuggerAuthorityPolicy, forKey: .debuggerAuthorityPolicy)
        try container.encodeIfPresent(runningRequestID, forKey: .runningRequestID)
        try container.encodeIfPresent(runningProcessIdentifier, forKey: .runningProcessIdentifier)
        try container.encodeIfPresent(nextTranscriptSequence, forKey: .nextTranscriptSequence)
        try container.encodeIfPresent(durableBrokerIdentity, forKey: .durableBrokerIdentity)
    }
}

/// Package-safe copy of the broker's public recovery identity. It intentionally contains no
/// capability secret, PTY binding identifier, or terminal-surface identifier.
struct WorkspacePackagePhase2DurableShellBrokerIdentity: Codable, Equatable {
    static let schemaVersion = 1

    var schemaVersion: Int
    var brokerIncarnationID: UUID
    var sessionID: UUID
    var capabilityID: UUID
    var requestID: UUID
    var executablePath: String
    var arguments: [String]
    var workingDirectoryPath: String?
    var launchRequestCreatedAt: Date
    var processIdentifier: Int32
    var processStartTimeUnixNanoseconds: UInt64
    var processGroupIdentifier: Int32
    var createdAt: Date
    var expiresAt: Date
    var nextTranscriptSequence: UInt64
    var capabilityVerifierSHA256: Data

    var isStructurallyValid: Bool {
        schemaVersion == Self.schemaVersion
            && processIdentifier > 1
            && processStartTimeUnixNanoseconds > 0
            && processGroupIdentifier > 1
            && executablePath.hasPrefix("/")
            && !executablePath.contains("\0")
            && !arguments.contains(where: { $0.contains("\0") })
            && (workingDirectoryPath == nil || (
                workingDirectoryPath?.hasPrefix("/") == true
                    && workingDirectoryPath?.contains("\0") == false
            ))
            && createdAt >= launchRequestCreatedAt
            && expiresAt > createdAt
            && nextTranscriptSequence > 0
            && capabilityVerifierSHA256.count == 32
    }
}

struct WorkspacePackagePhase2ShellLaunchPlan: Codable, Equatable {
    var sessionID: UUID
    var requestID: UUID
    var executablePath: String
    var arguments: [String]
    var environment: [String: String]
    var workingDirectoryPath: String?
    var columns: Int
    var rows: Int
    var transcriptMaximumEvents: Int
    var transcriptMaximumEventBytes: Int
    var transcriptMaximumCumulativeBytes: Int
}

enum WorkspacePackagePhase2ShellTerminalOutcome: Codable, Equatable {
    case exited(status: Int32)
    case signaled(String)
    case canceled
    case interrupted
    case brokerCrashed
    case outcomeUnknown

    private enum CodingKeys: String, CodingKey {
        case kind
        case status
        case signal
    }

    private enum Kind: String, Codable {
        case exited
        case signaled
        case canceled
        case interrupted
        case brokerCrashed
        case outcomeUnknown
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .exited:
            self = .exited(status: try container.decode(Int32.self, forKey: .status))
        case .signaled:
            self = .signaled(try container.decode(String.self, forKey: .signal))
        case .canceled:
            self = .canceled
        case .interrupted:
            self = .interrupted
        case .brokerCrashed:
            self = .brokerCrashed
        case .outcomeUnknown:
            self = .outcomeUnknown
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .exited(let status):
            try container.encode(Kind.exited, forKey: .kind)
            try container.encode(status, forKey: .status)
        case .signaled(let signal):
            try container.encode(Kind.signaled, forKey: .kind)
            try container.encode(signal, forKey: .signal)
        case .canceled:
            try container.encode(Kind.canceled, forKey: .kind)
        case .interrupted:
            try container.encode(Kind.interrupted, forKey: .kind)
        case .brokerCrashed:
            try container.encode(Kind.brokerCrashed, forKey: .kind)
        case .outcomeUnknown:
            try container.encode(Kind.outcomeUnknown, forKey: .kind)
        }
    }
}

struct WorkspacePackagePhase2ShellTranscriptEvent: Codable, Equatable {
    var sessionID: UUID
    var sequence: UInt64
    var source: String
    var payload: WorkspacePackagePhase2ShellTranscriptPayload
}

enum WorkspacePackagePhase2ShellTranscriptPayload: Codable, Equatable {
    case input(Data)
    case output(stream: String, bytes: Data)
    case resize(columns: Int, rows: Int)
    case signal(String)
    case reconnect(reconnectID: UUID)
    case gap(reason: String, lostByteCount: Int)
    case terminal(WorkspacePackagePhase2ShellTerminalOutcome)

    private enum CodingKeys: String, CodingKey {
        case kind
        case bytes
        case stream
        case columns
        case rows
        case signal
        case reconnectID
        case reason
        case lostByteCount
        case outcome
    }

    private enum Kind: String, Codable {
        case input
        case output
        case resize
        case signal
        case reconnect
        case gap
        case terminal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .input:
            self = .input(try container.decode(Data.self, forKey: .bytes))
        case .output:
            self = .output(
                stream: try container.decode(String.self, forKey: .stream),
                bytes: try container.decode(Data.self, forKey: .bytes)
            )
        case .resize:
            self = .resize(
                columns: try container.decode(Int.self, forKey: .columns),
                rows: try container.decode(Int.self, forKey: .rows)
            )
        case .signal:
            self = .signal(try container.decode(String.self, forKey: .signal))
        case .reconnect:
            self = .reconnect(reconnectID: try container.decode(UUID.self, forKey: .reconnectID))
        case .gap:
            self = .gap(
                reason: try container.decode(String.self, forKey: .reason),
                lostByteCount: try container.decode(Int.self, forKey: .lostByteCount)
            )
        case .terminal:
            self = .terminal(try container.decode(
                WorkspacePackagePhase2ShellTerminalOutcome.self,
                forKey: .outcome
            ))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .input(let bytes):
            try container.encode(Kind.input, forKey: .kind)
            try container.encode(bytes, forKey: .bytes)
        case .output(let stream, let bytes):
            try container.encode(Kind.output, forKey: .kind)
            try container.encode(stream, forKey: .stream)
            try container.encode(bytes, forKey: .bytes)
        case .resize(let columns, let rows):
            try container.encode(Kind.resize, forKey: .kind)
            try container.encode(columns, forKey: .columns)
            try container.encode(rows, forKey: .rows)
        case .signal(let signal):
            try container.encode(Kind.signal, forKey: .kind)
            try container.encode(signal, forKey: .signal)
        case .reconnect(let reconnectID):
            try container.encode(Kind.reconnect, forKey: .kind)
            try container.encode(reconnectID, forKey: .reconnectID)
        case .gap(let reason, let lostByteCount):
            try container.encode(Kind.gap, forKey: .kind)
            try container.encode(reason, forKey: .reason)
            try container.encode(lostByteCount, forKey: .lostByteCount)
        case .terminal(let outcome):
            try container.encode(Kind.terminal, forKey: .kind)
            try container.encode(outcome, forKey: .outcome)
        }
    }
}

enum WorkspacePackageNamespaceCoordinator {
    struct FileObjectIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    enum CoordinationError: Error {
        case failed
        case accessorNotInvoked
    }

    /// Serializes the complete staged-package namespace transaction for cooperating
    /// MacScope writers. This coordination boundary does not claim to exclude an
    /// arbitrary same-UID process that ignores `NSFileCoordinator`.
    static func coordinate<T>(
        stagedAt stagedURL: URL,
        destination destinationURL: URL,
        _ accessor: (URL, URL) throws -> T
    ) throws -> T {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(
            writingItemAt: stagedURL,
            options: .forMoving,
            writingItemAt: destinationURL,
            options: [],
            error: &coordinationError
        ) { coordinatedStageURL, coordinatedDestinationURL in
            result = Result {
                try accessor(coordinatedStageURL, coordinatedDestinationURL)
            }
        }
        if let result {
            return try result.get()
        }
        if coordinationError != nil {
            throw CoordinationError.failed
        }
        throw CoordinationError.accessorNotInvoked
    }

    static func fileObjectIdentity(at url: URL) throws -> FileObjectIdentity? {
        var metadata = stat()
        errno = 0
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            return Darwin.fstatat(AT_FDCWD, path, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if status != 0 {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard let device = UInt64(exactly: metadata.st_dev),
              let inode = UInt64(exactly: metadata.st_ino) else {
            throw POSIXError(.EOVERFLOW)
        }
        return FileObjectIdentity(device: device, inode: inode)
    }
}
