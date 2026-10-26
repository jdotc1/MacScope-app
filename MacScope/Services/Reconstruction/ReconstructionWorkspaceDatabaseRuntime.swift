import Darwin
import Foundation

enum ReconstructionWorkspaceDatabaseRuntimeError: Error, Equatable {
    case invalidBaseDirectory
    case invalidCanonicalPackagePath
    case identityAlreadyOpen
    case unsafeFilesystemEntry(String)
    case workspaceIdentityMismatch
    case documentIdentityMismatch
    case canonicalPackagePathMismatch
    case sourceCatalogMismatch
    case reconciliationConflict(ReconstructionWorkspaceStateConflictReason)
    case closed
    case retirementIdentityMismatch
    case retirementRequired
    case discardFailed
}

enum ReconstructionSidecarAttachmentAuthorityError: Error, Equatable {
    case invalidDirectoryDescriptor
    case invalidAttachmentIdentity
    case revoked
}

/// One app-owned, per-document durable Reconstruction authority.
///
/// The package remains the authoring authority. This sidecar retains resumable checkpoints and
/// attachment bytes without rewriting the package on every round. Opening is fail-closed: the
/// runtime binds the database to the exact workspace/document/package triple, reconciles package
/// and durable state, publishes every selected attachment into the durable vault, and only then
/// makes its `ReconstructionDatabaseOwner` available.
final class ReconstructionWorkspaceDatabaseRuntime: @unchecked Sendable {
    enum ReconciliationDisposition: Equatable, Sendable {
        case seededPackage
        case equal
        case usedDurableDescendant
        case fastForwardedDurableFromPackage
    }

    struct DatabaseOpenInterpositionForTesting {
        let perform: (_ operation: () throws -> WorkspaceDatabase) throws -> WorkspaceDatabase
    }

    struct VaultPublicationInterpositionForTesting {
        let perform: (
            _ operation: () throws -> [ReconstructionAttachmentSource]
        ) throws -> [ReconstructionAttachmentSource]
    }

    private enum Lifecycle: Equatable {
        case open
        case closed
        case retired
        case discarded
    }

    static let databaseFileName = "Reconstruction.sqlite3"
    static let attachmentVaultDirectoryName = "Attachments"

    let binding: ReconstructionWorkspaceStateBinding
    let sidecarDirectoryURL: URL
    let databaseURL: URL
    let attachmentVaultURL: URL
    /// The state selected during open. Live callers must read later commits through
    /// `databaseOwner()`.
    let reconciledOpeningState: ReconstructionWorkspaceState
    let reconciliationDisposition: ReconciliationDisposition

    private let lock = NSLock()
    private var lifecycle: Lifecycle = .open
    private var retainedOwner: ReconstructionDatabaseOwner?
    private var retainedAttachmentAuthority: ReconstructionSidecarAttachmentAuthority?
    private var directoryLease: SidecarDirectoryLease?
    private var identityClaim: SidecarRuntimeIdentityClaim?
    private var revocationTask: Task<Void, Never>?
    private var revocationToken: UUID?
    private var revocationFinished = false

    private init(
        binding: ReconstructionWorkspaceStateBinding,
        sidecarDirectoryURL: URL,
        databaseURL: URL,
        attachmentVaultURL: URL,
        reconciledOpeningState: ReconstructionWorkspaceState,
        reconciliationDisposition: ReconciliationDisposition,
        owner: ReconstructionDatabaseOwner,
        attachmentAuthority: ReconstructionSidecarAttachmentAuthority,
        directoryLease: SidecarDirectoryLease,
        identityClaim: SidecarRuntimeIdentityClaim
    ) {
        self.binding = binding
        self.sidecarDirectoryURL = sidecarDirectoryURL
        self.databaseURL = databaseURL
        self.attachmentVaultURL = attachmentVaultURL
        self.reconciledOpeningState = reconciledOpeningState
        self.reconciliationDisposition = reconciliationDisposition
        retainedOwner = owner
        retainedAttachmentAuthority = attachmentAuthority
        self.directoryLease = directoryLease
        self.identityClaim = identityClaim
    }

    deinit {
        let owner = retainedOwner
        let attachmentAuthority = retainedAttachmentAuthority
        let existingRevocation = revocationTask
        let claim = identityClaim
        retainedOwner = nil
        retainedAttachmentAuthority = nil
        identityClaim = nil

        if let existingRevocation {
            Task {
                await existingRevocation.value
                claim?.release()
            }
        } else if let owner {
            Task {
                await owner.revoke()
                attachmentAuthority?.revoke()
                claim?.release()
            }
        } else {
            attachmentAuthority?.revoke()
            claim?.release()
        }
    }

