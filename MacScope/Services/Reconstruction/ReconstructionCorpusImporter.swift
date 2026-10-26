import CryptoKit
import Darwin
import Foundation

struct ReconstructionImportSelection: Sendable {
    let rootURL: URL
    let roles: [ReconstructionArtifactRole]

    init(rootURL: URL, roles: [ReconstructionArtifactRole]) {
        self.rootURL = rootURL
        self.roles = roles
    }
}

enum ReconstructionOccurrenceFailureReason: String, Hashable, Codable, Sendable {
    case acquisitionFailed
    case boundsExceeded
    case cancelled
    case changedDuringImport
    case emptyContent
    case invalidSelection
    case unsupportedFileType
}

struct ReconstructionOccurrenceFailure: Sendable {
    let sourceURL: URL
    let relativePath: String?
    let reason: ReconstructionOccurrenceFailureReason
    let diagnostic: ReconstructionDiagnostic
}

final class ReconstructionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func check() throws {
        try Task.checkCancellation()
        if isCancelled { throw CancellationError() }
    }
}

struct ReconstructionImportResult: Sendable {
    let occurrences: [ReconstructionArtifactOccurrenceRecord]
    let contents: [ReconstructionContentIdentity]
    let relations: [ReconstructionArtifactRelationRecord]
    let attachmentSources: [ReconstructionAttachmentSource]
    let failures: [ReconstructionOccurrenceFailure]
    let canonicalManifestSHA256: String
}

struct ReconstructionImportProgress: Equatable, Sendable {
    let completedSelectionCount: Int
    let totalSelectionCount: Int
    let occurrenceCount: Int
    let failureCount: Int
}

struct ReconstructionCorpusImporterAttemptedWorkLimits: Sendable, Equatable {
    /// A loadable regular file can require five complete byte passes: catalog copy/hash,
    /// classification identity, loader materialization, importer identity, and relation identity.
    static let importerDefault = Self(
        maximumByteCount: ReconstructionPackageLayout.maximumCorpusAttachmentBytes * 5,
        maximumEntryCount: 100_000,
        maximumNameUTF8Bytes: 16 * 1_024 * 1_024,
        maximumExpandedPathUTF8Bytes: 64 * 1_024 * 1_024,
        maximumExpandedComponentWork: 1_000_000
    )

    let maximumByteCount: UInt64
    let maximumEntryCount: Int
    let maximumNameUTF8Bytes: Int
    let maximumExpandedPathUTF8Bytes: Int
    let maximumExpandedComponentWork: Int

    init(
        maximumByteCount: UInt64,
        maximumEntryCount: Int,
        maximumNameUTF8Bytes: Int,
        maximumExpandedPathUTF8Bytes: Int,
        maximumExpandedComponentWork: Int
    ) {
        self.maximumByteCount = maximumByteCount
        self.maximumEntryCount = maximumEntryCount
        self.maximumNameUTF8Bytes = maximumNameUTF8Bytes
        self.maximumExpandedPathUTF8Bytes = maximumExpandedPathUTF8Bytes
        self.maximumExpandedComponentWork = maximumExpandedComponentWork
    }
}

struct ReconstructionCorpusImporterHooks: Sendable {
    let didSnapshotRoot: (@Sendable (URL) async throws -> Void)?
    let didSnapshotDirectoryEntry: (@Sendable (URL, String) async throws -> Void)?
    let didSnapshotRegularFile: (@Sendable (URL, Int) async throws -> Void)?
    let didCatalogAttachment: (@Sendable (ReconstructionAttachmentSource) async -> Void)?
    let didAcquireOccurrence: (@Sendable (ReconstructionArtifactOccurrenceRecord) async -> Void)?
    let didCatalogContainerChildren: (@Sendable (URL) async throws -> Void)?
    let didBuildContainerManifest: (@Sendable (ReconstructionAttachmentSource) async throws -> Void)?
    let didPrepareContainerClassification: (@Sendable (
        URL,
        _ factCount: Int,
        _ maximumFactDepth: Int
    ) async throws -> Void)?
    let verificationObserver: ReconstructionCapturedTreeVerifier.VerificationObserver?
    let didPrepareSuccessfulResult: (@Sendable () async -> Void)?

    init(
        didSnapshotRoot: (@Sendable (URL) async throws -> Void)? = nil,
        didSnapshotDirectoryEntry: (@Sendable (URL, String) async throws -> Void)? = nil,
        didSnapshotRegularFile: (@Sendable (URL, Int) async throws -> Void)? = nil,
        didCatalogAttachment: (@Sendable (ReconstructionAttachmentSource) async -> Void)? = nil,
        didAcquireOccurrence: (@Sendable (ReconstructionArtifactOccurrenceRecord) async -> Void)? = nil,
        didCatalogContainerChildren: (@Sendable (URL) async throws -> Void)? = nil,
        didBuildContainerManifest: (@Sendable (ReconstructionAttachmentSource) async throws -> Void)? = nil,
        didPrepareContainerClassification: (@Sendable (
            URL,
            _ factCount: Int,
            _ maximumFactDepth: Int
        ) async throws -> Void)? = nil,
        verificationObserver: ReconstructionCapturedTreeVerifier.VerificationObserver? = nil,
        didPrepareSuccessfulResult: (@Sendable () async -> Void)? = nil
    ) {
        self.didSnapshotRoot = didSnapshotRoot
        self.didSnapshotDirectoryEntry = didSnapshotDirectoryEntry
        self.didSnapshotRegularFile = didSnapshotRegularFile
        self.didCatalogAttachment = didCatalogAttachment
        self.didAcquireOccurrence = didAcquireOccurrence
        self.didCatalogContainerChildren = didCatalogContainerChildren
        self.didBuildContainerManifest = didBuildContainerManifest
        self.didPrepareContainerClassification = didPrepareContainerClassification
        self.verificationObserver = verificationObserver
        self.didPrepareSuccessfulResult = didPrepareSuccessfulResult
    }
}

