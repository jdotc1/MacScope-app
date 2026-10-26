import CryptoKit
import Darwin
import Foundation

enum ReconstructionAttachmentCatalogError: Error {
    case changedDuringImport
    case emptyContent
    case invalidDescriptor
    case contentTooLarge
    case ioFailure
}

actor ReconstructionAttachmentCatalog {
    struct CataloguedContent: Sendable {
        let source: ReconstructionAttachmentSource
        let stableMode: UInt32
        let stableDevice: UInt64?
        let stableInode: UInt64?
    }

    struct Checkpoint: Sendable {
        fileprivate let retainedIdentities: Set<ReconstructionContentIdentity>
    }

    /// Deterministic race interposition used only by the in-process test target.
    struct TestHooks: Sendable {
        let beforeAttachmentInstall: (@Sendable (URL, ReconstructionContentIdentity) throws -> Void)?
        let beforeRollbackRemoval: (@Sendable (ReconstructionAttachmentSource) -> Void)?

        init(
            beforeAttachmentInstall: (@Sendable (
                URL,
                ReconstructionContentIdentity
            ) throws -> Void)? = nil,
            beforeRollbackRemoval: (@Sendable (
                ReconstructionAttachmentSource
            ) -> Void)? = nil
        ) {
            self.beforeAttachmentInstall = beforeAttachmentInstall
            self.beforeRollbackRemoval = beforeRollbackRemoval
        }
    }

    private struct StableMetadata: Equatable {
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

    private struct StagingFile {
        let name: String
        let url: URL
        let descriptor: Int32
        let lifetime: ReconstructionAttachmentLifetime
    }

    private struct Shard {
        let name: String
        let url: URL
        let descriptor: Int32
        let creationIdentity: ReconstructionAttachmentLifetime.CreationIdentity
        let lifetime: ReconstructionAttachmentLifetime
    }

    private struct CatalogEntry {
        let source: ReconstructionAttachmentSource
        let shardName: String
        let creationIdentity: ReconstructionAttachmentLifetime.CreationIdentity
        let lifetime: ReconstructionAttachmentLifetime
    }

    private let rootURL: URL
    private let rootName: String
    private let rootParentDescriptor: Int32
    private let rootDescriptor: Int32
    private let rootCreationIdentity: ReconstructionAttachmentLifetime.CreationIdentity
    private let rootLifetime: ReconstructionAttachmentLifetime
    private let testHooks: TestHooks
    private var entriesByIdentity: [ReconstructionContentIdentity: CatalogEntry] = [:]
    private var shardsByName: [String: Shard] = [:]
    private var discarded = false

    init(testHooks: TestHooks = .init()) throws {
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory.standardizedFileURL
        let temporaryDirectoryDescriptor = temporaryDirectoryURL.withUnsafeFileSystemRepresentation {
            path in
            path.map {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            } ?? -1
        }
        guard temporaryDirectoryDescriptor >= 0 else {
            throw ReconstructionAttachmentCatalogError.ioFailure
        }
        defer { _ = Darwin.close(temporaryDirectoryDescriptor) }

        var createdName: String?
        for _ in 0..<8 {
            let candidate = "MacScope-ReconstructionImport.\(UUID().uuidString)"
            let status = candidate.withCString {
                Darwin.mkdirat(temporaryDirectoryDescriptor, $0, 0o700)
            }
            if status == 0 {
                createdName = candidate
                break
            }
            if errno != EEXIST { break }
        }
        guard let rootName = createdName else {
            throw ReconstructionAttachmentCatalogError.ioFailure
        }
        let createdURL = temporaryDirectoryURL.appendingPathComponent(rootName, isDirectory: true)
        let createdDescriptor = rootName.withCString {
            Darwin.openat(
                temporaryDirectoryDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard createdDescriptor >= 0 else {
            // No pathname cleanup is attempted without a retained creator descriptor. A failed
            // initialization leaves the private, empty directory as a harmless orphan.
            throw ReconstructionAttachmentCatalogError.ioFailure
        }
        let retainedParentDescriptor = Darwin.fcntl(
            temporaryDirectoryDescriptor,
            F_DUPFD_CLOEXEC,
            0
        )
        guard retainedParentDescriptor >= 0 else {
            _ = Darwin.close(createdDescriptor)
            throw ReconstructionAttachmentCatalogError.ioFailure
        }
        let creationIdentity: ReconstructionAttachmentLifetime.CreationIdentity
        do {
            creationIdentity = try ReconstructionAttachmentLifetime.CreationIdentity(
                descriptor: createdDescriptor
            )
        } catch {
            _ = Darwin.close(retainedParentDescriptor)
            _ = Darwin.close(createdDescriptor)
            throw ReconstructionAttachmentCatalogError.ioFailure
        }
        let lifetime: ReconstructionAttachmentLifetime
        do {
            lifetime = try ReconstructionAttachmentLifetime(
                owning: createdURL,
                creatorDescriptor: createdDescriptor,
                parentDescriptor: temporaryDirectoryDescriptor,
                removingDirectoryContents: false
            )
        } catch {
            _ = Darwin.close(retainedParentDescriptor)
            _ = Darwin.close(createdDescriptor)
            throw ReconstructionAttachmentCatalogError.ioFailure
        }

        self.rootURL = createdURL
        self.rootName = rootName
        rootParentDescriptor = retainedParentDescriptor
        rootDescriptor = createdDescriptor
        rootCreationIdentity = creationIdentity
        rootLifetime = lifetime
        self.testHooks = testHooks
    }

    deinit {
        for shard in shardsByName.values {
            _ = Darwin.close(shard.descriptor)
        }
        _ = Darwin.close(rootDescriptor)
        _ = Darwin.close(rootParentDescriptor)
    }

    func checkpoint() -> Checkpoint {
        Checkpoint(retainedIdentities: Set(entriesByIdentity.keys))
    }

    func rollback(to checkpoint: Checkpoint) {
        let unpublished = Set(entriesByIdentity.keys).subtracting(checkpoint.retainedIdentities)
        for identity in unpublished {
            guard let entry = entriesByIdentity.removeValue(forKey: identity) else { continue }
            testHooks.beforeRollbackRemoval?(entry.source)
            entry.lifetime.discard()
            pruneShardIfUnused(entry.shardName)
        }
    }

    func catalogRegularFile(
        descriptor: Int32,
        maximumByteCount: UInt64,
        cancellation: ReconstructionCancellation,
        afterInitialMetadata: (@Sendable () async throws -> Void)? = nil
    ) async throws -> CataloguedContent {
        try cancellation.check()
        var beforeState = stat()
        guard Darwin.fstat(descriptor, &beforeState) == 0,
              (beforeState.st_mode & S_IFMT) == S_IFREG,
              beforeState.st_size >= 0 else {
            throw ReconstructionAttachmentCatalogError.invalidDescriptor
        }
        guard UInt64(beforeState.st_size) <= maximumByteCount else {
            throw ReconstructionAttachmentCatalogError.contentTooLarge
        }
        let before = StableMetadata(beforeState)
        try await afterInitialMetadata?()
        try cancellation.check()

        let staging = try makeStagingFile()
        defer {
            _ = Darwin.close(staging.descriptor)
            staging.lifetime.discard()
        }

        var hasher = SHA256()
        var byteCount: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try cancellation.check()
            let remainingBeforeLimit = maximumByteCount - byteCount
            let remainingWithSentinel = remainingBeforeLimit == UInt64.max
                ? UInt64.max
                : remainingBeforeLimit + 1
            let requestedByteCount = min(
                buffer.count,
                Int(min(UInt64(buffer.count), remainingWithSentinel))
            )
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, requestedByteCount)
            }
            if count > 0 {
                byteCount += UInt64(count)
                guard byteCount <= maximumByteCount else {
                    throw ReconstructionAttachmentCatalogError.contentTooLarge
                }
                let chunk = Data(buffer.prefix(Int(count)))
                hasher.update(data: chunk)
                try writeAll(chunk, to: staging.descriptor)
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            throw ReconstructionAttachmentCatalogError.ioFailure
        }

        var afterState = stat()
        guard Darwin.fstat(descriptor, &afterState) == 0 else {
            throw ReconstructionAttachmentCatalogError.ioFailure
        }
        guard StableMetadata(afterState) == before,
              byteCount == UInt64(afterState.st_size) else {
            throw ReconstructionAttachmentCatalogError.changedDuringImport
        }
        guard byteCount > 0 else {
            throw ReconstructionAttachmentCatalogError.emptyContent
        }
        try finalize(staging)

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let identity = try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: digest,
            byteCount: byteCount
        )
        if let existing = try verifiedExistingEntry(for: identity) {
            return CataloguedContent(
                source: existing.source,
                stableMode: UInt32(afterState.st_mode),
                stableDevice: UInt64(truncatingIfNeeded: afterState.st_dev),
                stableInode: UInt64(truncatingIfNeeded: afterState.st_ino)
            )
        }

        let entry = try install(staging: staging, identity: identity)
        entriesByIdentity[identity] = entry
        return CataloguedContent(
            source: entry.source,
            stableMode: UInt32(afterState.st_mode),
            stableDevice: UInt64(truncatingIfNeeded: afterState.st_dev),
            stableInode: UInt64(truncatingIfNeeded: afterState.st_ino)
        )
    }

    func catalogBytes(
        _ data: Data,
        maximumByteCount: UInt64,
        cancellation: ReconstructionCancellation
    ) throws -> CataloguedContent {
        try cancellation.check()
        guard !data.isEmpty else { throw ReconstructionAttachmentCatalogError.emptyContent }
        guard UInt64(data.count) <= maximumByteCount else {
            throw ReconstructionAttachmentCatalogError.contentTooLarge
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let identity = try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: digest,
            byteCount: UInt64(data.count)
        )
        if let existing = try verifiedExistingEntry(for: identity) {
            return CataloguedContent(
                source: existing.source,
                stableMode: 0,
                stableDevice: nil,
                stableInode: nil
            )
        }

        let staging = try makeStagingFile()
        defer {
            _ = Darwin.close(staging.descriptor)
            staging.lifetime.discard()
        }
        try writeAll(data, to: staging.descriptor)
        try finalize(staging)
        let entry = try install(staging: staging, identity: identity)
        entriesByIdentity[identity] = entry
        return CataloguedContent(
            source: entry.source,
            stableMode: 0,
            stableDevice: nil,
            stableInode: nil
        )
    }

    func discardAll() {
        guard !discarded else { return }
        discarded = true
        let entries = Array(entriesByIdentity.values)
        entriesByIdentity.removeAll()
        for entry in entries {
            entry.lifetime.discard()
        }
        let shards = Array(shardsByName.values)
        shardsByName.removeAll()
        for shard in shards {
            _ = Darwin.close(shard.descriptor)
            shard.lifetime.discard()
        }
        rootLifetime.discard()
    }

    private func makeStagingFile() throws -> StagingFile {
        guard !discarded else { throw ReconstructionAttachmentCatalogError.ioFailure }
        let name = "staging-\(UUID().uuidString)"
        let descriptor = name.withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                0o600
            )
        }
        guard descriptor >= 0 else {
            throw ReconstructionAttachmentCatalogError.ioFailure
        }
        let url = rootURL.appendingPathComponent(name)
        let lifetime: ReconstructionAttachmentLifetime
        do {
            lifetime = try ReconstructionAttachmentLifetime(
                owning: url,
                creatorDescriptor: descriptor,
                parentDescriptor: rootDescriptor,
                retaining: rootLifetime
            )
        } catch {
            _ = Darwin.close(descriptor)
            // Descriptor duplication failed; preserving the private staging inode is safer than
            // deleting a mutable name without an identity-bound lease.
            throw ReconstructionAttachmentCatalogError.ioFailure
        }
        return StagingFile(name: name, url: url, descriptor: descriptor, lifetime: lifetime)
    }

    private func finalize(_ staging: StagingFile) throws {
        guard Darwin.fsync(staging.descriptor) == 0,
              Darwin.fchmod(staging.descriptor, 0o400) == 0 else {
            throw ReconstructionAttachmentCatalogError.ioFailure
        }
    }

    private func install(
        staging: StagingFile,
        identity: ReconstructionContentIdentity
    ) throws -> CatalogEntry {
        try testHooks.beforeAttachmentInstall?(rootURL, identity)
        let shardName = String(identity.digest.prefix(2))
        let shard = try ensureShard(named: shardName)
        guard catalogRootStillNamesCreatorObject(),
              self.identity(named: shard.name, in: rootDescriptor) == shard.creationIdentity else {
            pruneShardIfUnused(shardName)
            throw ReconstructionAttachmentCatalogError.ioFailure
        }
        let finalURL = shard.url.appendingPathComponent(identity.digest)
        let creatorIdentity: ReconstructionAttachmentLifetime.CreationIdentity
        do {
            creatorIdentity = try ReconstructionAttachmentLifetime.CreationIdentity(
                descriptor: staging.descriptor
            )
        } catch {
            pruneShardIfUnused(shardName)
            throw ReconstructionAttachmentCatalogError.ioFailure
        }
        let installedLifetime: ReconstructionAttachmentLifetime
        do {
            installedLifetime = try ReconstructionAttachmentLifetime(
                owning: finalURL,
                creatorDescriptor: staging.descriptor,
                parentDescriptor: shard.descriptor,
                retaining: shard.lifetime
            )
        } catch {
            pruneShardIfUnused(shardName)
            throw ReconstructionAttachmentCatalogError.ioFailure
        }

        let renameStatus = staging.name.withCString { sourceName in
            identity.digest.withCString { destinationName in
                Darwin.renameatx_np(
                    rootDescriptor,
                    sourceName,
                    shard.descriptor,
                    destinationName,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard renameStatus == 0 else {
            installedLifetime.relinquishWithoutCleanup()
            pruneShardIfUnused(shardName)
            throw ReconstructionAttachmentCatalogError.ioFailure
        }
        staging.lifetime.relinquishWithoutCleanup()
        guard catalogRootStillNamesCreatorObject(),
              self.identity(named: shard.name, in: rootDescriptor) == shard.creationIdentity,
              self.identity(named: identity.digest, in: shard.descriptor) == creatorIdentity else {
            installedLifetime.discard()
            pruneShardIfUnused(shardName)
            throw ReconstructionAttachmentCatalogError.ioFailure
        }

        let source = ReconstructionAttachmentSource(
            contentIdentity: identity,
            verifiedURL: finalURL,
            lifetimeToken: installedLifetime
        )
        return CatalogEntry(
            source: source,
            shardName: shardName,
            creationIdentity: creatorIdentity,
            lifetime: installedLifetime
        )
    }

    private func ensureShard(named name: String) throws -> Shard {
        if let existing = shardsByName[name] {
            return existing
        }
        let mkdirStatus = name.withCString {
            Darwin.mkdirat(rootDescriptor, $0, 0o700)
        }
        guard mkdirStatus == 0 else {
            // Never adopt an entry discovered by mutable path, including a symlink or a directory
            // planted between digest calculation and installation.
            throw ReconstructionAttachmentCatalogError.ioFailure
        }
        let descriptor = name.withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw ReconstructionAttachmentCatalogError.ioFailure
        }
        let url = rootURL.appendingPathComponent(name, isDirectory: true)
        let lifetime: ReconstructionAttachmentLifetime
        let creationIdentity: ReconstructionAttachmentLifetime.CreationIdentity
        do {
            creationIdentity = try ReconstructionAttachmentLifetime.CreationIdentity(
                descriptor: descriptor
            )
            lifetime = try ReconstructionAttachmentLifetime(
                owning: url,
                creatorDescriptor: descriptor,
                parentDescriptor: rootDescriptor,
                retaining: rootLifetime,
                removingDirectoryContents: false
            )
        } catch {
            _ = Darwin.close(descriptor)
            throw ReconstructionAttachmentCatalogError.ioFailure
        }
        let shard = Shard(
            name: name,
            url: url,
            descriptor: descriptor,
            creationIdentity: creationIdentity,
            lifetime: lifetime
        )
        shardsByName[name] = shard
        return shard
    }

    private func pruneShardIfUnused(_ shardName: String) {
        guard !entriesByIdentity.values.contains(where: { $0.shardName == shardName }),
              let shard = shardsByName.removeValue(forKey: shardName) else {
            return
        }
        _ = Darwin.close(shard.descriptor)
        shard.lifetime.discard()
    }

    private func verifiedExistingEntry(
        for contentIdentity: ReconstructionContentIdentity
    ) throws -> CatalogEntry? {
        guard let entry = entriesByIdentity[contentIdentity] else { return nil }
        guard let shard = shardsByName[entry.shardName],
              catalogRootStillNamesCreatorObject(),
              identity(named: shard.name, in: rootDescriptor) == shard.creationIdentity,
              identity(named: contentIdentity.digest, in: shard.descriptor)
                == entry.creationIdentity else {
            throw ReconstructionAttachmentCatalogError.ioFailure
        }
        return entry
    }

    private func catalogRootStillNamesCreatorObject() -> Bool {
        identity(named: rootName, in: rootParentDescriptor) == rootCreationIdentity
    }

    private func identity(
        named name: String,
        in parentDescriptor: Int32
    ) -> ReconstructionAttachmentLifetime.CreationIdentity? {
        var metadata = stat()
        let status = name.withCString {
            Darwin.fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else { return nil }
        return ReconstructionAttachmentLifetime.CreationIdentity(metadata: metadata)
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                throw ReconstructionAttachmentCatalogError.ioFailure
            }
        }
    }
}
