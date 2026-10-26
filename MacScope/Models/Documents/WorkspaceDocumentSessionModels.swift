import Darwin
import Foundation
import Synchronization

struct WorkspaceDocumentSessionID: Hashable, Sendable {
    let rawValue: UUID
}

struct WorkspaceFileObjectIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct WorkspaceDocumentLocation: Hashable, Sendable {
    let canonicalURL: URL
    let fileObjectIdentity: WorkspaceFileObjectIdentity?

    static func canonicalized(
        from url: URL,
        fileManager: FileManager = .default
    ) throws -> WorkspaceDocumentLocation {
        guard url.isFileURL else {
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-location-not-file-url"
            )
        }

        let standardized = url.standardizedFileURL
        let absolute: URL
        if standardized.path.hasPrefix("/") {
            absolute = standardized
        } else {
            absolute = URL(
                fileURLWithPath: fileManager.currentDirectoryPath,
                isDirectory: true
            ).appendingPathComponent(standardized.path)
        }
        var resolvedURL = absolute
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        // Foundation resolves symlinks (and drops `/private` from `/private/tmp`, `/private/var`)
        // only for paths that exist. A not-yet-created package therefore resolves its existing
        // parent the same way the publisher resolves the stage parent, so `/private/tmp/X` and
        // `/tmp/X` name one location before and after the package is created.
        var existing = stat()
        if lstat(resolvedURL.path, &existing) != 0, errno == ENOENT {
            resolvedURL = resolvedURL.deletingLastPathComponent()
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .appendingPathComponent(resolvedURL.lastPathComponent, isDirectory: false)
        }
        // `NSSavePanel` returns a file-typed URL for a not-yet-created package,
        // while Foundation adds a trailing slash after that URL becomes a
        // directory. Rebuild from the resolved filesystem path so document
        // identity does not change solely with that directory hint.
        let canonicalURL = URL(
            fileURLWithPath: resolvedURL.path,
            isDirectory: false
        ).standardizedFileURL

        var metadata = stat()
        errno = 0
        let result = canonicalURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.fstatat(AT_FDCWD, path, &metadata, 0)
        }
        if result != 0 {
            if errno == ENOENT || errno == ENOTDIR {
                return WorkspaceDocumentLocation(
                    canonicalURL: canonicalURL,
                    fileObjectIdentity: nil
                )
            }
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-location-stat-failed"
            )
        }

        guard let device = UInt64(exactly: metadata.st_dev),
              let inode = UInt64(exactly: metadata.st_ino) else {
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-location-identity-out-of-range"
            )
        }
        return WorkspaceDocumentLocation(
            canonicalURL: canonicalURL,
            fileObjectIdentity: WorkspaceFileObjectIdentity(
                device: device,
                inode: inode
            )
        )
    }
}

enum WorkspacePackageObservationCondition: String, Sendable {
    case absent
    case valid
    case invalid
    case unverifiable
}

struct WorkspacePackageExternalVersion: Equatable, Sendable {
    static let schemaVersion = 1

    let location: WorkspaceDocumentLocation
    let condition: WorkspacePackageObservationCondition
    let observationSHA256: String
    let manifestSHA256: String?
    let validatedContentSHA256: String?
    let boundedReason: String?
}

struct WorkspaceDocumentMutationGeneration: Hashable, Comparable, Sendable {
    let rawValue: UInt64

    static func < (
        lhs: WorkspaceDocumentMutationGeneration,
        rhs: WorkspaceDocumentMutationGeneration
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    func next() throws -> WorkspaceDocumentMutationGeneration {
        guard rawValue < UInt64.max else {
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-generation-exhausted"
            )
        }
        return WorkspaceDocumentMutationGeneration(rawValue: rawValue + 1)
    }
}

struct WorkspaceDocumentSaveGeneration: Hashable, Comparable, Sendable {
    let rawValue: UInt64