    /// Opens or creates the identity-qualified sidecar. `baseDirectoryURL` is a test seam; when
    /// absent, storage is rooted below Application Support/MacScope/ReconstructionSidecars.
    static func open(
        binding: ReconstructionWorkspaceStateBinding,
        packageState: ReconstructionWorkspaceState,
        packageAttachmentSources: [ReconstructionAttachmentSource],
        workspaceName: String = "MacScope Workspace",
        baseDirectoryURL: URL? = nil,
        fileManager: FileManager = .default,
        now: Date = Date(),
        databaseOpenInterpositionForTesting: DatabaseOpenInterpositionForTesting? = nil,
        vaultPublicationInterpositionForTesting: VaultPublicationInterpositionForTesting? = nil
    ) throws -> ReconstructionWorkspaceDatabaseRuntime {
        try Task.checkCancellation()
        guard isCanonicalAbsolutePackagePath(binding.canonicalPackagePath) else {
            throw ReconstructionWorkspaceDatabaseRuntimeError.invalidCanonicalPackagePath
        }

        let root = try storageRootURL(
            baseDirectoryURL: baseDirectoryURL,
            fileManager: fileManager
        )
        let identityDirectory = try deterministicSidecarDirectoryURL(
            workspaceID: binding.workspaceID,
            documentID: binding.documentID,
            baseDirectoryURL: root
        )
        let identityClaim = try SidecarRuntimeIdentityRegistry.shared.claim(
            identityDirectory.standardizedFileURL.path
        )
        let lease = try SidecarDirectoryLease.openOrCreate(
            storageRootURL: root,
            workspaceID: binding.workspaceID,
            documentID: binding.documentID,
            rootIsRuntimeOwned: baseDirectoryURL == nil
        )
        let sidecarDirectory = lease.directoryURL
        let databaseURL = sidecarDirectory.appendingPathComponent(
            databaseFileName,
            isDirectory: false
        )
        let vaultURL = sidecarDirectory.appendingPathComponent(
            attachmentVaultDirectoryName,
            isDirectory: true
        )

        try lease.validatePathIdentity()
        try lease.prepareOrdinaryDatabaseFile(named: databaseFileName)
        try lease.validatePathIdentity()
        try lease.validateKnownEntries(
            databaseFileName: databaseFileName,
            vaultDirectoryName: attachmentVaultDirectoryName
        )

        let database: WorkspaceDatabase
        let attachmentAuthority: ReconstructionSidecarAttachmentAuthority
        let durableWasAbsent: Bool
        do {
            try lease.validatePathIdentity()
            let constructDatabase = {
                try WorkspaceDatabase(path: databaseURL.path)
            }
            if let databaseOpenInterpositionForTesting {
                database = try databaseOpenInterpositionForTesting.perform(
                    constructDatabase
                )
            } else {
                database = try constructDatabase()
            }
            try lease.validatePathIdentity()
            guard (try? database.reconstructionMainDatabaseFileHasMoved()) == false else {
                throw ReconstructionWorkspaceDatabaseRuntimeError
                    .unsafeFilesystemEntry(databaseURL.path)
            }
            try lease.validateKnownEntries(
                databaseFileName: databaseFileName,
                vaultDirectoryName: attachmentVaultDirectoryName
            )
            let preflight = try database.preflightReconstructionSidecarBindingBeforeMigration(
                workspaceUUID: binding.workspaceID,
                documentID: binding.documentID,
                canonicalPackagePath: binding.canonicalPackagePath
            )
            try lease.validatePathIdentity()
            guard (try? database.reconstructionMainDatabaseFileHasMoved()) == false else {
                throw ReconstructionWorkspaceDatabaseRuntimeError
                    .unsafeFilesystemEntry(databaseURL.path)
            }
            try lease.validateKnownEntries(
                databaseFileName: databaseFileName,
                vaultDirectoryName: attachmentVaultDirectoryName
            )
            let expectedWorkspaceRowID: Int64
            switch preflight {
            case .uninitialized, .emptyCurrentSchema:
                try database.applySchema()
                try lease.validatePathIdentity()
                expectedWorkspaceRowID = try database.bootstrapReconstructionWorkspaceSidecar(
                    workspaceUUID: binding.workspaceID,
                    workspaceName: workspaceName,
                    documentID: binding.documentID,
                    canonicalPackagePath: binding.canonicalPackagePath,
                    now: now
                )
                durableWasAbsent = true
            case .matched(workspaceRowID: let workspaceRowID):
                try database.applySchema()
                expectedWorkspaceRowID = workspaceRowID
                durableWasAbsent = false
            case .workspaceMismatch:
                throw ReconstructionWorkspaceDatabaseRuntimeError.workspaceIdentityMismatch
            case .documentMismatch:
                throw ReconstructionWorkspaceDatabaseRuntimeError.documentIdentityMismatch
            case .canonicalPackagePathMismatch:
                throw ReconstructionWorkspaceDatabaseRuntimeError
                    .canonicalPackagePathMismatch
            }
            let currentPreflight = try database.preflightReconstructionSidecarBinding(
                workspaceUUID: binding.workspaceID,
                documentID: binding.documentID,
                canonicalPackagePath: binding.canonicalPackagePath
            )
            switch currentPreflight {
            case .matched(workspaceRowID: let workspaceRowID)
                where workspaceRowID == expectedWorkspaceRowID:
                break
            case .workspaceMismatch:
                throw ReconstructionWorkspaceDatabaseRuntimeError.workspaceIdentityMismatch
            case .documentMismatch:
                throw ReconstructionWorkspaceDatabaseRuntimeError.documentIdentityMismatch
            case .canonicalPackagePathMismatch:
                throw ReconstructionWorkspaceDatabaseRuntimeError
                    .canonicalPackagePathMismatch
            case .uninitialized, .emptyCurrentSchema, .matched:
                throw WorkspaceDatabase.DatabaseError.reconstructionStateInvalid(
                    "sidecar post-migration identity verification"
                )
            }
            try lease.validatePathIdentity()
            try lease.prepareOrdinaryDirectory(named: attachmentVaultDirectoryName)
            try lease.validatePathIdentity()
            try lease.validateKnownEntries(
                databaseFileName: databaseFileName,
                vaultDirectoryName: attachmentVaultDirectoryName
            )
            let vaultDescriptor = try lease.openPinnedDirectoryDescriptor(
                named: attachmentVaultDirectoryName
            )
            defer { _ = Darwin.close(vaultDescriptor) }
            attachmentAuthority = try database.configureReconstructionAttachmentVault(
                rootURL: vaultURL,
                pinnedRootDescriptor: vaultDescriptor
            )
            try lease.validateKnownEntries(
                databaseFileName: databaseFileName,
                vaultDirectoryName: attachmentVaultDirectoryName
            )
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch let runtimeError as ReconstructionWorkspaceDatabaseRuntimeError {
            throw runtimeError
        } catch {
            throw error
        }

        let packageSources = try exactSourceMap(
            state: packageState,
            suppliedSources: packageAttachmentSources
        )
        let packageCut = try stateCut(
            binding: binding,
            state: packageState,
            availableIdentities: Set(packageSources.keys)
        )

        let durableState = try database.loadReconstructionState(workspaceID: binding.workspaceID)
        let durableSources = try database.availableDurableReconstructionAttachmentSources(
            workspaceID: binding.workspaceID
        )
        let durableSourceMap = try exactSourceMap(
            state: durableState,
            suppliedSources: durableSources
        )
        let durableCut = try stateCut(
            binding: binding,
            state: durableState,
            availableIdentities: Set(durableSourceMap.keys)
        )

        let decision = try ReconstructionWorkspaceStateReconciler.reconcile(
            package: packageCut,
            durable: durableWasAbsent
                ? .absent(binding: binding)
                : .present(cut: durableCut, corpusBasis: .trustedSamePathAppOwned)
        )
        let resolution: ReconstructionWorkspaceStateResolution
        let disposition: ReconciliationDisposition
        switch decision {
        case .seedPackage(let selected):
            resolution = selected
            disposition = .seededPackage
        case .equal(let selected):
            resolution = selected
            disposition = .equal
        case .useDurableDescendant(let selected):
            resolution = selected
            disposition = .usedDurableDescendant
        case .fastForwardDurableFromPackage(let selected):
            resolution = selected
            disposition = .fastForwardedDurableFromPackage
        case .conflict(let conflict):
            throw ReconstructionWorkspaceDatabaseRuntimeError.reconciliationConflict(conflict)
        }

        let selectedSources = try selectedSourceMap(
            resolution: resolution,
            packageSources: packageSources,
            durableSources: durableSourceMap
        )
        do {
            for manifest in resolution.state.corpusManifests.sorted(by: {
                if $0.reconstructionProjectID != $1.reconstructionProjectID {
                    return $0.reconstructionProjectID.uuidString
                        < $1.reconstructionProjectID.uuidString
                }
                return $0.canonicalSHA256 < $1.canonicalSHA256
            }) {
                let identities = Set(manifest.artifacts.map(\.contentIdentity))
                let sources = try identities.sorted(by: {
                    $0.digest < $1.digest
                }).map { identity in
                    guard let source = selectedSources[identity] else {
                        throw ReconstructionWorkspaceDatabaseRuntimeError.sourceCatalogMismatch
                    }
                    return source
                }
                try lease.validatePathIdentity()
                let publish = {
                    try database.publishDurableReconstructionAttachmentSources(
                        sources,
                        for: manifest
                    )
                }
                if let vaultPublicationInterpositionForTesting {
                    _ = try vaultPublicationInterpositionForTesting.perform(publish)
                } else {
                    _ = try publish()
                }
                try lease.validatePathIdentity()
            }
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch let runtimeError as ReconstructionWorkspaceDatabaseRuntimeError {
            throw runtimeError
        } catch {
            throw ReconstructionWorkspaceDatabaseRuntimeError.sourceCatalogMismatch
        }

        try database.replaceReconstructionState(
            workspaceID: binding.workspaceID,
            state: resolution.state
        )
        let finalSources = try database.availableDurableReconstructionAttachmentSources(
            workspaceID: binding.workspaceID
        )
        try lease.validatePathIdentity()
        let finalSourceMap = try exactSourceMap(
            state: resolution.state,
            suppliedSources: finalSources
        )
        let requiredIdentities = try requiredContentIdentities(in: resolution.state)
        guard Set(finalSourceMap.keys) == requiredIdentities else {
            throw ReconstructionWorkspaceDatabaseRuntimeError.sourceCatalogMismatch
        }

        let validateDatabaseAuthority: @Sendable () throws -> Void = {
            try lease.validatePathIdentity()
            try lease.validateKnownEntries(
                databaseFileName: databaseFileName,
                vaultDirectoryName: attachmentVaultDirectoryName
            )
        }
        let owner = ReconstructionDatabaseOwner(
            database: database,
            databaseAuthorityValidator: validateDatabaseAuthority,
            databaseAuthorityPostvalidator: validateDatabaseAuthority
        )
        return ReconstructionWorkspaceDatabaseRuntime(
            binding: binding,
            sidecarDirectoryURL: sidecarDirectory,
            databaseURL: databaseURL,
            attachmentVaultURL: vaultURL,
            reconciledOpeningState: resolution.state,
            reconciliationDisposition: disposition,
            owner: owner,
            attachmentAuthority: attachmentAuthority,
            directoryLease: lease,
            identityClaim: identityClaim
        )
    }

    static func deterministicSidecarDirectoryURL(
        workspaceID: UUID,
        documentID: UUID,
        baseDirectoryURL: URL
    ) throws -> URL {
        guard baseDirectoryURL.isFileURL else {
            throw ReconstructionWorkspaceDatabaseRuntimeError.invalidBaseDirectory
        }
        return baseDirectoryURL.standardizedFileURL
            .appendingPathComponent(workspaceID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(documentID.uuidString.lowercased(), isDirectory: true)
    }

    func databaseOwner() throws -> ReconstructionDatabaseOwner {
        lock.lock()
        defer { lock.unlock() }
        guard lifecycle == .open, let retainedOwner else {
            throw ReconstructionWorkspaceDatabaseRuntimeError.closed
        }
        return retainedOwner
    }

    /// Revokes and drains SQLite/actor ownership without deleting the database, WAL/SHM files, or
    /// vault. The identity claim remains exclusive until revocation has completed, after which the
    /// exact identity can be reopened from the same durable cut.
    func close() async {
        let revocation = prepareClose()
        if let revocation {
            await revocation.task.value
            finishRevocation(token: revocation.token)
        }
    }

    /// Records the document-lifecycle retirement event. The exact binding is required again so a
    /// stale window cannot retire another document's sidecar by retaining this object accidentally.
    func retire(binding expectedBinding: ReconstructionWorkspaceStateBinding) async throws {
        let revocation = try prepareRetirement(binding: expectedBinding)
        if let revocation {
            await revocation.task.value
            finishRevocation(token: revocation.token)
        }
    }

    /// Deletes only the descriptor-bound identity leaf and its bounded contents. It is illegal
    /// before `retire(binding:)`; ordinary close and deinitialization always preserve the sidecar.
    func discardRetiredSidecar() async throws {
        let prepared = try prepareDiscard()
        if let revocation = prepared.revocation {
            await revocation.task.value
            finishRevocation(token: revocation.token)
        }
        try requireRevokedRetirement()
        try prepared.lease.discard()
        finishDiscard()
    }

    private func prepareClose() -> (token: UUID, task: Task<Void, Never>)? {
        lock.lock()
        defer { lock.unlock() }
        switch lifecycle {
        case .open:
            lifecycle = .closed
            return startRevocationLocked()
        case .closed, .retired:
            return currentRevocationLocked()
        case .discarded:
            return nil
        }
    }

    private func prepareRetirement(
        binding expectedBinding: ReconstructionWorkspaceStateBinding
    ) throws -> (token: UUID, task: Task<Void, Never>)? {
        lock.lock()
        defer { lock.unlock() }
        guard expectedBinding == binding else {
            throw ReconstructionWorkspaceDatabaseRuntimeError.retirementIdentityMismatch
        }
        switch lifecycle {
        case .open:
            lifecycle = .retired
            return startRevocationLocked()
        case .retired:
            return currentRevocationLocked()
        case .closed:
            throw ReconstructionWorkspaceDatabaseRuntimeError.closed
        case .discarded:
            return nil
        }
    }

    private func prepareDiscard() throws -> (
        lease: SidecarDirectoryLease,
        revocation: (token: UUID, task: Task<Void, Never>)?
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let retainedLease = directoryLease else {
            throw ReconstructionWorkspaceDatabaseRuntimeError.retirementRequired
        }
        return (retainedLease, currentRevocationLocked())
    }

    private func requireRevokedRetirement() throws {
        lock.lock()
        defer { lock.unlock() }
        guard lifecycle == .retired, revocationFinished else {
            throw ReconstructionWorkspaceDatabaseRuntimeError.retirementRequired
        }
    }

    private func finishDiscard() {
        lock.lock()
        defer { lock.unlock() }
        directoryLease = nil
        identityClaim?.release()
        identityClaim = nil
        lifecycle = .discarded
    }

    private func startRevocationLocked() -> (token: UUID, task: Task<Void, Never>)? {
        if let current = currentRevocationLocked() { return current }
        guard let owner = retainedOwner else {
            retainedAttachmentAuthority?.revoke()
            retainedAttachmentAuthority = nil
            revocationFinished = true
            return nil
        }
        let attachmentAuthority = retainedAttachmentAuthority
        retainedOwner = nil
        retainedAttachmentAuthority = nil
        revocationFinished = false
        let token = UUID()
        let task = Task {
            await owner.revoke()
            attachmentAuthority?.revoke()
        }
        revocationToken = token
        revocationTask = task
        return (token, task)
    }

    private func currentRevocationLocked() -> (token: UUID, task: Task<Void, Never>)? {
        guard let token = revocationToken, let task = revocationTask else { return nil }
        return (token, task)
    }

    private func finishRevocation(token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard revocationToken == token else { return }
        revocationTask = nil
        revocationToken = nil
        revocationFinished = true
        if lifecycle == .closed {
            identityClaim?.release()
            identityClaim = nil
        }
    }

    private static func isCanonicalAbsolutePackagePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/" else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path == path
    }

    private static func storageRootURL(
        baseDirectoryURL: URL?,
        fileManager: FileManager
    ) throws -> URL {
        if let baseDirectoryURL {
            guard baseDirectoryURL.isFileURL else {
                throw ReconstructionWorkspaceDatabaseRuntimeError.invalidBaseDirectory
            }
            let standardized = baseDirectoryURL.standardizedFileURL
            var metadata = stat()
            let status = standardized.withUnsafeFileSystemRepresentation { path in
                path.map { Darwin.lstat($0, &metadata) } ?? -1
            }
            guard status == 0,
                  metadata.st_mode & S_IFMT == S_IFDIR else {
                throw ReconstructionWorkspaceDatabaseRuntimeError.invalidBaseDirectory
            }
            return standardized.resolvingSymlinksInPath().standardizedFileURL
        }

        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).resolvingSymlinksInPath().standardizedFileURL
        let macScope = applicationSupport.appendingPathComponent("MacScope", isDirectory: true)
        try createOwnedDirectoryIfNeeded(macScope)
        let root = macScope.appendingPathComponent(
            "ReconstructionSidecars",
            isDirectory: true
        )
        try createOwnedDirectoryIfNeeded(root)
        return root
    }

    private static func createOwnedDirectoryIfNeeded(_ url: URL) throws {
        var metadata = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &metadata) } ?? -1
        }
        if status != 0 {
            guard errno == ENOENT else {
                throw ReconstructionWorkspaceDatabaseRuntimeError
                    .unsafeFilesystemEntry(url.path)
            }
            let creationStatus = url.withUnsafeFileSystemRepresentation { path in
                path.map { Darwin.mkdir($0, 0o700) } ?? -1
            }
            guard creationStatus == 0 || errno == EEXIST else {
                throw ReconstructionWorkspaceDatabaseRuntimeError
                    .unsafeFilesystemEntry(url.path)
            }
            guard url.withUnsafeFileSystemRepresentation({ path in
                path.map { Darwin.lstat($0, &metadata) } ?? -1
            }) == 0 else {
                throw ReconstructionWorkspaceDatabaseRuntimeError
                    .unsafeFilesystemEntry(url.path)
            }
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw ReconstructionWorkspaceDatabaseRuntimeError.unsafeFilesystemEntry(url.path)
        }
    }

    private static func requiredContentIdentities(
        in state: ReconstructionWorkspaceState
    ) throws -> Set<ReconstructionContentIdentity> {
        Set(try ReconstructionPackageCodec.contentRecords(in: state).map(\.contentIdentity))
    }

    private static func exactSourceMap(
        state: ReconstructionWorkspaceState,
        suppliedSources: [ReconstructionAttachmentSource]
    ) throws -> [ReconstructionContentIdentity: ReconstructionAttachmentSource] {
        let required = try requiredContentIdentities(in: state)
        var sources: [ReconstructionContentIdentity: ReconstructionAttachmentSource] = [:]
        for source in suppliedSources {
            try Task.checkCancellation()
            guard required.contains(source.contentIdentity),
                  sources.updateValue(source, forKey: source.contentIdentity) == nil else {
                throw ReconstructionWorkspaceDatabaseRuntimeError.sourceCatalogMismatch
            }
        }
        return sources
    }

    private static func stateCut(
        binding: ReconstructionWorkspaceStateBinding,
        state: ReconstructionWorkspaceState,
        availableIdentities: Set<ReconstructionContentIdentity>
    ) throws -> ReconstructionWorkspaceStateCut {
        let required = try requiredContentIdentities(in: state)
        return ReconstructionWorkspaceStateCut(
            binding: binding,
            state: state,
            contentAvailability: required.sorted(by: { $0.digest < $1.digest }).map {
                ReconstructionWorkspaceContentAvailability(
                    contentIdentity: $0,
                    isAvailable: availableIdentities.contains($0)
                )
            }
        )
    }

    private static func selectedSourceMap(
        resolution: ReconstructionWorkspaceStateResolution,
        packageSources: [ReconstructionContentIdentity: ReconstructionAttachmentSource],
        durableSources: [ReconstructionContentIdentity: ReconstructionAttachmentSource]
    ) throws -> [ReconstructionContentIdentity: ReconstructionAttachmentSource] {
        var selected: [ReconstructionContentIdentity: ReconstructionAttachmentSource] = [:]
        for availability in resolution.requiredContentAvailability {
            try Task.checkCancellation()
            let identity = availability.contentIdentity
            if availability.isAvailableFromDurable, let source = durableSources[identity] {
                selected[identity] = source
            } else if availability.isAvailableFromPackage,
                      let source = packageSources[identity] {
                selected[identity] = source
            } else {
                throw ReconstructionWorkspaceDatabaseRuntimeError.sourceCatalogMismatch
            }
        }
        return selected
    }
}