actor ReconstructionCorpusImporter {
    private enum Limits {
        static let maximumDepth = 64
        static let maximumEntryCount = 100_000
        static let maximumNameUTF8Bytes = 1_024
        static let maximumTotalNameUTF8Bytes = 16 * 1_024 * 1_024
        static let maximumFileBytes = ReconstructionPackageLayout.maximumCorpusAttachmentBytes
        static let maximumTotalBytes = ReconstructionPackageLayout.maximumCorpusAttachmentBytes
        static let maximumLinkBytes = 16 * 1_024
    }

    private enum ImporterError: Error {
        case boundsExceeded(String)
        case changedDuringImport
        case invalidSelection(String)
        case unsupportedFileType
        case acquisitionFailed(String)
        case emptyContent
    }

    private struct AcquiredArtifact {
        let record: ReconstructionArtifactOccurrenceRecord
        let source: ReconstructionAttachmentSource
        var selectedRootOccurrenceID: ReconstructionArtifactOccurrenceID
        var parentContainerOccurrenceID: ReconstructionArtifactOccurrenceID?
        let relationRelativePath: String
        let verifiedLocators: [String]
        let symbolicLinkTarget: String?
        let isContainer: Bool
        let loadedBinary: LoadedBinary?
    }

    private struct CapturedFilesystemFact {
        let verificationNodeIndex: Int
        let snapshot: FileSnapshot
        let symbolicLinkText: Data?
    }

    private struct CapturedArtifact {
        let artifact: AcquiredArtifact
        let fact: CapturedFilesystemFact
    }

    private struct DirectoryCapture {
        var artifacts: [AcquiredArtifact]
        let facts: [CapturedFilesystemFact]
        let structuralFacts: [ReconstructionVerifiedContainerFact]
    }

    private struct DirectoryName {
        let raw: String
        let normalized: String
    }

    private struct FileObjectID: Hashable {
        let device: UInt64
        let inode: UInt64

        init(_ metadata: stat) {
            device = UInt64(truncatingIfNeeded: metadata.st_dev)
            inode = UInt64(truncatingIfNeeded: metadata.st_ino)
        }
    }

    private struct FileSnapshot: Equatable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let linkCount: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ metadata: stat) {
            device = UInt64(truncatingIfNeeded: metadata.st_dev)
            inode = UInt64(truncatingIfNeeded: metadata.st_ino)
            mode = UInt32(metadata.st_mode)
            linkCount = UInt64(truncatingIfNeeded: metadata.st_nlink)
            size = metadata.st_size
            modifiedSeconds = Int64(metadata.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
            changedSeconds = Int64(metadata.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
        }
    }

    private final class ImportBudget {
        struct SelectionCheckpoint {
            let remainingEntries: Int
            let remainingNameBytes: Int
            let remainingBytes: UInt64
            let remainingExpandedPathUTF8Bytes: Int
            let remainingExpandedComponentWork: Int
        }

        struct RegularFileByteReservation {
            let capacity: UInt64
        }

        private var remainingEntries: Int
        private var remainingNameBytes: Int
        private var remainingBytes: UInt64
        private var remainingExpandedPathUTF8Bytes: Int
        private var remainingExpandedComponentWork: Int
        private var remainingAttemptedBytes: UInt64
        private var remainingAttemptedEntries: Int
        private var remainingAttemptedNameBytes: Int
        private var remainingAttemptedExpandedPathUTF8Bytes: Int
        private var remainingAttemptedExpandedComponentWork: Int
        var visitedDirectories: Set<FileObjectID> = []

        init(
            maximumEntryCount: Int,
            maximumTotalNameUTF8Bytes: Int,
            maximumTotalByteCount: UInt64,
            capturedTreeLimits: ReconstructionCapturedTreeVerifier.Limits,
            attemptedWorkLimits: ReconstructionCorpusImporterAttemptedWorkLimits
        ) {
            remainingEntries = max(0, min(maximumEntryCount, Limits.maximumEntryCount))
            remainingNameBytes = max(
                0,
                min(maximumTotalNameUTF8Bytes, Limits.maximumTotalNameUTF8Bytes)
            )
            remainingBytes = min(maximumTotalByteCount, Limits.maximumTotalBytes)
            remainingExpandedPathUTF8Bytes = capturedTreeLimits.maximumExpandedPathUTF8Bytes
            remainingExpandedComponentWork = capturedTreeLimits.maximumExpandedComponentWork
            let defaults = ReconstructionCorpusImporterAttemptedWorkLimits.importerDefault
            remainingAttemptedBytes = min(
                attemptedWorkLimits.maximumByteCount,
                defaults.maximumByteCount
            )
            remainingAttemptedEntries = max(
                0,
                min(attemptedWorkLimits.maximumEntryCount, defaults.maximumEntryCount)
            )
            remainingAttemptedNameBytes = max(
                0,
                min(attemptedWorkLimits.maximumNameUTF8Bytes, defaults.maximumNameUTF8Bytes)
            )
            remainingAttemptedExpandedPathUTF8Bytes = max(
                0,
                min(
                    attemptedWorkLimits.maximumExpandedPathUTF8Bytes,
                    defaults.maximumExpandedPathUTF8Bytes
                )
            )
            remainingAttemptedExpandedComponentWork = max(
                0,
                min(
                    attemptedWorkLimits.maximumExpandedComponentWork,
                    defaults.maximumExpandedComponentWork
                )
            )
        }

        func admitName(_ name: String) throws {
            let count = name.utf8.count
            guard count > 0,
                  count <= Limits.maximumNameUTF8Bytes,
                  remainingEntries > 0,
                  remainingAttemptedEntries > 0,
                  count <= remainingNameBytes,
                  count <= remainingAttemptedNameBytes else {
                throw ImporterError.boundsExceeded("entry or name budget exceeded")
            }
            remainingEntries -= 1
            remainingNameBytes -= count
            remainingAttemptedEntries -= 1
            remainingAttemptedNameBytes -= count
        }

        func admitBytes(_ count: UInt64) throws {
            guard count <= remainingBytes,
                  count <= remainingAttemptedBytes else {
                throw ImporterError.boundsExceeded("byte budget exceeded")
            }
            remainingBytes -= count
            remainingAttemptedBytes -= count
        }

        func admitAttemptedBytePass(_ count: UInt64) throws {
            guard count <= remainingAttemptedBytes else {
                throw ImporterError.boundsExceeded("attempted byte-work budget exceeded")
            }
            remainingAttemptedBytes -= count
        }

        func admitIdentityPath(pathUTF8Bytes: Int, componentWork: Int) throws {
            guard pathUTF8Bytes > 0,
                  componentWork > 0,
                  pathUTF8Bytes <= remainingExpandedPathUTF8Bytes,
                  componentWork <= remainingExpandedComponentWork else {
                throw ImporterError.boundsExceeded("expanded identity-path budget exceeded")
            }
            try admitAttemptedCapturedWork(
                pathUTF8Bytes: pathUTF8Bytes,
                componentWork: componentWork
            )
            remainingExpandedPathUTF8Bytes -= pathUTF8Bytes
            remainingExpandedComponentWork -= componentWork
        }

        func admitAttemptedCapturedWork(pathUTF8Bytes: Int, componentWork: Int) throws {
            guard pathUTF8Bytes > 0,
                  componentWork > 0,
                  pathUTF8Bytes <= remainingAttemptedExpandedPathUTF8Bytes,
                  componentWork <= remainingAttemptedExpandedComponentWork else {
                throw ImporterError.boundsExceeded("attempted identity-path work budget exceeded")
            }
            remainingAttemptedExpandedPathUTF8Bytes -= pathUTF8Bytes
            remainingAttemptedExpandedComponentWork -= componentWork
        }

        func selectionCheckpoint() -> SelectionCheckpoint {
            SelectionCheckpoint(
                remainingEntries: remainingEntries,
                remainingNameBytes: remainingNameBytes,
                remainingBytes: remainingBytes,
                remainingExpandedPathUTF8Bytes: remainingExpandedPathUTF8Bytes,
                remainingExpandedComponentWork: remainingExpandedComponentWork
            )
        }

        func rollback(to checkpoint: SelectionCheckpoint) {
            remainingEntries = checkpoint.remainingEntries
            remainingNameBytes = checkpoint.remainingNameBytes
            remainingBytes = checkpoint.remainingBytes
            remainingExpandedPathUTF8Bytes = checkpoint.remainingExpandedPathUTF8Bytes
            remainingExpandedComponentWork = checkpoint.remainingExpandedComponentWork
        }

        func remainingCapturedTreeLimits() throws
            -> ReconstructionCapturedTreeVerifier.Limits {
            guard remainingExpandedPathUTF8Bytes > 0 else {
                throw ReconstructionCapturedTreeVerifier.VerificationError
                    .expandedPathUTF8ByteLimitExceeded
            }
            guard remainingExpandedComponentWork > 0 else {
                throw ReconstructionCapturedTreeVerifier.VerificationError
                    .expandedComponentWorkLimitExceeded
            }
            return ReconstructionCapturedTreeVerifier.Limits(
                maximumExpandedPathUTF8Bytes: remainingExpandedPathUTF8Bytes,
                maximumExpandedComponentWork: remainingExpandedComponentWork
            )
        }

        func admitCapturedTree(
            _ plan: ReconstructionCapturedTreeVerifier.Plan
        ) throws {
            guard plan.expandedPathUTF8ByteCount <= remainingExpandedPathUTF8Bytes else {
                throw ReconstructionCapturedTreeVerifier.VerificationError
                    .expandedPathUTF8ByteLimitExceeded
            }
            guard plan.expandedComponentWork <= remainingExpandedComponentWork else {
                throw ReconstructionCapturedTreeVerifier.VerificationError
                    .expandedComponentWorkLimitExceeded
            }
            remainingExpandedPathUTF8Bytes -= plan.expandedPathUTF8ByteCount
            remainingExpandedComponentWork -= plan.expandedComponentWork
        }

        func reserveRegularFileCapacity(
            expectedByteCount: UInt64,
            maximumByteCount: UInt64
        ) throws -> RegularFileByteReservation {
            guard expectedByteCount > 0 else {
                throw ImporterError.emptyContent
            }
            guard expectedByteCount <= maximumByteCount,
                  expectedByteCount <= remainingBytes,
                  expectedByteCount <= remainingAttemptedBytes else {
                throw ImporterError.boundsExceeded("file exceeds byte-work budget")
            }
            remainingBytes -= expectedByteCount
            remainingAttemptedBytes -= expectedByteCount
            return RegularFileByteReservation(capacity: expectedByteCount)
        }

        func commit(
            _ reservation: RegularFileByteReservation,
            consuming byteCount: UInt64
        ) throws {
            guard byteCount == reservation.capacity else {
                throw ImporterError.boundsExceeded("byte budget exceeded")
            }
        }

        func rollback(_ reservation: RegularFileByteReservation) {
            remainingBytes += reservation.capacity
        }
    }

    private static let loadableKinds: Set<ReconstructionArtifactKind> = [
        .machOImage,
        .dynamicLibrary,
        .objectFile,
    ]

    private let classifier: ReconstructionArtifactClassifier
    private let binaryLoader: any BinaryLoader
    private let hooks: ReconstructionCorpusImporterHooks
    private let maximumEntryCount: Int
    private let maximumTotalNameUTF8Bytes: Int
    private let maximumTotalByteCount: UInt64
    private let capturedTreeLimits: ReconstructionCapturedTreeVerifier.Limits
    private let attemptedWorkLimits: ReconstructionCorpusImporterAttemptedWorkLimits

    init(
        binaryLoader: any BinaryLoader = BinaryLoaderRouter(),
        hooks: ReconstructionCorpusImporterHooks = ReconstructionCorpusImporterHooks(),
        maximumEntryCount: Int = Limits.maximumEntryCount,
        maximumTotalNameUTF8Bytes: Int = Limits.maximumTotalNameUTF8Bytes,
        maximumTotalByteCount: UInt64 = Limits.maximumTotalBytes,
        capturedTreeLimits: ReconstructionCapturedTreeVerifier.Limits = .importerDefault,
        attemptedWorkLimits: ReconstructionCorpusImporterAttemptedWorkLimits = .importerDefault
    ) {
        self.binaryLoader = binaryLoader
        self.hooks = hooks
        self.maximumEntryCount = max(0, min(maximumEntryCount, Limits.maximumEntryCount))
        self.maximumTotalNameUTF8Bytes = max(
            0,
            min(maximumTotalNameUTF8Bytes, Limits.maximumTotalNameUTF8Bytes)
        )
        self.maximumTotalByteCount = min(maximumTotalByteCount, Limits.maximumTotalBytes)
        self.capturedTreeLimits = capturedTreeLimits
        self.attemptedWorkLimits = attemptedWorkLimits
        classifier = ReconstructionArtifactClassifier()
    }

    func ingest(
        selections: [ReconstructionImportSelection],
        projectID: UUID,
        cancellation: ReconstructionCancellation,
        progress: (@Sendable (ReconstructionImportProgress) async -> Void)? = nil
    ) async -> ReconstructionImportResult {
        let catalog: ReconstructionAttachmentCatalog
        do {
            catalog = try ReconstructionAttachmentCatalog()
        } catch {
            let failure = ReconstructionOccurrenceFailure(
                sourceURL: selections.first?.rootURL ?? FileManager.default.temporaryDirectory,
                relativePath: nil,
                reason: .acquisitionFailed,
                diagnostic: .sanitizing("Could not create a private reconstruction attachment catalog.")
            )
            return makeResult(projectID: projectID, artifacts: [], failures: [failure])
        }

        var acquired: [AcquiredArtifact] = []
        var failures: [ReconstructionOccurrenceFailure] = []
        let budget = ImportBudget(
            maximumEntryCount: maximumEntryCount,
            maximumTotalNameUTF8Bytes: maximumTotalNameUTF8Bytes,
            maximumTotalByteCount: maximumTotalByteCount,
            capturedTreeLimits: capturedTreeLimits,
            attemptedWorkLimits: attemptedWorkLimits
        )
        for (selectionIndex, selection) in selections.enumerated() {
            await progress?(ReconstructionImportProgress(
                completedSelectionCount: selectionIndex,
                totalSelectionCount: selections.count,
                occurrenceCount: acquired.count,
                failureCount: failures.count
            ))
            if cancellation.isCancelled || Task.isCancelled {
                await catalog.discardAll()
                return cancelledResult(
                    projectID: projectID,
                    sourceURL: selection.rootURL
                )
            }

            let roles = normalizedRoles(selection.roles)
            guard !roles.isEmpty else {
                failures.append(failure(
                    sourceURL: selection.rootURL,
                    relativePath: nil,
                    error: ImporterError.invalidSelection("selection has no roles")
                ))
                continue
            }
            guard selection.rootURL.isFileURL else {
                failures.append(failure(
                    sourceURL: selection.rootURL,
                    relativePath: nil,
                    error: ImporterError.invalidSelection("selection is not a file URL")
                ))
                continue
            }

            let normalizedRootName = normalizedComponent(selection.rootURL.lastPathComponent)
            guard let normalizedRootName else {
                failures.append(failure(
                    sourceURL: selection.rootURL,
                    relativePath: nil,
                    error: ImporterError.invalidSelection("selection name is invalid")
                ))
                continue
            }

            budget.visitedDirectories.removeAll(keepingCapacity: true)
            let checkpoint = await catalog.checkpoint()
            let selectionCheckpoint = budget.selectionCheckpoint()
            do {
                let selectionArtifacts = try await acquireSelection(
                    selection,
                    selectionIndex: selectionIndex,
                    normalizedRootName: normalizedRootName,
                    roles: roles,
                    projectID: projectID,
                    catalog: catalog,
                    budget: budget,
                    cancellation: cancellation
                )
                acquired.append(contentsOf: selectionArtifacts)
            } catch is CancellationError {
                await catalog.discardAll()
                return cancelledResult(projectID: projectID, sourceURL: selection.rootURL)
            } catch {
                await catalog.rollback(to: checkpoint)
                budget.rollback(to: selectionCheckpoint)
                failures.append(failure(
                    sourceURL: selection.rootURL,
                    relativePath: normalizedRootName,
                    error: error
                ))
            }
        }

        if cancellation.isCancelled || Task.isCancelled {
            await catalog.discardAll()
            return cancelledResult(
                projectID: projectID,
                sourceURL: selections.last?.rootURL ?? FileManager.default.temporaryDirectory
            )
        }
        do {
            let relations = try await discoverRelations(
                in: acquired,
                budget: budget,
                cancellation: cancellation
            )
            try cancellation.check()
            let result = makeResult(
                projectID: projectID,
                artifacts: acquired,
                relations: relations,
                failures: failures
            )
            await hooks.didPrepareSuccessfulResult?()
            try cancellation.check()
            await progress?(ReconstructionImportProgress(
                completedSelectionCount: selections.count,
                totalSelectionCount: selections.count,
                occurrenceCount: result.occurrences.count,
                failureCount: result.failures.count
            ))
            try cancellation.check()
            return result
        } catch is CancellationError {
            await catalog.discardAll()
            return cancelledResult(
                projectID: projectID,
                sourceURL: selections.last?.rootURL
                    ?? FileManager.default.temporaryDirectory
            )
        } catch {
            await catalog.discardAll()
            return makeResult(
                projectID: projectID,
                artifacts: [],
                relations: [],
                failures: failures + [failure(
                    sourceURL: selections.last?.rootURL
                        ?? FileManager.default.temporaryDirectory,
                    relativePath: nil,
                    error: error
                )]
            )
        }
    }

    private func acquireSelection(
        _ selection: ReconstructionImportSelection,
        selectionIndex: Int,
        normalizedRootName: String,
        roles: [ReconstructionArtifactRole],
        projectID: UUID,
        catalog: ReconstructionAttachmentCatalog,
        budget: ImportBudget,
        cancellation: ReconstructionCancellation
    ) async throws -> [AcquiredArtifact] {
        try cancellation.check()
        var metadata = stat()
        let status = selection.rootURL.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &metadata) } ?? -1
        }
        guard status == 0 else {
            throw ImporterError.acquisitionFailed("selected root could not be inspected")
        }
        let rootSnapshot = FileSnapshot(metadata)
        try await hooks.didSnapshotRoot?(selection.rootURL)
        try cancellation.check()

        switch metadata.st_mode & S_IFMT {
        case S_IFREG:
            try budget.admitName(normalizedRootName)
            try budget.admitIdentityPath(
                pathUTF8Bytes: normalizedRootName.utf8.count,
                componentWork: 1
            )
            let capture = try await acquireRegularFile(
                identityPath: normalizedRootName,
                relationRelativePath: ".",
                originalName: normalizedRootName,
                sourceURL: selection.rootURL,
                verificationNodeIndex: 0,
                expectedSnapshot: rootSnapshot,
                selectionIndex: selectionIndex,
                roles: roles,
                projectID: projectID,
                catalog: catalog,
                budget: budget,
                cancellation: cancellation,
                openDescriptor: {
                    selection.rootURL.withUnsafeFileSystemRepresentation { path in
                        path.map {
                            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                        } ?? -1
                    }
                }
            )
            try verifyRootPath(selection.rootURL, expected: capture.fact.snapshot)
            return [capture.artifact]
        case S_IFDIR:
            try budget.admitName(normalizedRootName)
            let descriptor = selection.rootURL.withUnsafeFileSystemRepresentation { path in
                path.map {
                    Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                } ?? -1
            }
            guard descriptor >= 0 else {
                throw ImporterError.acquisitionFailed("selected directory could not be opened")
            }
            defer { _ = Darwin.close(descriptor) }
            var openedMetadata = stat()
            guard Darwin.fstat(descriptor, &openedMetadata) == 0,
                  (openedMetadata.st_mode & S_IFMT) == S_IFDIR,
                  FileSnapshot(openedMetadata) == rootSnapshot else {
                throw ImporterError.changedDuringImport
            }
            guard budget.visitedDirectories.insert(FileObjectID(openedMetadata)).inserted else {
                throw ImporterError.invalidSelection("selected directory repeats an object")
            }
            let verificationCapture = try ReconstructionCapturedTreeVerifier.Capture(
                limits: try budget.remainingCapturedTreeLimits(),
                normalizedRootIdentityComponent: normalizedRootName,
                attemptedWorkObserver: { pathBytes, componentWork in
                    try budget.admitAttemptedCapturedWork(
                        pathUTF8Bytes: pathBytes,
                        componentWork: componentWork
                    )
                }
            )
            var capture = try await captureDirectory(
                descriptor: descriptor,
                directoryURL: selection.rootURL,
                normalizedComponents: [normalizedRootName],
                relationComponents: [],
                verificationCapture: verificationCapture,
                verificationNodeIndex: 0,
                currentSnapshot: FileSnapshot(openedMetadata),
                depth: 0,
                selectionIndex: selectionIndex,
                roles: roles,
                projectID: projectID,
                catalog: catalog,
                budget: budget,
                cancellation: cancellation
            )
            try cancellation.check()
            let verificationPlan = try verificationCapture.makeVerificationPlan(
                cancellation: cancellation
            )
            try verifySelectedRoot(
                selection.rootURL,
                expected: rootSnapshot,
                descriptor: descriptor,
                facts: capture.facts,
                verificationPlan: verificationPlan,
                cancellation: cancellation
            )
            try budget.admitCapturedTree(verificationPlan)
            guard let root = capture.artifacts.first else {
                throw ImporterError.acquisitionFailed("container capture was empty")
            }
            for index in capture.artifacts.indices {
                capture.artifacts[index].selectedRootOccurrenceID = root.record.occurrenceID
            }
            return capture.artifacts
        case S_IFLNK:
            try budget.admitName(normalizedRootName)
            try budget.admitIdentityPath(
                pathUTF8Bytes: normalizedRootName.utf8.count,
                componentWork: 1
            )
            let data = try readRootLink(selection.rootURL, expected: metadata)
            try budget.admitBytes(UInt64(data.count))
            let content = try await catalog.catalogBytes(
                data,
                maximumByteCount: UInt64(Limits.maximumLinkBytes),
                cancellation: cancellation
            )
            await hooks.didCatalogAttachment?(content.source)
            let artifact = try await makeArtifact(
                content: content,
                kind: .symbolicLink,
                diagnostic: nil,
                identityPath: normalizedRootName,
                relationRelativePath: ".",
                originalName: normalizedRootName,
                selectionIndex: selectionIndex,
                roles: roles,
                projectID: projectID,
                selectedRootOccurrenceID: nil,
                parentContainerOccurrenceID: nil,
                symbolicLinkTarget: String(data: data, encoding: .utf8),
                isContainer: false,
                cancellation: cancellation
            )
            try verifyRootPath(selection.rootURL, expected: rootSnapshot)
            return [artifact]
        default:
            throw ImporterError.unsupportedFileType
        }
    }

    private func captureDirectory(
        descriptor: Int32,
        directoryURL: URL,
        normalizedComponents: [String],
        relationComponents: [String],
        verificationCapture: ReconstructionCapturedTreeVerifier.Capture,
        verificationNodeIndex: Int,
        currentSnapshot: FileSnapshot,
        depth: Int,
        selectionIndex: Int,
        roles: [ReconstructionArtifactRole],
        projectID: UUID,
        catalog: ReconstructionAttachmentCatalog,
        budget: ImportBudget,
        cancellation: ReconstructionCancellation
    ) async throws -> DirectoryCapture {
        try cancellation.check()
        guard depth <= Limits.maximumDepth else {
            throw ImporterError.boundsExceeded("directory depth exceeded")
        }
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else {
            throw ImporterError.acquisitionFailed("directory descriptor could not be duplicated")
        }
        guard let directory = Darwin.fdopendir(duplicate) else {
            _ = Darwin.close(duplicate)
            throw ImporterError.acquisitionFailed("directory descriptor could not be enumerated")
        }
        defer { _ = Darwin.closedir(directory) }

        var names: [DirectoryName] = []
        var normalizedNames = Set<String>()
        while true {
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                guard errno == 0 else {
                    throw ImporterError.acquisitionFailed("directory enumeration failed")
                }
                break
            }
            try cancellation.check()
            let length = Int(entry.pointee.d_namlen)
            guard length > 0, length <= Int(NAME_MAX) else {
                throw ImporterError.boundsExceeded("directory entry name is invalid")
            }
            let bytes: [UInt8] = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: UInt8.self, capacity: Int(NAME_MAX) + 1) { start in
                    Array(UnsafeBufferPointer(start: start, count: length))
                }
            }
            guard let rawName = String(bytes: bytes, encoding: .utf8) else {
                throw ImporterError.invalidSelection("directory entry name is not UTF-8")
            }
            if rawName == "." || rawName == ".." { continue }
            guard let normalizedName = normalizedComponent(rawName) else {
                throw ImporterError.invalidSelection("directory entry name is invalid")
            }
            try budget.admitName(normalizedName)
            guard normalizedNames.insert(normalizedName).inserted else {
                throw ImporterError.invalidSelection("directory entry names collide after normalization")
            }
            names.append(DirectoryName(raw: rawName, normalized: normalizedName))
        }
        names.sort { utf8Less($0.normalized, $1.normalized) }

        var childCaptures: [[AcquiredArtifact]] = []
        var facts = [CapturedFilesystemFact(
            verificationNodeIndex: verificationNodeIndex,
            snapshot: currentSnapshot,
            symbolicLinkText: nil
        )]
        var structuralFacts: [ReconstructionVerifiedContainerFact] = []
        var manifestEntries: [ReconstructionContainerManifestBuilder.CapturedEntry] = []
        for name in names {
            try cancellation.check()
            var metadata = stat()
            let status = name.raw.withCString {
                Darwin.fstatat(descriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else { throw ImporterError.changedDuringImport }
            let childVerificationNodeIndex = try verificationCapture.append(
                parentIndex: verificationNodeIndex,
                rawComponent: name.raw,
                normalizedComponent: name.normalized,
                kind: try capturedNodeKind(for: metadata.st_mode),
                cancellation: cancellation
            )
            let normalizedChildComponents = normalizedComponents + [name.normalized]
            let childRelationComponents = relationComponents + [name.normalized]
            let identityPath = normalizedChildComponents.joined(separator: "/")
            let relationRelativePath = try verificationCapture.materializeNormalizedRelativePath(
                to: childVerificationNodeIndex,
                cancellation: cancellation
            )
            let childURL = directoryURL.appendingPathComponent(name.raw, isDirectory: false)
            try await hooks.didSnapshotDirectoryEntry?(childURL, relationRelativePath)
            try cancellation.check()

            switch metadata.st_mode & S_IFMT {
            case S_IFREG:
                let captured = try await acquireRegularFile(
                    identityPath: identityPath,
                    relationRelativePath: relationRelativePath,
                    originalName: name.normalized,
                    sourceURL: childURL,
                    verificationNodeIndex: childVerificationNodeIndex,
                    expectedSnapshot: FileSnapshot(metadata),
                    selectionIndex: selectionIndex,
                    roles: roles,
                    projectID: projectID,
                    catalog: catalog,
                    budget: budget,
                    cancellation: cancellation,
                    openDescriptor: {
                        name.raw.withCString {
                            Darwin.openat(
                                descriptor,
                                $0,
                                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
                            )
                        }
                    }
                )
                childCaptures.append([captured.artifact])
                facts.append(captured.fact)
                structuralFacts.append(ReconstructionVerifiedContainerFact(
                    relativePath: name.normalized,
                    nodeKind: .regularFile,
                    artifactKind: captured.artifact.record.kind,
                    executableMode: captured.artifact.record.executableMode
                ))
                manifestEntries.append(capturedManifestEntry(
                    relativePath: name.normalized,
                    artifact: captured.artifact
                ))
            case S_IFDIR:
                let child = name.raw.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard child >= 0 else { throw ImporterError.changedDuringImport }
                do {
                    var openedMetadata = stat()
                    guard Darwin.fstat(child, &openedMetadata) == 0,
                          FileSnapshot(openedMetadata) == FileSnapshot(metadata),
                          (openedMetadata.st_mode & S_IFMT) == S_IFDIR else {
                        throw ImporterError.changedDuringImport
                    }
                    guard budget.visitedDirectories.insert(FileObjectID(openedMetadata)).inserted else {
                        throw ImporterError.invalidSelection("directory object repeats within selection")
                    }
                    let childCapture = try await captureDirectory(
                        descriptor: child,
                        directoryURL: childURL,
                        normalizedComponents: normalizedChildComponents,
                        relationComponents: childRelationComponents,
                        verificationCapture: verificationCapture,
                        verificationNodeIndex: childVerificationNodeIndex,
                        currentSnapshot: FileSnapshot(openedMetadata),
                        depth: depth + 1,
                        selectionIndex: selectionIndex,
                        roles: roles,
                        projectID: projectID,
                        catalog: catalog,
                        budget: budget,
                        cancellation: cancellation
                    )
                    guard let childRoot = childCapture.artifacts.first else {
                        throw ImporterError.acquisitionFailed("nested container capture was empty")
                    }
                    childCaptures.append(childCapture.artifacts)
                    facts.append(contentsOf: childCapture.facts)
                    structuralFacts.append(ReconstructionVerifiedContainerFact(
                        relativePath: name.normalized,
                        nodeKind: .directory,
                        artifactKind: childRoot.record.kind,
                        executableMode: childRoot.record.executableMode
                    ))
                    for fact in childCapture.structuralFacts {
                        try cancellation.check()
                        let factDepth = fact.relativePath.split(
                            separator: "/",
                            omittingEmptySubsequences: false
                        ).count
                        guard factDepth < ReconstructionArtifactClassifier
                            .maximumVerifiedContainerFactDepth else {
                            continue
                        }
                        structuralFacts.append(ReconstructionVerifiedContainerFact(
                            relativePath: "\(name.normalized)/\(fact.relativePath)",
                            nodeKind: fact.nodeKind,
                            artifactKind: fact.artifactKind,
                            executableMode: fact.executableMode
                        ))
                    }
                    manifestEntries.append(capturedManifestEntry(
                        relativePath: name.normalized,
                        artifact: childRoot
                    ))
                    _ = Darwin.close(child)
                } catch {
                    _ = Darwin.close(child)
                    throw error
                }
            case S_IFLNK:
                let data = try readLink(name.raw, relativeTo: descriptor, expected: metadata)
                try budget.admitBytes(UInt64(data.count))
                let content = try await catalog.catalogBytes(
                    data,
                    maximumByteCount: UInt64(Limits.maximumLinkBytes),
                    cancellation: cancellation
                )
                await hooks.didCatalogAttachment?(content.source)
                let artifact = try await makeArtifact(
                    content: content,
                    kind: .symbolicLink,
                    diagnostic: nil,
                    identityPath: identityPath,
                    relationRelativePath: relationRelativePath,
                    originalName: name.normalized,
                    selectionIndex: selectionIndex,
                    roles: roles,
                    projectID: projectID,
                    selectedRootOccurrenceID: nil,
                    parentContainerOccurrenceID: nil,
                    symbolicLinkTarget: String(data: data, encoding: .utf8),
                    isContainer: false,
                    cancellation: cancellation
                )
                childCaptures.append([artifact])
                facts.append(CapturedFilesystemFact(
                    verificationNodeIndex: childVerificationNodeIndex,
                    snapshot: FileSnapshot(metadata),
                    symbolicLinkText: data
                ))
                structuralFacts.append(ReconstructionVerifiedContainerFact(
                    relativePath: name.normalized,
                    nodeKind: .symbolicLink,
                    artifactKind: .symbolicLink,
                    executableMode: false
                ))
                manifestEntries.append(capturedManifestEntry(
                    relativePath: name.normalized,
                    artifact: artifact
                ))
            default:
                throw ImporterError.unsupportedFileType
            }
        }

        var afterTraversal = stat()
        guard Darwin.fstat(descriptor, &afterTraversal) == 0,
              FileSnapshot(afterTraversal) == currentSnapshot else {
            throw ImporterError.changedDuringImport
        }
        try await hooks.didCatalogContainerChildren?(directoryURL)
        try cancellation.check()
        let manifest = try ReconstructionContainerManifestBuilder().buildCapturedManifest(
            entries: manifestEntries,
            limits: ReconstructionContainerManifestBuilder.Limits(
                maximumDepth: Limits.maximumDepth,
                maximumEntries: Limits.maximumEntryCount,
                maximumRelativePathUTF8Bytes:
                    ReconstructionContainerManifestBuilder.maximumSupportedRelativePathUTF8Bytes,
                maximumEncodedBytes: 64 * 1_024 * 1_024
            ),
            cancellation: cancellation
        )
        try await hooks.didBuildContainerManifest?(manifest.attachmentSource)
        try cancellation.check()
        try budget.admitBytes(manifest.contentIdentity.byteCount)
        let content = try await catalog.catalogBytes(
            manifest.canonicalManifestBytes,
            maximumByteCount: Limits.maximumFileBytes,
            cancellation: cancellation
        )
        guard content.source.contentIdentity == manifest.contentIdentity else {
            throw ImporterError.acquisitionFailed("container manifest identity did not verify")
        }
        await hooks.didCatalogAttachment?(content.source)

        let originalName = normalizedComponents.last!
        let maximumFactDepth = structuralFacts.lazy.map { fact in
            fact.relativePath.split(separator: "/", omittingEmptySubsequences: false).count
        }.max() ?? 0
        try await hooks.didPrepareContainerClassification?(
            directoryURL,
            structuralFacts.count,
            maximumFactDepth
        )
        try cancellation.check()
        let kind = classifier.classifyContainer(
            originalName: originalName,
            verifiedFacts: structuralFacts
        )
        let relationRelativePath = relationComponents.isEmpty
            ? "."
            : relationComponents.joined(separator: "/")
        let container = try await makeArtifact(
            content: content,
            kind: kind,
            diagnostic: nil,
            identityPath: normalizedComponents.joined(separator: "/"),
            relationRelativePath: relationRelativePath,
            originalName: originalName,
            selectionIndex: selectionIndex,
            roles: roles,
            projectID: projectID,
            selectedRootOccurrenceID: nil,
            parentContainerOccurrenceID: nil,
            symbolicLinkTarget: nil,
            isContainer: true,
            executableMode: (currentSnapshot.mode & 0o111) != 0,
            cancellation: cancellation
        )
        var artifacts = [container]
        for var childCapture in childCaptures {
            guard !childCapture.isEmpty else { continue }
            childCapture[0].parentContainerOccurrenceID = container.record.occurrenceID
            artifacts.append(contentsOf: childCapture)
        }
        return DirectoryCapture(
            artifacts: artifacts,
            facts: facts,
            structuralFacts: structuralFacts
        )
    }

    private func capturedManifestEntry(
        relativePath: String,
        artifact: AcquiredArtifact
    ) -> ReconstructionContainerManifestBuilder.CapturedEntry {
        ReconstructionContainerManifestBuilder.CapturedEntry(
            relativePath: relativePath,
            kind: artifact.record.kind,
            contentIdentity: artifact.record.kind == .symbolicLink
                ? nil
                : artifact.record.contentIdentity,
            executableMode: artifact.record.executableMode,
            symbolicLinkTarget: artifact.symbolicLinkTarget
        )
    }

    private func verifySelectedRoot(
        _ rootURL: URL,
        expected: FileSnapshot,
        descriptor: Int32,
        facts: [CapturedFilesystemFact],
        verificationPlan: ReconstructionCapturedTreeVerifier.Plan,
        cancellation: ReconstructionCancellation
    ) throws {
        try cancellation.check()
        guard verificationPlan.nodes.indices.contains(0),
              verificationPlan.nodes[0].parentIndex == nil,
              verificationPlan.nodes[0].kind == .directory,
              verificationPlan.nodes.count == facts.count else {
            throw ImporterError.acquisitionFailed("captured verification plan was incomplete")
        }
        var factsByNodeIndex = [CapturedFilesystemFact?](
            repeating: nil,
            count: verificationPlan.nodes.count
        )
        for fact in facts {
            try cancellation.check()
            guard factsByNodeIndex.indices.contains(fact.verificationNodeIndex),
                  factsByNodeIndex[fact.verificationNodeIndex] == nil else {
                throw ImporterError.acquisitionFailed("captured verification facts were invalid")
            }
            factsByNodeIndex[fact.verificationNodeIndex] = fact
        }
        guard let rootFact = factsByNodeIndex[0],
              rootFact.snapshot == expected,
              rootFact.symbolicLinkText == nil,
              factsByNodeIndex.allSatisfy({ $0 != nil }) else {
            throw ImporterError.acquisitionFailed("captured verification facts were incomplete")
        }

        var pathMetadata = stat()
        let pathStatus = rootURL.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &pathMetadata) } ?? -1
        }
        var descriptorMetadata = stat()
        guard pathStatus == 0,
              FileSnapshot(pathMetadata) == expected,
              (pathMetadata.st_mode & S_IFMT) == S_IFDIR,
              Darwin.fstat(descriptor, &descriptorMetadata) == 0,
              FileSnapshot(descriptorMetadata) == expected else {
            throw ImporterError.changedDuringImport
        }

        var visitedNodeCount = 1
        try verifyCapturedChildren(
            parentNodeIndex: 0,
            parentDescriptor: descriptor,
            verificationPlan: verificationPlan,
            factsByNodeIndex: factsByNodeIndex,
            visitedNodeCount: &visitedNodeCount,
            cancellation: cancellation
        )
        guard visitedNodeCount == verificationPlan.nodes.count else {
            throw ImporterError.acquisitionFailed("captured verification tree was disconnected")
        }

        var finalPathMetadata = stat()
        let finalPathStatus = rootURL.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &finalPathMetadata) } ?? -1
        }
        var finalDescriptorMetadata = stat()
        guard finalPathStatus == 0,
              FileSnapshot(finalPathMetadata) == expected,
              Darwin.fstat(descriptor, &finalDescriptorMetadata) == 0,
              FileSnapshot(finalDescriptorMetadata) == expected else {
            throw ImporterError.changedDuringImport
        }
        try cancellation.check()
    }

    private func verifyRootPath(_ rootURL: URL, expected: FileSnapshot) throws {
        var metadata = stat()
        let status = rootURL.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &metadata) } ?? -1
        }
        guard status == 0,
              FileSnapshot(metadata) == expected else {
            throw ImporterError.changedDuringImport
        }
    }

    private func verifyCapturedChildren(
        parentNodeIndex: Int,
        parentDescriptor: Int32,
        verificationPlan: ReconstructionCapturedTreeVerifier.Plan,
        factsByNodeIndex: [CapturedFilesystemFact?],
        visitedNodeCount: inout Int,
        cancellation: ReconstructionCancellation
    ) throws {
        try cancellation.check()
        guard verificationPlan.nodes.indices.contains(parentNodeIndex),
              verificationPlan.nodes[parentNodeIndex].kind == .directory else {
            throw ImporterError.acquisitionFailed("captured verification parent was invalid")
        }
        var childIndex = verificationPlan.nodes[parentNodeIndex].firstChildIndex
        while let currentIndex = childIndex {
            try cancellation.check()
            guard verificationPlan.nodes.indices.contains(currentIndex),
                  currentIndex != 0,
                  let fact = factsByNodeIndex[currentIndex] else {
                throw ImporterError.acquisitionFailed("captured verification child was invalid")
            }
            let node = verificationPlan.nodes[currentIndex]
            guard node.parentIndex == parentNodeIndex,
                  let rawComponent = node.rawComponent,
                  node.normalizedComponent != nil else {
                throw ImporterError.acquisitionFailed("captured verification edge was invalid")
            }

            var metadata = stat()
            let status = rawComponent.withCString {
                Darwin.fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0,
                  FileSnapshot(metadata) == fact.snapshot,
                  try capturedNodeKind(for: metadata.st_mode) == node.kind else {
                throw ImporterError.changedDuringImport
            }
            switch node.kind {
            case .regularFile:
                guard fact.symbolicLinkText == nil else {
                    throw ImporterError.acquisitionFailed("regular verification fact was invalid")
                }
                visitedNodeCount += 1
                hooks.verificationObserver?.recordVerifiedEdge(
                    parentNodeIndex: parentNodeIndex,
                    childNodeIndex: currentIndex
                )
            case .symbolicLink:
                guard let expectedText = fact.symbolicLinkText else {
                    throw ImporterError.acquisitionFailed("symbolic-link verification fact was invalid")
                }
                let actualText = try readLink(
                    rawComponent,
                    relativeTo: parentDescriptor,
                    expected: metadata
                )
                guard actualText == expectedText else {
                    throw ImporterError.changedDuringImport
                }
                visitedNodeCount += 1
                hooks.verificationObserver?.recordVerifiedEdge(
                    parentNodeIndex: parentNodeIndex,
                    childNodeIndex: currentIndex
                )
            case .directory:
                guard fact.symbolicLinkText == nil else {
                    throw ImporterError.acquisitionFailed("directory verification fact was invalid")
                }
                let childDescriptor = rawComponent.withCString {
                    Darwin.openat(
                        parentDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard childDescriptor >= 0 else {
                    throw ImporterError.changedDuringImport
                }
                do {
                    var openedMetadata = stat()
                    guard Darwin.fstat(childDescriptor, &openedMetadata) == 0,
                          FileSnapshot(openedMetadata) == fact.snapshot else {
                        throw ImporterError.changedDuringImport
                    }
                    visitedNodeCount += 1
                    hooks.verificationObserver?.recordVerifiedEdge(
                        parentNodeIndex: parentNodeIndex,
                        childNodeIndex: currentIndex
                    )
                    try verifyCapturedChildren(
                        parentNodeIndex: currentIndex,
                        parentDescriptor: childDescriptor,
                        verificationPlan: verificationPlan,
                        factsByNodeIndex: factsByNodeIndex,
                        visitedNodeCount: &visitedNodeCount,
                        cancellation: cancellation
                    )
                    _ = Darwin.close(childDescriptor)
                } catch {
                    _ = Darwin.close(childDescriptor)
                    throw error
                }
            }
            childIndex = node.nextSiblingIndex
        }
        try cancellation.check()
    }

    private func capturedNodeKind(
        for mode: mode_t
    ) throws -> ReconstructionCapturedTreeVerifier.NodeKind {
        switch mode & S_IFMT {
        case S_IFDIR: .directory
        case S_IFREG: .regularFile
        case S_IFLNK: .symbolicLink
        default: throw ImporterError.unsupportedFileType
        }
    }

    private func acquireRegularFile(
        identityPath: String,
        relationRelativePath: String,
        originalName: String,
        sourceURL: URL,
        verificationNodeIndex: Int,
        expectedSnapshot: FileSnapshot,
        selectionIndex: Int,
        roles: [ReconstructionArtifactRole],
        projectID: UUID,
        catalog: ReconstructionAttachmentCatalog,
        budget: ImportBudget,
        cancellation: ReconstructionCancellation,
        openDescriptor: () -> Int32
    ) async throws -> CapturedArtifact {
        for attempt in 0..<2 {
            try cancellation.check()
            let descriptor = openDescriptor()
            guard descriptor >= 0 else {
                throw ImporterError.changedDuringImport
            }
            defer { _ = Darwin.close(descriptor) }
            do {
                var openedMetadata = stat()
                guard Darwin.fstat(descriptor, &openedMetadata) == 0,
                      (openedMetadata.st_mode & S_IFMT) == S_IFREG,
                      openedMetadata.st_size >= 0 else {
                    throw ImporterError.changedDuringImport
                }
                let openedObjectID = FileObjectID(openedMetadata)
                guard openedObjectID.device == expectedSnapshot.device,
                      openedObjectID.inode == expectedSnapshot.inode else {
                    throw ImporterError.changedDuringImport
                }
                let openedSnapshot = FileSnapshot(openedMetadata)
                let expectedByteCount = UInt64(openedMetadata.st_size)
                let byteReservation = try budget.reserveRegularFileCapacity(
                    expectedByteCount: expectedByteCount,
                    maximumByteCount: Limits.maximumFileBytes
                )
                var committedByteReservation = false
                defer {
                    if !committedByteReservation {
                        budget.rollback(byteReservation)
                    }
                }
                let snapshotHook = hooks.didSnapshotRegularFile
                let content = try await catalog.catalogRegularFile(
                    descriptor: descriptor,
                    maximumByteCount: byteReservation.capacity,
                    cancellation: cancellation,
                    afterInitialMetadata: {
                        try await snapshotHook?(sourceURL, attempt + 1)
                    }
                )
                await hooks.didCatalogAttachment?(content.source)
                var finalMetadata = stat()
                guard Darwin.fstat(descriptor, &finalMetadata) == 0,
                      FileSnapshot(finalMetadata) == openedSnapshot,
                      content.stableDevice == openedSnapshot.device,
                      content.stableInode == openedSnapshot.inode,
                      content.stableMode == openedSnapshot.mode else {
                    throw ImporterError.changedDuringImport
                }
                try budget.admitAttemptedBytePass(expectedByteCount)
                let classification = try classifier.classify(
                    source: content.source,
                    originalName: originalName,
                    cancellation: cancellation
                )
                var kind = classification.kind
                var diagnostic = classification.diagnostic
                var loadedBinary: LoadedBinary?
                if Self.loadableKinds.contains(kind) {
                    try cancellation.check()
                    do {
                        loadedBinary = try loadIdentityBoundBinary(
                            source: content.source,
                            budget: budget,
                            cancellation: cancellation
                        )
                    } catch ImporterError.changedDuringImport {
                        throw ImporterError.changedDuringImport
                    } catch let error as ImporterError {
                        throw error
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        kind = .opaque
                        diagnostic = .sanitizing(
                            "The verified binary hint could not be loaded; retained as opaque."
                        )
                    }
                    try cancellation.check()
                }
                let artifact = try await makeArtifact(
                    content: content,
                    kind: kind,
                    diagnostic: diagnostic,
                    identityPath: identityPath,
                    relationRelativePath: relationRelativePath,
                    originalName: originalName,
                    selectionIndex: selectionIndex,
                    roles: roles,
                    projectID: projectID,
                    selectedRootOccurrenceID: nil,
                    parentContainerOccurrenceID: nil,
                    symbolicLinkTarget: nil,
                    isContainer: false,
                    loadedBinary: loadedBinary,
                    cancellation: cancellation
                )
                try budget.commit(
                    byteReservation,
                    consuming: content.source.contentIdentity.byteCount
                )
                committedByteReservation = true
                return CapturedArtifact(
                    artifact: artifact,
                    fact: CapturedFilesystemFact(
                        verificationNodeIndex: verificationNodeIndex,
                        snapshot: openedSnapshot,
                        symbolicLinkText: nil
                    )
                )
            } catch ImporterError.changedDuringImport {
                throw ImporterError.changedDuringImport
            } catch ReconstructionAttachmentCatalogError.changedDuringImport {
                if attempt == 0 { continue }
                throw ImporterError.changedDuringImport
            } catch ReconstructionAttachmentCatalogError.emptyContent {
                throw ImporterError.emptyContent
            } catch ReconstructionAttachmentCatalogError.contentTooLarge {
                // The catalog reads at most one byte beyond the descriptor-preflight size.
                // Charge that nonrefundable proof byte, then retry once from fresh metadata.
                try budget.admitAttemptedBytePass(1)
                if attempt == 0 { continue }
                throw ImporterError.changedDuringImport
            } catch ReconstructionArtifactClassifierError.invalidAttachment {
                throw ImporterError.changedDuringImport
            } catch ReconstructionArtifactClassifierError.unreadableAttachment {
                throw ImporterError.acquisitionFailed("verified attachment could not be classified")
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ImporterError {
                throw error
            } catch {
                throw ImporterError.acquisitionFailed("regular file acquisition failed")
            }
        }
        throw ImporterError.changedDuringImport
    }

    private func loadIdentityBoundBinary(
        source: ReconstructionAttachmentSource,
        budget: ImportBudget,
        cancellation: ReconstructionCancellation
    ) throws -> LoadedBinary {
        try cancellation.check()
        let descriptor = source.verifiedURL.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else {
            throw ImporterError.changedDuringImport
        }
        defer { _ = Darwin.close(descriptor) }

        var beforeMetadata = stat()
        var beforePathMetadata = stat()
        let beforePathStatus = source.verifiedURL.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &beforePathMetadata) } ?? -1
        }
        guard Darwin.fstat(descriptor, &beforeMetadata) == 0,
              beforePathStatus == 0,
              (beforeMetadata.st_mode & S_IFMT) == S_IFREG,
              beforeMetadata.st_size >= 0,
              FileSnapshot(beforeMetadata) == FileSnapshot(beforePathMetadata),
              UInt64(beforeMetadata.st_size) == source.contentIdentity.byteCount else {
            throw ImporterError.changedDuringImport
        }
        let stableSnapshot = FileSnapshot(beforeMetadata)

        // The loader performs a separate full materialization from its URL seam.
        try budget.admitAttemptedBytePass(source.contentIdentity.byteCount)
        let loaded = try binaryLoader.load(at: source.verifiedURL)
        try cancellation.check()

        var afterMetadata = stat()
        var afterPathMetadata = stat()
        let afterPathStatus = source.verifiedURL.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &afterPathMetadata) } ?? -1
        }
        guard Darwin.fstat(descriptor, &afterMetadata) == 0,
              afterPathStatus == 0,
              FileSnapshot(afterMetadata) == stableSnapshot,
              FileSnapshot(afterPathMetadata) == stableSnapshot,
              UInt64(loaded.bytes.count) == source.contentIdentity.byteCount else {
            throw ImporterError.changedDuringImport
        }

        // Identity verification is another complete byte pass over the loader-owned immutable data.
        try budget.admitAttemptedBytePass(source.contentIdentity.byteCount)
        let digest = SHA256.hash(data: loaded.bytes)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == source.contentIdentity.digest else {
            throw ImporterError.changedDuringImport
        }
        try cancellation.check()
        return loaded
    }

    private func makeArtifact(
        content: ReconstructionAttachmentCatalog.CataloguedContent,
        kind: ReconstructionArtifactKind,
        diagnostic: ReconstructionDiagnostic?,
        identityPath: String,
        relationRelativePath: String,
        originalName: String,
        selectionIndex: Int,
        roles: [ReconstructionArtifactRole],
        projectID: UUID,
        selectedRootOccurrenceID: ReconstructionArtifactOccurrenceID?,
        parentContainerOccurrenceID: ReconstructionArtifactOccurrenceID?,
        symbolicLinkTarget: String?,
        isContainer: Bool,
        executableMode: Bool? = nil,
        loadedBinary: LoadedBinary? = nil,
        cancellation: ReconstructionCancellation
    ) async throws -> AcquiredArtifact {
        let occurrenceID = deterministicOccurrenceID(
            projectID: projectID,
            selectionIndex: selectionIndex,
            relativePath: identityPath,
            content: content.source.contentIdentity,
            kind: kind,
            roles: roles
        )
        let record = try ReconstructionArtifactOccurrenceRecord(
            occurrenceID: occurrenceID,
            contentIdentity: content.source.contentIdentity,
            kind: kind,
            roles: roles,
            executableMode: executableMode ?? ((content.stableMode & 0o111) != 0),
            originalName: originalName,
            diagnostic: diagnostic
        )
        await hooks.didAcquireOccurrence?(record)
        try cancellation.check()
        let locators = Array(Set([
            originalName,
            relationRelativePath == "." ? nil : relationRelativePath,
        ].compactMap { $0 })).sorted(by: utf8Less)
        return AcquiredArtifact(
            record: record,
            source: content.source,
            selectedRootOccurrenceID: selectedRootOccurrenceID ?? occurrenceID,
            parentContainerOccurrenceID: parentContainerOccurrenceID,
            relationRelativePath: relationRelativePath,
            verifiedLocators: locators,
            symbolicLinkTarget: symbolicLinkTarget,
            isContainer: isContainer,
            loadedBinary: loadedBinary
        )
    }

    private func discoverRelations(
        in artifacts: [AcquiredArtifact],
        budget: ImportBudget,
        cancellation: ReconstructionCancellation
    ) async throws -> [ReconstructionArtifactRelationRecord] {
        try cancellation.check()
        let occurrences = artifacts.map { artifact in
            ReconstructionRelationDiscoveryOccurrence(
                artifact: artifact.record,
                selectedRootOccurrenceID: artifact.selectedRootOccurrenceID,
                relativePath: artifact.relationRelativePath,
                verifiedLocators: artifact.verifiedLocators
            )
        }
        let memberships: [ReconstructionContainerMembershipEvidence] = artifacts.compactMap { artifact in
            guard let parentContainerOccurrenceID = artifact.parentContainerOccurrenceID else {
                return nil
            }
            return ReconstructionContainerMembershipEvidence(
                containerOccurrenceID: parentContainerOccurrenceID,
                childOccurrenceID: artifact.record.occurrenceID,
                isVerifiedManifestEntry: true
            )
        }
        let symbolicLinks: [ReconstructionSymbolicLinkEvidence] = artifacts.compactMap { artifact in
            guard artifact.parentContainerOccurrenceID != nil,
                  let target = artifact.symbolicLinkTarget else {
                return nil
            }
            return ReconstructionSymbolicLinkEvidence(
                sourceOccurrenceID: artifact.record.occurrenceID,
                selectedRootOccurrenceID: artifact.selectedRootOccurrenceID,
                sourceRelativePath: artifact.relationRelativePath,
                targetText: target,
                isVerifiedManifestEntry: true
            )
        }
        var loadedBinaries: [ReconstructionLoadedBinaryRelationEvidence] = []
        for artifact in artifacts {
            try cancellation.check()
            guard !artifact.isContainer,
                  let loaded = artifact.loadedBinary else {
                continue
            }
            // Relation discovery independently re-hashes loader bytes before it accepts them as
            // evidence, so reserve that complete pass before handing the value across the seam.
            try budget.admitAttemptedBytePass(artifact.record.contentIdentity.byteCount)
            loadedBinaries.append(ReconstructionLoadedBinaryRelationEvidence(
                sourceOccurrenceID: artifact.record.occurrenceID,
                loadedBinary: loaded
            ))
        }
        try cancellation.check()
        let relations = try ReconstructionRelationDiscoverer().discover(
            ReconstructionRelationDiscoveryInput(
                occurrences: occurrences,
                containerMemberships: memberships,
                symbolicLinks: symbolicLinks,
                loadedBinaries: loadedBinaries
            ),
            cancellation: cancellation
        )
        try cancellation.check()
        return relations
    }

    private func makeResult(
        projectID: UUID,
        artifacts: [AcquiredArtifact],
        relations: [ReconstructionArtifactRelationRecord] = [],
        failures: [ReconstructionOccurrenceFailure]
    ) -> ReconstructionImportResult {
        let occurrences = artifacts.map(\.record).sorted {
            $0.occurrenceID.rawValue.uuidString < $1.occurrenceID.rawValue.uuidString
        }
        var sourcesByIdentity: [ReconstructionContentIdentity: ReconstructionAttachmentSource] = [:]
        for artifact in artifacts {
            sourcesByIdentity[artifact.source.contentIdentity] = artifact.source
        }
        let contents = sourcesByIdentity.keys.sorted {
            if $0.digest != $1.digest { return $0.digest < $1.digest }
            return $0.byteCount < $1.byteCount
        }
        let sources = contents.compactMap { sourcesByIdentity[$0] }
        let digest = try! ReconstructionCorpusCanonicalizer.canonicalSHA256(
            reconstructionProjectID: projectID,
            artifacts: occurrences,
            relations: relations
        )
        return ReconstructionImportResult(
            occurrences: occurrences,
            contents: contents,
            relations: relations,
            attachmentSources: sources,
            failures: failures,
            canonicalManifestSHA256: digest
        )
    }

    private func cancelledResult(projectID: UUID, sourceURL: URL) -> ReconstructionImportResult {
        makeResult(
            projectID: projectID,
            artifacts: [],
            failures: [ReconstructionOccurrenceFailure(
                sourceURL: sourceURL,
                relativePath: nil,
                reason: .cancelled,
                diagnostic: .sanitizing("Reconstruction corpus import was cancelled.")
            )]
        )
    }

    private func failure(
        sourceURL: URL,
        relativePath: String?,
        error: Error
    ) -> ReconstructionOccurrenceFailure {
        let reason: ReconstructionOccurrenceFailureReason
        let text: String
        switch error {
        case ImporterError.changedDuringImport,
             ReconstructionAttachmentCatalogError.changedDuringImport:
            reason = .changedDuringImport
            text = "The selected artifact changed during import."
        case ImporterError.emptyContent,
             ReconstructionAttachmentCatalogError.emptyContent:
            reason = .emptyContent
            text = "Empty artifacts cannot form a reconstruction content identity."
        case ImporterError.boundsExceeded(let detail):
            reason = .boundsExceeded
            text = "The selected artifact exceeded an import bound: \(detail)."
        case ReconstructionCapturedTreeVerifier.VerificationError
                .expandedPathUTF8ByteLimitExceeded,
             ReconstructionCapturedTreeVerifier.VerificationError
                .expandedComponentWorkLimitExceeded:
            reason = .boundsExceeded
            text = "The selected artifact exceeded the expanded path-work bound."
        case ImporterError.invalidSelection(let detail):
            reason = .invalidSelection
            text = "The selected artifact is invalid: \(detail)."
        case ReconstructionCapturedTreeVerifier.VerificationError.invalidTree,
             ReconstructionCapturedTreeVerifier.VerificationError.invalidComponent:
            reason = .invalidSelection
            text = "The selected artifact has an invalid captured path structure."
        case ImporterError.unsupportedFileType:
            reason = .unsupportedFileType
            text = "The selected filesystem object type is unsupported."
        case is CancellationError:
            reason = .cancelled
            text = "Reconstruction corpus import was cancelled."
        default:
            reason = .acquisitionFailed
            text = "The selected artifact could not be acquired without following links."
        }
        return ReconstructionOccurrenceFailure(
            sourceURL: sourceURL,
            relativePath: relativePath,
            reason: reason,
            diagnostic: .sanitizing(text)
        )
    }

    private func normalizedRoles(
        _ roles: [ReconstructionArtifactRole]
    ) -> [ReconstructionArtifactRole] {
        Array(Set(roles)).sorted { $0.rawValue < $1.rawValue }
    }

    private func normalizedComponent(_ value: String) -> String? {
        let normalized = value.precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty,
              normalized != ".",
              normalized != "..",
              normalized.utf8.count <= Limits.maximumNameUTF8Bytes,
              !normalized.contains("/"),
              !normalized.contains("\0"),
              !normalized.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7f
              }) else {
            return nil
        }
        return normalized
    }

    private func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private func deterministicOccurrenceID(
        projectID: UUID,
        selectionIndex: Int,
        relativePath: String,
        content: ReconstructionContentIdentity,
        kind: ReconstructionArtifactKind,
        roles: [ReconstructionArtifactRole]
    ) -> ReconstructionArtifactOccurrenceID {
        var seed = Data("MacScope.ReconstructionOccurrence.v1".utf8)
        let fields = [
            projectID.uuidString.lowercased(),
            String(selectionIndex),
            relativePath,
            content.algorithm.rawValue,
            content.digest,
            String(content.byteCount),
            kind.rawValue,
        ] + roles.map(\.rawValue)
        for field in fields {
            var length = UInt64(field.utf8.count).littleEndian
            withUnsafeBytes(of: &length) { seed.append(contentsOf: $0) }
            seed.append(contentsOf: field.utf8)
        }
        var bytes = Array(SHA256.hash(data: seed).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return ReconstructionArtifactOccurrenceID(rawValue: uuid)
    }

    private func readRootLink(_ url: URL, expected: stat) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: Limits.maximumLinkBytes)
        let count = url.withUnsafeFileSystemRepresentation { path in
            path.map { pathPointer in
                buffer.withUnsafeMutableBytes { bytes in
                    Darwin.readlink(pathPointer, bytes.baseAddress, bytes.count)
                }
            } ?? -1
        }
        guard count > 0, count < buffer.count else {
            throw ImporterError.boundsExceeded("symbolic-link text exceeded the limit")
        }
        var after = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &after) } ?? -1
        }
        guard status == 0,
              FileSnapshot(after) == FileSnapshot(expected),
              (after.st_mode & S_IFMT) == S_IFLNK else {
            throw ImporterError.changedDuringImport
        }
        return Data(buffer.prefix(count))
    }

    private func readLink(
        _ name: String,
        relativeTo descriptor: Int32,
        expected: stat
    ) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: Limits.maximumLinkBytes)
        let count = name.withCString { pointer in
            buffer.withUnsafeMutableBytes { bytes in
                Darwin.readlinkat(descriptor, pointer, bytes.baseAddress, bytes.count)
            }
        }
        guard count > 0, count < buffer.count else {
            throw ImporterError.boundsExceeded("symbolic-link text exceeded the limit")
        }
        var after = stat()
        let status = name.withCString {
            Darwin.fstatat(descriptor, $0, &after, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0,
              FileSnapshot(after) == FileSnapshot(expected),
              (after.st_mode & S_IFMT) == S_IFLNK else {
            throw ImporterError.changedDuringImport
        }
        return Data(buffer.prefix(count))
    }
}