    static func < (
        lhs: WorkspaceDocumentSaveGeneration,
        rhs: WorkspaceDocumentSaveGeneration
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    func next() throws -> WorkspaceDocumentSaveGeneration {
        guard rawValue < UInt64.max else {
            throw WorkspaceDocumentSessionError.operationFailed(
                "document-generation-exhausted"
            )
        }
        return WorkspaceDocumentSaveGeneration(rawValue: rawValue + 1)
    }
}

struct WorkspaceDocumentSaveRequestID: Hashable, Sendable {
    let rawValue: UUID
}

enum WorkspaceDocumentConflictReason: Equatable, Sendable {
    case externallyChanged
    case destinationMissing
    case destinationInvalid(String)
    case destinationUnverifiable(String)
    case destinationOwnedByAnotherWindow
}

struct WorkspaceDocumentConflict: Equatable, Sendable {
    let expected: WorkspacePackageExternalVersion
    let observed: WorkspacePackageExternalVersion
    let reason: WorkspaceDocumentConflictReason
}

enum WorkspaceDocumentWriteIntent: Equatable, Sendable {
    case save
    case autosave
    case saveAs(adopting: WorkspaceDocumentLocation)
    case saveCopy(to: WorkspaceDocumentLocation)
    case keepLocalVersion(over: WorkspacePackageExternalVersion)
}

struct WorkspaceDocumentActiveSave: Equatable, Sendable {
    let requestID: WorkspaceDocumentSaveRequestID
    let saveGeneration: WorkspaceDocumentSaveGeneration
    let capturedMutationGeneration: WorkspaceDocumentMutationGeneration
    let intent: WorkspaceDocumentWriteIntent
}

struct WorkspaceDocumentSessionSnapshot: Equatable, Sendable {
    let sessionID: WorkspaceDocumentSessionID
    let documentID: UUID
    let workspaceID: UUID
    let location: WorkspaceDocumentLocation?
    let expectedExternalVersion: WorkspacePackageExternalVersion?
    let mutationGeneration: WorkspaceDocumentMutationGeneration
    let savedMutationGeneration: WorkspaceDocumentMutationGeneration
    let hasUnsavedChanges: Bool
    let nextSaveGeneration: WorkspaceDocumentSaveGeneration
    let activeSave: WorkspaceDocumentActiveSave?
    let conflict: WorkspaceDocumentConflict?
    let lastFailure: String?
}

enum WorkspaceDocumentLifecyclePresentationState: Equatable, Sendable {
    case untitled
    case clean
    case dirty
    case saving
    case conflicted(WorkspaceDocumentConflictReason)
    case failed(String, hasUnsavedChanges: Bool)
}

extension WorkspaceDocumentSessionSnapshot {
    var lifecyclePresentationState: WorkspaceDocumentLifecyclePresentationState {
        if location == nil {
            return .untitled
        }
        if let conflict {
            return .conflicted(conflict.reason)
        }
        if activeSave != nil {
            return .saving
        }
        if let lastFailure {
            return .failed(lastFailure, hasUnsavedChanges: hasUnsavedChanges)
        }
        return hasUnsavedChanges ? .dirty : .clean
    }
}

enum WorkspaceDocumentWriteOutcome: Equatable, Sendable {
    case saved(clean: Bool, adopted: WorkspaceDocumentLocation?)
    case copied(WorkspaceDocumentLocation)
    case conflicted(WorkspaceDocumentConflict)
    /// An alternate destination failed; the active document retains its own conflict state.
    case destinationConflicted(intent: WorkspaceDocumentWriteIntent, conflict: WorkspaceDocumentConflict)
    case superseded
    case failed(String)
}

enum WorkspaceDocumentSessionError: Error, Equatable, Sendable {
    case closed
    case noActiveLocation
    case writeAlreadyActive
    case unresolvedConflict
    case invalidResolution(String)
    case operationFailed(String)
}

enum WorkspaceDocumentChangeHint: Equatable, Sendable {
    case changed
    case moved
    case deleted
}

/// Records authoritative-probe demand at file-presenter callback time.
///
/// Stream delivery is only a wake-up mechanism. Multiple callbacks admitted while one
/// generation is running all request the same single follow-up generation.
final class WorkspaceDocumentProbeDemand: Sendable {
    private struct State {
        var completedGeneration: UInt64 = 0
        var runningGeneration: UInt64?
        var highestRequestedGeneration: UInt64 = 0
    }

    private let state = Mutex(State())

    func admit() {
        state.withLock { state in
            let activeGeneration = state.runningGeneration ?? state.completedGeneration
            guard activeGeneration < UInt64.max else { return }
            state.highestRequestedGeneration = max(
                state.highestRequestedGeneration,
                activeGeneration + 1
            )
        }
    }

    func beginNext() -> UInt64? {
        state.withLock { state in
            guard state.runningGeneration == nil,
                  state.highestRequestedGeneration > state.completedGeneration else {
                return nil
            }
            let generation = state.completedGeneration + 1
            state.runningGeneration = generation
            return generation
        }
    }