/// Shared transient authority for the durable attachment vault. The database uses duplicated root
/// descriptors for publication, while each source token opens its file below the same retained
/// directory inode. No path is rediscovered after this authority is created.
final class ReconstructionSidecarAttachmentAuthority: @unchecked Sendable {
    private struct DirectoryIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let type: UInt32

        init(_ metadata: stat) {
            device = UInt64(truncatingIfNeeded: metadata.st_dev)
            inode = UInt64(truncatingIfNeeded: metadata.st_ino)
            type = UInt32(metadata.st_mode) & UInt32(S_IFMT)
        }
    }

    private let lock = NSLock()
    private let rootIdentity: DirectoryIdentity
    private var rootDescriptor: Int32

    init(pinnedRootDescriptor: Int32) throws {
        var sourceMetadata = stat()
        guard Darwin.fstat(pinnedRootDescriptor, &sourceMetadata) == 0,
              DirectoryIdentity(sourceMetadata).type == UInt32(S_IFDIR) else {
            throw ReconstructionSidecarAttachmentAuthorityError.invalidDirectoryDescriptor
        }
        let duplicate = Darwin.fcntl(pinnedRootDescriptor, F_DUPFD_CLOEXEC, 0)
        var duplicateMetadata = stat()
        guard duplicate >= 0,
              Darwin.fstat(duplicate, &duplicateMetadata) == 0,
              DirectoryIdentity(duplicateMetadata) == DirectoryIdentity(sourceMetadata) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            throw ReconstructionSidecarAttachmentAuthorityError.invalidDirectoryDescriptor
        }
        rootIdentity = DirectoryIdentity(sourceMetadata)
        rootDescriptor = duplicate
    }

    deinit {
        revoke()
    }

    /// Prevents every later source open and releases the pinned vault directory. The lock is an
    /// admission barrier: an open admitted before revocation finishes first; none begins after.
    func revoke() {
        lock.lock()
        let descriptor = rootDescriptor
        rootDescriptor = -1
        lock.unlock()
        if descriptor >= 0 { _ = Darwin.close(descriptor) }
    }

    func duplicateRootDescriptor() throws -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let descriptor = try validatedRootDescriptorLocked()
        let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        var duplicateMetadata = stat()
        guard duplicate >= 0,
              Darwin.fstat(duplicate, &duplicateMetadata) == 0,
              DirectoryIdentity(duplicateMetadata) == rootIdentity else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            throw ReconstructionSidecarAttachmentAuthorityError.invalidDirectoryDescriptor
        }
        return duplicate
    }

    func source(
        contentIdentity: ReconstructionContentIdentity,
        rootURL: URL
    ) -> ReconstructionAttachmentSource {
        let shardName = String(contentIdentity.digest.prefix(2))
        let verifiedURL = rootURL
            .appendingPathComponent(shardName, isDirectory: true)
            .appendingPathComponent(contentIdentity.digest, isDirectory: false)
        return ReconstructionAttachmentSource(
            contentIdentity: contentIdentity,
            verifiedURL: verifiedURL,
            lifetimeToken: ReconstructionSidecarAttachmentDescriptorToken(
                authority: self,
                contentIdentity: contentIdentity
            )
        )
    }

    fileprivate func openAttachmentDescriptor(
        contentIdentity: ReconstructionContentIdentity
    ) throws -> Int32 {
        let digest = contentIdentity.digest
        let shardName = String(digest.prefix(2))
        guard digest.count == 64,
              digest.allSatisfy({ "0123456789abcdef".contains($0) }),
              shardName.count == 2 else {
            throw ReconstructionSidecarAttachmentAuthorityError.invalidAttachmentIdentity
        }

        lock.lock()
        defer { lock.unlock() }
        let root = try validatedRootDescriptorLocked()
        let shardDescriptor = shardName.withCString {
            Darwin.openat(
                root,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard shardDescriptor >= 0 else {
            throw ReconstructionSidecarAttachmentAuthorityError.invalidAttachmentIdentity
        }
        defer { _ = Darwin.close(shardDescriptor) }

        var shardMetadata = stat()
        guard Darwin.fstat(shardDescriptor, &shardMetadata) == 0,
              UInt32(shardMetadata.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR) else {
            throw ReconstructionSidecarAttachmentAuthorityError.invalidAttachmentIdentity
        }

        let descriptor = digest.withCString {
            Darwin.openat(
                shardDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        var metadata = stat()
        guard descriptor >= 0,
              Darwin.fstat(descriptor, &metadata) == 0,
              UInt32(metadata.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG),
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              UInt64(metadata.st_size) == contentIdentity.byteCount else {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            throw ReconstructionSidecarAttachmentAuthorityError.invalidAttachmentIdentity
        }
        return descriptor
    }

    private func validatedRootDescriptorLocked() throws -> Int32 {
        guard rootDescriptor >= 0 else {
            throw ReconstructionSidecarAttachmentAuthorityError.revoked
        }
        var metadata = stat()
        guard Darwin.fstat(rootDescriptor, &metadata) == 0,
              DirectoryIdentity(metadata) == rootIdentity else {
            throw ReconstructionSidecarAttachmentAuthorityError.invalidDirectoryDescriptor
        }
        return rootDescriptor
    }
}

private final class ReconstructionSidecarAttachmentDescriptorToken:
    ReconstructionAttachmentSourceDescriptorToken,
    @unchecked Sendable
{
    private let authority: ReconstructionSidecarAttachmentAuthority
    private let contentIdentity: ReconstructionContentIdentity

    init(
        authority: ReconstructionSidecarAttachmentAuthority,
        contentIdentity: ReconstructionContentIdentity
    ) {
        self.authority = authority
        self.contentIdentity = contentIdentity
    }

    func openVerifiedDescriptor() throws -> Int32 {
        try authority.openAttachmentDescriptor(contentIdentity: contentIdentity)
    }
}

private final class SidecarDirectoryLease: @unchecked Sendable {
    private struct StableEntryIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let type: UInt32

        init(_ metadata: stat) {
            device = UInt64(truncatingIfNeeded: metadata.st_dev)
            inode = UInt64(truncatingIfNeeded: metadata.st_ino)
            type = UInt32(metadata.st_mode) & UInt32(S_IFMT)
        }
    }

    let directoryURL: URL
    private let storageRootURL: URL
    private let rootDescriptor: Int32
    private let parentDescriptor: Int32
    private let directoryDescriptor: Int32
    private let rootDevice: UInt64
    private let rootInode: UInt64
    private let workspaceName: String
    private let workspaceDevice: UInt64
    private let workspaceInode: UInt64
    private let directoryName: String
    private let directoryDevice: UInt64
    private let directoryInode: UInt64
    private let lock = NSLock()
    private var discarded = false
    private var stableEntryIdentities: [String: StableEntryIdentity] = [:]

    private init(
        directoryURL: URL,
        storageRootURL: URL,
        rootDescriptor: Int32,
        parentDescriptor: Int32,
        directoryDescriptor: Int32,
        rootMetadata: stat,
        workspaceName: String,
        workspaceMetadata: stat,
        directoryName: String,
        directoryMetadata: stat
    ) {
        self.directoryURL = directoryURL
        self.storageRootURL = storageRootURL
        self.rootDescriptor = rootDescriptor
        self.parentDescriptor = parentDescriptor
        self.directoryDescriptor = directoryDescriptor
        rootDevice = UInt64(truncatingIfNeeded: rootMetadata.st_dev)
        rootInode = UInt64(truncatingIfNeeded: rootMetadata.st_ino)
        self.workspaceName = workspaceName
        workspaceDevice = UInt64(truncatingIfNeeded: workspaceMetadata.st_dev)
        workspaceInode = UInt64(truncatingIfNeeded: workspaceMetadata.st_ino)
        self.directoryName = directoryName
        directoryDevice = UInt64(truncatingIfNeeded: directoryMetadata.st_dev)
        directoryInode = UInt64(truncatingIfNeeded: directoryMetadata.st_ino)
    }

    deinit {
        _ = Darwin.close(directoryDescriptor)
        _ = Darwin.close(parentDescriptor)
        _ = Darwin.close(rootDescriptor)
    }

    static func openOrCreate(
        storageRootURL: URL,
        workspaceID: UUID,
        documentID: UUID,
        rootIsRuntimeOwned: Bool
    ) throws -> SidecarDirectoryLease {
        let rootDescriptor = try openDirectory(storageRootURL)
        if rootIsRuntimeOwned {
            guard Darwin.fchmod(rootDescriptor, 0o700) == 0 else {
                _ = Darwin.close(rootDescriptor)
                throw ReconstructionWorkspaceDatabaseRuntimeError
                    .unsafeFilesystemEntry(storageRootURL.path)
            }
        }
        let workspaceName = workspaceID.uuidString.lowercased()
        let workspaceURL = storageRootURL.appendingPathComponent(
            workspaceName,
            isDirectory: true
        )
        let workspaceDescriptor: Int32
        do {
            workspaceDescriptor = try openOrCreateDirectory(
                named: workspaceName,
                in: rootDescriptor,
                url: workspaceURL
            )
        } catch {
            _ = Darwin.close(rootDescriptor)
            throw error
        }

        let documentName = documentID.uuidString.lowercased()
        let documentURL = workspaceURL.appendingPathComponent(
            documentName,
            isDirectory: true
        )
        let documentDescriptor: Int32
        do {
            documentDescriptor = try openOrCreateDirectory(
                named: documentName,
                in: workspaceDescriptor,
                url: documentURL
            )
        } catch {
            _ = Darwin.close(workspaceDescriptor)
            _ = Darwin.close(rootDescriptor)
            throw error
        }
        var rootMetadata = stat()
        var workspaceMetadata = stat()
        var directoryMetadata = stat()
        guard Darwin.fstat(rootDescriptor, &rootMetadata) == 0,
              Darwin.fstat(workspaceDescriptor, &workspaceMetadata) == 0,
              Darwin.fstat(documentDescriptor, &directoryMetadata) == 0 else {
            _ = Darwin.close(documentDescriptor)
            _ = Darwin.close(workspaceDescriptor)
            _ = Darwin.close(rootDescriptor)
            throw ReconstructionWorkspaceDatabaseRuntimeError
                .unsafeFilesystemEntry(documentURL.path)
        }
        return SidecarDirectoryLease(
            directoryURL: documentURL,
            storageRootURL: storageRootURL,
            rootDescriptor: rootDescriptor,
            parentDescriptor: workspaceDescriptor,
            directoryDescriptor: documentDescriptor,
            rootMetadata: rootMetadata,
            workspaceName: workspaceName,
            workspaceMetadata: workspaceMetadata,
            directoryName: documentName,
            directoryMetadata: directoryMetadata
        )
    }

    /// Re-proves that the absolute pathname passed to SQLite and the attachment vault still names
    /// the complete descriptor-qualified root/workspace/document chain. This closes the
    /// validation/use split for pathname-only APIs and detects rename/replacement before and after
    /// each such operation.
    func validatePathIdentity() throws {
        var observedRoot = stat()
        let rootStatus = storageRootURL.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &observedRoot) } ?? -1
        }
        var observedWorkspace = stat()
        let workspaceStatus = workspaceName.withCString {
            Darwin.fstatat(rootDescriptor, $0, &observedWorkspace, AT_SYMLINK_NOFOLLOW)
        }
        var observedDirectory = stat()
        let directoryStatus = directoryName.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &observedDirectory,
                AT_SYMLINK_NOFOLLOW
            )
        }
        guard rootStatus == 0,
              UInt32(observedRoot.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR),
              UInt64(truncatingIfNeeded: observedRoot.st_dev) == rootDevice,
              UInt64(truncatingIfNeeded: observedRoot.st_ino) == rootInode,
              workspaceStatus == 0,
              UInt32(observedWorkspace.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR),
              UInt64(truncatingIfNeeded: observedWorkspace.st_dev) == workspaceDevice,
              UInt64(truncatingIfNeeded: observedWorkspace.st_ino) == workspaceInode,
              directoryStatus == 0,
              UInt32(observedDirectory.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR),
              UInt64(truncatingIfNeeded: observedDirectory.st_dev) == directoryDevice,
              UInt64(truncatingIfNeeded: observedDirectory.st_ino) == directoryInode else {
            throw ReconstructionWorkspaceDatabaseRuntimeError
                .unsafeFilesystemEntry(directoryURL.path)
        }
    }

    func prepareOrdinaryDatabaseFile(named name: String) throws {
        var metadata = stat()
        let status = name.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if status == 0 {
            guard UInt32(metadata.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG),
                  metadata.st_nlink == 1 else {
                throw ReconstructionWorkspaceDatabaseRuntimeError
                    .unsafeFilesystemEntry(directoryURL.appendingPathComponent(name).path)
            }
            try pinStableEntry(named: name, metadata: metadata)
            return
        }
        guard errno == ENOENT else {
            throw ReconstructionWorkspaceDatabaseRuntimeError
                .unsafeFilesystemEntry(directoryURL.appendingPathComponent(name).path)
        }
        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                0o600
            )
        }
        guard descriptor >= 0 else {
            throw ReconstructionWorkspaceDatabaseRuntimeError
                .unsafeFilesystemEntry(directoryURL.appendingPathComponent(name).path)
        }
        _ = Darwin.close(descriptor)
        guard name.withCString({
            Darwin.fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }) == 0,
        UInt32(metadata.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG),
        metadata.st_nlink == 1 else {
            throw ReconstructionWorkspaceDatabaseRuntimeError
                .unsafeFilesystemEntry(directoryURL.appendingPathComponent(name).path)
        }
        try pinStableEntry(named: name, metadata: metadata)
    }

    func prepareOrdinaryDirectory(named name: String) throws {
        let url = directoryURL.appendingPathComponent(name, isDirectory: true)
        let descriptor = try Self.openOrCreateDirectory(
            named: name,
            in: directoryDescriptor,
            url: url
        )
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw ReconstructionWorkspaceDatabaseRuntimeError.unsafeFilesystemEntry(url.path)
        }
        try pinStableEntry(named: name, metadata: metadata)
    }

    /// Opens the exact directory inode already pinned by `prepareOrdinaryDirectory`. The caller
    /// owns the returned descriptor. Consumers that outlive the call must duplicate it rather
    /// than falling back to the mutable absolute pathname.
    func openPinnedDirectoryDescriptor(named name: String) throws -> Int32 {
        lock.lock()
        let expected = stableEntryIdentities[name]
        lock.unlock()
        guard let expected, expected.type == UInt32(S_IFDIR) else {
            throw ReconstructionWorkspaceDatabaseRuntimeError
                .unsafeFilesystemEntry(directoryURL.appendingPathComponent(name).path)
        }

        let descriptor = name.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        var metadata = stat()
        guard descriptor >= 0,
              Darwin.fstat(descriptor, &metadata) == 0,
              StableEntryIdentity(metadata) == expected else {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            throw ReconstructionWorkspaceDatabaseRuntimeError
                .unsafeFilesystemEntry(directoryURL.appendingPathComponent(name).path)
        }
        return descriptor
    }

    func validateKnownEntries(
        databaseFileName: String,
        vaultDirectoryName: String
    ) throws {
        try validateStableEntry(
            named: databaseFileName,
            expectedType: UInt32(S_IFREG)
        )
        try validateEntryIfPresent(
            named: databaseFileName + "-journal",
            expectedType: UInt32(S_IFREG)
        )
        try validateEntryIfPresent(named: databaseFileName + "-wal", expectedType: UInt32(S_IFREG))
        try validateEntryIfPresent(named: databaseFileName + "-shm", expectedType: UInt32(S_IFREG))
        try validateStableEntryIfPresent(
            named: vaultDirectoryName,
            expectedType: UInt32(S_IFDIR)
        )
    }

    func discard() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !discarded else { return }
        try validatePathIdentity()
        let cleanup: ReconstructionAttachmentLifetime
        do {
            cleanup = try ReconstructionAttachmentLifetime(
                owning: directoryURL,
                creatorDescriptor: directoryDescriptor,
                parentDescriptor: parentDescriptor,
                removingDirectoryContents: true
            )
        } catch {
            throw ReconstructionWorkspaceDatabaseRuntimeError.discardFailed
        }
        cleanup.discard()

        var removedPathMetadata = stat()
        let removedPathStatus = directoryName.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &removedPathMetadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        let removedPathErrno = errno
        var retainedMetadata = stat()
        guard removedPathStatus == -1,
              removedPathErrno == ENOENT,
              Darwin.fstat(directoryDescriptor, &retainedMetadata) == 0,
              UInt32(retainedMetadata.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR),
              UInt64(truncatingIfNeeded: retainedMetadata.st_dev) == directoryDevice,
              UInt64(truncatingIfNeeded: retainedMetadata.st_ino) == directoryInode else {
            throw ReconstructionWorkspaceDatabaseRuntimeError.discardFailed
        }
        discarded = true
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        var expectedMetadata = stat()
        guard url.withUnsafeFileSystemRepresentation({ path in
            path.map { Darwin.lstat($0, &expectedMetadata) } ?? -1
        }) == 0,
        UInt32(expectedMetadata.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR) else {
            throw ReconstructionWorkspaceDatabaseRuntimeError
                .unsafeFilesystemEntry(url.path)
        }
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            } ?? -1
        }
        var openedMetadata = stat()
        guard descriptor >= 0,
              Darwin.fstat(descriptor, &openedMetadata) == 0,
              UInt32(openedMetadata.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR),
              openedMetadata.st_dev == expectedMetadata.st_dev,
              openedMetadata.st_ino == expectedMetadata.st_ino else {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            throw ReconstructionWorkspaceDatabaseRuntimeError
                .unsafeFilesystemEntry(url.path)
        }
        return descriptor
    }

    private static func openOrCreateDirectory(
        named name: String,
        in parentDescriptor: Int32,
        url: URL
    ) throws -> Int32 {
        var metadata = stat()
        var wasCreated = false
        let initialStatus = name.withCString {
            Darwin.fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if initialStatus != 0 {
            guard errno == ENOENT else {
                throw ReconstructionWorkspaceDatabaseRuntimeError
                    .unsafeFilesystemEntry(url.path)
            }
            let creationStatus = name.withCString {
                Darwin.mkdirat(parentDescriptor, $0, 0o700)
            }
            guard creationStatus == 0 || errno == EEXIST else {
                throw ReconstructionWorkspaceDatabaseRuntimeError
                    .unsafeFilesystemEntry(url.path)
            }
            wasCreated = creationStatus == 0
            guard name.withCString({
                Darwin.fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }) == 0 else {
                throw ReconstructionWorkspaceDatabaseRuntimeError
                    .unsafeFilesystemEntry(url.path)
            }
        }
        guard UInt32(metadata.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR),
              wasCreated || UInt32(metadata.st_mode) & 0o7777 == 0o700 else {
            throw ReconstructionWorkspaceDatabaseRuntimeError.unsafeFilesystemEntry(url.path)
        }

        let expectedDevice = metadata.st_dev
        let expectedInode = metadata.st_ino
        let descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0,
              Darwin.fstat(descriptor, &metadata) == 0,
              UInt32(metadata.st_mode) & UInt32(S_IFMT) == UInt32(S_IFDIR),
              metadata.st_dev == expectedDevice,
              metadata.st_ino == expectedInode else {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            throw ReconstructionWorkspaceDatabaseRuntimeError.unsafeFilesystemEntry(url.path)
        }
        if wasCreated {
            guard Darwin.fchmod(descriptor, 0o700) == 0 else {
                _ = Darwin.close(descriptor)
                throw ReconstructionWorkspaceDatabaseRuntimeError
                    .unsafeFilesystemEntry(url.path)
            }
        } else {
            guard UInt32(metadata.st_mode) & 0o7777 == 0o700 else {
                _ = Darwin.close(descriptor)
                throw ReconstructionWorkspaceDatabaseRuntimeError
                    .unsafeFilesystemEntry(url.path)
            }
        }
        return descriptor
    }

    private func validateEntryIfPresent(named name: String, expectedType: UInt32) throws {
        var metadata = stat()
        let status = name.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if status != 0 {
            guard errno == ENOENT else {
                throw ReconstructionWorkspaceDatabaseRuntimeError
                    .unsafeFilesystemEntry(directoryURL.appendingPathComponent(name).path)
            }
            return
        }
        guard UInt32(metadata.st_mode) & UInt32(S_IFMT) == expectedType,
              expectedType != UInt32(S_IFREG) || metadata.st_nlink == 1 else {
            throw ReconstructionWorkspaceDatabaseRuntimeError
                .unsafeFilesystemEntry(directoryURL.appendingPathComponent(name).path)
        }
    }

    private func pinStableEntry(named name: String, metadata: stat) throws {
        let observed = StableEntryIdentity(metadata)
        lock.lock()
        defer { lock.unlock() }
        if let expected = stableEntryIdentities[name] {
            guard observed == expected else {
                throw ReconstructionWorkspaceDatabaseRuntimeError
                    .unsafeFilesystemEntry(directoryURL.appendingPathComponent(name).path)
            }
        } else {
            stableEntryIdentities[name] = observed
        }
    }

    private func validateStableEntry(named name: String, expectedType: UInt32) throws {
        var metadata = stat()
        let status = name.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0,
              UInt32(metadata.st_mode) & UInt32(S_IFMT) == expectedType,
              expectedType != UInt32(S_IFREG) || metadata.st_nlink == 1 else {
            throw ReconstructionWorkspaceDatabaseRuntimeError
                .unsafeFilesystemEntry(directoryURL.appendingPathComponent(name).path)
        }
        try pinStableEntry(named: name, metadata: metadata)
    }

    private func validateStableEntryIfPresent(named name: String, expectedType: UInt32) throws {
        var metadata = stat()
        let status = name.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if status != 0 {
            guard errno == ENOENT else {
                throw ReconstructionWorkspaceDatabaseRuntimeError
                    .unsafeFilesystemEntry(directoryURL.appendingPathComponent(name).path)
            }
            lock.lock()
            let wasPinned = stableEntryIdentities[name] != nil
            lock.unlock()
            guard !wasPinned else {
                throw ReconstructionWorkspaceDatabaseRuntimeError
                    .unsafeFilesystemEntry(directoryURL.appendingPathComponent(name).path)
            }
            return
        }
        guard UInt32(metadata.st_mode) & UInt32(S_IFMT) == expectedType,
              expectedType != UInt32(S_IFREG) || metadata.st_nlink == 1 else {
            throw ReconstructionWorkspaceDatabaseRuntimeError
                .unsafeFilesystemEntry(directoryURL.appendingPathComponent(name).path)
        }
        try pinStableEntry(named: name, metadata: metadata)
    }
}