    func complete(_ generation: UInt64) {
        state.withLock { state in
            guard state.runningGeneration == generation else { return }
            state.completedGeneration = generation
            state.runningGeneration = nil
        }
    }
}

struct WorkspaceDocumentChangeFeed: Sendable {
    let stream: AsyncStream<WorkspaceDocumentChangeHint>
    let probeDemand: WorkspaceDocumentProbeDemand
}

struct WorkspaceDocumentPackagePayload: Sendable {
    let documentID: UUID
    let workspaceID: UUID
    let manifestData: Data
    let instructionSidecarData: Data?
    let attachmentsByBinaryID: [UUID: Data]
    let reconstructionState: ReconstructionWorkspaceState
    let reconstructionAttachmentSources: [ReconstructionAttachmentSource]
    let capturedMutationGeneration: WorkspaceDocumentMutationGeneration

    init(
        documentID: UUID,
        workspaceID: UUID,
        manifestData: Data,
        attachmentsByBinaryID: [UUID: Data],
        reconstructionState: ReconstructionWorkspaceState = .empty,
        reconstructionAttachmentSources: [ReconstructionAttachmentSource] = [],
        instructionSidecarData: Data? = nil,
        capturedMutationGeneration: WorkspaceDocumentMutationGeneration
    ) {
        self.documentID = documentID
        self.workspaceID = workspaceID
        self.manifestData = manifestData
        self.instructionSidecarData = instructionSidecarData
        self.attachmentsByBinaryID = attachmentsByBinaryID
        self.reconstructionState = reconstructionState
        self.reconstructionAttachmentSources = reconstructionAttachmentSources
        self.capturedMutationGeneration = capturedMutationGeneration
    }
}

struct WorkspaceDocumentValidatedPackage: Sendable {
    let manifestData: Data
    let instructionSidecarData: Data?
    let attachmentsByBinaryID: [UUID: Data]
    let reconstructionState: ReconstructionWorkspaceState
    let reconstructionAttachmentSources: [ReconstructionAttachmentSource]
    let observation: WorkspacePackageExternalVersion

    init(
        manifestData: Data,
        attachmentsByBinaryID: [UUID: Data],
        reconstructionState: ReconstructionWorkspaceState = .empty,
        reconstructionAttachmentSources: [ReconstructionAttachmentSource] = [],
        instructionSidecarData: Data? = nil,
        observation: WorkspacePackageExternalVersion
    ) {
        self.manifestData = manifestData
        self.instructionSidecarData = instructionSidecarData
        self.attachmentsByBinaryID = attachmentsByBinaryID
        self.reconstructionState = reconstructionState
        self.reconstructionAttachmentSources = reconstructionAttachmentSources
        self.observation = observation
    }
}

struct WorkspaceDocumentStagedPackage: Sendable {
    let stagingID: UUID
    let stagingURL: URL
    let stagedObservation: WorkspacePackageExternalVersion
    let capturedMutationGeneration: WorkspaceDocumentMutationGeneration
}

struct WorkspaceDocumentPublishReceipt: Sendable {
    let stagingID: UUID
    let destination: WorkspaceDocumentLocation
    let priorObservation: WorkspacePackageExternalVersion
    let publishedObservation: WorkspacePackageExternalVersion
}

enum WorkspaceDocumentLocationReservationResult: Equatable, Sendable {
    case reserved
    case alreadyOwned(WorkspaceWindowID)
}

struct WorkspaceDocumentPublicationReservation: Hashable, Sendable {
    private let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum WorkspaceDocumentPublicationReservationResult: Equatable, Sendable {
    case reserved(WorkspaceDocumentPublicationReservation)
    case alreadyOwned(WorkspaceWindowID)
}

enum WorkspaceDocumentPublicationCompletionResult: Equatable, Sendable {
    case completed
    case alreadyOwned(WorkspaceWindowID)
    case invalid
}

enum WorkspaceOpenSource: String, Sendable {
    case fileMenu
    case recentMenu
    case finder
    case dragAndDrop
    case automation
    /// Reopening what a window showed when the app last quit (macOS window restoration).
    case stateRestoration
}

struct WorkspaceOpenRequest: Sendable {
    let url: URL
    let source: WorkspaceOpenSource
    let preferredReusableWindow: WorkspaceWindowID?
}

enum WorkspaceOpenDisposition: Equatable, Sendable {
    case activatedExisting(WorkspaceWindowID)
    case reusedWindow(WorkspaceWindowID)
    case openedWindow(WorkspaceWindowID)
    case rejected(String)
}