/// Process-local exclusivity for one identity-qualified sidecar. The filesystem descriptor lease
/// prevents path substitution; this registry prevents two app runtimes from becoming concurrent
/// mutation authorities for the same workspace/document pair.
private final class SidecarRuntimeIdentityRegistry: @unchecked Sendable {
    static let shared = SidecarRuntimeIdentityRegistry()

    private let lock = NSLock()
    private var claims: [String: UUID] = [:]

    func claim(_ key: String) throws -> SidecarRuntimeIdentityClaim {
        lock.lock()
        defer { lock.unlock() }
        guard claims[key] == nil else {
            throw ReconstructionWorkspaceDatabaseRuntimeError.identityAlreadyOpen
        }
        let token = UUID()
        claims[key] = token
        return SidecarRuntimeIdentityClaim(registry: self, key: key, token: token)
    }

    fileprivate func release(key: String, token: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard claims[key] == token else { return }
        claims[key] = nil
    }
}

private final class SidecarRuntimeIdentityClaim: @unchecked Sendable {
    private weak var registry: SidecarRuntimeIdentityRegistry?
    private let key: String
    private let token: UUID
    private let lock = NSLock()
    private var isReleased = false

    init(registry: SidecarRuntimeIdentityRegistry, key: String, token: UUID) {
        self.registry = registry
        self.key = key
        self.token = token
    }

    deinit {
        release()
    }

    func release() {
        lock.lock()
        guard !isReleased else {
            lock.unlock()
            return
        }
        isReleased = true
        let registry = registry
        lock.unlock()
        registry?.release(key: key, token: token)
    }
}
