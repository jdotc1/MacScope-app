import CryptoKit
import Darwin
import Foundation
import SQLite3

private enum ReconstructionAttachmentDescriptorReader {
    private struct StableMetadata: Equatable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let linkCount: UInt64
        let byteCount: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ metadata: stat) {
            device = UInt64(truncatingIfNeeded: metadata.st_dev)
            inode = UInt64(truncatingIfNeeded: metadata.st_ino)
            mode = UInt32(metadata.st_mode)
            linkCount = UInt64(truncatingIfNeeded: metadata.st_nlink)
            byteCount = metadata.st_size
            modifiedSeconds = Int64(metadata.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(metadata.st_mtimespec.tv_nsec)
            changedSeconds = Int64(metadata.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(metadata.st_ctimespec.tv_nsec)
        }

        var isRegularFile: Bool {
            mode & UInt32(S_IFMT) == UInt32(S_IFREG)
        }
    }

    static func validate(_ source: ReconstructionAttachmentSource) throws {
        try consume(source) { _ in }
    }

    static func consume(
        _ source: ReconstructionAttachmentSource,
        chunk: (Data) throws -> Void
    ) throws {
        try Task.checkCancellation()
        guard source.verifiedURL.isFileURL else {
            throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
        }
        let descriptor: Int32
        do {
            descriptor = try source.openVerifiedDescriptor()
        } catch {
            throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
        }
        guard descriptor >= 0 else {
            throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
        }
        defer { _ = Darwin.close(descriptor) }

        var initialMetadata = stat()
        guard Darwin.fstat(descriptor, &initialMetadata) == 0 else {
            throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
        }
        let initial = StableMetadata(initialMetadata)
        guard initial.isRegularFile,
              initial.linkCount == 1,
              initial.byteCount >= 0,
              UInt64(initial.byteCount) == source.contentIdentity.byteCount else {
            throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
        }

        var hasher = SHA256()
        var consumedByteCount: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                let (nextByteCount, overflow) = consumedByteCount.addingReportingOverflow(
                    UInt64(count)
                )
                guard !overflow,
                      nextByteCount <= source.contentIdentity.byteCount else {
                    throw WorkspaceDatabase.DatabaseError
                        .reconstructionAttachmentSourcesUnavailable
                }
                let data = Data(buffer.prefix(Int(count)))
                hasher.update(data: data)
                try chunk(data)
                consumedByteCount = nextByteCount
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
        }
        try Task.checkCancellation()

        var finalMetadata = stat()
        guard Darwin.fstat(descriptor, &finalMetadata) == 0,
              StableMetadata(finalMetadata) == initial else {
            throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard consumedByteCount == source.contentIdentity.byteCount,
              digest == source.contentIdentity.digest else {
            throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
        }
    }
}

final class ReconstructionDurableAttachmentVault {
    private let rootURL: URL
    private let attachmentAuthority: ReconstructionSidecarAttachmentAuthority?

    init(
        rootURL: URL,
        attachmentAuthority: ReconstructionSidecarAttachmentAuthority? = nil
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.attachmentAuthority = attachmentAuthority
    }

    func publish(
        _ suppliedSources: [ReconstructionAttachmentSource],
        for manifest: ReconstructionCorpusManifest
    ) throws -> [ReconstructionAttachmentSource] {
        try Task.checkCancellation()
        var expectedByDigest: [String: ReconstructionContentIdentity] = [:]
        for occurrence in manifest.artifacts {
            let identity = occurrence.contentIdentity
            if let existing = expectedByDigest[identity.digest], existing != identity {
                throw WorkspaceDatabase.DatabaseError.reconstructionIdentityConflict(
                    "content digest"
                )
            }
            expectedByDigest[identity.digest] = identity
        }

        var suppliedByDigest: [String: ReconstructionAttachmentSource] = [:]
        for source in suppliedSources {
            try Task.checkCancellation()
            guard expectedByDigest[source.contentIdentity.digest] == source.contentIdentity else {
                throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
            }
            if let existing = suppliedByDigest[source.contentIdentity.digest] {
                if source.verifiedURL.absoluteString < existing.verifiedURL.absoluteString {
                    suppliedByDigest[source.contentIdentity.digest] = source
                }
            } else {
                suppliedByDigest[source.contentIdentity.digest] = source
            }
        }
        guard suppliedByDigest.count == expectedByDigest.count else {
            throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
        }

        let rootDescriptor = try openRootDirectory()
        defer { _ = Darwin.close(rootDescriptor) }
        try recoverCrashStageResiduesIfExclusivelyOwned(rootDescriptor: rootDescriptor)
        var durableSources: [ReconstructionAttachmentSource] = []
        durableSources.reserveCapacity(expectedByDigest.count)
        for identity in expectedByDigest.values.sorted(by: { $0.digest < $1.digest }) {
            try Task.checkCancellation()
            guard let supplied = suppliedByDigest[identity.digest] else {
                throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
            }
            durableSources.append(
                try install(
                    supplied,
                    identity: identity,
                    rootDescriptor: rootDescriptor
                )
            )
        }
        return durableSources
    }

    func availableSources(
        for suppliedIdentities: [ReconstructionContentIdentity]
    ) throws -> [ReconstructionAttachmentSource] {
        try Task.checkCancellation()
        var identitiesByDigest: [String: ReconstructionContentIdentity] = [:]
        for identity in suppliedIdentities {
            if let existing = identitiesByDigest[identity.digest], existing != identity {
                throw WorkspaceDatabase.DatabaseError.reconstructionIdentityConflict(
                    "content digest"
                )
            }
            identitiesByDigest[identity.digest] = identity
        }
        if attachmentAuthority == nil {
            guard try Self.pathExists(rootURL) else { return [] }
        }
        let rootDescriptor = try openRootDirectory(createIfMissing: false)
        defer { _ = Darwin.close(rootDescriptor) }
        try recoverCrashStageResiduesIfExclusivelyOwned(rootDescriptor: rootDescriptor)
        return try identitiesByDigest.values.sorted(by: { $0.digest < $1.digest }).compactMap {
            try Task.checkCancellation()
            return try availableValidatedSource(for: $0, rootDescriptor: rootDescriptor)
        }
    }

    /// Forms deterministic durable-vault handles without opening or hashing their files. The
    /// database-owner actor may return these immutable candidates immediately; callers validate
    /// every descriptor only after leaving actor isolation.
    func candidateSources(
        for suppliedIdentities: [ReconstructionContentIdentity]
    ) throws -> [ReconstructionAttachmentSource] {
        var identitiesByDigest: [String: ReconstructionContentIdentity] = [:]
        for identity in suppliedIdentities {
            if let existing = identitiesByDigest[identity.digest], existing != identity {
                throw WorkspaceDatabase.DatabaseError.reconstructionIdentityConflict(
                    "content digest"
                )
            }
            identitiesByDigest[identity.digest] = identity
        }
        return identitiesByDigest.values.sorted(by: { $0.digest < $1.digest }).map {
            source(for: $0)
        }
    }

    private func install(
        _ supplied: ReconstructionAttachmentSource,
        identity: ReconstructionContentIdentity,
        rootDescriptor: Int32
    ) throws -> ReconstructionAttachmentSource {
        let shardName = String(identity.digest.prefix(2))
        let shardDescriptor = try openShardDirectory(
            named: shardName,
            rootDescriptor: rootDescriptor
        )
        defer { _ = Darwin.close(shardDescriptor) }

        if try Self.entryExists(named: identity.digest, directoryDescriptor: shardDescriptor) {
            let existing = source(for: identity)
            try ReconstructionAttachmentDescriptorReader.validate(existing)
            return existing
        }

        let stagingName = ".stage-\(UUID().uuidString.lowercased())"
        let stagingDescriptor = stagingName.withCString {
            Darwin.openat(
                shardDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                0o600
            )
        }
        guard stagingDescriptor >= 0 else {
            throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
        }
        var stagingIsOpen = true
        var stagingIsPublished = false
        defer {
            if stagingIsOpen { _ = Darwin.close(stagingDescriptor) }
            if !stagingIsPublished {
                stagingName.withCString { _ = Darwin.unlinkat(shardDescriptor, $0, 0) }
            }
        }

        try ReconstructionAttachmentDescriptorReader.consume(supplied) { data in
            try Self.writeAll(data, descriptor: stagingDescriptor)
        }
        guard Darwin.fchmod(stagingDescriptor, 0o400) == 0 else {
            throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
        }
        try Self.syncRegularFile(stagingDescriptor)
        guard Darwin.close(stagingDescriptor) == 0 else {
            stagingIsOpen = false
            throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
        }
        stagingIsOpen = false

        let renameStatus = stagingName.withCString { stagingPath in
            identity.digest.withCString { finalPath in
                Darwin.renameatx_np(
                    shardDescriptor,
                    stagingPath,
                    shardDescriptor,
                    finalPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        if renameStatus == 0 {
            stagingIsPublished = true
            try Self.syncDirectory(shardDescriptor)
        } else if errno == EEXIST {
            stagingName.withCString { _ = Darwin.unlinkat(shardDescriptor, $0, 0) }
        } else {
            throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
        }

        let durable = source(for: identity)
        try ReconstructionAttachmentDescriptorReader.validate(durable)
        return durable
    }

    private func availableValidatedSource(
        for identity: ReconstructionContentIdentity,
        rootDescriptor: Int32
    ) throws -> ReconstructionAttachmentSource? {
        let shardName = String(identity.digest.prefix(2))
        guard try Self.entryExists(named: shardName, directoryDescriptor: rootDescriptor) else {
            return nil
        }
        let shardDescriptor = try openShardDirectory(
            named: shardName,
            rootDescriptor: rootDescriptor,
            createIfMissing: false
        )
        defer { _ = Darwin.close(shardDescriptor) }
        guard try Self.entryExists(named: identity.digest, directoryDescriptor: shardDescriptor) else {
            return nil
        }
        let source = source(for: identity)
        try ReconstructionAttachmentDescriptorReader.validate(source)
        return source
    }

    private func openRootDirectory(createIfMissing: Bool = true) throws -> Int32 {
        try Task.checkCancellation()
        if let attachmentAuthority {
            do {
                return try attachmentAuthority.duplicateRootDescriptor()
            } catch {
                throw WorkspaceDatabase.DatabaseError
                    .reconstructionAttachmentSourcesUnavailable
            }
        }
        var created = false
        if createIfMissing {
            let status = rootURL.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                if Darwin.mkdir(path, 0o700) == 0 {
                    created = true
                    return 0
                }
                return errno == EEXIST ? 0 : -1
            }
            guard status == 0 else {
                throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
            }
        } else {
            guard try Self.pathExists(rootURL) else {
                throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
            }
        }
        let descriptor = rootURL.withUnsafeFileSystemRepresentation { path in
            path.map {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            } ?? -1
        }
        guard descriptor >= 0, Darwin.fchmod(descriptor, 0o700) == 0 else {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
        }
        if created {
            let parentURL = rootURL.deletingLastPathComponent()
            let parentDescriptor = parentURL.withUnsafeFileSystemRepresentation { path in
                path.map {
                    Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                } ?? -1
            }
            guard parentDescriptor >= 0 else {
                _ = Darwin.close(descriptor)
                throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
            }
            defer { _ = Darwin.close(parentDescriptor) }
            try Self.syncDirectory(parentDescriptor)
        }
        try Self.syncDirectory(descriptor)
        return descriptor
    }

    private func source(
        for identity: ReconstructionContentIdentity
    ) -> ReconstructionAttachmentSource {
        if let attachmentAuthority {
            return attachmentAuthority.source(
                contentIdentity: identity,
                rootURL: rootURL
            )
        }
        return ReconstructionAttachmentSource(
            contentIdentity: identity,
            verifiedURL: rootURL
                .appendingPathComponent(String(identity.digest.prefix(2)), isDirectory: true)
                .appendingPathComponent(identity.digest, isDirectory: false)
        )
    }

    /// A process can die after creating a staging file and before its exclusive rename. Only a
    /// pinned sidecar-directory authority proves that this process has exclusive vault ownership,
    /// so ordinary path-configured vaults deliberately leave even valid-looking residues alone.
    /// Every lookup and removal below is relative to an already opened directory descriptor; a
    /// published digest object is recognized by name and never opened, removed, or otherwise
    /// mutated by this recovery pass.
    fileprivate func recoverCrashStageResiduesIfExclusivelyOwned(rootDescriptor: Int32) throws {
        guard attachmentAuthority != nil else { return }

        for shardName in try Self.directoryEntryNames(descriptor: rootDescriptor) {
            guard Self.isCanonicalShardName(shardName) else {
                throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
            }
            let shardDescriptor = try openShardDirectory(
                named: shardName,
                rootDescriptor: rootDescriptor,
                createIfMissing: false
            )
            defer { _ = Darwin.close(shardDescriptor) }

            var changed = false
            for entryName in try Self.directoryEntryNames(descriptor: shardDescriptor) {
                if Self.isCanonicalPublishedDigest(entryName, in: shardName) {
                    continue
                }
                guard Self.isCanonicalCrashStageName(entryName) else {
                    throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
                }

                var metadata = stat()
                let status = entryName.withCString {
                    Darwin.fstatat(shardDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
                }
                guard status == 0,
                      (metadata.st_mode & S_IFMT) == S_IFREG,
                      metadata.st_nlink == 1 else {
                    throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
                }
                guard entryName.withCString({ Darwin.unlinkat(shardDescriptor, $0, 0) }) == 0 else {
                    throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
                }
                changed = true
            }
            if changed {
                try Self.syncDirectory(shardDescriptor)
            }
        }
    }

    private func openShardDirectory(
        named name: String,
        rootDescriptor: Int32,
        createIfMissing: Bool = true
    ) throws -> Int32 {
        var created = false
        if createIfMissing {
            let makeStatus = name.withCString { path -> Int32 in
                if Darwin.mkdirat(rootDescriptor, path, 0o700) == 0 {
                    created = true
                    return 0
                }
                return errno == EEXIST ? 0 : -1
            }
            guard makeStatus == 0 else {
                throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
            }
        } else {
            guard try Self.entryExists(named: name, directoryDescriptor: rootDescriptor) else {
                throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
            }
        }
        let descriptor = name.withCString {
            Darwin.openat(
                rootDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0, Darwin.fchmod(descriptor, 0o700) == 0 else {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
        }
        if created { try Self.syncDirectory(rootDescriptor) }
        return descriptor
    }

    private static func entryExists(
        named name: String,
        directoryDescriptor: Int32
    ) throws -> Bool {
        var metadata = stat()
        let status = name.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        if status == 0 { return true }
        if errno == ENOENT { return false }
        throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
    }

    private static func directoryEntryNames(descriptor: Int32) throws -> [String] {
        let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0, let directory = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
        }
        defer { _ = Darwin.closedir(directory) }

        // The vault is keyed by digest and must remain bounded even if an unexpected directory
        // was populated before the sidecar authority was acquired. Exceeding this limit fails
        // closed rather than leaving recovery trapped in an attacker-controlled enumeration.
        let maximumEntries = 131_072
        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let length = Int(entry.pointee.d_namlen)
            guard length > 0, length <= Int(NAME_MAX), names.count < maximumEntries else {
                throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
            }
            let bytes: [UInt8] = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: UInt8.self, capacity: Int(NAME_MAX) + 1) { start in
                    Array(UnsafeBufferPointer(start: start, count: length))
                }
            }
            guard let name = String(bytes: bytes, encoding: .utf8) else {
                throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
            }
            if name != "." && name != ".." {
                names.append(name)
            }
        }
        guard errno == 0 else {
            throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
        }
        return names
    }

    private static func isCanonicalShardName(_ name: String) -> Bool {
        name.utf8.count == 2 && name.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private static func isCanonicalPublishedDigest(_ name: String, in shardName: String) -> Bool {
        name.utf8.count == 64 && name.hasPrefix(shardName)
            && name.allSatisfy { "0123456789abcdef".contains($0) }
    }

    private static func isCanonicalCrashStageName(_ name: String) -> Bool {
        let prefix = ".stage-"
        guard name.hasPrefix(prefix) else { return false }
        let rawUUID = String(name.dropFirst(prefix.count))
        guard let identifier = UUID(uuidString: rawUUID) else { return false }
        return rawUUID == identifier.uuidString.lowercased()
    }

    private static func pathExists(_ url: URL) throws -> Bool {
        var metadata = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &metadata) } ?? -1
        }
        if status == 0 { return true }
        if errno == ENOENT { return false }
        throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count > 0 {
                    offset += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
            }
        }
    }

    private static func syncRegularFile(_ descriptor: Int32) throws {
        while Darwin.fcntl(descriptor, F_FULLFSYNC) != 0 {
            if errno == EINTR { continue }
            while Darwin.fsync(descriptor) != 0 {
                if errno == EINTR { continue }
                throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
            }
            return
        }
    }

    private static func syncDirectory(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw WorkspaceDatabase.DatabaseError.reconstructionAttachmentSourcesUnavailable
        }
    }
}

struct WorkspacePackageComponents {
    let manifest: WorkspacePackageManifest
    let attachmentsByBinaryID: [UUID: Data]
}

final class WorkspaceDatabase {
    static let schemaVersion = 44
    static let savedWatchesSchemaSQL = """
    CREATE TABLE IF NOT EXISTS saved_watch_catalogs (
      workspace_id INTEGER PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
      workspace_uuid TEXT NOT NULL,
      catalog_blob BLOB NOT NULL CHECK(length(catalog_blob) <= 32768),
      catalog_sha256 TEXT NOT NULL
    );
    """
    private static let supportedReconstructionSidecarMigrationVersions: Set<Int> = [38, 39, 40, 42, 43]

    static let phase2ShellSessionsSchemaSQL = """
    CREATE TABLE IF NOT EXISTS phase2_shell_sessions (
      workspace_id INTEGER PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
      workspace_uuid TEXT NOT NULL,
      document_id TEXT NOT NULL,
      shell_session_json TEXT NOT NULL,
      record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 1),
      updated_at TEXT NOT NULL
    );
    """

    static let phase2RuntimeAuthorityRecordsSchemaSQL = """
    CREATE TABLE IF NOT EXISTS phase2_runtime_authority_records (
      id TEXT PRIMARY KEY,
      workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      workspace_uuid TEXT NOT NULL,
      document_id TEXT NOT NULL,
      session_id TEXT NOT NULL,
      surfaces_json TEXT NOT NULL,
      terminal_backend TEXT NOT NULL,
      pty_reuse_policy TEXT NOT NULL,
      debugger_authority_policy_json TEXT NOT NULL,
      provider_visible_shell_execution_enabled INTEGER NOT NULL CHECK(provider_visible_shell_execution_enabled IN (0, 1)),
      record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 1),
      created_at TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_phase2_runtime_authority_workspace_created
      ON phase2_runtime_authority_records(workspace_id, created_at DESC, id);
    """

    static let phase2AssistantSessionRecordsSchemaSQL = """
    CREATE TABLE IF NOT EXISTS phase2_assistant_session_records (
      id TEXT PRIMARY KEY,
      workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      workspace_uuid TEXT NOT NULL,
      document_id TEXT NOT NULL,
      sequence INTEGER NOT NULL CHECK(sequence > 0),
      conversation_id TEXT NOT NULL,
      turn_sequence INTEGER NOT NULL CHECK(turn_sequence > 0),
      inference_turn_id TEXT NOT NULL,
      is_legacy INTEGER NOT NULL DEFAULT 0 CHECK(is_legacy IN (0, 1)),
      intent_id TEXT NOT NULL,
      user_goal TEXT NOT NULL,
      status TEXT NOT NULL,
      prompt_text TEXT NOT NULL,
      answer_text TEXT,
      transcript_text TEXT NOT NULL,
      context_digest TEXT,
      canonical_byte_count INTEGER CHECK(canonical_byte_count IS NULL OR canonical_byte_count >= 0),
      provider_tool_count INTEGER NOT NULL DEFAULT 0 CHECK(provider_tool_count BETWEEN 0 AND 64),
      continuation_checkpoint_json TEXT,
      shell_proposal_id TEXT,
      shell_execution_id TEXT,
      continuation_ordinal INTEGER CHECK(continuation_ordinal IS NULL OR continuation_ordinal = 1),
      continuation_request_id TEXT,
      record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 3),
      created_at TEXT NOT NULL,
      completed_at TEXT,
      content_sha256 TEXT NOT NULL
    );

    CREATE UNIQUE INDEX IF NOT EXISTS idx_phase2_assistant_sessions_workspace_sequence
      ON phase2_assistant_session_records(workspace_id, sequence);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_phase2_assistant_sessions_workspace_conversation_turn
      ON phase2_assistant_session_records(workspace_id, conversation_id, turn_sequence);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_phase2_assistant_sessions_workspace_inference_turn
      ON phase2_assistant_session_records(workspace_id, inference_turn_id);
    CREATE INDEX IF NOT EXISTS idx_phase2_assistant_sessions_workspace_created
      ON phase2_assistant_session_records(workspace_id, created_at DESC, id);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_phase2_assistant_sessions_workspace_proposal
      ON phase2_assistant_session_records(workspace_id, shell_proposal_id)
      WHERE shell_proposal_id IS NOT NULL;
    CREATE UNIQUE INDEX IF NOT EXISTS idx_phase2_assistant_sessions_workspace_execution
      ON phase2_assistant_session_records(workspace_id, shell_execution_id)
      WHERE shell_execution_id IS NOT NULL;
    CREATE UNIQUE INDEX IF NOT EXISTS idx_phase2_assistant_sessions_workspace_continuation_ordinal
      ON phase2_assistant_session_records(workspace_id, conversation_id, turn_sequence, continuation_ordinal)
      WHERE continuation_ordinal IS NOT NULL;
    CREATE UNIQUE INDEX IF NOT EXISTS idx_phase2_assistant_sessions_continuation_request
      ON phase2_assistant_session_records(continuation_request_id)
      WHERE continuation_request_id IS NOT NULL;
    """

    private static let phase2AssistantSessionRecordsV1SchemaSQL = """
    CREATE TABLE IF NOT EXISTS phase2_assistant_session_records (
      id TEXT PRIMARY KEY,
      workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      workspace_uuid TEXT NOT NULL,
      document_id TEXT NOT NULL,
      sequence INTEGER NOT NULL CHECK(sequence > 0),
      intent_id TEXT NOT NULL,
      user_goal TEXT NOT NULL,
      status TEXT NOT NULL,
      prompt_text TEXT NOT NULL,
      answer_text TEXT,
      transcript_text TEXT NOT NULL,
      context_digest TEXT,
      canonical_byte_count INTEGER CHECK(canonical_byte_count IS NULL OR canonical_byte_count >= 0),
      provider_tool_count INTEGER NOT NULL DEFAULT 0 CHECK(provider_tool_count BETWEEN 0 AND 64),
      record_schema_version INTEGER NOT NULL CHECK(record_schema_version = 1),
      created_at TEXT NOT NULL,
      completed_at TEXT,
      content_sha256 TEXT NOT NULL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_phase2_assistant_sessions_workspace_sequence
      ON phase2_assistant_session_records(workspace_id, sequence);
    CREATE INDEX IF NOT EXISTS idx_phase2_assistant_sessions_workspace_created
      ON phase2_assistant_session_records(workspace_id, created_at DESC, id);
    """

    static let launchProfilesSchemaSQL = """
    CREATE TABLE IF NOT EXISTS launch_profile_catalogs (
      workspace_id INTEGER PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
      workspace_uuid TEXT NOT NULL,
      catalog_uuid TEXT NOT NULL,
      revision INTEGER NOT NULL,
      profile_count INTEGER NOT NULL,
      selected_profile_uuid TEXT,
      catalog_version INTEGER NOT NULL,
      catalog_byte_count INTEGER NOT NULL,
      catalog_sha256 TEXT NOT NULL,
      catalog_blob BLOB NOT NULL
    );
    """

    static let logicalBreakpointsSchemaSQL = """
    CREATE TABLE IF NOT EXISTS logical_breakpoint_catalogs (
      workspace_id INTEGER PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
      workspace_uuid TEXT NOT NULL,
      catalog_uuid TEXT NOT NULL,
      revision INTEGER NOT NULL CHECK(revision > 0),
      specification_count INTEGER NOT NULL CHECK(specification_count >= 0),
      catalog_sha256 TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS logical_breakpoints (
      id TEXT PRIMARY KEY,
      workspace_id INTEGER NOT NULL REFERENCES logical_breakpoint_catalogs(workspace_id)
        ON DELETE CASCADE,
      revision INTEGER NOT NULL CHECK(revision > 0),
      specification_version INTEGER NOT NULL,
      specification_byte_count INTEGER NOT NULL,
      specification_sha256 TEXT NOT NULL,
      specification_json TEXT NOT NULL,
      created_at TEXT NOT NULL,
      modified_at TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_logical_breakpoints_workspace_id
      ON logical_breakpoints(workspace_id, id);
    """

    /// User-authored address overrides (rename/comment, tag/color added in v14,
    /// is_data mark in v15, signature_json in v16, applied_type_name in v17,
    /// switch_hint_json in v18, operand_format in v19, mark_as_procedure in v20,
    /// data_shape_json — Make Array/Alignment/String — in v21, is_undefined +
    /// patch_json — Mark-as-Undefined and Patch-Bytes — in v22, register_names_json +
    /// local_label — pseudocode register renames and per-procedure local labels — in v24).
    /// Factored out so both the fresh-install schema and the migration paths create
    /// it identically.
    static let addressOverridesSchemaSQL = """
    CREATE TABLE IF NOT EXISTS address_overrides (
      id INTEGER PRIMARY KEY,
      workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      address INTEGER NOT NULL,
      custom_name TEXT,
      custom_comment TEXT,
      tag TEXT,
      color_tag TEXT,
      is_data INTEGER NOT NULL DEFAULT 0,
      signature_json TEXT,
      applied_type_name TEXT,
      switch_hint_json TEXT,
      operand_format TEXT,
      created_at TEXT NOT NULL,
      modified_at TEXT NOT NULL,
      mark_as_procedure INTEGER NOT NULL DEFAULT 0,
      data_shape_json TEXT,
      is_undefined INTEGER NOT NULL DEFAULT 0,
      patch_json TEXT,
      register_names_json TEXT,
      local_label TEXT,
      image_slot INTEGER NOT NULL DEFAULT 0,
      appended_cave_json TEXT,
      stack_locals_json TEXT
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_address_overrides_workspace_address
      ON address_overrides(workspace_id, image_slot, address);
    """

    /// User-authored cross-reference edits (added/suppressed xrefs), workspace-scoped.
    /// Arrived in v22. Like the overrides/type tables it must be created on every
    /// migration path (factored out). The UNIQUE(workspace_id, from, to, kind, is_suppression)
    /// index dedupes a repeat edit so a second save never collides + aborts.
    static let manualXRefsSchemaSQL = """
    CREATE TABLE IF NOT EXISTS manual_xrefs (
      id TEXT PRIMARY KEY,
      workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      from_address INTEGER NOT NULL,
      to_address INTEGER NOT NULL,
      kind TEXT NOT NULL,
      is_suppression INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      modified_at TEXT NOT NULL,
      image_slot INTEGER NOT NULL DEFAULT 0
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_manual_xrefs_workspace_endpoints
      ON manual_xrefs(workspace_id, image_slot, from_address, to_address, kind, is_suppression);
    """

    /// User navigation bookmarks, workspace-scoped. Arrived in v22. Created on every
    /// migration path (factored out). The UNIQUE(workspace_id, address) index dedupes a
    /// repeat bookmark at the same address (last-writer-wins via OR REPLACE on insert) so
    /// the in-place re-save never collides + aborts.
    static let bookmarksSchemaSQL = """
    CREATE TABLE IF NOT EXISTS bookmarks (
      id TEXT PRIMARY KEY,
      workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      address INTEGER NOT NULL,
      name TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL,
      modified_at TEXT NOT NULL,
      image_slot INTEGER NOT NULL DEFAULT 0
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_bookmarks_workspace_address
      ON bookmarks(workspace_id, image_slot, address);
    """

    /// User segment/section DISPLAY overrides (rename + rebase), workspace-scoped.
    /// Arrived in v23. Like the overrides/bookmarks tables it must be created on every
    /// migration path (factored out). The UNIQUE(workspace_id, original_name) index
    /// dedupes a repeat override on the same section (last-writer-wins via OR REPLACE on
    /// insert) so the in-place re-save never collides + aborts.
    static let segmentOverridesSchemaSQL = """
    CREATE TABLE IF NOT EXISTS segment_overrides (
      id TEXT PRIMARY KEY,
      workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      original_name TEXT NOT NULL,
      display_name TEXT,
      rebase_delta INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      modified_at TEXT NOT NULL,
      image_slot INTEGER NOT NULL DEFAULT 0
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_segment_overrides_workspace_name
      ON segment_overrides(workspace_id, image_slot, original_name);
    """

    /// Workspace-global user type catalog (struct/union/enum/typedef). Like the
    /// overrides table it must be created on every migration path (factored out).
    static let typeDefinitionsSchemaSQL = """
    CREATE TABLE IF NOT EXISTS type_definitions (
      id TEXT PRIMARY KEY,
      workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      kind TEXT NOT NULL,
      name TEXT NOT NULL,
      fields_json TEXT NOT NULL,
      layout_rules_json TEXT,
      created_at TEXT NOT NULL,
      modified_at TEXT NOT NULL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_type_definitions_workspace_name
      ON type_definitions(workspace_id, name);
    """

    static let reconstructionFinalResultsSchemaSQL = """
    CREATE TABLE IF NOT EXISTS reconstruction_final_results (
      workspace_uuid TEXT NOT NULL REFERENCES workspaces(uuid) ON DELETE CASCADE,
      result_id TEXT NOT NULL,
      job_id TEXT NOT NULL,
      task_id TEXT NOT NULL,
      checkpoint_id TEXT NOT NULL,
      checkpoint_revision INTEGER NOT NULL CHECK(checkpoint_revision >= 0),
      request_id TEXT NOT NULL,
      request_identity_sha256 TEXT NOT NULL
        CHECK(length(request_identity_sha256) = 64
          AND request_identity_sha256 = lower(request_identity_sha256)
          AND request_identity_sha256 NOT GLOB '*[^0-9a-f]*'),
      kind TEXT NOT NULL CHECK(kind IN ('synthesis', 'insufficientEvidence')),
      payload_byte_count INTEGER NOT NULL
        CHECK(payload_byte_count > 0 AND payload_byte_count <= 1048576),
      payload_sha256 TEXT NOT NULL
        CHECK(length(payload_sha256) = 64
          AND payload_sha256 = lower(payload_sha256)
          AND payload_sha256 NOT GLOB '*[^0-9a-f]*'),
      producer_canonical_sha256 TEXT NOT NULL
        CHECK(length(producer_canonical_sha256) = 64
          AND producer_canonical_sha256 = lower(producer_canonical_sha256)
          AND producer_canonical_sha256 NOT GLOB '*[^0-9a-f]*'),
      model_receipt_id TEXT NOT NULL,
      canonical_sha256 TEXT NOT NULL
        CHECK(length(canonical_sha256) = 64
          AND canonical_sha256 = lower(canonical_sha256)
          AND canonical_sha256 NOT GLOB '*[^0-9a-f]*'),
      record_json BLOB NOT NULL,
      PRIMARY KEY (workspace_uuid, result_id),
      UNIQUE (workspace_uuid, job_id),
      UNIQUE (workspace_uuid, model_receipt_id),
      CHECK(request_id = model_receipt_id),
      FOREIGN KEY (workspace_uuid, job_id)
        REFERENCES reconstruction_jobs(workspace_uuid, job_id) ON DELETE CASCADE,
      FOREIGN KEY (workspace_uuid, task_id)
        REFERENCES reconstruction_tasks(workspace_uuid, task_id) ON DELETE CASCADE,
      FOREIGN KEY (workspace_uuid, checkpoint_id)
        REFERENCES reconstruction_checkpoints(workspace_uuid, checkpoint_id) ON DELETE CASCADE,
      FOREIGN KEY (workspace_uuid, model_receipt_id)
        REFERENCES reconstruction_model_receipts(workspace_uuid, receipt_id) ON DELETE CASCADE
    );
    """

    /// Reconstruction state is workspace-scoped and keyed exclusively by durable UUID/digest
    /// identities. `record_json` is the canonical MacScope-owned record; the extracted columns
    /// make identity, ownership, and graph edges independently auditable without borrowing rowids.
    static let reconstructionSchemaSQL = """
    CREATE TABLE IF NOT EXISTS reconstruction_projects (
      workspace_uuid TEXT NOT NULL REFERENCES workspaces(uuid) ON DELETE CASCADE,
      project_id TEXT NOT NULL,
      current_manifest_sha256 TEXT,
      record_json BLOB NOT NULL,
      state_json BLOB NOT NULL,
      PRIMARY KEY (workspace_uuid, project_id)
    );

    CREATE TABLE IF NOT EXISTS reconstruction_artifact_contents (
      workspace_uuid TEXT NOT NULL REFERENCES workspaces(uuid) ON DELETE CASCADE,
      content_sha256 TEXT NOT NULL,
      algorithm TEXT NOT NULL,
      byte_count INTEGER NOT NULL CHECK(byte_count > 0),
      record_json BLOB NOT NULL,
      PRIMARY KEY (workspace_uuid, content_sha256)
    );

    CREATE TABLE IF NOT EXISTS reconstruction_artifact_occurrences (
      workspace_uuid TEXT NOT NULL REFERENCES workspaces(uuid) ON DELETE CASCADE,
      project_id TEXT NOT NULL,
      occurrence_id TEXT NOT NULL,
      content_sha256 TEXT NOT NULL,
      kind TEXT NOT NULL,
      executable_mode INTEGER NOT NULL CHECK(executable_mode IN (0, 1)),
      record_json BLOB NOT NULL,
      PRIMARY KEY (workspace_uuid, occurrence_id)
    );

    CREATE TABLE IF NOT EXISTS reconstruction_artifact_roles (
      workspace_uuid TEXT NOT NULL REFERENCES workspaces(uuid) ON DELETE CASCADE,
      project_id TEXT NOT NULL,
      occurrence_id TEXT NOT NULL,
      role TEXT NOT NULL,
      ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
      PRIMARY KEY (workspace_uuid, occurrence_id, role)
    );

    CREATE TABLE IF NOT EXISTS reconstruction_artifact_relations (
      workspace_uuid TEXT NOT NULL REFERENCES workspaces(uuid) ON DELETE CASCADE,
      project_id TEXT NOT NULL,
      relation_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      source_occurrence_id TEXT NOT NULL,
      target_occurrence_id TEXT,
      canonical_sha256 TEXT NOT NULL,
      record_json BLOB NOT NULL,
      PRIMARY KEY (workspace_uuid, project_id, relation_id)
    );

    CREATE TABLE IF NOT EXISTS reconstruction_evidence (
      workspace_uuid TEXT NOT NULL REFERENCES workspaces(uuid) ON DELETE CASCADE,
      evidence_id TEXT NOT NULL,
      classification TEXT NOT NULL,
      payload_sha256 TEXT NOT NULL,
      record_json BLOB NOT NULL,
      PRIMARY KEY (workspace_uuid, evidence_id)
    );

    CREATE TABLE IF NOT EXISTS reconstruction_evidence_citations (
      workspace_uuid TEXT NOT NULL REFERENCES workspaces(uuid) ON DELETE CASCADE,
      evidence_id TEXT NOT NULL,
      citation_id TEXT NOT NULL,
      source_evidence_id TEXT,
      record_json BLOB NOT NULL,
      PRIMARY KEY (workspace_uuid, evidence_id, citation_id)
    );

    CREATE TABLE IF NOT EXISTS reconstruction_evidence_relations (
      workspace_uuid TEXT NOT NULL REFERENCES workspaces(uuid) ON DELETE CASCADE,
      relation_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      source_evidence_id TEXT NOT NULL,
      target_evidence_id TEXT NOT NULL,
      record_json BLOB NOT NULL,
      PRIMARY KEY (workspace_uuid, relation_id)
    );

    CREATE TABLE IF NOT EXISTS reconstruction_tool_receipts (
      workspace_uuid TEXT NOT NULL REFERENCES workspaces(uuid) ON DELETE CASCADE,
      receipt_id TEXT NOT NULL,
      job_id TEXT NOT NULL,
      task_id TEXT NOT NULL,
      canonical_sha256 TEXT NOT NULL,
      record_json BLOB NOT NULL,
      PRIMARY KEY (workspace_uuid, receipt_id)
    );

    CREATE TABLE IF NOT EXISTS reconstruction_model_receipts (
      workspace_uuid TEXT NOT NULL REFERENCES workspaces(uuid) ON DELETE CASCADE,
      receipt_id TEXT NOT NULL,
      job_id TEXT NOT NULL,
      task_id TEXT NOT NULL,
      canonical_sha256 TEXT NOT NULL,
      record_json BLOB NOT NULL,
      PRIMARY KEY (workspace_uuid, receipt_id)
    );

    CREATE TABLE IF NOT EXISTS reconstruction_jobs (
      workspace_uuid TEXT NOT NULL REFERENCES workspaces(uuid) ON DELETE CASCADE,
      job_id TEXT NOT NULL,
      project_id TEXT NOT NULL,
      current_checkpoint_id TEXT,
      state TEXT NOT NULL,
      record_json BLOB NOT NULL,
      PRIMARY KEY (workspace_uuid, job_id)
    );

    CREATE TABLE IF NOT EXISTS reconstruction_tasks (
      workspace_uuid TEXT NOT NULL REFERENCES workspaces(uuid) ON DELETE CASCADE,
      task_id TEXT NOT NULL,
      job_id TEXT NOT NULL,
      state TEXT NOT NULL,
      record_json BLOB NOT NULL,
      PRIMARY KEY (workspace_uuid, task_id)
    );

    CREATE TABLE IF NOT EXISTS reconstruction_checkpoints (
      workspace_uuid TEXT NOT NULL REFERENCES workspaces(uuid) ON DELETE CASCADE,
      checkpoint_id TEXT NOT NULL,
      job_id TEXT NOT NULL,
      revision INTEGER NOT NULL CHECK(revision >= 0),
      parent_checkpoint_id TEXT,
      canonical_sha256 TEXT NOT NULL,
      record_json BLOB NOT NULL,
      PRIMARY KEY (workspace_uuid, checkpoint_id),
      UNIQUE (workspace_uuid, job_id, revision)
    );

    CREATE TABLE IF NOT EXISTS reconstruction_checkpoint_tasks (
      workspace_uuid TEXT NOT NULL REFERENCES workspaces(uuid) ON DELETE CASCADE,
      checkpoint_id TEXT NOT NULL,
      task_id TEXT NOT NULL,
      state_bucket TEXT NOT NULL,
      ordinal INTEGER NOT NULL CHECK(ordinal >= 0),
      PRIMARY KEY (workspace_uuid, checkpoint_id, state_bucket, task_id)
    );

    \(reconstructionFinalResultsSchemaSQL)
    """

    private static let reconstructionProjectionColumns: [String: [String]] = [
        "reconstruction_projects": [
            "workspace_uuid", "project_id", "current_manifest_sha256",
            "record_json", "state_json",
        ],
        "reconstruction_artifact_contents": [
            "workspace_uuid", "content_sha256", "algorithm", "byte_count", "record_json",
        ],
        "reconstruction_artifact_occurrences": [
            "workspace_uuid", "project_id", "occurrence_id", "content_sha256", "kind",
            "executable_mode", "record_json",
        ],
        "reconstruction_artifact_roles": [
            "workspace_uuid", "project_id", "occurrence_id", "role", "ordinal",
        ],
        "reconstruction_artifact_relations": [
            "workspace_uuid", "project_id", "relation_id", "kind",
            "source_occurrence_id", "target_occurrence_id", "canonical_sha256", "record_json",
        ],
        "reconstruction_evidence": [
            "workspace_uuid", "evidence_id", "classification", "payload_sha256", "record_json",
        ],
        "reconstruction_evidence_citations": [
            "workspace_uuid", "evidence_id", "citation_id", "source_evidence_id", "record_json",
        ],
        "reconstruction_evidence_relations": [
            "workspace_uuid", "relation_id", "kind", "source_evidence_id",
            "target_evidence_id", "record_json",
        ],
        "reconstruction_tool_receipts": [
            "workspace_uuid", "receipt_id", "job_id", "task_id",
            "canonical_sha256", "record_json",
        ],
        "reconstruction_model_receipts": [
            "workspace_uuid", "receipt_id", "job_id", "task_id",
            "canonical_sha256", "record_json",
        ],
        "reconstruction_jobs": [
            "workspace_uuid", "job_id", "project_id", "current_checkpoint_id", "state", "record_json",
        ],
        "reconstruction_tasks": [
            "workspace_uuid", "task_id", "job_id", "state", "record_json",
        ],
        "reconstruction_checkpoints": [
            "workspace_uuid", "checkpoint_id", "job_id", "revision",
            "parent_checkpoint_id", "canonical_sha256", "record_json",
        ],
        "reconstruction_checkpoint_tasks": [
            "workspace_uuid", "checkpoint_id", "task_id", "state_bucket", "ordinal",
        ],
        "reconstruction_final_results": [
            "workspace_uuid", "result_id", "job_id", "task_id", "checkpoint_id",
            "checkpoint_revision", "request_id", "request_identity_sha256", "kind",
            "payload_byte_count", "payload_sha256", "producer_canonical_sha256",
            "model_receipt_id", "canonical_sha256", "record_json",
        ],
    ]

    private struct ReconstructionSchemaColumn: Equatable {
        let name: String
        let declaredType: String
        let notNull: Bool
        let defaultValue: String?
        let primaryKeyOrdinal: Int
        let hidden: Int
    }

    private struct ReconstructionSchemaForeignKey: Equatable {
        let id: Int
        let sequence: Int
        let parentTable: String
        let sourceColumn: String
        let targetColumn: String?
        let onUpdate: String
        let onDelete: String
        let match: String
    }

    private struct ReconstructionSchemaIndexColumn: Equatable {
        let sequence: Int
        let columnID: Int
        let name: String?
        let descending: Bool
        let collation: String?
        let isKey: Bool
    }

    private struct ReconstructionSchemaIndex: Equatable {
        let name: String
        let unique: Bool
        let origin: String
        let partial: Bool
        let columns: [ReconstructionSchemaIndexColumn]
    }

    private struct ReconstructionSchemaTable: Equatable {
        let normalizedSQL: String
        let columns: [ReconstructionSchemaColumn]
        let foreignKeys: [ReconstructionSchemaForeignKey]
        let indexes: [ReconstructionSchemaIndex]

        func hasEquivalentStructuralAuthority(to other: Self) -> Bool {
            columns == other.columns
                && foreignKeys == other.foreignKeys
                && indexes == other.indexes
        }
    }

    private enum ReconstructionProjectionCell: Hashable {
        case null
        case integer(Int64)
        case real(UInt64)
        case text(String)
        case blob(Data)
    }

    static let schemaSQL = """
    CREATE TABLE workspaces (
      id INTEGER PRIMARY KEY,
      uuid TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      created_at TEXT NOT NULL,
      modified_at TEXT NOT NULL,
      next_image_slot INTEGER NOT NULL DEFAULT 1
    );

    CREATE TABLE binaries (
      id INTEGER PRIMARY KEY,
      uuid TEXT NOT NULL UNIQUE,
      workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      path TEXT NOT NULL,
      original_path_bookmark BLOB,
      kind TEXT NOT NULL,
      architecture TEXT NOT NULL,
      file_hash TEXT NOT NULL,
      file_size INTEGER NOT NULL,
      hex_bytes BLOB,
      is_bundle INTEGER NOT NULL DEFAULT 0,
      image_slot INTEGER NOT NULL DEFAULT 0,
      selected_slice_index INTEGER,
      analysis_input_fingerprint_json TEXT,
      binary_metadata_json TEXT,
      elf_archive_member_identity_json TEXT,
      macho_selected_slice_fact_json TEXT
    );

    CREATE TABLE functions (
      id INTEGER PRIMARY KEY,
      uuid TEXT NOT NULL UNIQUE,
      binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE,
      start_address INTEGER NOT NULL,
      end_address INTEGER,
      symbol_name TEXT,
      demangled_name TEXT,
      confidence REAL NOT NULL DEFAULT 0.0,
      no_return_provenance TEXT
    );

    CREATE TABLE symbols (
      id INTEGER PRIMARY KEY,
      uuid TEXT NOT NULL UNIQUE,
      binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      address INTEGER,
      kind TEXT NOT NULL,
      library_name TEXT,
      raw_linkage_name TEXT
    );

    CREATE TABLE imports (
      id INTEGER PRIMARY KEY,
      uuid TEXT NOT NULL UNIQUE,
      binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      library_name TEXT,
      library_ordinal INTEGER
    );

    CREATE TABLE indirect_symbols (
      id INTEGER PRIMARY KEY,
      uuid TEXT NOT NULL UNIQUE,
      binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE,
      kind TEXT NOT NULL,
      source_section TEXT NOT NULL,
      address INTEGER NOT NULL,
      entry_size INTEGER NOT NULL,
      table_index INTEGER NOT NULL,
      raw_symbol_index INTEGER NOT NULL,
      symbol_index INTEGER,
      symbol_name TEXT,
      library_ordinal INTEGER,
      library_name TEXT,
      is_local INTEGER NOT NULL DEFAULT 0,
      is_absolute INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE exports (
      id INTEGER PRIMARY KEY,
      uuid TEXT NOT NULL UNIQUE,
      binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      address INTEGER,
      source TEXT NOT NULL
    );

    CREATE TABLE string_literals (
      id INTEGER PRIMARY KEY,
      uuid TEXT NOT NULL UNIQUE,
      binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE,
      value TEXT NOT NULL,
      address INTEGER NOT NULL,
      source_section TEXT NOT NULL,
      byte_length INTEGER NOT NULL
    );

    CREATE TABLE instructions (
      id INTEGER PRIMARY KEY,
      function_id INTEGER NOT NULL REFERENCES functions(id) ON DELETE CASCADE,
      address INTEGER NOT NULL,
      bytes BLOB NOT NULL,
      mnemonic TEXT NOT NULL,
      operands TEXT NOT NULL,
      has_breakpoint INTEGER NOT NULL DEFAULT 0,
      comment TEXT,
      ir_json BLOB,
      structured_operands_json BLOB
    );

    CREATE TABLE basic_blocks (
      id INTEGER PRIMARY KEY,
      uuid TEXT NOT NULL UNIQUE,
      function_id INTEGER NOT NULL REFERENCES functions(id) ON DELETE CASCADE,
      start_address INTEGER NOT NULL,
      end_address INTEGER NOT NULL,
      instruction_count INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE xrefs (
      id INTEGER PRIMARY KEY,
      uuid TEXT NOT NULL UNIQUE,
      binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE,
      from_address INTEGER NOT NULL,
      to_address INTEGER NOT NULL,
      kind TEXT NOT NULL
    );

    CREATE TABLE control_flow_edges (
      id INTEGER PRIMARY KEY,
      uuid TEXT NOT NULL UNIQUE,
      binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE,
      from_address INTEGER NOT NULL,
      to_address INTEGER NOT NULL,
      kind TEXT NOT NULL
    );

    CREATE TABLE workspace_sessions (
      workspace_id INTEGER PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
      selected_sidebar_item_id TEXT,
      selected_address INTEGER,
      selected_tool TEXT NOT NULL,
      editor_mode TEXT NOT NULL,
      is_inspector_presented INTEGER NOT NULL DEFAULT 1,
      sidebar_search_text TEXT NOT NULL DEFAULT '',
      updated_at TEXT NOT NULL,
      focused_image_slot INTEGER NOT NULL DEFAULT 0
    );

    CREATE TABLE workspace_documents (
      workspace_id INTEGER PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
      document_id TEXT NOT NULL,
      package_path TEXT NOT NULL,
      last_opened_at TEXT NOT NULL,
      last_saved_at TEXT,
      is_dirty INTEGER NOT NULL DEFAULT 0,
      file_version_identifier TEXT,
      conflict_detected_at TEXT,
      conflict_reason TEXT,
      input_copying_decision TEXT NOT NULL DEFAULT 'copy_inputs_into_package',
      bookmark_resolution_decision TEXT NOT NULL DEFAULT 'resolve_stored_bookmarks',
      bookmark_resolution_error TEXT,
      recent_document_state TEXT NOT NULL DEFAULT 'available',
      recent_document_state_updated_at TEXT
    );

    CREATE TABLE workspace_document_autosave_decisions (
      id INTEGER PRIMARY KEY,
      uuid TEXT NOT NULL UNIQUE,
      workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      document_id TEXT NOT NULL,
      package_path TEXT NOT NULL,
      decision TEXT NOT NULL,
      reason TEXT,
      file_version_identifier TEXT,
      decided_at TEXT NOT NULL,
      completed_at TEXT,
      error_message TEXT
    );

    CREATE TABLE plugin_trust_decisions (
      plugin_identifier TEXT PRIMARY KEY,
      decision TEXT NOT NULL,
      manifest_hash TEXT,
      updated_at TEXT NOT NULL
    );

    CREATE TABLE plugin_external_runs (
      id INTEGER PRIMARY KEY,
      request_id TEXT NOT NULL UNIQUE,
      plugin_identifier TEXT NOT NULL,
      display_name TEXT NOT NULL,
      executable_path TEXT NOT NULL,
      manifest_hash TEXT,
      status TEXT NOT NULL,
      started_at TEXT NOT NULL,
      completed_at TEXT,
      termination_status INTEGER,
      stdout TEXT NOT NULL DEFAULT '',
      stderr TEXT NOT NULL DEFAULT '',
      log TEXT NOT NULL DEFAULT '',
      error_message TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_binaries_workspace_id ON binaries(workspace_id);
    DROP INDEX IF EXISTS idx_binaries_workspace_image_slot;
    CREATE UNIQUE INDEX idx_binaries_workspace_image_slot ON binaries(workspace_id, image_slot);
    CREATE INDEX IF NOT EXISTS idx_functions_binary_id ON functions(binary_id);
    CREATE INDEX IF NOT EXISTS idx_symbols_binary_id ON symbols(binary_id);
    CREATE INDEX IF NOT EXISTS idx_imports_binary_id ON imports(binary_id);
    CREATE INDEX IF NOT EXISTS idx_indirect_symbols_binary_id ON indirect_symbols(binary_id);
    CREATE INDEX IF NOT EXISTS idx_indirect_symbols_address ON indirect_symbols(binary_id, address);
    CREATE INDEX IF NOT EXISTS idx_exports_binary_id ON exports(binary_id);
    CREATE INDEX IF NOT EXISTS idx_string_literals_binary_id ON string_literals(binary_id);
    CREATE INDEX IF NOT EXISTS idx_instructions_function_id ON instructions(function_id);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_instructions_function_address ON instructions(function_id, address);
    CREATE INDEX IF NOT EXISTS idx_basic_blocks_function_id ON basic_blocks(function_id);
    CREATE UNIQUE INDEX IF NOT EXISTS idx_basic_blocks_function_start ON basic_blocks(function_id, start_address);
    CREATE INDEX IF NOT EXISTS idx_xrefs_binary_id ON xrefs(binary_id);
    CREATE INDEX IF NOT EXISTS idx_control_flow_edges_binary_id ON control_flow_edges(binary_id);
    CREATE INDEX IF NOT EXISTS idx_workspace_document_autosave_decisions_workspace_id ON workspace_document_autosave_decisions(workspace_id, decided_at DESC);
    CREATE INDEX IF NOT EXISTS idx_workspace_document_autosave_decisions_decided_at ON workspace_document_autosave_decisions(decided_at DESC);
    CREATE INDEX IF NOT EXISTS idx_workspace_documents_last_opened_at ON workspace_documents(last_opened_at DESC);
    CREATE INDEX IF NOT EXISTS idx_workspace_documents_conflict_detected_at ON workspace_documents(conflict_detected_at DESC);
    CREATE INDEX IF NOT EXISTS idx_workspace_documents_recent_document_state ON workspace_documents(recent_document_state);
    CREATE INDEX IF NOT EXISTS idx_plugin_external_runs_plugin_identifier ON plugin_external_runs(plugin_identifier);
    CREATE INDEX IF NOT EXISTS idx_plugin_external_runs_status ON plugin_external_runs(status);

    CREATE TABLE address_overrides (
      id INTEGER PRIMARY KEY,
      workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      address INTEGER NOT NULL,
      custom_name TEXT,
      custom_comment TEXT,
      tag TEXT,
      color_tag TEXT,
      is_data INTEGER NOT NULL DEFAULT 0,
      signature_json TEXT,
      applied_type_name TEXT,
      switch_hint_json TEXT,
      operand_format TEXT,
      created_at TEXT NOT NULL,
      modified_at TEXT NOT NULL,
      mark_as_procedure INTEGER NOT NULL DEFAULT 0,
      data_shape_json TEXT,
      is_undefined INTEGER NOT NULL DEFAULT 0,
      patch_json TEXT,
      register_names_json TEXT,
      local_label TEXT,
      image_slot INTEGER NOT NULL DEFAULT 0,
      appended_cave_json TEXT,
      stack_locals_json TEXT
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_address_overrides_workspace_address
      ON address_overrides(workspace_id, image_slot, address);

    CREATE TABLE type_definitions (
      id TEXT PRIMARY KEY,
      workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      kind TEXT NOT NULL,
      name TEXT NOT NULL,
      fields_json TEXT NOT NULL,
      layout_rules_json TEXT,
      created_at TEXT NOT NULL,
      modified_at TEXT NOT NULL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_type_definitions_workspace_name
      ON type_definitions(workspace_id, name);

    CREATE TABLE manual_xrefs (
      id TEXT PRIMARY KEY,
      workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      from_address INTEGER NOT NULL,
      to_address INTEGER NOT NULL,
      kind TEXT NOT NULL,
      is_suppression INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      modified_at TEXT NOT NULL,
      image_slot INTEGER NOT NULL DEFAULT 0
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_manual_xrefs_workspace_endpoints
      ON manual_xrefs(workspace_id, image_slot, from_address, to_address, kind, is_suppression);

    CREATE TABLE bookmarks (
      id TEXT PRIMARY KEY,
      workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      address INTEGER NOT NULL,
      name TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL,
      modified_at TEXT NOT NULL,
      image_slot INTEGER NOT NULL DEFAULT 0
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_bookmarks_workspace_address
      ON bookmarks(workspace_id, image_slot, address);

    CREATE TABLE segment_overrides (
      id TEXT PRIMARY KEY,
      workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      original_name TEXT NOT NULL,
      display_name TEXT,
      rebase_delta INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      modified_at TEXT NOT NULL,
      image_slot INTEGER NOT NULL DEFAULT 0
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_segment_overrides_workspace_name
      ON segment_overrides(workspace_id, image_slot, original_name);

    CREATE TABLE source_lines (
      id INTEGER PRIMARY KEY,
      binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE,
      address INTEGER NOT NULL,
      file TEXT,
      line INTEGER NOT NULL,
      column INTEGER NOT NULL,
      is_end_sequence INTEGER NOT NULL DEFAULT 0,
      debug_artifact_uuid TEXT,
      debug_artifact_macho_sha256 TEXT,
      debug_artifact_macho_byte_count INTEGER,
      line_program_unit_offset INTEGER,
      file_table_index INTEGER,
      table_path_kind TEXT,
      table_path TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_source_lines_binary_id ON source_lines(binary_id);

    CREATE TABLE logical_breakpoint_catalogs (
      workspace_id INTEGER PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
      workspace_uuid TEXT NOT NULL,
      catalog_uuid TEXT NOT NULL,
      revision INTEGER NOT NULL CHECK(revision > 0),
      specification_count INTEGER NOT NULL CHECK(specification_count >= 0),
      catalog_sha256 TEXT NOT NULL
    );

    CREATE TABLE logical_breakpoints (
      id TEXT PRIMARY KEY,
      workspace_id INTEGER NOT NULL REFERENCES logical_breakpoint_catalogs(workspace_id)
        ON DELETE CASCADE,
      revision INTEGER NOT NULL CHECK(revision > 0),
      specification_version INTEGER NOT NULL,
      specification_byte_count INTEGER NOT NULL,
      specification_sha256 TEXT NOT NULL,
      specification_json TEXT NOT NULL,
      created_at TEXT NOT NULL,
      modified_at TEXT NOT NULL
    );
    CREATE INDEX idx_logical_breakpoints_workspace_id
      ON logical_breakpoints(workspace_id, id);

    CREATE TABLE launch_profile_catalogs (
      workspace_id INTEGER PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
      workspace_uuid TEXT NOT NULL,
      catalog_uuid TEXT NOT NULL,
      revision INTEGER NOT NULL,
      profile_count INTEGER NOT NULL,
      selected_profile_uuid TEXT,
      catalog_version INTEGER NOT NULL,
      catalog_byte_count INTEGER NOT NULL,
      catalog_sha256 TEXT NOT NULL,
      catalog_blob BLOB NOT NULL
    );

    \(phase2AssistantSessionRecordsSchemaSQL)
    \(phase2RuntimeAuthorityRecordsSchemaSQL)
    \(phase2ShellSessionsSchemaSQL)
    \(reconstructionSchemaSQL)
    \(savedWatchesSchemaSQL)
    \(constantCFStringsSchemaSQL)
    PRAGMA user_version = 44;
    """

    /// Versions 1...7 predate the individually factored migrations below. Their core tables are
    /// still recognizable, so converge by adding every absent current table/index without
    /// replacing an existing object, then run the same image-aware and logical-breakpoint
    /// finalizers as every later version. The version pragma is deliberately removed: only the
    /// finalizer may stamp v30 after it has validated and migrated durable intent.
    private static let earlySchemaConvergenceSQL = schemaSQL
        .replacingOccurrences(of: "CREATE TABLE ", with: "CREATE TABLE IF NOT EXISTS ")
        .replacingOccurrences(
            of: "CREATE TABLE IF NOT EXISTS IF NOT EXISTS ",
            with: "CREATE TABLE IF NOT EXISTS "
        )
        .replacingOccurrences(
            of: "CREATE UNIQUE INDEX idx_binaries_workspace_image_slot",
            with: "CREATE UNIQUE INDEX IF NOT EXISTS idx_binaries_workspace_image_slot"
        )
        .replacingOccurrences(
            of: "CREATE INDEX idx_logical_breakpoints_workspace_id",
            with: "CREATE INDEX IF NOT EXISTS idx_logical_breakpoints_workspace_id"
        )
        .replacingOccurrences(of: "PRAGMA user_version = 44;", with: "")

    private static let workspaceDocumentsSchemaSQL = """
    CREATE TABLE IF NOT EXISTS workspace_documents (
      workspace_id INTEGER PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
      document_id TEXT NOT NULL,
      package_path TEXT NOT NULL,
      last_opened_at TEXT NOT NULL,
      last_saved_at TEXT,
      is_dirty INTEGER NOT NULL DEFAULT 0,
      file_version_identifier TEXT,
      conflict_detected_at TEXT,
      conflict_reason TEXT,
      input_copying_decision TEXT NOT NULL DEFAULT 'copy_inputs_into_package',
      bookmark_resolution_decision TEXT NOT NULL DEFAULT 'resolve_stored_bookmarks',
      bookmark_resolution_error TEXT,
      recent_document_state TEXT NOT NULL DEFAULT 'available',
      recent_document_state_updated_at TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_workspace_documents_last_opened_at ON workspace_documents(last_opened_at DESC);
    CREATE INDEX IF NOT EXISTS idx_workspace_documents_conflict_detected_at ON workspace_documents(conflict_detected_at DESC);
    CREATE INDEX IF NOT EXISTS idx_workspace_documents_recent_document_state ON workspace_documents(recent_document_state);
    """

    private static let workspaceDocumentAutosaveDecisionsSchemaSQL = """
    CREATE TABLE IF NOT EXISTS workspace_document_autosave_decisions (
      id INTEGER PRIMARY KEY,
      uuid TEXT NOT NULL UNIQUE,
      workspace_id INTEGER NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
      document_id TEXT NOT NULL,
      package_path TEXT NOT NULL,
      decision TEXT NOT NULL,
      reason TEXT,
      file_version_identifier TEXT,
      decided_at TEXT NOT NULL,
      completed_at TEXT,
      error_message TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_workspace_document_autosave_decisions_workspace_id ON workspace_document_autosave_decisions(workspace_id, decided_at DESC);
    CREATE INDEX IF NOT EXISTS idx_workspace_document_autosave_decisions_decided_at ON workspace_document_autosave_decisions(decided_at DESC);
    """

    struct WorkspaceRecord: Equatable {
        var id: Int64?
        var uuid: UUID
        var name: String
        var createdAt: Date
        var modifiedAt: Date
    }

    struct BinaryRecord: Equatable {
        var id: Int64?
        var uuid: UUID
        var workspaceID: Int64
        var name: String
        var path: String
        var originalPathBookmark: Data?
        var kind: String
        var architecture: String
        var fileHash: String
        var fileSize: Int64
        var hexBytes: Data?
        var isBundle: Bool
        var imageSlot: Int = 0
        /// The persisted universal-slice pick (nil = default selection rule / thin binary).
        var selectedSliceIndex: Int? = nil
        /// Original loader observation; never inferred from retained thin attachment bytes.
        var machOSelectedSliceFact: MachOSelectedSliceFact? = nil
        /// Optional Codable `AnalysisInputFingerprint` JSON, scoped 1:1 to this binary's image
        /// analysis bucket.
        var analysisInputFingerprintJSON: String? = nil
        /// Full loader-authored metadata. Empty metadata is represented as SQL
        /// NULL so schema-v40 rows migrate without a fabricated backfill.
        var metadata: BinaryMetadataSummary = .empty
        /// Exact outer-container/member coordinate for an ELF object selected from a Unix archive.
        /// Stored separately from `path`, which remains the outer archive authority.
        var elfArchiveMemberIdentity: ELFArchiveMemberSelection? = nil
    }

    struct FunctionRecord: Equatable {
        var id: Int64?
        var uuid: UUID
        var binaryID: Int64
        var startAddress: UInt64
        var endAddress: UInt64?
        var symbolName: String?
        var demangledName: String?
        var confidence: Double
        /// HOP-1 analysis no-return provenance (`AnalysisNoReturnProvenance` raw value); NULL when
        /// the function is not known to halt or the row predates the column (§4.12a).
        var noReturnProvenance: String? = nil
    }

    struct SymbolRecord: Equatable {
        var id: Int64?
        var uuid: UUID
        var binaryID: Int64
        var name: String
        var address: UInt64?
        var kind: String
        var libraryName: String?
        var rawLinkageName: String? = nil
    }

    struct ImportRecord: Equatable {
        var id: Int64?
        var uuid: UUID
        var binaryID: Int64
        var name: String
        var libraryName: String?
        var libraryOrdinal: Int?
    }

    struct IndirectSymbolRecord: Equatable {
        var id: Int64?
        var uuid: UUID
        var binaryID: Int64
        var kind: String
        var sourceSection: String
        var address: UInt64
        var entrySize: UInt32
        var tableIndex: UInt32
        var rawSymbolIndex: UInt32
        var symbolIndex: Int?
        var symbolName: String?
        var libraryOrdinal: Int?
        var libraryName: String?
        var isLocal: Bool
        var isAbsolute: Bool
    }

    struct ExportRecord: Equatable {
        var id: Int64?
        var uuid: UUID
        var binaryID: Int64
        var name: String
        var address: UInt64?
        var source: String
        var terminalFlags: UInt64? = nil
    }

    struct StringLiteralRecord: Equatable {
        var id: Int64?
        var uuid: UUID
        var binaryID: Int64
        var value: String
        var address: UInt64
        var sourceSection: String
        var byteLength: Int
    }

    struct BasicBlockRecord: Equatable {
        var id: Int64?
        var uuid: UUID
        var functionID: Int64
        var startAddress: UInt64
        var endAddress: UInt64
        var instructionCount: Int
    }

    struct XRefRecord: Equatable {
        var id: Int64?
        var uuid: UUID
        var binaryID: Int64
        var fromAddress: UInt64
        var toAddress: UInt64
        var kind: String
    }

    struct ControlFlowEdgeRecord: Equatable {
        var id: Int64?
        var uuid: UUID
        var binaryID: Int64
        var fromAddress: UInt64
        var toAddress: UInt64
        var kind: String
    }

    struct AddressOverrideRecord: Equatable {
        var id: Int64?
        var workspaceID: Int64
        var address: UInt64
        var imageSlot: Int = 0
        var customName: String?
        var customComment: String?
        var tag: String?
        var colorTag: String?
        var isData: Bool
        var signatureJSON: String?
        var appliedTypeName: String?
        var switchHintJSON: String?
        var operandFormat: String?
        var markAsProcedure: Bool
        var dataShapeJSON: String?
        var isUndefined: Bool
        var patchJSON: String?
        var appendedCaveJSON: String? = nil
        var registerNamesJSON: String?
        var stackLocalsJSON: String? = nil
        var localLabel: String?
        var createdAt: Date
        var modifiedAt: Date
    }

    struct ManualXRefRecord: Equatable {
        var id: UUID
        var workspaceID: Int64
        var fromAddress: UInt64
        var toAddress: UInt64
        var kind: String
        var isSuppression: Bool
        var imageSlot: Int = 0
        var createdAt: Date
        var modifiedAt: Date
    }

    struct BookmarkRecord: Equatable {
        var id: UUID
        var workspaceID: Int64
        var address: UInt64
        var imageSlot: Int = 0
        var name: String
        var createdAt: Date
        var modifiedAt: Date
    }

    struct SegmentOverrideRecord: Equatable {
        var id: UUID
        var workspaceID: Int64
        var originalName: String
        var imageSlot: Int = 0
        var displayName: String?
        var rebaseDelta: Int64
        var createdAt: Date
        var modifiedAt: Date
    }

    struct TypeDefinitionRecord: Equatable {
        var id: UUID
        var workspaceID: Int64
        var kind: String
        var name: String
        var fieldsJSON: String
        var layoutRulesJSON: String?
        var createdAt: Date
        var modifiedAt: Date
    }

    struct WorkspaceSessionRecord: Equatable {
        var workspaceID: Int64
        var selectedSidebarItemID: String?
        var selectedAddress: UInt64?
        var selectedTool: WorkspaceTool
        var editorMode: EditorMode
        var isInspectorPresented: Bool
        var sidebarSearchText: String
        var updatedAt: Date
        var focusedImageSlot: ImageSlot = .primary
    }

    struct WorkspaceDocumentRecord: Equatable {
        var workspaceID: Int64
        var documentID: UUID
        var packagePath: String
        var lastOpenedAt: Date
        var lastSavedAt: Date?
        var isDirty: Bool
        var fileVersionIdentifier: String? = nil
        var conflictDetectedAt: Date? = nil
        var conflictReason: String? = nil
        var inputCopyingDecision: WorkspaceInputCopyingDecision = .copyInputsIntoPackage
        var bookmarkResolutionDecision: WorkspaceBookmarkResolutionDecision = .resolveStoredBookmarks
        var bookmarkResolutionError: String? = nil
        var recentDocumentState: WorkspaceRecentDocumentState = .available
        var recentDocumentStateUpdatedAt: Date? = nil

        var lifecycleState: WorkspaceDocumentLifecycleState {
            if conflictDetectedAt != nil || conflictReason != nil || recentDocumentState == .conflicted {
                return .conflicted(reason: conflictReason)
            }
            return isDirty ? .dirty : .clean
        }

        var allowsAutosave: Bool {
            guard recentDocumentState == .available else {
                return false
            }

            return switch lifecycleState {
            case .clean, .dirty:
                true
            case .conflicted:
                false
            }
        }
    }

    enum WorkspaceDocumentAutosaveDecision: String, Equatable, CaseIterable {
        case saved = "saved"
        case skippedNoChanges = "skipped_no_changes"
        case skippedConflict = "skipped_conflict"
        case failed = "failed"
    }

    struct WorkspaceDocumentAutosaveDecisionRecord: Equatable {
        var id: Int64?
        var uuid: UUID
        var workspaceID: Int64
        var documentID: UUID
        var packagePath: String
        var decision: WorkspaceDocumentAutosaveDecision
        var reason: String?
        var fileVersionIdentifier: String?
        var decidedAt: Date
        var completedAt: Date?
        var errorMessage: String?
    }

    enum WorkspaceDocumentLifecycleState: Equatable {
        case clean
        case dirty
        case conflicted(reason: String?)
    }

    struct WorkspaceDocumentMetadata: Equatable {
        var workspace: WorkspaceRecord
        var document: WorkspaceDocumentRecord

        var workspaceID: Int64 {
            document.workspaceID
        }

        var workspaceName: String {
            workspace.name
        }

        var documentID: UUID {
            document.documentID
        }

        var packageURL: URL {
            URL(fileURLWithPath: document.packagePath, isDirectory: true)
        }

        var packageDisplayName: String {
            let name = packageURL.deletingPathExtension().lastPathComponent
            return name.isEmpty ? workspace.name : name
        }

        var lifecycleState: WorkspaceDocumentLifecycleState {
            document.lifecycleState
        }

        var allowsAutosave: Bool {
            document.allowsAutosave
        }

        var inputCopyingDecision: WorkspaceInputCopyingDecision {
            document.inputCopyingDecision
        }

        var bookmarkResolutionDecision: WorkspaceBookmarkResolutionDecision {
            document.bookmarkResolutionDecision
        }

        var bookmarkResolutionError: String? {
            document.bookmarkResolutionError
        }

        var recentDocumentState: WorkspaceRecentDocumentState {
            document.recentDocumentState
        }
    }

    struct PersistedWorkspace {
        var workspace: WorkspaceRecord
        var snapshot: WorkspaceSnapshot
        var session: WorkspaceSessionRecord
        var reconstructionState: ReconstructionWorkspaceState = .empty
        var phase2ShellSessionRecord: Phase2ShellSessionPersistenceRecord?
        var assistantSessionRecords: [Phase2AssistantSessionPersistenceRecord] = []
        var runtimeAuthorityRecords: [Phase2RuntimeAuthorityPersistenceRecord] = []
        var logicalBreakpointCatalogAvailability: DebuggerLogicalBreakpointCatalogAvailability = .available
        var launchProfileCatalogAvailability: DebuggerLaunchProfileCatalogAvailability = .available
        var typeCatalogLoadDiagnostics: [WorkspaceTypeCatalogLoadDiagnostic] = []
        /// HS-2b: what load-time validation repaired while this workspace entered the database
        /// (`importPackage`). Transient, never persisted; the store surfaces it and rebuilds.
        var analysisRepairs: [WorkspaceAnalysisRepair] = []
    }

    enum Phase2AssistantPersistedSessionStatus: String, Equatable, CaseIterable {
        case completed
        case failed
        case cancelled
        case readinessBlocked = "readiness_blocked"
        case outcomeUnknown = "outcome_unknown"
    }

    struct Phase2AssistantSessionPersistenceRecord: Equatable {
        static let schemaVersion = 3

        var id: UUID
        var workspaceID: Int64
        var workspaceUUID: UUID
        var documentID: UUID
        var sequence: Int
        var conversationID: UUID
        var turnSequence: Int
        var inferenceTurnID: UUID
        var isLegacy: Bool
        var intentID: String
        var userGoal: String
        var status: Phase2AssistantPersistedSessionStatus
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

        init(
            id: UUID,
            workspaceID: Int64,
            workspaceUUID: UUID,
            documentID: UUID,
            sequence: Int,
            conversationID: UUID? = nil,
            turnSequence: Int = 1,
            inferenceTurnID: UUID? = nil,
            isLegacy: Bool = false,
            intentID: String,
            userGoal: String,
            status: Phase2AssistantPersistedSessionStatus,
            promptText: String,
            answerText: String?,
            transcriptText: String,
            contextDigest: String?,
            canonicalByteCount: Int?,
            providerToolCount: Int = 0,
            recordSchemaVersion: Int = Self.schemaVersion,
            createdAt: Date,
            completedAt: Date? = nil,
            continuationCheckpoint: Phase2AssistantContinuationCheckpointRecord? = nil,
            contentSHA256: String? = nil
        ) {
            self.id = id
            self.workspaceID = workspaceID
            self.workspaceUUID = workspaceUUID
            self.documentID = documentID
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
            self.contentSHA256 = contentSHA256 ?? Self.contentSHA256(
                id: id,
                workspaceUUID: workspaceUUID,
                documentID: documentID,
                sequence: sequence,
                conversationID: conversationID ?? id,
                turnSequence: turnSequence,
                inferenceTurnID: inferenceTurnID ?? id,
                isLegacy: isLegacy,
                intentID: intentID,
                userGoal: userGoal,
                status: status,
                promptText: promptText,
                answerText: answerText,
                transcriptText: transcriptText,
                contextDigest: contextDigest,
                canonicalByteCount: canonicalByteCount,
                providerToolCount: providerToolCount,
                recordSchemaVersion: recordSchemaVersion,
                createdAt: createdAt,
                completedAt: completedAt,
                continuationCheckpoint: continuationCheckpoint
            )
        }

        static func contentSHA256(
            id: UUID,
            workspaceUUID: UUID,
            documentID: UUID,
            sequence: Int,
            conversationID: UUID,
            turnSequence: Int,
            inferenceTurnID: UUID,
            isLegacy: Bool,
            intentID: String,
            userGoal: String,
            status: Phase2AssistantPersistedSessionStatus,
            promptText: String,
            answerText: String?,
            transcriptText: String,
            contextDigest: String?,
            canonicalByteCount: Int?,
            providerToolCount: Int,
            recordSchemaVersion: Int,
            createdAt: Date,
            completedAt: Date?,
            continuationCheckpoint: Phase2AssistantContinuationCheckpointRecord? = nil
        ) -> String {
            var canonical = [
                "schema=\(recordSchemaVersion)",
                "id=\(id.uuidString)",
                "workspace=\(workspaceUUID.uuidString)",
                "document=\(documentID.uuidString)",
                "sequence=\(sequence)",
                "conversation=\(conversationID.uuidString)",
                "turnSequence=\(turnSequence)",
                "inferenceTurn=\(inferenceTurnID.uuidString)",
                "legacy=\(isLegacy ? 1 : 0)",
                "intent=\(intentID)",
                "status=\(status.rawValue)",
                "providerToolCount=\(providerToolCount)",
                "canonicalByteCount=\(canonicalByteCount.map(String.init) ?? "null")",
                "contextDigest=\(contextDigest ?? "null")",
                "createdAt=\(WorkspaceDatabase.string(from: createdAt))",
                "completedAt=\(completedAt.map(WorkspaceDatabase.string(from:)) ?? "null")",
                "goal=\(userGoal)",
                "prompt=\(promptText)",
                "answer=\(answerText ?? "null")",
                "transcript=\(transcriptText)",
            ].joined(separator: "\n")
            if recordSchemaVersion >= 3 {
                canonical += "\ncontinuationCheckpoint=\(continuationCheckpoint?.canonicalJSON ?? "null")"
            }
            let digest = SHA256.hash(data: Data(canonical.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }

        func calculatedContentSHA256() -> String {
            Self.contentSHA256(
                id: id, workspaceUUID: workspaceUUID, documentID: documentID,
                sequence: sequence, conversationID: conversationID, turnSequence: turnSequence,
                inferenceTurnID: inferenceTurnID, isLegacy: isLegacy, intentID: intentID,
                userGoal: userGoal, status: status, promptText: promptText, answerText: answerText,
                transcriptText: transcriptText, contextDigest: contextDigest,
                canonicalByteCount: canonicalByteCount, providerToolCount: providerToolCount,
                recordSchemaVersion: recordSchemaVersion, createdAt: createdAt,
                completedAt: completedAt, continuationCheckpoint: continuationCheckpoint
            )
        }

        static func contentSHA256V1(
            id: UUID,
            workspaceUUID: UUID,
            documentID: UUID,
            sequence: Int,
            intentID: String,
            userGoal: String,
            status: Phase2AssistantPersistedSessionStatus,
            promptText: String,
            answerText: String?,
            transcriptText: String,
            contextDigest: String?,
            canonicalByteCount: Int?,
            providerToolCount: Int,
            createdAt: Date,
            completedAt: Date?
        ) -> String {
            let canonical = [
                "schema=1", "id=\(id.uuidString)", "workspace=\(workspaceUUID.uuidString)",
                "document=\(documentID.uuidString)", "sequence=\(sequence)", "intent=\(intentID)",
                "status=\(status.rawValue)", "providerToolCount=\(providerToolCount)",
                "canonicalByteCount=\(canonicalByteCount.map(String.init) ?? "null")",
                "contextDigest=\(contextDigest ?? "null")",
                "createdAt=\(WorkspaceDatabase.string(from: createdAt))",
                "completedAt=\(completedAt.map(WorkspaceDatabase.string(from:)) ?? "null")",
                "goal=\(userGoal)", "prompt=\(promptText)", "answer=\(answerText ?? "null")",
                "transcript=\(transcriptText)",
            ].joined(separator: "\n")
            let digest = SHA256.hash(data: Data(canonical.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    struct Phase2RuntimeAuthorityPersistenceRecord: Equatable {
        static let schemaVersion = 1

        var id: UUID
        var workspaceID: Int64
        var workspaceUUID: UUID
        var documentID: UUID
        var sessionID: UUID
        var surfaces: Set<Phase2RuntimeAuthoritySurface>
        var terminalBackend: Phase2TerminalEmulationBackend
        var ptyReusePolicy: Phase2TerminalPTYReusePolicy
        var debuggerAuthorityPolicy: Phase2DebuggerAuthorityToolPolicy
        var providerVisibleShellExecutionEnabled: Bool
        var recordSchemaVersion: Int
        var createdAt: Date

        init(
            id: UUID = UUID(),
            workspaceID: Int64,
            workspaceUUID: UUID,
            documentID: UUID,
            sessionID: UUID,
            surfaces: Set<Phase2RuntimeAuthoritySurface>,
            terminalBackend: Phase2TerminalEmulationBackend,
            ptyReusePolicy: Phase2TerminalPTYReusePolicy,
            debuggerAuthorityPolicy: Phase2DebuggerAuthorityToolPolicy,
            providerVisibleShellExecutionEnabled: Bool,
            recordSchemaVersion: Int = Self.schemaVersion,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.workspaceID = workspaceID
            self.workspaceUUID = workspaceUUID
            self.documentID = documentID
            self.sessionID = sessionID
            self.surfaces = surfaces
            self.terminalBackend = terminalBackend
            self.ptyReusePolicy = ptyReusePolicy
            self.debuggerAuthorityPolicy = debuggerAuthorityPolicy
            self.providerVisibleShellExecutionEnabled = providerVisibleShellExecutionEnabled
            self.recordSchemaVersion = recordSchemaVersion
            self.createdAt = createdAt
        }

        init(
            _ record: Phase2TerminalRuntimeAuthorityRecord,
            workspaceID: Int64,
            workspaceUUID: UUID,
            documentID: UUID
        ) {
            self.init(
                id: record.id,
                workspaceID: workspaceID,
                workspaceUUID: workspaceUUID,
                documentID: documentID,
                sessionID: record.sessionID,
                surfaces: record.surfaces,
                terminalBackend: record.terminalBackend,
                ptyReusePolicy: record.ptyReusePolicy,
                debuggerAuthorityPolicy: record.debuggerAuthorityPolicy,
                providerVisibleShellExecutionEnabled: record.providerVisibleShellExecutionEnabled,
                recordSchemaVersion: record.schemaVersion,
                createdAt: record.createdAt
            )
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

    struct Phase2ShellSessionPersistenceRecord: Equatable {
        static let schemaVersion = 1

        var workspaceID: Int64
        var workspaceUUID: UUID
        var documentID: UUID
        var shellSession: WorkspacePackagePhase2ShellSession
        var recordSchemaVersion: Int
        var updatedAt: Date

        init(
            workspaceID: Int64,
            workspaceUUID: UUID,
            documentID: UUID,
            shellSession: WorkspacePackagePhase2ShellSession,
            recordSchemaVersion: Int = Self.schemaVersion,
            updatedAt: Date = Date()
        ) {
            self.workspaceID = workspaceID
            self.workspaceUUID = workspaceUUID
            self.documentID = documentID
            self.shellSession = shellSession
            self.recordSchemaVersion = recordSchemaVersion
            self.updatedAt = updatedAt
        }
    }

    struct PluginTrustRecord: Equatable {
        var identifier: String
        var decision: PluginTrustDecision
        var manifestHash: String?
        var updatedAt: Date
    }

    enum ReconstructionMutationPhase: String, CaseIterable {
        case deletedRows
        case insertedProjects
        case insertedArtifactContents
        case insertedArtifactGraph
        case insertedJobs
        case insertedTasks
        case insertedCheckpoints
        case insertedToolReceipts
        case insertedModelReceipts
        case insertedEvidence
        case insertedEvidenceRelations
    }

    enum ReconstructionSidecarBootstrapPhase: String {
        case insertedWorkspace
    }

    enum ReconstructionFinalResultMutationPhase: String {
        case insertedFinalResults
    }

    enum ReconstructionSidecarBindingPreflight: Equatable {
        case uninitialized
        case emptyCurrentSchema
        case matched(workspaceRowID: Int64)
        case workspaceMismatch
        case documentMismatch
        case canonicalPackagePathMismatch
    }

    enum DatabaseError: Error, Equatable, LocalizedError {
        case openFailed(String)
        case prepareFailed(String)
        case bindFailed(String)
        case corruptRow(table: String, rowIdentity: String, field: String)
        case stepFailed(String)
        case invalidAddress(UInt64)
        case invalidUnsignedInteger(field: String, value: Int64)
        case invalidDate(String)
        case invalidEditorMode(String)
        case invalidWorkspaceBookmarkResolutionDecision(String)
        case invalidWorkspaceInputCopyingDecision(String)
        case invalidWorkspaceRecentDocumentState(String)
        case invalidPluginTrustDecision(String)
        case invalidPluginExternalRunStatus(String)
        case invalidUUID(String)
        case invalidWorkspaceDocumentAutosaveDecision(String)
        case invalidWorkspaceTool(String)
        case invalidPhase2AssistantSessionStatus(String)
        case invalidPhase2AssistantSessionRecord(String)
        case invalidPhase2RuntimeAuthority(String)
        case artifactIntegrityRequiresReimport(binaryID: UUID)
        case archiveIdentityRequiresReimport(binaryID: UUID)
        case incompatibleSourceLinesData(reasons: [String])
        case incompatibleSourceLinesDependencies(objects: [String])
        case incompatibleSourceLinesSchema(columns: [String])
        case binaryMetadataSchemaInvalid(columns: [String])
        case logicalBreakpointCatalogUnavailable
        case logicalBreakpointSchemaInvalid
        case launchProfileCatalogUnavailable
        case launchProfileSchemaInvalid
        case phase2AssistantSessionSchemaInvalid
        case reconstructionCheckpointConflict(String)
        case reconstructionIdentityConflict(String)
        case reconstructionInjectedFailure(String)
        case reconstructionSchemaInvalid(String)
        case reconstructionAttachmentSourcesUnavailable
        case reconstructionStateInvalid(String)
        case duplicateImageSlot(workspaceID: Int64, imageSlot: Int)
        case migrationRequired(stored: Int, supported: Int)
        case migrationRollbackFailed(original: String, rollback: String)
        case transactionRollbackFailed(original: String, rollback: String)
        case missingImageAnalysis(ImageSlot)
        case missingPackageAttachmentData(UUID)
        case notFound
        case unsupportedSchemaVersion(stored: Int, supported: Int)

        var errorDescription: String? {
            switch self {
            case .openFailed(let message):
                "SQLite open failed: \(message)"
            case .prepareFailed(let message):
                "SQLite prepare failed: \(message)"
            case .bindFailed(let message):
                "SQLite bind failed: \(message)"
            case .corruptRow(let table, let rowIdentity, let field):
                "Corrupt SQLite row in \(table) (\(rowIdentity)), field \(field)."
            case .stepFailed(let message):
                "SQLite step failed: \(message)"
            case .migrationRollbackFailed(let original, let rollback):
                "Schema migration failed (\(original)) and its savepoint rollback also failed (\(rollback)); the database requires manual inspection."
            case .transactionRollbackFailed(let original, let rollback):
                "Database transaction failed (\(original)) and its rollback also failed (\(rollback)); the connection was closed and the database requires manual inspection."
            case .invalidAddress(let address):
                "Address \(address.hexAddress) is outside SQLite signed integer storage."
            case .invalidUnsignedInteger(let field, let value):
                "Invalid negative or out-of-range unsigned database value for \(field): \(value)"
            case .invalidDate(let value):
                "Invalid database date value: \(value)"
            case .invalidEditorMode(let value):
                "Invalid workspace editor mode value: \(value)"
            case .invalidWorkspaceBookmarkResolutionDecision(let value):
                "Invalid workspace bookmark resolution decision value: \(value)"
            case .invalidWorkspaceInputCopyingDecision(let value):
                "Invalid workspace input copying decision value: \(value)"
            case .invalidWorkspaceRecentDocumentState(let value):
                "Invalid workspace recent document state value: \(value)"
            case .invalidPluginTrustDecision(let value):
                "Invalid plugin trust decision value: \(value)"
            case .invalidPluginExternalRunStatus(let value):
                "Invalid plugin external run status value: \(value)"
            case .invalidUUID(let value):
                "Invalid database UUID value: \(value)"
            case .invalidWorkspaceDocumentAutosaveDecision(let value):
                "Invalid workspace document autosave decision value: \(value)"
            case .invalidWorkspaceTool(let value):
                "Invalid workspace tool value: \(value)"
            case .invalidPhase2AssistantSessionStatus(let value):
                "Invalid Phase 2 Assistant session status: \(value)"
            case .invalidPhase2AssistantSessionRecord(let value):
                "Invalid Phase 2 Assistant session record: \(value)"
            case .invalidPhase2RuntimeAuthority(let value):
                "Invalid Phase 2 runtime authority record: \(value)"
            case .artifactIntegrityRequiresReimport(let binaryID):
                "Binary \(binaryID.uuidString) has contradictory selected-slice evidence and must be reimported before saving."
            case .archiveIdentityRequiresReimport(let binaryID):
                "Binary \(binaryID.uuidString) has contradictory ELF archive member evidence and must be reimported before saving."
            case .incompatibleSourceLinesData(let reasons):
                "Workspace source_lines table contains data that cannot be normalized without changing row identity: \(reasons.joined(separator: ", "))."
            case .incompatibleSourceLinesDependencies(let objects):
                "Workspace source_lines table has unsupported dependent schema objects: \(objects.joined(separator: ", "))."
            case .incompatibleSourceLinesSchema(let columns):
                "Workspace source_lines table has an unsupported column layout: \(columns.joined(separator: ", "))."
            case .binaryMetadataSchemaInvalid(let columns):
                "Workspace binaries table does not match schema v41 loader-metadata columns: \(columns.joined(separator: ", "))."
            case .logicalBreakpointCatalogUnavailable:
                "The logical-breakpoint catalog is unavailable because its persistence receipt is invalid."
            case .logicalBreakpointSchemaInvalid:
                "The logical-breakpoint persistence schema does not match schema v30."
            case .launchProfileCatalogUnavailable:
                "The launch-profile catalog is unavailable because its persistence receipt is invalid."
            case .launchProfileSchemaInvalid:
                "The launch-profile persistence schema does not match schema v31."
            case .phase2AssistantSessionSchemaInvalid:
                "The Phase 2 Assistant session persistence schema does not match schema v32."
            case .reconstructionCheckpointConflict(let reason):
                "The reconstruction checkpoint compare-and-swap failed: \(reason)"
            case .reconstructionIdentityConflict(let reason):
                "The reconstruction identity collides with different canonical content: \(reason)"
            case .reconstructionInjectedFailure(let phase):
                "The reconstruction transaction injected a test failure after \(phase)."
            case .reconstructionSchemaInvalid(let reason):
                "The reconstruction persistence schema does not match schema v\(WorkspaceDatabase.schemaVersion): \(reason)"
            case .reconstructionAttachmentSourcesUnavailable:
                "The reconstruction corpus bytes are unavailable from a verified package source."
            case .reconstructionStateInvalid(let reason):
                "The reconstruction state graph is invalid: \(reason)"
            case .duplicateImageSlot(let workspaceID, let imageSlot):
                "Workspace \(workspaceID) contains duplicate binary image slot \(imageSlot); migration cannot enforce per-image uniqueness without data loss."
            case .migrationRequired(let stored, let supported):
                "Workspace database schema v\(stored) requires migration before opening with schema v\(supported)."
            case .missingImageAnalysis(let slot):
                "Workspace binary in image slot \(slot.rawValue) has no analysis bucket; refusing a data-losing save."
            case .missingPackageAttachmentData(let id):
                "Workspace database has no package attachment bytes for binary \(id.uuidString)."
            case .notFound:
                "No matching database row was found."
            case .unsupportedSchemaVersion(let stored, let supported):
                "Workspace database schema v\(stored) is newer than supported schema v\(supported)."
            }
        }
    }

    private var connection: OpaquePointer?
    /// C8: `run` reuses one prepared statement per SQL text. A save inserts every instruction,
    /// block, edge and xref through `run`, and re-preparing the same INSERT for each row (590,883
    /// instructions on vim) spent seconds in SQLite's parser. Finalized before the connection closes.
    private var runStatements: [String: OpaquePointer] = [:]
    private static let runStatementLimit = 128
    private var reconstructionMutationFailureForTesting: ReconstructionMutationPhase?
    private var reconstructionSidecarBootstrapFailureForTesting:
        ReconstructionSidecarBootstrapPhase?
    private var reconstructionFinalResultMutationFailureForTesting:
        ReconstructionFinalResultMutationPhase?
    private var transactionRollbackFailureForTesting = false
    let reconstructionCommitSequencingIdentity: String
    private let reconstructionMainDatabaseIsInMemory: Bool
    private(set) var reconstructionAttachmentVaultRootURL: URL
    private var reconstructionAttachmentVault: ReconstructionDurableAttachmentVault

    init(path: String = ":memory:") throws {
        reconstructionMainDatabaseIsInMemory = path == ":memory:"
        if reconstructionMainDatabaseIsInMemory {
            reconstructionCommitSequencingIdentity = "memory:\(UUID().uuidString)"
            reconstructionAttachmentVaultRootURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "MacScope-ReconstructionDatabaseVault-\(UUID().uuidString)",
                    isDirectory: true
                )
        } else {
            let databaseURL = URL(fileURLWithPath: path, isDirectory: false)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            reconstructionCommitSequencingIdentity = "file:\(databaseURL.path)"
            reconstructionAttachmentVaultRootURL = databaseURL.deletingLastPathComponent()
                .appendingPathComponent(
                    ".\(databaseURL.lastPathComponent).reconstruction-vault",
                    isDirectory: true
                )
        }
        reconstructionAttachmentVault = ReconstructionDurableAttachmentVault(
            rootURL: reconstructionAttachmentVaultRootURL
        )
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            if let handle {
                sqlite3_close(handle)
            }
            throw DatabaseError.openFailed(message)
        }

        connection = handle
        try execute("PRAGMA foreign_keys = ON;")
    }

    deinit {
        finalizeRunStatements()
        if let connection {
            sqlite3_close(connection)
        }
    }

    private func finalizeRunStatements() {
        for statement in runStatements.values { sqlite3_finalize(statement) }
        runStatements.removeAll()
    }

    static func inMemory() throws -> WorkspaceDatabase {
        try WorkspaceDatabase(path: ":memory:")
    }

    func applySchema() throws {
        try applyBaseSchema()
        // Additive authoring table, like imported prototypes; absent rows mean no accepted source.
        try execute("""
            CREATE TABLE IF NOT EXISTS source_link_states (
              workspace_id INTEGER PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
              state_blob BLOB NOT NULL CHECK(length(state_blob) <= 1048576)
            );
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS imported_function_prototypes (
              workspace_id INTEGER PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
              prototypes_json TEXT NOT NULL
            );
            """)
        if !Set(try columnNames(in: "exports")).contains("terminal_flags") {
            try execute("ALTER TABLE exports ADD COLUMN terminal_flags INTEGER;")
        }
    }

    private func applyBaseSchema() throws {
        let version = try userVersion()
        if version == Self.schemaVersion {
            try validateInstructionOperandsSchema()
            try ensureAddressOverrideColumns()
            try validateSavedWatchesSchema()
            try ensureAnalysisFingerprintSchema()
            try validateBinaryMetadataSchema()
            try validateMachOSelectedSliceFactSchema()
            try validateBreakpointResolutionPrerequisiteSchema(requireTables: true)
            try validateLogicalBreakpointsSchema()
            try validateLaunchProfilesSchema()
            try validatePhase2AssistantSessionRecordsSchema()
            try execute(Self.phase2RuntimeAuthorityRecordsSchemaSQL)
            try execute(Self.phase2ShellSessionsSchemaSQL)
            try validateReconstructionSchema()
            return
        }

        if (1...7).contains(version) {
            try migrateEarlyVersionToCurrent(stored: version)
            return
        }

        if version == 8 {
            try migrateVersion8To12()
            return
        }

        if version == 9 {
            try migrateVersion9To12()
            return
        }

        if version == 10 {
            try migrateVersion10To12()
            return
        }

        if version == 11 {
            try migrateVersion11To12()
            return
        }

        if version == 12 {
            try migrateVersion12To13()
            return
        }

        if version == 13 {
            try migrateVersion13To14()
            return
        }

        if version == 14 {
            try migrateVersion14To15()
            return
        }

        if version == 15 {
            try migrateVersion15To16()
            return
        }

        if version == 16 {
            try migrateVersion16To17()
            return
        }

        if version == 17 {
            try migrateVersion17To18()
            return
        }

        if version == 18 {
            try migrateVersion18To19()
            return
        }

        if version == 19 {
            try migrateVersion19To20()
            return
        }

        if version == 20 {
            try migrateVersion20To21()
            return
        }

        if version == 21 {
            try migrateVersion21To22()
            return
        }

        if version == 22 {
            try migrateVersion22To23()
            return
        }

        if version == 23 {
            try migrateVersion23To24()
            return
        }

        if version == 24 {
            try migrateVersion24To25()
            return
        }

        if version == 25 {
            try migrateVersion25To26()
            return
        }

        if version == 26 {
            try migrateVersion26To27()
            return
        }

        if version == 27 {
            try migrateVersion27ToCurrent()
            return
        }

        if version == 28 {
            try migrateVersion28To29()
            return
        }

        if version == 29 {
            try migrateVersion29To30()
            return
        }

        if version == 30 {
            try migrateVersion30To31()
            return
        }

        if version == 31 {
            try migrateVersion31To32()
            return
        }

        if version == 32 {
            try migrateVersion32To33()
            return
        }

        if version == 33 {
            try migrateVersion33To34()
            return
        }

        if version == 34 {
            try migrateVersion34To35()
            return
        }

        if version == 35 {
            try migrateVersion35To36()
            return
        }

        if version == 36 {
            try migrateVersion36To37()
            return
        }

        if version == 37 {
            try migrateVersion37To38()
            return
        }

        if version == 38 {
            try migrateVersion38To39()
            return
        }

        if version == 39 {
            try migrateVersion39To40()
            return
        }

        if version == 40 {
            try migrateVersion40To41()
            return
        }

        if version == 41 {
            try migrateVersion41To42()
            return
        }
        if version == 42 {
            try migrateVersion42To43()
            return
        }
        if version == 43 {
            try migrateVersion43To44()
            return
        }
        guard version == 0 else {
            if version > Self.schemaVersion {
                throw DatabaseError.unsupportedSchemaVersion(stored: version, supported: Self.schemaVersion)
            }
            throw DatabaseError.migrationRequired(stored: version, supported: Self.schemaVersion)
        }

        guard try tableNames().isEmpty else {
            throw DatabaseError.migrationRequired(stored: version, supported: Self.schemaVersion)
        }

        try transaction {
            try execute(Self.schemaSQL)
            try validateInstructionOperandsSchema()
            try execute(Self.savedWatchesSchemaSQL)
            try validateSavedWatchesSchema()
            try validateBreakpointResolutionPrerequisiteSchema(requireTables: true)
            try validateLogicalBreakpointsSchema()
            try validateLaunchProfilesSchema()
            try execute(Self.phase2RuntimeAuthorityRecordsSchemaSQL)
            try execute(Self.phase2ShellSessionsSchemaSQL)
            try validateReconstructionSchema()
        }
    }

    private func migrateEarlyVersionToCurrent(stored: Int) throws {
        let tables = Set(try tableNames())
        if tables.isEmpty {
            try transaction {
                try execute(Self.earlySchemaConvergenceSQL)
                try finalizeLogicalBreakpointsAndStampV30()
            }
            return
        }
        guard tables.isSuperset(of: Set(["workspaces", "binaries", "functions", "instructions"])) else {
            throw DatabaseError.migrationRequired(stored: stored, supported: Self.schemaVersion)
        }
        try transaction {
            // Add slot columns before the current index inventory is converged; an early binaries
            // table cannot satisfy the v27 unique index until image_slot exists.
            try ensureImageAwareSchema()
            try execute(Self.earlySchemaConvergenceSQL)
            try ensureImageAwareSchema()
            try finalizeLogicalBreakpointsAndStampV30()
        }
    }

    private func migrateVersion8To12() throws {
        let tables = Set(try tableNames())
        let expectedVersion8Tables: Set<String> = [
            "basic_blocks",
            "binaries",
            "control_flow_edges",
            "exports",
            "functions",
            "imports",
            "indirect_symbols",
            "instructions",
            "plugin_external_runs",
            "plugin_trust_decisions",
            "string_literals",
            "symbols",
            "workspace_sessions",
            "workspaces",
            "xrefs"
        ]
        guard expectedVersion8Tables.isSubset(of: tables) else {
            throw DatabaseError.migrationRequired(stored: 8, supported: Self.schemaVersion)
        }

        try transaction {
            try execute(Self.workspaceDocumentsSchemaSQL)
            try execute(Self.workspaceDocumentAutosaveDecisionsSchemaSQL)
            try execute(Self.addressOverridesSchemaSQL)
            try execute(Self.typeDefinitionsSchemaSQL)
            try execute(Self.manualXRefsSchemaSQL)
            try execute(Self.bookmarksSchemaSQL)
            try execute(Self.segmentOverridesSchemaSQL)
            try ensureImageAwareSchema()
            try finalizeLogicalBreakpointsAndStampV30()
        }
    }

    private func migrateVersion9To12() throws {
        let tables = Set(try tableNames())
        guard tables.contains("workspace_documents") else {
            throw DatabaseError.migrationRequired(stored: 9, supported: Self.schemaVersion)
        }

        let columns = Set(try columnNames(in: "workspace_documents"))
        try transaction {
            try migrateWorkspaceDocumentsToCurrentSchema(existingColumns: columns)
            try execute(Self.workspaceDocumentAutosaveDecisionsSchemaSQL)
            try execute(Self.addressOverridesSchemaSQL)
            try execute(Self.typeDefinitionsSchemaSQL)
            try execute(Self.manualXRefsSchemaSQL)
            try execute(Self.bookmarksSchemaSQL)
            try execute(Self.segmentOverridesSchemaSQL)
            try ensureImageAwareSchema()
            try finalizeLogicalBreakpointsAndStampV30()
        }
    }

    private func migrateVersion10To12() throws {
        let tables = Set(try tableNames())
        guard tables.contains("workspace_documents") else {
            throw DatabaseError.migrationRequired(stored: 10, supported: Self.schemaVersion)
        }

        let columns = Set(try columnNames(in: "workspace_documents"))
        try transaction {
            try migrateWorkspaceDocumentsToCurrentSchema(existingColumns: columns)
            try execute(Self.workspaceDocumentAutosaveDecisionsSchemaSQL)
            try execute(Self.addressOverridesSchemaSQL)
            try execute(Self.typeDefinitionsSchemaSQL)
            try execute(Self.manualXRefsSchemaSQL)
            try execute(Self.bookmarksSchemaSQL)
            try execute(Self.segmentOverridesSchemaSQL)
            try ensureImageAwareSchema()
            try finalizeLogicalBreakpointsAndStampV30()
        }
    }

    private func migrateVersion11To12() throws {
        let tables = Set(try tableNames())
        guard tables.contains("workspace_documents"),
              tables.contains("workspace_document_autosave_decisions") else {
            throw DatabaseError.migrationRequired(stored: 11, supported: Self.schemaVersion)
        }

        let columns = Set(try columnNames(in: "workspace_documents"))
        try transaction {
            try migrateWorkspaceDocumentsToCurrentSchema(existingColumns: columns)
            try execute(Self.workspaceDocumentAutosaveDecisionsSchemaSQL)
            try execute(Self.addressOverridesSchemaSQL)
            try execute(Self.typeDefinitionsSchemaSQL)
            try execute(Self.manualXRefsSchemaSQL)
            try execute(Self.bookmarksSchemaSQL)
            try execute(Self.segmentOverridesSchemaSQL)
            try ensureImageAwareSchema()
            try finalizeLogicalBreakpointsAndStampV30()
        }
    }

    private func migrateVersion12To13() throws {
        let tables = Set(try tableNames())
        guard tables.contains("workspaces") else {
            throw DatabaseError.migrationRequired(stored: 12, supported: Self.schemaVersion)
        }
        try transaction {
            try execute(Self.addressOverridesSchemaSQL)
            try execute(Self.typeDefinitionsSchemaSQL)
            try execute(Self.manualXRefsSchemaSQL)
            try execute(Self.bookmarksSchemaSQL)
            try execute(Self.segmentOverridesSchemaSQL)
            try ensureImageAwareSchema()
            try finalizeLogicalBreakpointsAndStampV30()
        }
    }

    /// v13/v14 → current: bring an existing `address_overrides` table fully up to
    /// the current column set. Each migration jumps straight to `schemaVersion`, so
    /// it must add EVERY column the current schema expects — not just the one its
    /// version nominally introduced — or a later column is skipped (a v13 DB would
    /// otherwise reach version 15 with no `is_data`). The shared idempotent helper
    /// keeps every ALTER path complete as new columns are added over time.
    private func migrateVersion13To14() throws {
        try migrateAddressOverrideColumnsToCurrent(stored: 13)
    }

    private func migrateVersion14To15() throws {
        try migrateAddressOverrideColumnsToCurrent(stored: 14)
    }

    private func migrateVersion15To16() throws {
        try migrateAddressOverrideColumnsToCurrent(stored: 15)
    }

    private func migrateVersion16To17() throws {
        try migrateAddressOverrideColumnsToCurrent(stored: 16)
    }

    private func migrateVersion17To18() throws {
        try migrateAddressOverrideColumnsToCurrent(stored: 17)
    }

    private func migrateVersion18To19() throws {
        try migrateAddressOverrideColumnsToCurrent(stored: 18)
    }

    private func migrateVersion19To20() throws {
        try migrateAddressOverrideColumnsToCurrent(stored: 19)
    }

    private func migrateVersion20To21() throws {
        try migrateAddressOverrideColumnsToCurrent(stored: 20)
    }

    private func migrateVersion21To22() throws {
        try migrateAddressOverrideColumnsToCurrent(stored: 21)
    }

    private func migrateVersion22To23() throws {
        try migrateAddressOverrideColumnsToCurrent(stored: 22)
    }

    private func migrateVersion23To24() throws {
        try migrateAddressOverrideColumnsToCurrent(stored: 23)
    }

    private func migrateVersion24To25() throws {
        try migrateAddressOverrideColumnsToCurrent(stored: 24)
    }

    private func migrateVersion25To26() throws {
        try migrateAddressOverrideColumnsToCurrent(stored: 25)
    }

    private func migrateVersion26To27() throws {
        try transaction {
            try ensureImageAwareSchema()
            try finalizeLogicalBreakpointsAndStampV30()
        }
    }

    /// v27 → current (WS-5): adds the `source_lines` table via the idempotent image-aware
    /// convergence. Like the other jump-to-current migrations, it stamps `schemaVersion`.
    private func migrateVersion27ToCurrent() throws {
        try transaction {
            try ensureImageAwareSchema()
            try finalizeLogicalBreakpointsAndStampV30()
        }
    }

    /// v28 → v29: normalizes the short-lived migrated `source_lines` shape. The original
    /// v27→v28 convergence accidentally added a required `workspace_id` column even though the
    /// table is owned transitively by `binary_id` and every production write uses that canonical
    /// per-binary contract. Rebuild the known bad child table transactionally, preserving row IDs
    /// and all source-line data; reject any other shape rather than guessing or dropping data.
    private func migrateVersion28To29() throws {
        try transaction {
            let tables = try tableNames()
            let hasSourceLines = tables.contains {
                $0.caseInsensitiveCompare("source_lines") == .orderedSame
            }
            if !hasSourceLines {
                try ensureImageAwareSchema()
            } else {
                // `table_info` omits generated and virtual-table hidden columns. Migration
                // classification must see the complete shape or an altered v28 database could
                // be mistaken for a known product layout and lose unrecognized schema state.
                let columnMetadata = try query("PRAGMA table_xinfo(source_lines);") { statement in
                    (
                        name: try Self.textColumn(statement, 1),
                        hidden: Int(sqlite3_column_int(statement, 6))
                    )
                }
                let columns = columnMetadata.map { $0.name }
                let tableTypes = try query(
                    """
                    SELECT type
                    FROM pragma_table_list
                    WHERE schema = 'main' AND name = ? COLLATE NOCASE;
                    """,
                    bindings: [.text("source_lines")]
                ) { statement in
                    try Self.textColumn(statement, 0)
                }
                let canonicalColumns = [
                    "id", "binary_id", "address", "file", "line", "column", "is_end_sequence",
                ]
                let workspaceScopedColumns = [
                    "id", "workspace_id", "binary_id", "address", "file", "line", "column", "is_end_sequence",
                ]

                let isOrdinaryVisibleTable = tableTypes == ["table"]
                    && columnMetadata.allSatisfy { $0.hidden == 0 }
                if isOrdinaryVisibleTable
                    && (columns == workspaceScopedColumns || columns == canonicalColumns) {
                    if try scalarInt("SELECT EXISTS(SELECT 1 FROM source_lines WHERE id IS NULL);") == 1 {
                        throw DatabaseError.incompatibleSourceLinesData(reasons: ["null-id"])
                    }
                    if try scalarInt(
                        "SELECT EXISTS(SELECT 1 FROM source_lines WHERE typeof(id) <> 'integer');"
                    ) == 1 {
                        throw DatabaseError.incompatibleSourceLinesData(reasons: ["non-integer-id"])
                    }
                    let dependencies = try unsupportedSourceLinesDependencies()
                    if !dependencies.isEmpty {
                        throw DatabaseError.incompatibleSourceLinesDependencies(objects: dependencies)
                    }
                    try execute("""
                        CREATE TABLE source_lines_v29 (
                          id INTEGER PRIMARY KEY,
                          binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE,
                          address INTEGER NOT NULL,
                          file TEXT,
                          line INTEGER NOT NULL,
                          column INTEGER NOT NULL,
                          is_end_sequence INTEGER NOT NULL DEFAULT 0
                        );
                        INSERT INTO source_lines_v29 (
                          id, binary_id, address, file, line, column, is_end_sequence
                        )
                        SELECT id, binary_id, address, file, line, column, is_end_sequence
                        FROM source_lines;
                        DROP TABLE source_lines;
                        ALTER TABLE source_lines_v29 RENAME TO source_lines;
                        CREATE INDEX idx_source_lines_binary_id ON source_lines(binary_id);
                        """)
                } else {
                    throw DatabaseError.incompatibleSourceLinesSchema(columns: columns)
                }
            }
            try finalizeLogicalBreakpointsAndStampV30()
        }
    }

    private func migrateVersion29To30() throws {
        try transaction {
            try finalizeLogicalBreakpointsAndStampV30()
        }
    }

    private func migrateVersion30To31() throws {
        try transaction {
            // v30 already owns exact logical-breakpoint authority. Never replay legacy
            // instruction bits or otherwise touch those tables during the v31 migration.
            try validateBreakpointResolutionPrerequisiteSchema(requireTables: true)
            try validateLogicalBreakpointsSchema()
            try finalizeLaunchProfilesAndStampV31()
        }
    }

    private struct LegacyLogicalBreakpointSite {
        let workspaceID: Int64
        let workspaceUUID: UUID
        let workspaceCreatedAt: String
        let binaryID: UUID
        let imageSlot: ImageSlot
        let preferredVA: UInt64
    }

    /// The sole v30 finalizer. Every supported historical migration calls this from its existing
    /// transaction after completing its version-specific convergence and before stamping v30.
    private func finalizeLogicalBreakpointsAndStampV30() throws {
        try ensureBreakpointResolutionPrerequisiteColumns()
        try validateBreakpointResolutionPrerequisiteSchema()
        try execute(Self.logicalBreakpointsSchemaSQL)
        try validateLogicalBreakpointsSchema()

        // A pre-v30 interrupted attempt may leave child rows without a catalog header. They carry
        // no independently valid authority or receipt and must not survive to collide with the
        // deterministic rebuild.
        try execute("""
            DELETE FROM logical_breakpoints
            WHERE workspace_id NOT IN (
              SELECT workspace_id FROM logical_breakpoint_catalogs
            );
            """)

        let tables = Set(try tableNames())
        let sites: [LegacyLogicalBreakpointSite]
        if tables.contains("instructions") {
            guard tables.isSuperset(of: ["functions", "binaries", "workspaces"]) else {
                throw DatabaseError.logicalBreakpointCatalogUnavailable
            }
            let orphanCount = try scalarInt(
                """
                SELECT COUNT(*)
                FROM instructions AS i
                LEFT JOIN functions AS f ON f.id = i.function_id
                LEFT JOIN binaries AS b ON b.id = f.binary_id
                LEFT JOIN workspaces AS w ON w.id = b.workspace_id
                WHERE i.has_breakpoint = 1
                  AND (f.id IS NULL OR b.id IS NULL OR w.id IS NULL);
                """
            )
            guard orphanCount == 0 else {
                throw DatabaseError.logicalBreakpointCatalogUnavailable
            }
            sites = try query(
                """
                SELECT DISTINCT w.id, w.uuid, w.created_at, b.uuid, b.image_slot, i.address
                FROM instructions AS i
                JOIN functions AS f ON f.id = i.function_id
                JOIN binaries AS b ON b.id = f.binary_id
                JOIN workspaces AS w ON w.id = b.workspace_id
                WHERE i.has_breakpoint = 1
                ORDER BY w.id, b.uuid, b.image_slot, i.address;
                """
            ) { statement -> LegacyLogicalBreakpointSite in
                let workspaceUUIDText = try Self.textColumn(statement, 1)
                let binaryUUIDText = try Self.textColumn(statement, 3)
                guard let workspaceUUID = UUID(uuidString: workspaceUUIDText) else {
                    throw DatabaseError.invalidUUID(workspaceUUIDText)
                }
                guard let binaryID = UUID(uuidString: binaryUUIDText) else {
                    throw DatabaseError.invalidUUID(binaryUUIDText)
                }
                let slot = Int(sqlite3_column_int64(statement, 4))
                guard slot >= 0 else { throw DatabaseError.logicalBreakpointCatalogUnavailable }
                return LegacyLogicalBreakpointSite(
                    workspaceID: sqlite3_column_int64(statement, 0),
                    workspaceUUID: workspaceUUID,
                    workspaceCreatedAt: try Self.textColumn(statement, 2),
                    binaryID: binaryID,
                    imageSlot: ImageSlot(rawValue: slot),
                    preferredVA: try Self.addressColumn(
                        statement, 5, field: "instructions.address"
                    )
                )
            }
        } else {
            sites = []
        }
        let sitesByWorkspace = Dictionary(grouping: sites, by: \.workspaceID)

        let workspaces = try query(
            "SELECT id, uuid, created_at FROM workspaces ORDER BY id;"
        ) { statement -> (Int64, UUID, String) in
            let uuidText = try Self.textColumn(statement, 1)
            guard let uuid = UUID(uuidString: uuidText) else {
                throw DatabaseError.invalidUUID(uuidText)
            }
            return (
                sqlite3_column_int64(statement, 0),
                uuid,
                try Self.textColumn(statement, 2)
            )
        }

        for (workspaceID, workspaceUUID, createdAt) in workspaces {
            let specifications = try (sitesByWorkspace[workspaceID] ?? []).map { site in
                try DebuggerLogicalBreakpointSpecification(
                    id: DebuggerLogicalBreakpointID(
                        rawValue: Self.deterministicBreakpointUUID(
                            domain: "legacy-specification",
                            workspaceUUID: workspaceUUID,
                            binaryUUID: site.binaryID,
                            preferredVA: site.preferredVA
                        )
                    ),
                    revision: DebuggerLogicalBreakpointRevision(validating: 1),
                    enabled: true,
                    target: .preferredAddress(
                        owner: DebuggerWorkspaceImageOwnerSeal(
                            slot: site.imageSlot,
                            binaryID: site.binaryID,
                            artifactIdentity: nil
                        ),
                        preferredVA: site.preferredVA
                    ),
                    condition: nil,
                    hitPolicy: .always,
                    actions: [],
                    disposition: .stop
                )
            }
            let catalog = try DebuggerLogicalBreakpointCatalog(
                catalogID: Self.deterministicBreakpointUUID(
                    domain: "legacy-catalog",
                    workspaceUUID: workspaceUUID,
                    binaryUUID: nil,
                    preferredVA: nil
                ),
                revision: 1,
                specifications: specifications
            )

            let hasExistingCatalog = try scalarInt(
                "SELECT EXISTS(SELECT 1 FROM logical_breakpoint_catalogs WHERE workspace_id = \(workspaceID));"
            ) == 1
            if hasExistingCatalog {
                let existing = try? loadLogicalBreakpointCatalog(
                    workspaceID: workspaceID,
                    workspaceUUID: workspaceUUID
                )
                if existing == catalog { continue }
                // user_version is still pre-v30, so legacy instruction intent remains the sole
                // authority. A partial, corrupt, or contradictory pre-created v30 receipt is not
                // silently accepted; transactionally replace it with the deterministic migration.
                try run(
                    "DELETE FROM logical_breakpoint_catalogs WHERE workspace_id = ?;",
                    bindings: [.int64(workspaceID)]
                )
            }
            try insertLogicalBreakpointCatalog(
                catalog,
                workspaceID: workspaceID,
                workspaceUUID: workspaceUUID,
                timestamp: sitesByWorkspace[workspaceID]?.first?.workspaceCreatedAt ?? createdAt
            )
        }

        // This must remain a literal. Using `schemaVersion` here would let a future schema bump
        // falsely stamp a database current before its later authority tables exist.
        try execute("PRAGMA user_version = 30;")
        try finalizeLaunchProfilesAndStampV31()
    }

    /// The sole v31 finalizer. It is intentionally independent from legacy instruction state:
    /// schema-v30 logical-breakpoint rows are already authoritative and must remain byte-for-byte
    /// untouched while each workspace receives one deterministic pristine launch catalog.
    private func finalizeLaunchProfilesAndStampV31() throws {
        try execute(Self.launchProfilesSchemaSQL)
        try validateLaunchProfilesSchema()

        let workspaces = try query(
            "SELECT id, uuid FROM workspaces ORDER BY id;"
        ) { statement -> (Int64, UUID) in
            let uuidText = try Self.textColumn(statement, 1)
            guard let uuid = UUID(uuidString: uuidText), uuid.uuidString == uuidText else {
                throw DatabaseError.invalidUUID(uuidText)
            }
            return (sqlite3_column_int64(statement, 0), uuid)
        }

        for (workspaceID, workspaceUUID) in workspaces {
            let migrated = DebuggerLaunchProfileCatalog.freshPristine(
                catalogID: Self.deterministicLaunchProfileCatalogUUID(workspaceUUID: workspaceUUID)
            )
            if (try? loadLaunchProfileCatalog(
                workspaceID: workspaceID,
                workspaceUUID: workspaceUUID
            )) == migrated {
                continue
            }
            // An interrupted attempt may have left a coercible or invalid receipt. Before v31 is
            // stamped there is no user-authored launch authority, so converge it deterministically.
            try run(
                """
                DELETE FROM launch_profile_catalogs
                WHERE workspace_id = ?
                   OR (typeof(workspace_id) != 'integer'
                       AND CAST(workspace_id AS INTEGER) = ?);
                """,
                bindings: [.int64(workspaceID), .int64(workspaceID)]
            )
            try insertLaunchProfileCatalog(
                migrated,
                workspaceID: workspaceID,
                workspaceUUID: workspaceUUID
            )
        }

        try execute("PRAGMA user_version = 31;")
        try migrateVersion31To32()
    }

    /// Runs one direct-entry schema migration inside a named savepoint so a crash,
    /// I/O error, or constraint failure part-way through a multi-statement migration
    /// can never strand the database between versions. The `user_version` stamp must
    /// be executed inside `body`, so schema mutations and the version stamp commit or
    /// roll back together; chain the *next* migration only after this helper returns.
    ///
    /// A savepoint (not `BEGIN`) is deliberate for the same reason documented in
    /// `migrateVersion35To36`: historical entry points already own a transaction,
    /// while opening at exactly this version reaches the migration directly, and a
    /// savepoint is atomic in both situations. Savepoint names are compile-time
    /// literals only — never interpolate runtime strings into these statements.
    /// A rollback that itself fails is surfaced as `migrationRollbackFailed` rather
    /// than swallowed, because that state needs manual inspection.
    private func withMigrationSavepoint(
        _ name: StaticString,
        _ body: () throws -> Void
    ) throws {
        let identifier = String(describing: name)
        try execute("SAVEPOINT \(identifier);")
        do {
            try body()
            try execute("RELEASE SAVEPOINT \(identifier);")
        } catch {
            let original = error
            do {
                try execute("ROLLBACK TO SAVEPOINT \(identifier);")
                try execute("RELEASE SAVEPOINT \(identifier);")
            } catch let rollbackError {
                invalidateConnectionAfterRollbackFailure()
                throw DatabaseError.migrationRollbackFailed(
                    original: String(describing: original),
                    rollback: String(describing: rollbackError)
                )
            }
            throw original
        }
    }

    private func migrateVersion31To32() throws {
        try withMigrationSavepoint("phase2_assistant_v32") {
            try execute(Self.phase2AssistantSessionRecordsV1SchemaSQL)
            try execute("PRAGMA user_version = 32;")
        }
        try migrateVersion32To33()
    }

    private func migrateVersion32To33() throws {
        try withMigrationSavepoint("phase2_assistant_v33") {
            try execute("""
                ALTER TABLE phase2_assistant_session_records
                  RENAME TO phase2_assistant_session_records_v32;
                """)
            try execute("DROP INDEX IF EXISTS idx_phase2_assistant_sessions_workspace_sequence;")
            try execute("DROP INDEX IF EXISTS idx_phase2_assistant_sessions_workspace_created;")
            try execute(Self.phase2AssistantSessionRecordsV1SchemaSQL)
            try execute("""
                INSERT INTO phase2_assistant_session_records (
                  id, workspace_id, workspace_uuid, document_id, sequence, intent_id,
                  user_goal, status, prompt_text, answer_text, transcript_text,
                  context_digest, canonical_byte_count, provider_tool_count,
                  record_schema_version, created_at, completed_at, content_sha256
                )
                SELECT
                  id, workspace_id, workspace_uuid, document_id, sequence, intent_id,
                  user_goal, status, prompt_text, answer_text, transcript_text,
                  context_digest, canonical_byte_count, provider_tool_count,
                  record_schema_version, created_at, completed_at, content_sha256
                FROM phase2_assistant_session_records_v32;
                """)
            try execute("DROP TABLE phase2_assistant_session_records_v32;")
            try execute("PRAGMA user_version = 33;")
        }
        try migrateVersion33To34()
    }

    private func migrateVersion33To34() throws {
        try withMigrationSavepoint("phase2_runtime_authority_v34") {
            try execute(Self.phase2RuntimeAuthorityRecordsSchemaSQL)
            try execute("PRAGMA user_version = 34;")
        }
        try migrateVersion34To35()
    }

    private func migrateVersion34To35() throws {
        try withMigrationSavepoint("phase2_shell_sessions_v35") {
            try execute(Self.phase2ShellSessionsSchemaSQL)
            try execute("PRAGMA user_version = 35;")
        }
        try migrateVersion35To36()
    }

    private func migrateVersion35To36() throws {
        // Historical migration entry points already own a transaction, while opening a v35
        // database reaches this method directly. A savepoint is atomic in both situations and
        // avoids SQLite's illegal nested-BEGIN failure.
        try withMigrationSavepoint("phase2_assistant_v36") {
            let existingColumns = Set(try columnNames(in: "phase2_assistant_session_records"))
            if existingColumns.contains("conversation_id") {
                // A partially forward-converged database (including migration fixtures) may
                // already carry either the complete v36 Assistant table or the later v37 table
                // while user_version is still 35. Validate the exact observed generation rather
                // than attempting to reinterpret either forward-converged shape as v1.
                if existingColumns.contains("continuation_checkpoint_json") {
                    try validatePhase2AssistantSessionRecordsSchema()
                } else {
                    try validatePhase2AssistantSessionRecordsV2Schema()
                }
                try execute("PRAGMA user_version = 36;")
                return
            }
            try execute("""
                ALTER TABLE phase2_assistant_session_records
                  RENAME TO phase2_assistant_session_records_v35;
                """)
            try execute("DROP INDEX IF EXISTS idx_phase2_assistant_sessions_workspace_sequence;")
            try execute("DROP INDEX IF EXISTS idx_phase2_assistant_sessions_workspace_created;")
            try execute(Self.phase2AssistantSessionRecordsSchemaSQL)

            let legacyRecords = try query(
                """
                SELECT id, workspace_id, workspace_uuid, document_id, sequence, intent_id,
                       user_goal, status, prompt_text, answer_text, transcript_text,
                       context_digest, canonical_byte_count, provider_tool_count,
                       record_schema_version, created_at, completed_at, content_sha256
                FROM phase2_assistant_session_records_v35
                ORDER BY workspace_id, sequence, id;
                """,
                map: Self.phase2AssistantSessionRecordV1
            )
            for record in legacyRecords {
                try upsertPhase2AssistantSessionRecord(record)
            }
            try execute("DROP TABLE phase2_assistant_session_records_v35;")
            try validatePhase2AssistantSessionRecordsSchema()
            try execute("PRAGMA user_version = 36;")
        }
        try migrateVersion36To37()
    }

    private func migrateVersion36To37() throws {
        try withMigrationSavepoint("phase2_assistant_v37") {
            let columns = Set(try columnNames(in: "phase2_assistant_session_records"))
            if columns.contains("continuation_checkpoint_json") {
                try validatePhase2AssistantSessionRecordsSchema()
                try execute("PRAGMA user_version = 37;")
                return
            }
            try execute("ALTER TABLE phase2_assistant_session_records RENAME TO phase2_assistant_session_records_v36;")
            try execute("DROP INDEX IF EXISTS idx_phase2_assistant_sessions_workspace_sequence;")
            try execute("DROP INDEX IF EXISTS idx_phase2_assistant_sessions_workspace_conversation_turn;")
            try execute("DROP INDEX IF EXISTS idx_phase2_assistant_sessions_workspace_inference_turn;")
            try execute("DROP INDEX IF EXISTS idx_phase2_assistant_sessions_workspace_created;")
            try execute(Self.phase2AssistantSessionRecordsSchemaSQL)
            let records = try query(
                """
                SELECT id, workspace_id, workspace_uuid, document_id, sequence, conversation_id,
                       turn_sequence, inference_turn_id, is_legacy, intent_id, user_goal, status,
                       prompt_text, answer_text, transcript_text, context_digest,
                       canonical_byte_count, provider_tool_count, record_schema_version,
                       created_at, completed_at, content_sha256
                FROM phase2_assistant_session_records_v36
                ORDER BY workspace_id, sequence, id;
                """,
                map: Self.phase2AssistantSessionRecordV2
            )
            for record in records { try upsertPhase2AssistantSessionRecord(record) }
            try execute("DROP TABLE phase2_assistant_session_records_v36;")
            try validatePhase2AssistantSessionRecordsSchema()
            try execute("PRAGMA user_version = 37;")
        }
        try migrateVersion37To38()
    }

    private func migrateVersion37To38() throws {
        try withMigrationSavepoint("reconstruction_v38") {
            try execute(Self.reconstructionSchemaSQL)
            try validateReconstructionSchema()
            try execute("PRAGMA user_version = 38;")
        }
        try migrateVersion38To39()
    }

    private func migrateVersion38To39() throws {
        try withMigrationSavepoint("type_layout_v39") {
            // Some supported historical schemas predate the factored type-catalog
            // table. Establish its current base shape before applying the v39
            // column migration so every supported upgrade path converges.
            try execute(Self.typeDefinitionsSchemaSQL)
            let columns = Set(try columnNames(in: "type_definitions"))
            if !columns.contains("layout_rules_json") {
                try execute("ALTER TABLE type_definitions ADD COLUMN layout_rules_json TEXT;")
            }
            // This must remain literal so a later schema bump cannot make this migration
            // claim convergence beyond the exact shape it establishes.
            try execute("PRAGMA user_version = 39;")
        }
        try migrateVersion39To40()
    }

    private func migrateVersion39To40() throws {
        try withMigrationSavepoint("reconstruction_final_result_v40") {
            try execute(Self.reconstructionFinalResultsSchemaSQL)
            try validateReconstructionSchema()
            // This must remain literal so a later schema bump cannot make this migration
            // claim convergence beyond the exact final-result table it establishes.
            try execute("PRAGMA user_version = 40;")
        }
        try migrateVersion40To41()
    }

    private func migrateVersion40To41() throws {
        try withMigrationSavepoint("binary_metadata_v41") {
            let columns = Set(try columnNames(in: "binaries"))
            if !columns.contains("binary_metadata_json") {
                try execute("ALTER TABLE binaries ADD COLUMN binary_metadata_json TEXT;")
            }
            if !columns.contains("elf_archive_member_identity_json") {
                try execute("ALTER TABLE binaries ADD COLUMN elf_archive_member_identity_json TEXT;")
            }
            try validateBinaryMetadataSchema()
            // This must remain literal: v40 rows intentionally receive neither loader-metadata
            // nor archive-member identity backfill, and this migration establishes exactly v41.
            try execute("PRAGMA user_version = 41;")
        }
        try migrateVersion41To42()
    }

    private func migrateVersion41To42() throws {
        try withMigrationSavepoint("saved_watches_v42") {
            try execute(Self.savedWatchesSchemaSQL)
            try validateSavedWatchesSchema()
            for workspace in try workspaces() {
                guard let workspaceID = workspace.id else { throw DatabaseError.notFound }
                let exists = try scalarInt("SELECT EXISTS(SELECT 1 FROM saved_watch_catalogs WHERE workspace_id = \(workspaceID));")
                if exists == 0 {
                    try insertSavedWatchCatalog(.empty, workspaceID: workspaceID,
                                               workspaceUUID: workspace.uuid)
                }
            }
            try execute("PRAGMA user_version = 42;")
            try applySchema()
        }
    }

    private func migrateVersion42To43() throws {
        try withMigrationSavepoint("instruction_operands_v43") {
            try addInstructionOperandsColumnIfMissing()
            try validateInstructionOperandsSchema()
            // This migration establishes only v43; older rows deliberately retain SQL NULL.
            try execute("PRAGMA user_version = 43;")
            try applySchema()
        }
    }

    private func migrateVersion43To44() throws {
        try withMigrationSavepoint("macho_selected_slice_fact_v44") {
            if !Set(try columnNames(in: "binaries")).contains("macho_selected_slice_fact_json") {
                try execute("ALTER TABLE binaries ADD COLUMN macho_selected_slice_fact_json TEXT;")
            }
            try validateMachOSelectedSliceFactSchema()
            // No backfill: neither a request nor a retained thin attachment proves origin.
            try execute("PRAGMA user_version = 44;")
            try applySchema()
        }
    }

    private func validateMachOSelectedSliceFactSchema() throws {
        let columns = try query("PRAGMA table_xinfo(binaries);") {
            (try Self.textColumn($0, 1), try Self.textColumn($0, 2).uppercased(),
             sqlite3_column_int($0, 3), sqlite3_column_int($0, 5), sqlite3_column_int($0, 6))
        }
        guard columns.contains(where: {
            $0 == ("macho_selected_slice_fact_json", "TEXT", 0, 0, 0)
        }) else {
            throw DatabaseError.binaryMetadataSchemaInvalid(columns: ["macho_selected_slice_fact_json"])
        }
    }

    private func validateSavedWatchesSchema() throws {
        let columns = try query("PRAGMA table_info(saved_watch_catalogs);") {
            (try Self.textColumn($0, 1), try Self.textColumn($0, 2),
             sqlite3_column_int($0, 3), sqlite3_column_int($0, 5))
        }
        guard columns.count == 4,
              columns[0] == ("workspace_id", "INTEGER", 0, 1),
              columns[1] == ("workspace_uuid", "TEXT", 1, 0),
              columns[2] == ("catalog_blob", "BLOB", 1, 0),
              columns[3] == ("catalog_sha256", "TEXT", 1, 0) else {
            throw WorkspaceSavedWatchValidationError.invalid
        }
        let foreignKeys = try query("PRAGMA foreign_key_list(saved_watch_catalogs);") {
            (try Self.textColumn($0, 2), try Self.textColumn($0, 3),
             try Self.textColumn($0, 4), try Self.textColumn($0, 6))
        }
        guard foreignKeys.count == 1,
              foreignKeys[0] == ("workspaces", "workspace_id", "id", "CASCADE") else {
            throw WorkspaceSavedWatchValidationError.invalid
        }
    }

    private func validateBinaryMetadataSchema() throws {
        struct Column: Equatable {
            let name: String
            let type: String
            let notNull: Bool
            let primaryKeyPosition: Int
            let hidden: Int
        }
        let required = [
            Column(
                name: "binary_metadata_json", type: "TEXT", notNull: false,
                primaryKeyPosition: 0, hidden: 0
            ),
            Column(
                name: "elf_archive_member_identity_json", type: "TEXT", notNull: false,
                primaryKeyPosition: 0, hidden: 0
            ),
        ]
        let observed = try query("PRAGMA table_xinfo(binaries);") { statement in
            Column(
                name: try Self.textColumn(statement, 1),
                type: try Self.textColumn(statement, 2).uppercased(),
                notNull: sqlite3_column_int(statement, 3) != 0,
                primaryKeyPosition: Int(sqlite3_column_int(statement, 5)),
                hidden: Int(sqlite3_column_int(statement, 6))
            )
        }
        let observedByName = Dictionary(uniqueKeysWithValues: observed.map { ($0.name, $0) })
        let invalid = required.filter { observedByName[$0.name] != $0 }.map(\.name)
        guard invalid.isEmpty else {
            throw DatabaseError.binaryMetadataSchemaInvalid(columns: invalid)
        }
    }

    /// F3 durable lifecycle timestamps: `created_at_ms`, `started_at_ms`, `finished_at_ms`
    /// (INTEGER, ms since 1970, nullable) on `reconstruction_jobs` and `reconstruction_tasks`.
    /// Additive and nullable like `functions.no_return_provenance` (#305): an idempotent ADD COLUMN
    /// with no user_version bump. It runs on every database (fresh and migrated) before the
    /// reconstruction schema check, and on the canonical comparison database, so the stored
    /// `CREATE TABLE` text is identical for both. Older rows keep NULL (lifecycle not observed).
    static let reconstructionLifecycleColumns = ["created_at_ms", "started_at_ms", "finished_at_ms"]
    static let reconstructionLifecycleTables = ["reconstruction_jobs", "reconstruction_tasks"]

    private func ensureReconstructionLifecycleTimestampSchema() throws {
        let tables = Set(try tableNames())
        for table in Self.reconstructionLifecycleTables where tables.contains(table) {
            let columns = Set(try columnNames(in: table))
            for column in Self.reconstructionLifecycleColumns where !columns.contains(column) {
                try execute("ALTER TABLE \(table) ADD COLUMN \(column) INTEGER;")
            }
        }
    }

    private func validateReconstructionSchema() throws {
        try ensureReconstructionLifecycleTimestampSchema()
        // owner_job_inference_replay is the DatabaseOwner's optional input journal, not a task
        // projection table. Its independent schema is validated by that owner; the closed set
        // below stays unchanged so pre-journal readers can open the same SQLite database.
        let actualTables = Set(try tableNames().filter { $0.hasPrefix("reconstruction_") })
        let expectedTables = Set(Self.reconstructionProjectionColumns.keys)
        guard actualTables == expectedTables else {
            throw DatabaseError.reconstructionSchemaInvalid(
                "table-set expected=\(expectedTables.sorted()) actual=\(actualTables.sorted())"
            )
        }

        let canonical = try WorkspaceDatabase.inMemory()
        try canonical.execute(Self.reconstructionSchemaSQL)
        try canonical.ensureReconstructionLifecycleTimestampSchema()
        let expected = try canonical.reconstructionSchemaDescription()
        let actual = try reconstructionSchemaDescription()
        for table in expectedTables.sorted() {
            guard actual[table] == expected[table] else {
                throw DatabaseError.reconstructionSchemaInvalid(
                    "structural contract differs for table=\(table)"
                )
            }
        }
    }

    private func reconstructionSchemaDescription() throws -> [String: ReconstructionSchemaTable] {
        try schemaDescription(for: Array(Self.reconstructionProjectionColumns.keys))
    }

    private static func normalizedSQLiteSchemaSQL(_ sql: String) -> String {
        sql.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The durable sidecar identity is meaningful only when its two authority tables retain the
    /// exact schema that gave those rows their uniqueness and ownership semantics. v38 through
    /// v40 intentionally share this shape with v41, so one canonical description covers both the
    /// pre-migration historical gate and the exact-current postflight.
    private func validateReconstructionSidecarIdentitySchema() throws {
        let tableNames = ["workspaces", "workspace_documents"]
        let canonical = try WorkspaceDatabase.inMemory()
        try canonical.execute(Self.schemaSQL)
        let expected = try canonical.schemaDescription(for: tableNames)
        let actual = try schemaDescription(for: tableNames)
        for tableName in tableNames {
            guard let actualTable = actual[tableName],
                  let expectedTable = expected[tableName],
                  actualTable.hasEquivalentStructuralAuthority(to: expectedTable) else {
                throw DatabaseError.reconstructionSchemaInvalid(
                    "sidecar identity structural contract differs for table=\(tableName)"
                )
            }
        }
    }

    private func schemaDescription(
        for tableNames: [String]
    ) throws -> [String: ReconstructionSchemaTable] {
        var result: [String: ReconstructionSchemaTable] = [:]
        for table in tableNames.sorted() {
            guard let sql = try first(
                "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?;",
                bindings: [.text(table)],
                map: { try Self.textColumn($0, 0) }
            ) else {
                throw DatabaseError.reconstructionSchemaInvalid("missing table=\(table)")
            }
            let columns = try query("PRAGMA table_xinfo(\(table));") { statement in
                ReconstructionSchemaColumn(
                    name: try Self.textColumn(statement, 1),
                    declaredType: try Self.textColumn(statement, 2).uppercased(),
                    notNull: sqlite3_column_int(statement, 3) != 0,
                    defaultValue: Self.optionalTextColumn(statement, 4),
                    primaryKeyOrdinal: Int(sqlite3_column_int(statement, 5)),
                    hidden: Int(sqlite3_column_int(statement, 6))
                )
            }
            let foreignKeys = try query("PRAGMA foreign_key_list(\(table));") { statement in
                ReconstructionSchemaForeignKey(
                    id: Int(sqlite3_column_int(statement, 0)),
                    sequence: Int(sqlite3_column_int(statement, 1)),
                    parentTable: try Self.textColumn(statement, 2),
                    sourceColumn: try Self.textColumn(statement, 3),
                    targetColumn: Self.optionalTextColumn(statement, 4),
                    onUpdate: try Self.textColumn(statement, 5),
                    onDelete: try Self.textColumn(statement, 6),
                    match: try Self.textColumn(statement, 7)
                )
            }
            let indexHeaders: [(name: String, unique: Bool, origin: String, partial: Bool)] = try query(
                "PRAGMA index_list(\(table));"
            ) { statement in
                (
                    name: try Self.textColumn(statement, 1),
                    unique: sqlite3_column_int(statement, 2) != 0,
                    origin: try Self.textColumn(statement, 3),
                    partial: sqlite3_column_int(statement, 4) != 0
                )
            }
            let indexes = try indexHeaders.map { header in
                let escapedName = header.name.replacingOccurrences(of: "'", with: "''")
                let columns = try query("PRAGMA index_xinfo('\(escapedName)');") { statement in
                    ReconstructionSchemaIndexColumn(
                        sequence: Int(sqlite3_column_int(statement, 0)),
                        columnID: Int(sqlite3_column_int(statement, 1)),
                        name: Self.optionalTextColumn(statement, 2),
                        descending: sqlite3_column_int(statement, 3) != 0,
                        collation: Self.optionalTextColumn(statement, 4),
                        isKey: sqlite3_column_int(statement, 5) != 0
                    )
                }
                return ReconstructionSchemaIndex(
                    name: header.name,
                    unique: header.unique,
                    origin: header.origin,
                    partial: header.partial,
                    columns: columns
                )
            }.sorted { $0.name < $1.name }
            result[table] = ReconstructionSchemaTable(
                normalizedSQL: Self.normalizedSQLiteSchemaSQL(sql),
                columns: columns,
                foreignKeys: foreignKeys,
                indexes: indexes
            )
        }
        return result
    }

    private func ensureBreakpointResolutionPrerequisiteColumns() throws {
        let tables = Set(try tableNames())
        if tables.contains("symbols"), !Set(try columnNames(in: "symbols")).contains("raw_linkage_name") {
            try execute("ALTER TABLE symbols ADD COLUMN raw_linkage_name TEXT;")
        }
        if tables.contains("source_lines") {
            let columns = Set(try columnNames(in: "source_lines"))
            let additions: [(String, String)] = [
                ("debug_artifact_uuid", "TEXT"),
                ("debug_artifact_macho_sha256", "TEXT"),
                ("debug_artifact_macho_byte_count", "INTEGER"),
                ("line_program_unit_offset", "INTEGER"),
                ("file_table_index", "INTEGER"),
                ("table_path_kind", "TEXT"),
                ("table_path", "TEXT"),
            ]
            for (name, type) in additions where !columns.contains(name) {
                try execute("ALTER TABLE source_lines ADD COLUMN \(name) \(type);")
            }
        }
    }

    private func validateBreakpointResolutionPrerequisiteSchema(
        requireTables: Bool = false
    ) throws {
        struct Column: Equatable {
            let name: String
            let type: String
            let notNull: Bool
            let primaryKeyPosition: Int
            let hidden: Int
        }
        func columns(_ table: String) throws -> [Column] {
            try query("PRAGMA table_xinfo(\(table));") { statement in
                Column(
                    name: try Self.textColumn(statement, 1),
                    type: try Self.textColumn(statement, 2).uppercased(),
                    notNull: sqlite3_column_int(statement, 3) != 0,
                    primaryKeyPosition: Int(sqlite3_column_int(statement, 5)),
                    hidden: Int(sqlite3_column_int(statement, 6))
                )
            }
        }
        func isOrdinaryTable(_ table: String, count: Int) throws -> Bool {
            try query(
                """
                SELECT type, ncol, wr, strict
                FROM pragma_table_list
                WHERE schema = 'main' AND name = ?;
                """,
                bindings: [.text(table)]
            ) { statement in
                try Self.textColumn(statement, 0) == "table"
                    && sqlite3_column_int(statement, 1) == count
                    && sqlite3_column_int(statement, 2) == 0
                    && sqlite3_column_int(statement, 3) == 0
            } == [true]
        }

        let tables = Set(try tableNames())
        if requireTables,
           !tables.isSuperset(of: ["symbols", "source_lines"]) {
            throw DatabaseError.logicalBreakpointSchemaInvalid
        }
        if tables.contains("symbols") {
            let expected = [
                Column(name: "id", type: "INTEGER", notNull: false, primaryKeyPosition: 1, hidden: 0),
                Column(name: "uuid", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
                Column(name: "binary_id", type: "INTEGER", notNull: true, primaryKeyPosition: 0, hidden: 0),
                Column(name: "name", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
                Column(name: "address", type: "INTEGER", notNull: false, primaryKeyPosition: 0, hidden: 0),
                Column(name: "kind", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
                Column(name: "library_name", type: "TEXT", notNull: false, primaryKeyPosition: 0, hidden: 0),
                Column(name: "raw_linkage_name", type: "TEXT", notNull: false, primaryKeyPosition: 0, hidden: 0),
            ]
            guard try columns("symbols") == expected,
                  try isOrdinaryTable("symbols", count: expected.count) else {
                throw DatabaseError.logicalBreakpointSchemaInvalid
            }
        }
        if tables.contains("source_lines") {
            let expected = [
                Column(name: "id", type: "INTEGER", notNull: false, primaryKeyPosition: 1, hidden: 0),
                Column(name: "binary_id", type: "INTEGER", notNull: true, primaryKeyPosition: 0, hidden: 0),
                Column(name: "address", type: "INTEGER", notNull: true, primaryKeyPosition: 0, hidden: 0),
                Column(name: "file", type: "TEXT", notNull: false, primaryKeyPosition: 0, hidden: 0),
                Column(name: "line", type: "INTEGER", notNull: true, primaryKeyPosition: 0, hidden: 0),
                Column(name: "column", type: "INTEGER", notNull: true, primaryKeyPosition: 0, hidden: 0),
                Column(name: "is_end_sequence", type: "INTEGER", notNull: true, primaryKeyPosition: 0, hidden: 0),
                Column(name: "debug_artifact_uuid", type: "TEXT", notNull: false, primaryKeyPosition: 0, hidden: 0),
                Column(name: "debug_artifact_macho_sha256", type: "TEXT", notNull: false, primaryKeyPosition: 0, hidden: 0),
                Column(name: "debug_artifact_macho_byte_count", type: "INTEGER", notNull: false, primaryKeyPosition: 0, hidden: 0),
                Column(name: "line_program_unit_offset", type: "INTEGER", notNull: false, primaryKeyPosition: 0, hidden: 0),
                Column(name: "file_table_index", type: "INTEGER", notNull: false, primaryKeyPosition: 0, hidden: 0),
                Column(name: "table_path_kind", type: "TEXT", notNull: false, primaryKeyPosition: 0, hidden: 0),
                Column(name: "table_path", type: "TEXT", notNull: false, primaryKeyPosition: 0, hidden: 0),
            ]
            guard try columns("source_lines") == expected,
                  try isOrdinaryTable("source_lines", count: expected.count) else {
                throw DatabaseError.logicalBreakpointSchemaInvalid
            }
        }
    }

    private func validateLogicalBreakpointsSchema() throws {
        struct Column: Equatable {
            let name: String
            let type: String
            let notNull: Bool
            let primaryKeyPosition: Int
            let hidden: Int
        }
        let catalogColumns = [
            Column(name: "workspace_id", type: "INTEGER", notNull: false, primaryKeyPosition: 1, hidden: 0),
            Column(name: "workspace_uuid", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "catalog_uuid", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "revision", type: "INTEGER", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "specification_count", type: "INTEGER", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "catalog_sha256", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
        ]
        let specificationColumns = [
            Column(name: "id", type: "TEXT", notNull: false, primaryKeyPosition: 1, hidden: 0),
            Column(name: "workspace_id", type: "INTEGER", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "revision", type: "INTEGER", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "specification_version", type: "INTEGER", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "specification_byte_count", type: "INTEGER", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "specification_sha256", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "specification_json", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "created_at", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "modified_at", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
        ]
        func columns(in table: String) throws -> [Column] {
            try query("PRAGMA table_xinfo(\(table));") { statement in
                Column(
                    name: try Self.textColumn(statement, 1),
                    type: try Self.textColumn(statement, 2),
                    notNull: sqlite3_column_int(statement, 3) == 1,
                    primaryKeyPosition: Int(sqlite3_column_int(statement, 5)),
                    hidden: Int(sqlite3_column_int(statement, 6))
                )
            }
        }
        let tableKinds = try query(
            """
            SELECT name, type, ncol, wr, strict
            FROM pragma_table_list
            WHERE schema = 'main' AND name IN ('logical_breakpoint_catalogs', 'logical_breakpoints')
            ORDER BY name;
            """
        ) { statement in
            (
                try Self.textColumn(statement, 0), try Self.textColumn(statement, 1),
                Int(sqlite3_column_int(statement, 2)), Int(sqlite3_column_int(statement, 3)),
                Int(sqlite3_column_int(statement, 4))
            )
        }
        guard tableKinds.count == 2,
              tableKinds[0].0 == "logical_breakpoint_catalogs",
              tableKinds[0].1 == "table", tableKinds[0].2 == 6,
              tableKinds[0].3 == 0, tableKinds[0].4 == 0,
              tableKinds[1].0 == "logical_breakpoints",
              tableKinds[1].1 == "table", tableKinds[1].2 == 9,
              tableKinds[1].3 == 0, tableKinds[1].4 == 0,
              try columns(in: "logical_breakpoint_catalogs") == catalogColumns,
              try columns(in: "logical_breakpoints") == specificationColumns
        else {
            throw DatabaseError.logicalBreakpointSchemaInvalid
        }
        let schemaObjects = try query(
            """
            SELECT type, name, tbl_name, sql
            FROM sqlite_master
            WHERE name IN (
              'logical_breakpoint_catalogs', 'logical_breakpoints',
              'idx_logical_breakpoints_workspace_id'
            )
            ORDER BY name;
            """
        ) { statement in
            (
                try Self.textColumn(statement, 0), try Self.textColumn(statement, 1),
                try Self.textColumn(statement, 2), try Self.textColumn(statement, 3)
            )
        }
        let expectedSQL: [String: (String, String, String)] = [
            "logical_breakpoint_catalogs": (
                "table", "logical_breakpoint_catalogs",
                "CREATE TABLE logical_breakpoint_catalogs (workspace_id INTEGER PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE, workspace_uuid TEXT NOT NULL, catalog_uuid TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision > 0), specification_count INTEGER NOT NULL CHECK(specification_count >= 0), catalog_sha256 TEXT NOT NULL)"
            ),
            "logical_breakpoints": (
                "table", "logical_breakpoints",
                "CREATE TABLE logical_breakpoints (id TEXT PRIMARY KEY, workspace_id INTEGER NOT NULL REFERENCES logical_breakpoint_catalogs(workspace_id) ON DELETE CASCADE, revision INTEGER NOT NULL CHECK(revision > 0), specification_version INTEGER NOT NULL, specification_byte_count INTEGER NOT NULL, specification_sha256 TEXT NOT NULL, specification_json TEXT NOT NULL, created_at TEXT NOT NULL, modified_at TEXT NOT NULL)"
            ),
            "idx_logical_breakpoints_workspace_id": (
                "index", "logical_breakpoints",
                "CREATE INDEX idx_logical_breakpoints_workspace_id ON logical_breakpoints(workspace_id, id)"
            ),
        ]
        guard schemaObjects.count == 3,
              schemaObjects.allSatisfy({ object in
                  guard let expected = expectedSQL[object.1] else { return false }
                  return object.0 == expected.0 && object.2 == expected.1
                      && Self.compactSchemaSQL(object.3) == Self.compactSchemaSQL(expected.2)
              })
        else { throw DatabaseError.logicalBreakpointSchemaInvalid }
        let indexDefinitions = try query(
            """
            SELECT name, "unique", origin, partial
            FROM pragma_index_list('logical_breakpoints')
            WHERE name = 'idx_logical_breakpoints_workspace_id';
            """
        ) { statement in
            (
                try Self.textColumn(statement, 0), Int(sqlite3_column_int(statement, 1)),
                try Self.textColumn(statement, 2), Int(sqlite3_column_int(statement, 3))
            )
        }
        guard indexDefinitions.count == 1,
              indexDefinitions[0].0 == "idx_logical_breakpoints_workspace_id",
              indexDefinitions[0].1 == 0, indexDefinitions[0].2 == "c", indexDefinitions[0].3 == 0,
              try indexColumns(of: "idx_logical_breakpoints_workspace_id") == ["workspace_id", "id"]
        else { throw DatabaseError.logicalBreakpointSchemaInvalid }
        let catalogForeignKeys = try query(
            "SELECT \"table\", \"from\", \"to\", on_delete FROM pragma_foreign_key_list('logical_breakpoint_catalogs');"
        ) { statement in
            [
                try Self.textColumn(statement, 0), try Self.textColumn(statement, 1),
                try Self.textColumn(statement, 2), try Self.textColumn(statement, 3),
            ]
        }
        let breakpointForeignKeys = try query(
            "SELECT \"table\", \"from\", \"to\", on_delete FROM pragma_foreign_key_list('logical_breakpoints');"
        ) { statement in
            [
                try Self.textColumn(statement, 0), try Self.textColumn(statement, 1),
                try Self.textColumn(statement, 2), try Self.textColumn(statement, 3),
            ]
        }
        guard catalogForeignKeys == [["workspaces", "workspace_id", "id", "CASCADE"]],
              breakpointForeignKeys == [[
                "logical_breakpoint_catalogs", "workspace_id", "workspace_id", "CASCADE",
              ]]
        else {
            throw DatabaseError.logicalBreakpointSchemaInvalid
        }
    }

    private func validateLaunchProfilesSchema() throws {
        struct Column: Equatable {
            let name: String
            let type: String
            let notNull: Bool
            let primaryKeyPosition: Int
            let hidden: Int
        }
        let expectedColumns = [
            Column(name: "workspace_id", type: "INTEGER", notNull: false, primaryKeyPosition: 1, hidden: 0),
            Column(name: "workspace_uuid", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "catalog_uuid", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "revision", type: "INTEGER", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "profile_count", type: "INTEGER", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "selected_profile_uuid", type: "TEXT", notNull: false, primaryKeyPosition: 0, hidden: 0),
            Column(name: "catalog_version", type: "INTEGER", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "catalog_byte_count", type: "INTEGER", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "catalog_sha256", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "catalog_blob", type: "BLOB", notNull: true, primaryKeyPosition: 0, hidden: 0),
        ]
        let columns = try query("PRAGMA table_xinfo(launch_profile_catalogs);") { statement in
            Column(
                name: try Self.textColumn(statement, 1),
                type: try Self.textColumn(statement, 2),
                notNull: sqlite3_column_int(statement, 3) == 1,
                primaryKeyPosition: Int(sqlite3_column_int(statement, 5)),
                hidden: Int(sqlite3_column_int(statement, 6))
            )
        }
        let tableKinds = try query(
            """
            SELECT type, ncol, wr, strict
            FROM pragma_table_list
            WHERE schema = 'main' AND name = 'launch_profile_catalogs';
            """
        ) { statement in
            (
                try Self.textColumn(statement, 0), Int(sqlite3_column_int(statement, 1)),
                Int(sqlite3_column_int(statement, 2)), Int(sqlite3_column_int(statement, 3))
            )
        }
        let schemaObjects = try query(
            """
            SELECT type, tbl_name, sql
            FROM sqlite_master
            WHERE name = 'launch_profile_catalogs'
               OR tbl_name = 'launch_profile_catalogs';
            """
        ) { statement in
            (
                try Self.textColumn(statement, 0), try Self.textColumn(statement, 1),
                try Self.textColumn(statement, 2)
            )
        }
        let expectedSQL = """
        CREATE TABLE launch_profile_catalogs (
          workspace_id INTEGER PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
          workspace_uuid TEXT NOT NULL,
          catalog_uuid TEXT NOT NULL,
          revision INTEGER NOT NULL,
          profile_count INTEGER NOT NULL,
          selected_profile_uuid TEXT,
          catalog_version INTEGER NOT NULL,
          catalog_byte_count INTEGER NOT NULL,
          catalog_sha256 TEXT NOT NULL,
          catalog_blob BLOB NOT NULL
        )
        """
        let foreignKeys = try query(
            "SELECT \"table\", \"from\", \"to\", on_delete FROM pragma_foreign_key_list('launch_profile_catalogs');"
        ) { statement in
            [
                try Self.textColumn(statement, 0), try Self.textColumn(statement, 1),
                try Self.textColumn(statement, 2), try Self.textColumn(statement, 3),
            ]
        }
        guard columns == expectedColumns,
              tableKinds.count == 1,
              tableKinds[0].0 == "table", tableKinds[0].1 == expectedColumns.count,
              tableKinds[0].2 == 0, tableKinds[0].3 == 0,
              schemaObjects.count == 1,
              schemaObjects[0].0 == "table", schemaObjects[0].1 == "launch_profile_catalogs",
              Self.compactSchemaSQL(schemaObjects[0].2) == Self.compactSchemaSQL(expectedSQL),
              foreignKeys == [["workspaces", "workspace_id", "id", "CASCADE"]]
        else {
            throw DatabaseError.launchProfileSchemaInvalid
        }
    }

    private func validatePhase2AssistantSessionRecordsV2Schema() throws {
        let expectedColumns = [
            "id", "workspace_id", "workspace_uuid", "document_id", "sequence",
            "conversation_id", "turn_sequence", "inference_turn_id", "is_legacy",
            "intent_id", "user_goal", "status", "prompt_text", "answer_text",
            "transcript_text", "context_digest", "canonical_byte_count", "provider_tool_count",
            "record_schema_version", "created_at", "completed_at", "content_sha256",
        ]
        guard try columnNames(in: "phase2_assistant_session_records") == expectedColumns,
              try indexColumns(of: "idx_phase2_assistant_sessions_workspace_sequence") == ["workspace_id", "sequence"],
              try indexColumns(of: "idx_phase2_assistant_sessions_workspace_conversation_turn") == ["workspace_id", "conversation_id", "turn_sequence"],
              try indexColumns(of: "idx_phase2_assistant_sessions_workspace_inference_turn") == ["workspace_id", "inference_turn_id"],
              try indexColumns(of: "idx_phase2_assistant_sessions_workspace_created") == ["workspace_id", "created_at", "id"] else {
            throw DatabaseError.phase2AssistantSessionSchemaInvalid
        }
    }

    private func validatePhase2AssistantSessionRecordsSchema() throws {
        struct Column: Equatable {
            let name: String
            let type: String
            let notNull: Bool
            let primaryKeyPosition: Int
            let hidden: Int
        }
        let expectedColumns = [
            Column(name: "id", type: "TEXT", notNull: false, primaryKeyPosition: 1, hidden: 0),
            Column(name: "workspace_id", type: "INTEGER", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "workspace_uuid", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "document_id", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "sequence", type: "INTEGER", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "conversation_id", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "turn_sequence", type: "INTEGER", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "inference_turn_id", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "is_legacy", type: "INTEGER", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "intent_id", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "user_goal", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "status", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "prompt_text", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "answer_text", type: "TEXT", notNull: false, primaryKeyPosition: 0, hidden: 0),
            Column(name: "transcript_text", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "context_digest", type: "TEXT", notNull: false, primaryKeyPosition: 0, hidden: 0),
            Column(name: "canonical_byte_count", type: "INTEGER", notNull: false, primaryKeyPosition: 0, hidden: 0),
            Column(name: "provider_tool_count", type: "INTEGER", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "continuation_checkpoint_json", type: "TEXT", notNull: false, primaryKeyPosition: 0, hidden: 0),
            Column(name: "shell_proposal_id", type: "TEXT", notNull: false, primaryKeyPosition: 0, hidden: 0),
            Column(name: "shell_execution_id", type: "TEXT", notNull: false, primaryKeyPosition: 0, hidden: 0),
            Column(name: "continuation_ordinal", type: "INTEGER", notNull: false, primaryKeyPosition: 0, hidden: 0),
            Column(name: "continuation_request_id", type: "TEXT", notNull: false, primaryKeyPosition: 0, hidden: 0),
            Column(name: "record_schema_version", type: "INTEGER", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "created_at", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
            Column(name: "completed_at", type: "TEXT", notNull: false, primaryKeyPosition: 0, hidden: 0),
            Column(name: "content_sha256", type: "TEXT", notNull: true, primaryKeyPosition: 0, hidden: 0),
        ]
        let columns = try query("PRAGMA table_xinfo(phase2_assistant_session_records);") { statement in
            Column(
                name: try Self.textColumn(statement, 1),
                type: try Self.textColumn(statement, 2),
                notNull: sqlite3_column_int(statement, 3) == 1,
                primaryKeyPosition: Int(sqlite3_column_int(statement, 5)),
                hidden: Int(sqlite3_column_int(statement, 6))
            )
        }
        let tableKinds = try query(
            """
            SELECT type, ncol, wr, strict
            FROM pragma_table_list
            WHERE schema = 'main' AND name = 'phase2_assistant_session_records';
            """
        ) { statement in
            (
                try Self.textColumn(statement, 0), Int(sqlite3_column_int(statement, 1)),
                Int(sqlite3_column_int(statement, 2)), Int(sqlite3_column_int(statement, 3))
            )
        }
        guard columns == expectedColumns,
              tableKinds.count == 1,
              tableKinds[0].0 == "table", tableKinds[0].1 == expectedColumns.count,
              tableKinds[0].2 == 0, tableKinds[0].3 == 0,
              try indexColumns(of: "idx_phase2_assistant_sessions_workspace_sequence") == ["workspace_id", "sequence"],
              try indexColumns(of: "idx_phase2_assistant_sessions_workspace_conversation_turn") == ["workspace_id", "conversation_id", "turn_sequence"],
              try indexColumns(of: "idx_phase2_assistant_sessions_workspace_inference_turn") == ["workspace_id", "inference_turn_id"],
              try indexColumns(of: "idx_phase2_assistant_sessions_workspace_created") == ["workspace_id", "created_at", "id"],
              try indexColumns(of: "idx_phase2_assistant_sessions_workspace_proposal") == ["workspace_id", "shell_proposal_id"],
              try indexColumns(of: "idx_phase2_assistant_sessions_workspace_execution") == ["workspace_id", "shell_execution_id"],
              try indexColumns(of: "idx_phase2_assistant_sessions_workspace_continuation_ordinal") == ["workspace_id", "conversation_id", "turn_sequence", "continuation_ordinal"],
              try indexColumns(of: "idx_phase2_assistant_sessions_continuation_request") == ["continuation_request_id"]
        else {
            throw DatabaseError.phase2AssistantSessionSchemaInvalid
        }
        let foreignKeys = try query(
            "SELECT \"table\", \"from\", \"to\", on_delete FROM pragma_foreign_key_list('phase2_assistant_session_records');"
        ) { statement in
            [
                try Self.textColumn(statement, 0), try Self.textColumn(statement, 1),
                try Self.textColumn(statement, 2), try Self.textColumn(statement, 3),
            ]
        }
        guard foreignKeys == [["workspaces", "workspace_id", "id", "CASCADE"]] else {
            throw DatabaseError.phase2AssistantSessionSchemaInvalid
        }
    }

    private static func compactSchemaSQL(_ sql: String) -> String {
        sql.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .replacingOccurrences(of: ";", with: "")
    }

    private static func deterministicBreakpointUUID(
        domain: String,
        workspaceUUID: UUID,
        binaryUUID: UUID?,
        preferredVA: UInt64?
    ) -> UUID {
        var input = Data("com.macscope.ws21.\(domain)\u{0}".utf8)
        withUnsafeBytes(of: workspaceUUID.uuid) { input.append(contentsOf: $0) }
        if let binaryUUID {
            withUnsafeBytes(of: binaryUUID.uuid) { input.append(contentsOf: $0) }
        }
        if var address = preferredVA?.bigEndian {
            withUnsafeBytes(of: &address) { input.append(contentsOf: $0) }
        }
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func deterministicLaunchProfileCatalogUUID(workspaceUUID: UUID) -> UUID {
        var input = Data("com.macscope.ws22.launch-profile-catalog.v1\u{0}".utf8)
        withUnsafeBytes(of: workspaceUUID.uuid) { input.append(contentsOf: $0) }
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// A recognized column list is not sufficient permission to rebuild a table: unknown
    /// triggers or indexes would be discarded, while inbound ON DELETE actions can mutate child
    /// tables when `source_lines` is dropped. Genuine product v28 databases have no such objects;
    /// fail closed before any DDL if an altered database does.
    private func unsupportedSourceLinesDependencies() throws -> [String] {
        var objects = try query(
            """
            SELECT 'index', name
            FROM sqlite_master
            WHERE tbl_name = ? COLLATE NOCASE
              AND type = 'index'
              AND name <> ? COLLATE NOCASE
            ORDER BY name;
            """,
            bindings: [.text("source_lines"), .text("idx_source_lines_binary_id")]
        ) { statement in
            let type = try Self.textColumn(statement, 0)
            let name = try Self.textColumn(statement, 1)
            return "\(type):\(name)"
        }

        objects.append(contentsOf: try query(
            """
            SELECT type, name
            FROM sqlite_master
            WHERE type IN ('trigger', 'view')
              AND instr(lower(coalesce(sql, '')), 'source_lines') > 0
            ORDER BY type, name;
            """
        ) { statement in
            let type = try Self.textColumn(statement, 0)
            let name = try Self.textColumn(statement, 1)
            return "\(type):\(name)"
        })

        let expectedIndexOwners = try query(
            """
            SELECT tbl_name
            FROM sqlite_master
            WHERE type = 'index' AND name = ? COLLATE NOCASE;
            """,
            bindings: [.text("idx_source_lines_binary_id")]
        ) { statement in
            try Self.textColumn(statement, 0)
        }
        objects.append(contentsOf: expectedIndexOwners.compactMap { owner in
            owner.caseInsensitiveCompare("source_lines") == .orderedSame
                ? nil
                : "index-owner:idx_source_lines_binary_id:\(owner)"
        })

        for tableName in try tableNames() {
            let referencedTables = try query(
                "SELECT \"table\" FROM pragma_foreign_key_list(?);",
                bindings: [.text(tableName)]
            ) { statement in
                try Self.textColumn(statement, 0)
            }
            if referencedTables.contains(where: {
                $0.caseInsensitiveCompare("source_lines") == .orderedSame
            }) {
                objects.append("foreign-key:\(tableName)")
            }
        }

        return objects.sorted()
    }

    /// Shared v25-v27 image-aware schema convergence: every workspace-scoped authoring row gains an `image_slot`
    /// (0 = the primary/legacy image) and every authoring UNIQUE index widens to include it, so
    /// two images at the same VA no longer collide. Fully idempotent (column existence checks +
    /// DROP/CREATE indexes), so it is safe on every migration path AND on a fresh install where
    /// the factored schema already produced the wide form. The INDEX RESURRECTION trap: an
    /// existing DB already holds each narrow index UNDER THE SAME NAME, so `CREATE … IF NOT
    /// EXISTS` would leave it narrow — the DROP below is mandatory before the wide CREATE.
    private func ensureImageAwareSchema() throws {
        let tables = Set(try tableNames())

        // 1) image_slot column on each authoring table (idempotent).
        for table in ["address_overrides", "manual_xrefs", "bookmarks", "segment_overrides"] where tables.contains(table) {
            if !Set(try columnNames(in: table)).contains("image_slot") {
                try execute("ALTER TABLE \(table) ADD COLUMN image_slot INTEGER NOT NULL DEFAULT 0;")
            }
        }

        // 2) Re-create each authoring UNIQUE index in its WIDE (image-slot-qualified) form. DROP
        //    first so an already-present narrow index of the same name is genuinely replaced.
        let wideIndexes: [(table: String, name: String, sql: String)] = [
            ("address_overrides", "idx_address_overrides_workspace_address",
             "CREATE UNIQUE INDEX idx_address_overrides_workspace_address ON address_overrides(workspace_id, image_slot, address);"),
            ("manual_xrefs", "idx_manual_xrefs_workspace_endpoints",
             "CREATE UNIQUE INDEX idx_manual_xrefs_workspace_endpoints ON manual_xrefs(workspace_id, image_slot, from_address, to_address, kind, is_suppression);"),
            ("bookmarks", "idx_bookmarks_workspace_address",
             "CREATE UNIQUE INDEX idx_bookmarks_workspace_address ON bookmarks(workspace_id, image_slot, address);"),
            ("segment_overrides", "idx_segment_overrides_workspace_name",
             "CREATE UNIQUE INDEX idx_segment_overrides_workspace_name ON segment_overrides(workspace_id, image_slot, original_name);"),
        ]
        for index in wideIndexes where tables.contains(index.table) {
            try execute("DROP INDEX IF EXISTS \(index.name);")
            try execute(index.sql)
        }

        // 3) binaries.image_slot: durable per-image slot. Existing rows are numbered by insertion
        //    order within each workspace (rowid ascending), so the first binary is slot 0. This
        //    matches the in-memory rule that binaries.first is the primary image.
        if tables.contains("binaries"), !Set(try columnNames(in: "binaries")).contains("image_slot") {
            try execute("ALTER TABLE binaries ADD COLUMN image_slot INTEGER NOT NULL DEFAULT 0;")
            try execute("""
                UPDATE binaries SET image_slot = (
                  SELECT COUNT(*) FROM binaries AS b2
                  WHERE b2.workspace_id = binaries.workspace_id AND b2.id < binaries.id
                );
                """)
        }

        // v27: a durable slot identifies at most one binary within a workspace. Validate before
        // enforcing the UNIQUE index so a corrupt/hand-edited v26 database receives an actionable
        // diagnostic and is left untouched instead of being silently renumbered or surfacing a
        // generic SQLite constraint failure. DROP first avoids the index-resurrection trap.
        if tables.contains("binaries") {
            let duplicateSlot = try first(
                """
                SELECT workspace_id, image_slot
                FROM binaries
                GROUP BY workspace_id, image_slot
                HAVING COUNT(*) > 1
                ORDER BY workspace_id, image_slot
                LIMIT 1;
                """,
                map: { statement in
                    (
                        workspaceID: sqlite3_column_int64(statement, 0),
                        imageSlot: Int(sqlite3_column_int64(statement, 1))
                    )
                }
            )
            if let duplicateSlot {
                throw DatabaseError.duplicateImageSlot(
                    workspaceID: duplicateSlot.workspaceID,
                    imageSlot: duplicateSlot.imageSlot
                )
            }
            try execute("DROP INDEX IF EXISTS idx_binaries_workspace_image_slot;")
            try execute("CREATE UNIQUE INDEX idx_binaries_workspace_image_slot ON binaries(workspace_id, image_slot);")
        }

        // v26: binaries.selected_slice_index — the persisted universal-slice pick (nullable; NULL
        // = the default selection rule / a thin binary). Idempotent add so every migration path
        // (which funnels through here) gains it; legacy rows keep NULL, correctly meaning "no
        // recorded pick" so reanalysis applies the default rule exactly as it did pre-v26.
        if tables.contains("binaries"), !Set(try columnNames(in: "binaries")).contains("selected_slice_index") {
            try execute("ALTER TABLE binaries ADD COLUMN selected_slice_index INTEGER;")
        }
        try ensureAnalysisFingerprintSchema()

        // 4) workspaces.next_image_slot: monotonic slot allocator, backfilled to the current
        //    binary count so the next allocated slot never reuses an existing one. The backfill
        //    subquery reads `binaries`, so it is additionally gated on that table existing (a
        //    degenerate DB without it keeps the DEFAULT 1, which is correct: only slot 0 exists).
        if tables.contains("workspaces"), !Set(try columnNames(in: "workspaces")).contains("next_image_slot") {
            try execute("ALTER TABLE workspaces ADD COLUMN next_image_slot INTEGER NOT NULL DEFAULT 1;")
            if tables.contains("binaries") {
                try execute("""
                    UPDATE workspaces SET next_image_slot = MAX(1, (
                      SELECT COUNT(*) FROM binaries WHERE binaries.workspace_id = workspaces.id
                    ));
                """)
            }
        }
        // v27: persisted UI focus. Old sessions default to the legacy/primary slot. Guard table
        // presence because the intentionally minimal historical migration fixtures omit sessions.
        if tables.contains("workspace_sessions"),
           !Set(try columnNames(in: "workspace_sessions")).contains("focused_image_slot") {
            try execute("ALTER TABLE workspace_sessions ADD COLUMN focused_image_slot INTEGER NOT NULL DEFAULT 0;")
        }

        // v28 (WS-5): per-image dSYM source lines. dSYM-imported (not byte-derivable), so persisted
        // rather than rehydrated. Fresh table → no index-resurrection concern; idempotent create so
        // every migration path (which funnels through here) gains it. CASCADE-deletes with binaries.
        try execute("""
            CREATE TABLE IF NOT EXISTS source_lines (
              id INTEGER PRIMARY KEY,
              binary_id INTEGER NOT NULL REFERENCES binaries(id) ON DELETE CASCADE,
              address INTEGER NOT NULL,
              file TEXT,
              line INTEGER NOT NULL,
              column INTEGER NOT NULL,
              is_end_sequence INTEGER NOT NULL DEFAULT 0
            );
            """)
        try execute("CREATE INDEX IF NOT EXISTS idx_source_lines_binary_id ON source_lines(binary_id);")
    }

    private func migrateAddressOverrideColumnsToCurrent(stored: Int) throws {
        guard Set(try tableNames()).contains("address_overrides") else {
            throw DatabaseError.migrationRequired(stored: stored, supported: Self.schemaVersion)
        }
        try transaction {
            try ensureAddressOverrideColumns()
            // The type catalog table arrived in v17; create it on every ALTER path
            // (idempotent) so an old DB reaching the current version always has it.
            try execute(Self.typeDefinitionsSchemaSQL)
            // manual_xrefs + bookmarks arrived in v22; create them on every ALTER path
            // (idempotent) so an old DB reaching the current version always has them.
            try execute(Self.manualXRefsSchemaSQL)
            try execute(Self.bookmarksSchemaSQL)
            // segment_overrides arrived in v23; same idempotent-create rationale.
            try execute(Self.segmentOverridesSchemaSQL)
            try ensureImageAwareSchema()
            try finalizeLogicalBreakpointsAndStampV30()
        }
    }

    private func ensureAnalysisFingerprintSchema() throws {
        let tables = Set(try tableNames())
        guard tables.contains("binaries") else { return }
        let columns = Set(try columnNames(in: "binaries"))
        if !columns.contains("analysis_input_fingerprint_json") {
            try execute("ALTER TABLE binaries ADD COLUMN analysis_input_fingerprint_json TEXT;")
        }
        try ensureFunctionNoReturnProvenanceSchema()
        try execute(Self.constantCFStringsSchemaSQL)
    }

    /// §4.12a: HOP-1 no-return provenance per function row. Additive and nullable like the
    /// analysis fingerprint column, so it rides the same idempotent ensure (no user_version bump):
    /// every migration path and every current-version open gains it, and pre-existing rows keep
    /// NULL ("not known to halt" until the next re-analysis recomputes it).
    private func ensureFunctionNoReturnProvenanceSchema() throws {
        guard Set(try tableNames()).contains("functions") else { return }
        if !Set(try columnNames(in: "functions")).contains("no_return_provenance") {
            try execute("ALTER TABLE functions ADD COLUMN no_return_provenance TEXT;")
        }
    }

    /// Idempotently adds every column the current `address_overrides` schema needs
    /// beyond the v13 baseline (custom_name/comment). ADD COLUMN with NOT NULL
    /// DEFAULT is data-preserving. Add new authoring columns here so all migration
    /// ALTER paths stay complete.
    private func ensureAddressOverrideColumns() throws {
        let columns = Set(try columnNames(in: "address_overrides"))
        if !columns.contains("tag") {
            try execute("ALTER TABLE address_overrides ADD COLUMN tag TEXT;")
        }
        if !columns.contains("color_tag") {
            try execute("ALTER TABLE address_overrides ADD COLUMN color_tag TEXT;")
        }
        if !columns.contains("is_data") {
            try execute("ALTER TABLE address_overrides ADD COLUMN is_data INTEGER NOT NULL DEFAULT 0;")
        }
        if !columns.contains("signature_json") {
            try execute("ALTER TABLE address_overrides ADD COLUMN signature_json TEXT;")
        }
        if !columns.contains("applied_type_name") {
            try execute("ALTER TABLE address_overrides ADD COLUMN applied_type_name TEXT;")
        }
        if !columns.contains("switch_hint_json") {
            try execute("ALTER TABLE address_overrides ADD COLUMN switch_hint_json TEXT;")
        }
        if !columns.contains("operand_format") {
            try execute("ALTER TABLE address_overrides ADD COLUMN operand_format TEXT;")
        }
        if !columns.contains("mark_as_procedure") {
            try execute("ALTER TABLE address_overrides ADD COLUMN mark_as_procedure INTEGER NOT NULL DEFAULT 0;")
        }
        if !columns.contains("data_shape_json") {
            try execute("ALTER TABLE address_overrides ADD COLUMN data_shape_json TEXT;")
        }
        if !columns.contains("is_undefined") {
            try execute("ALTER TABLE address_overrides ADD COLUMN is_undefined INTEGER NOT NULL DEFAULT 0;")
        }
        if !columns.contains("patch_json") {
            try execute("ALTER TABLE address_overrides ADD COLUMN patch_json TEXT;")
        }
        if !columns.contains("register_names_json") {
            try execute("ALTER TABLE address_overrides ADD COLUMN register_names_json TEXT;")
        }
        if !columns.contains("local_label") {
            try execute("ALTER TABLE address_overrides ADD COLUMN local_label TEXT;")
        }
        if !columns.contains("appended_cave_json") {
            try execute("ALTER TABLE address_overrides ADD COLUMN appended_cave_json TEXT;")
        }
        if !columns.contains("stack_locals_json") {
            try execute("ALTER TABLE address_overrides ADD COLUMN stack_locals_json TEXT;")
        }
    }

    private func migrateWorkspaceDocumentsToCurrentSchema(existingColumns columns: Set<String>) throws {
        if !columns.contains("file_version_identifier") {
            try execute("ALTER TABLE workspace_documents ADD COLUMN file_version_identifier TEXT;")
        }
        if !columns.contains("conflict_detected_at") {
            try execute("ALTER TABLE workspace_documents ADD COLUMN conflict_detected_at TEXT;")
        }
        if !columns.contains("conflict_reason") {
            try execute("ALTER TABLE workspace_documents ADD COLUMN conflict_reason TEXT;")
        }
        if !columns.contains("input_copying_decision") {
            try execute("ALTER TABLE workspace_documents ADD COLUMN input_copying_decision TEXT NOT NULL DEFAULT 'copy_inputs_into_package';")
        }
        if !columns.contains("bookmark_resolution_decision") {
            try execute("ALTER TABLE workspace_documents ADD COLUMN bookmark_resolution_decision TEXT NOT NULL DEFAULT 'resolve_stored_bookmarks';")
        }
        if !columns.contains("bookmark_resolution_error") {
            try execute("ALTER TABLE workspace_documents ADD COLUMN bookmark_resolution_error TEXT;")
        }
        if !columns.contains("recent_document_state") {
            try execute("ALTER TABLE workspace_documents ADD COLUMN recent_document_state TEXT NOT NULL DEFAULT 'available';")
        }
        if !columns.contains("recent_document_state_updated_at") {
            try execute("ALTER TABLE workspace_documents ADD COLUMN recent_document_state_updated_at TEXT;")
        }
        try execute("CREATE INDEX IF NOT EXISTS idx_workspace_documents_conflict_detected_at ON workspace_documents(conflict_detected_at DESC);")
        try execute("CREATE INDEX IF NOT EXISTS idx_workspace_documents_recent_document_state ON workspace_documents(recent_document_state);")
    }

    func userVersion() throws -> Int {
        try scalarInt("PRAGMA user_version;")
    }

    /// Runs `PRAGMA integrity_check` and returns its rows. SQLite returns a single "ok"
    /// row when the database is structurally consistent; otherwise one row per problem.
    func integrityCheck() throws -> [String] {
        try query("PRAGMA integrity_check;") { statement in
            try Self.textColumn(statement, 0)
        }
    }

    /// Whether SQLite foreign-key enforcement is active for this connection.
    func foreignKeysEnabled() throws -> Bool {
        try scalarInt("PRAGMA foreign_keys;") == 1
    }

    func tableNames() throws -> [String] {
        try query(
            """
            SELECT name
            FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            ORDER BY name;
            """
        ) { statement in
            try Self.textColumn(statement, 0)
        }
    }

    func columnNames(in tableName: String) throws -> [String] {
        try query("PRAGMA table_info(\(tableName));") { statement in
            try Self.textColumn(statement, 1)
        }
    }

    /// The columns of an index in order — used by the migration tests to prove a UNIQUE index
    /// widened to include `image_slot`. Internal (test-only in practice).
    func indexColumns(of indexName: String) throws -> [String] {
        try query("PRAGMA index_info(\(indexName));") { statement in
            try Self.textColumn(statement, 2)
        }
    }

    /// Runs raw SQL. Internal so the migration tests can materialize a pre-v25 (narrow) schema
    /// and prove `applySchema()` upgrades it without data loss or index resurrection. Production
    /// code never calls this — it goes through the typed insert/query helpers.
    func executeRawForTesting(_ sql: String) throws {
        try execute(sql)
    }

    func scalarIntForTesting(_ sql: String) throws -> Int {
        try scalarInt(sql)
    }

    func scalarTextForTesting(_ sql: String) throws -> String? {
        let values: [String?] = try query(sql) { statement in
            Self.optionalTextColumn(statement, 0)
        }
        return values.first ?? nil
    }

    func setReconstructionMutationFailureForTesting(
        after phase: ReconstructionMutationPhase?
    ) {
        reconstructionMutationFailureForTesting = phase
    }

    func setReconstructionSidecarBootstrapFailureForTesting(
        after phase: ReconstructionSidecarBootstrapPhase?
    ) {
        reconstructionSidecarBootstrapFailureForTesting = phase
    }

    func setReconstructionFinalResultMutationFailureForTesting(
        after phase: ReconstructionFinalResultMutationPhase?
    ) {
        reconstructionFinalResultMutationFailureForTesting = phase
    }

    func setTransactionRollbackFailureForTesting(_ enabled: Bool) {
        transactionRollbackFailureForTesting = enabled
    }

    /// Asks SQLite's active VFS whether the opened main database is still the file currently
    /// reached by its pathname. Unlike `PRAGMA database_list`, this detects rename/replace ABA
    /// attacks that leave the same path string pointing at a different inode after `sqlite3_open`.
    func reconstructionMainDatabaseFileHasMoved() throws -> Bool {
        guard !reconstructionMainDatabaseIsInMemory else { return false }
        let connection = try requireConnection()
        var hasMoved: Int32 = 0
        let status = "main".withCString { databaseName in
            sqlite3_file_control(
                connection,
                databaseName,
                SQLITE_FCNTL_HAS_MOVED,
                &hasMoved
            )
        }
        guard status == SQLITE_OK else {
            throw DatabaseError.stepFailed(lastErrorMessage())
        }
        return hasMoved != 0
    }

    func reconstructionProjectionSnapshotForTesting(
        workspaceID: UUID
    ) throws -> [String] {
        Self.reconstructionProjectionSnapshot(
            try reconstructionProjectionRows(workspaceID: workspaceID)
        )
    }

    /// Sets `PRAGMA user_version` directly — the migration tests use it to stamp a fabricated
    /// pre-v25 database so `applySchema()` takes the v24→v25 path.
    func setUserVersionForTesting(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version);")
    }

    @discardableResult
    func insertWorkspace(_ record: WorkspaceRecord) throws -> WorkspaceRecord {
        try run(
            """
            INSERT INTO workspaces (uuid, name, created_at, modified_at)
            VALUES (?, ?, ?, ?);
            """,
            bindings: [
                .text(record.uuid.uuidString),
                .text(record.name),
                .text(Self.string(from: record.createdAt)),
                .text(Self.string(from: record.modifiedAt))
            ]
        )

        var inserted = record
        inserted.id = sqlite3_last_insert_rowid(try requireConnection())
        return inserted
    }

    /// Reads the durable sidecar's identity authority without applying schema or mutating rows.
    ///
    /// Callers must run this before `applySchema()`. Schema v0 is accepted only when no user table
    /// exists; the public entry point accepts only current schema, while the migration entry point
    /// additionally accepts the explicitly frozen historical versions. Every accepted nonzero
    /// database must carry the exact identity-table structure. A current schema with no
    /// workspace/document rows is the sole recoverable post-schema/pre-bootstrap state; every
    /// partial or ambiguous row graph fails closed rather than selecting a row by guesswork.
    func preflightReconstructionSidecarBinding(
        workspaceUUID: UUID,
        documentID: UUID,
        canonicalPackagePath: String
    ) throws -> ReconstructionSidecarBindingPreflight {
        try preflightReconstructionSidecarBinding(
            workspaceUUID: workspaceUUID,
            documentID: documentID,
            canonicalPackagePath: canonicalPackagePath,
            acceptedHistoricalVersions: []
        )
    }

    /// Reads only the identity-bearing rows needed to authorize a supported sidecar migration.
    /// v38-v40, v42 and v43 are historical sidecar schemas whose identity tables are
    /// identical to the current schema. Every other historical version remains fail-closed.
    func preflightReconstructionSidecarBindingBeforeMigration(
        workspaceUUID: UUID,
        documentID: UUID,
        canonicalPackagePath: String
    ) throws -> ReconstructionSidecarBindingPreflight {
        try preflightReconstructionSidecarBinding(
            workspaceUUID: workspaceUUID,
            documentID: documentID,
            canonicalPackagePath: canonicalPackagePath,
            acceptedHistoricalVersions: Self.supportedReconstructionSidecarMigrationVersions
        )
    }

    private func preflightReconstructionSidecarBinding(
        workspaceUUID: UUID,
        documentID: UUID,
        canonicalPackagePath: String,
        acceptedHistoricalVersions: Set<Int>
    ) throws -> ReconstructionSidecarBindingPreflight {
        guard Self.isCanonicalAbsolutePackagePath(canonicalPackagePath) else {
            throw DatabaseError.reconstructionStateInvalid(
                "sidecar canonical package path"
            )
        }

        // `query_only` is connection-local and does not alter the database. It converts any
        // accidental write added to this preflight in the future into an immediate SQLite error.
        let queryOnlyWasEnabled = try scalarInt("PRAGMA query_only;") == 1
        if !queryOnlyWasEnabled {
            try execute("PRAGMA query_only = ON;")
        }
        defer {
            if !queryOnlyWasEnabled {
                try? execute("PRAGMA query_only = OFF;")
            }
        }

        let version = try userVersion()
        let tables = try tableNames()
        if version == 0 {
            guard tables.isEmpty else {
                throw DatabaseError.migrationRequired(
                    stored: version,
                    supported: Self.schemaVersion
                )
            }
            return .uninitialized
        }
        let isAcceptedHistoricalVersion = acceptedHistoricalVersions.contains(version)
        guard version == Self.schemaVersion || isAcceptedHistoricalVersion else {
            if version > Self.schemaVersion {
                throw DatabaseError.unsupportedSchemaVersion(
                    stored: version,
                    supported: Self.schemaVersion
                )
            }
            throw DatabaseError.migrationRequired(
                stored: version,
                supported: Self.schemaVersion
            )
        }
        try validateReconstructionSidecarIdentitySchema()
        try requireReconstructionSidecarForeignKeyIntegrity()

        let workspaces = try workspaces()
        let documents = try workspaceDocuments()
        if workspaces.isEmpty, documents.isEmpty {
            guard try reconstructionSidecarHasNoUserRows() else {
                throw DatabaseError.reconstructionStateInvalid(
                    "sidecar empty schema contains durable rows"
                )
            }
            return .emptyCurrentSchema
        }
        guard workspaces.count == 1,
              let workspaceRowID = workspaces[0].id,
              workspaces[0].uuid == workspaceUUID else {
            return .workspaceMismatch
        }
        guard documents.count == 1,
              documents[0].workspaceID == workspaceRowID,
              documents[0].documentID == documentID else {
            return .documentMismatch
        }
        guard documents[0].packagePath == canonicalPackagePath else {
            return .canonicalPackagePathMismatch
        }
        return .matched(workspaceRowID: workspaceRowID)
    }

    /// Atomically creates the two rows that establish a new sidecar's durable identity.
    ///
    /// This operation is deliberately create-only. An existing workspace row, an existing
    /// document row, or a partial pair is an integrity error; the caller must never recover by
    /// searching for a plausible row after a failed bootstrap.
    func bootstrapReconstructionWorkspaceSidecar(
        workspaceUUID: UUID,
        workspaceName: String,
        documentID: UUID,
        canonicalPackagePath: String,
        now: Date
    ) throws -> Int64 {
        guard Self.isCanonicalAbsolutePackagePath(canonicalPackagePath) else {
            throw DatabaseError.reconstructionStateInvalid(
                "sidecar canonical package path"
            )
        }
        let version = try userVersion()
        guard version == Self.schemaVersion else {
            if version > Self.schemaVersion {
                throw DatabaseError.unsupportedSchemaVersion(
                    stored: version,
                    supported: Self.schemaVersion
                )
            }
            throw DatabaseError.migrationRequired(
                stored: version,
                supported: Self.schemaVersion
            )
        }
        try requireReconstructionSidecarForeignKeyIntegrity()

        let persistedNowText = Self.string(from: now)
        guard let persistedNow = Self.date(from: persistedNowText) else {
            throw DatabaseError.invalidDate(persistedNowText)
        }

        return try transaction {
            guard try reconstructionSidecarHasNoUserRows() else {
                throw DatabaseError.reconstructionStateInvalid(
                    "sidecar bootstrap requires globally empty current schema"
                )
            }
            let workspace = try saveSnapshot(
                workspaceUUID: workspaceUUID,
                workspaceName: workspaceName,
                snapshot: WorkspaceSnapshot(binaries: [], analysisBySlot: [:]),
                now: persistedNow
            )
            guard let workspaceRowID = workspace.id else {
                throw DatabaseError.notFound
            }
            try triggerReconstructionSidecarBootstrapFailureForTesting(
                after: .insertedWorkspace
            )
            let expectedDocument = WorkspaceDocumentRecord(
                workspaceID: workspaceRowID,
                documentID: documentID,
                packagePath: canonicalPackagePath,
                lastOpenedAt: persistedNow,
                lastSavedAt: nil,
                isDirty: false,
                inputCopyingDecision: .copyInputsIntoPackage,
                bookmarkResolutionDecision: .usePackageAttachmentsOnly,
                recentDocumentState: .available,
                recentDocumentStateUpdatedAt: persistedNow
            )
            _ = try upsertWorkspaceDocument(expectedDocument)

            guard try self.workspace(id: workspaceRowID)?.uuid == workspaceUUID,
                  try workspaceDocument(workspaceID: workspaceRowID) == expectedDocument else {
                throw DatabaseError.reconstructionStateInvalid(
                    "sidecar bootstrap identity verification"
                )
            }
            return workspaceRowID
        }
    }

    private func requireReconstructionSidecarForeignKeyIntegrity() throws {
        let statement = try prepare("PRAGMA foreign_key_check;")
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_DONE:
            return
        case SQLITE_ROW:
            throw DatabaseError.reconstructionStateInvalid(
                "sidecar foreign key integrity"
            )
        default:
            throw DatabaseError.stepFailed(lastErrorMessage())
        }
    }

    private func reconstructionSidecarHasNoUserRows() throws -> Bool {
        for tableName in try tableNames() {
            let quotedTableName = "\""
                + tableName.replacingOccurrences(of: "\"", with: "\"\"")
                + "\""
            if try scalarInt("SELECT EXISTS(SELECT 1 FROM \(quotedTableName));") == 1 {
                return false
            }
        }
        return true
    }

    func workspace(id: Int64) throws -> WorkspaceRecord? {
        try first(
            """
            SELECT id, uuid, name, created_at, modified_at
            FROM workspaces
            WHERE id = ?;
            """,
            bindings: [.int64(id)],
            map: Self.workspaceRecord
        )
    }

    func workspaces() throws -> [WorkspaceRecord] {
        try query(
            """
            SELECT id, uuid, name, created_at, modified_at
            FROM workspaces
            ORDER BY id;
            """,
            map: Self.workspaceRecord
        )
    }

    func updateWorkspaceName(id: Int64, name: String, modifiedAt: Date = Date()) throws {
        try run(
            """
            UPDATE workspaces
            SET name = ?, modified_at = ?
            WHERE id = ?;
            """,
            bindings: [
                .text(name),
                .text(Self.string(from: modifiedAt)),
                .int64(id)
            ]
        )
    }

    func deleteWorkspace(id: Int64) throws {
        try run("DELETE FROM workspaces WHERE id = ?;", bindings: [.int64(id)])
    }

    @discardableResult
    func insertBinary(_ record: BinaryRecord) throws -> BinaryRecord {
        try run(
            """
            INSERT INTO binaries (
              uuid,
              workspace_id,
              name,
              path,
              original_path_bookmark,
              kind,
              architecture,
              file_hash,
              file_size,
              hex_bytes,
              is_bundle,
              image_slot,
              selected_slice_index,
              analysis_input_fingerprint_json,
              binary_metadata_json,
              elf_archive_member_identity_json,
              macho_selected_slice_fact_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(record.uuid.uuidString),
                .int64(record.workspaceID),
                .text(record.name),
                .text(record.path),
                record.originalPathBookmark.map(Binding.blob) ?? .null,
                .text(record.kind),
                .text(record.architecture),
                .text(record.fileHash),
                .int64(record.fileSize),
                record.hexBytes.map(Binding.blob) ?? .null,
                .bool(record.isBundle),
                .int64(Int64(record.imageSlot)),
                record.selectedSliceIndex.map { .int64(Int64($0)) } ?? .null,
                record.analysisInputFingerprintJSON.map(Binding.text) ?? .null,
                try Self.encodeBinaryMetadataJSON(record.metadata).map(Binding.text) ?? .null,
                try Self.encodeELFArchiveMemberIdentityJSON(record.elfArchiveMemberIdentity)
                    .map(Binding.text) ?? .null,
                try Self.encodeMachOSelectedSliceFactJSON(record.machOSelectedSliceFact)
                    .map(Binding.text) ?? .null
            ]
        )

        var inserted = record
        inserted.id = sqlite3_last_insert_rowid(try requireConnection())
        return inserted
    }

    func binaries(workspaceID: Int64) throws -> [BinaryRecord] {
        try query(
            """
            SELECT id, uuid, workspace_id, name, path, original_path_bookmark, kind, architecture,
                   file_hash, file_size, hex_bytes, is_bundle, image_slot, selected_slice_index,
                   analysis_input_fingerprint_json, binary_metadata_json,
                   elf_archive_member_identity_json, macho_selected_slice_fact_json
            FROM binaries
            WHERE workspace_id = ?
            ORDER BY image_slot, id;
            """,
            bindings: [.int64(workspaceID)],
            map: Self.binaryRecord
        )
    }

    @discardableResult
    func insertFunction(_ record: FunctionRecord) throws -> FunctionRecord {
        try run(
            """
            INSERT INTO functions (uuid, binary_id, start_address, end_address, symbol_name, demangled_name, confidence,
                                   no_return_provenance)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(record.uuid.uuidString),
                .int64(record.binaryID),
                .address(record.startAddress),
                record.endAddress.map(Binding.address) ?? .null,
                record.symbolName.map(Binding.text) ?? .null,
                record.demangledName.map(Binding.text) ?? .null,
                .double(record.confidence),
                record.noReturnProvenance.map(Binding.text) ?? .null
            ]
        )

        var inserted = record
        inserted.id = sqlite3_last_insert_rowid(try requireConnection())
        return inserted
    }

    func functions(binaryID: Int64) throws -> [FunctionRecord] {
        try query(
            """
            SELECT id, uuid, binary_id, start_address, end_address, symbol_name, demangled_name, confidence,
                   no_return_provenance
            FROM functions
            WHERE binary_id = ?
            ORDER BY start_address, id;
            """,
            bindings: [.int64(binaryID)],
            map: Self.functionRecord
        )
    }

    @discardableResult
    func insertSymbol(_ record: SymbolRecord) throws -> SymbolRecord {
        try run(
            """
            INSERT INTO symbols (
              uuid, binary_id, name, address, kind, library_name, raw_linkage_name
            )
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(record.uuid.uuidString),
                .int64(record.binaryID),
                .text(record.name),
                record.address.map(Binding.address) ?? .null,
                .text(record.kind),
                record.libraryName.map(Binding.text) ?? .null,
                record.rawLinkageName.map(Binding.text) ?? .null
            ]
        )

        var inserted = record
        inserted.id = sqlite3_last_insert_rowid(try requireConnection())
        return inserted
    }

    func symbols(binaryID: Int64) throws -> [SymbolRecord] {
        try query(
            """
            SELECT id, uuid, binary_id, name, address, kind, library_name, raw_linkage_name
            FROM symbols
            WHERE binary_id = ?
            ORDER BY id;
            """,
            bindings: [.int64(binaryID)],
            map: Self.symbolRecord
        )
    }

    @discardableResult
    func insertImport(_ record: ImportRecord) throws -> ImportRecord {
        try run(
            """
            INSERT INTO imports (uuid, binary_id, name, library_name, library_ordinal)
            VALUES (?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(record.uuid.uuidString),
                .int64(record.binaryID),
                .text(record.name),
                record.libraryName.map(Binding.text) ?? .null,
                record.libraryOrdinal.map { Binding.int64(Int64($0)) } ?? .null
            ]
        )

        var inserted = record
        inserted.id = sqlite3_last_insert_rowid(try requireConnection())
        return inserted
    }

    func imports(binaryID: Int64) throws -> [ImportRecord] {
        try query(
            """
            SELECT id, uuid, binary_id, name, library_name, library_ordinal
            FROM imports
            WHERE binary_id = ?
            ORDER BY id;
            """,
            bindings: [.int64(binaryID)],
            map: Self.importRecord
        )
    }

    @discardableResult
    func insertIndirectSymbol(_ record: IndirectSymbolRecord) throws -> IndirectSymbolRecord {
        try run(
            """
            INSERT INTO indirect_symbols (
              uuid,
              binary_id,
              kind,
              source_section,
              address,
              entry_size,
              table_index,
              raw_symbol_index,
              symbol_index,
              symbol_name,
              library_ordinal,
              library_name,
              is_local,
              is_absolute
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(record.uuid.uuidString),
                .int64(record.binaryID),
                .text(record.kind),
                .text(record.sourceSection),
                .address(record.address),
                .int64(Int64(record.entrySize)),
                .int64(Int64(record.tableIndex)),
                .int64(Int64(record.rawSymbolIndex)),
                record.symbolIndex.map { Binding.int64(Int64($0)) } ?? .null,
                record.symbolName.map(Binding.text) ?? .null,
                record.libraryOrdinal.map { Binding.int64(Int64($0)) } ?? .null,
                record.libraryName.map(Binding.text) ?? .null,
                .bool(record.isLocal),
                .bool(record.isAbsolute)
            ]
        )

        var inserted = record
        inserted.id = sqlite3_last_insert_rowid(try requireConnection())
        return inserted
    }

    func indirectSymbols(binaryID: Int64) throws -> [IndirectSymbolRecord] {
        try query(
            """
            SELECT id, uuid, binary_id, kind, source_section, address, entry_size,
                   table_index, raw_symbol_index, symbol_index, symbol_name,
                   library_ordinal, library_name, is_local, is_absolute
            FROM indirect_symbols
            WHERE binary_id = ?
            ORDER BY address, table_index, id;
            """,
            bindings: [.int64(binaryID)],
            map: Self.indirectSymbolRecord
        )
    }

    @discardableResult
    func insertExport(_ record: ExportRecord) throws -> ExportRecord {
        try run(
            """
            INSERT INTO exports (uuid, binary_id, name, address, source, terminal_flags)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(record.uuid.uuidString),
                .int64(record.binaryID),
                .text(record.name),
                record.address.map(Binding.address) ?? .null,
                .text(record.source),
                record.terminalFlags.map(Binding.address) ?? .null
            ]
        )

        var inserted = record
        inserted.id = sqlite3_last_insert_rowid(try requireConnection())
        return inserted
    }

    func exports(binaryID: Int64) throws -> [ExportRecord] {
        try query(
            """
            SELECT id, uuid, binary_id, name, address, source, terminal_flags
            FROM exports
            WHERE binary_id = ?
            ORDER BY id;
            """,
            bindings: [.int64(binaryID)],
            map: Self.exportRecord
        )
    }

    /// WS-5: the persisted dSYM source lines for a binary, address-ordered (as `sourceLine(at:)`
    /// expects for its binary search).
    func sourceLines(binaryID: Int64) throws -> [SourceLineEntry] {
        let decoded: [SourceLineEntry] = try query(
            """
            SELECT address, file, line, column, is_end_sequence,
                   debug_artifact_uuid, debug_artifact_macho_sha256,
                   debug_artifact_macho_byte_count, line_program_unit_offset,
                   file_table_index, table_path_kind, table_path
            FROM source_lines
            WHERE binary_id = ?
            ORDER BY address, id;
            """,
            bindings: [.int64(binaryID)],
            map: { statement in
                let tablePathKind = Self.optionalExactTextColumn(statement, 10)
                let tablePathValue = Self.optionalExactTextColumn(statement, 11)
                let tablePath: DebuggerCanonicalSourceTablePath?
                switch (tablePathKind, tablePathValue) {
                case ("absoluteUTF8"?, let value?):
                    tablePath = .absoluteUTF8(value)
                case ("compilationDirectoryRelativeUTF8"?, let value?):
                    tablePath = .compilationDirectoryRelativeUTF8(value)
                default:
                    tablePath = nil
                }
                return SourceLineEntry(
                    address: try Self.addressColumn(
                        statement, 0, field: "source_lines.address"
                    ),
                    file: sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : try Self.textColumn(statement, 1),
                    line: Int(sqlite3_column_int64(statement, 2)),
                    column: Int(sqlite3_column_int64(statement, 3)),
                    endSequence: sqlite3_column_int64(statement, 4) != 0,
                    debugArtifactUUID: Self.optionalExactTextColumn(statement, 5)
                        .flatMap(UUID.init(uuidString:)),
                    debugArtifactMachOSHA256: Self.optionalExactTextColumn(statement, 6),
                    debugArtifactMachOByteCount: try Self.optionalNonnegativeUInt64Column(
                        statement, 7, field: "source_lines.debug_artifact_macho_byte_count"
                    ),
                    lineProgramUnitOffset: try Self.optionalNonnegativeUInt64Column(
                        statement, 8, field: "source_lines.line_program_unit_offset"
                    ),
                    fileTableIndex: try Self.optionalNonnegativeUInt32Column(
                        statement, 9, field: "source_lines.file_table_index"
                    ),
                    tablePath: tablePath
                )
            }
        )
        // SQLite orders the signed Int64 storage representation, while source-line addresses
        // are decoded as UInt64. Carry the deterministic SQL `id` order through the in-memory
        // reorder so equal-address rows retain their persisted insertion order without relying
        // on an undocumented stable-sort property.
        return decoded.enumerated().sorted { lhs, rhs in
            if lhs.element.address != rhs.element.address {
                return lhs.element.address < rhs.element.address
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    @discardableResult
    func insertInstruction(_ record: InstructionRecord) throws -> InstructionRecord {
        let structuredOperandsJSON = try record.structuredOperands.map { try InstructionOperandsStorageCodec.encode($0) }
        try run(
            """
            INSERT INTO instructions (function_id, address, bytes, mnemonic, operands, has_breakpoint, comment, ir_json, structured_operands_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .int64(record.functionID),
                .address(record.address),
                .blob(record.bytes),
                .text(record.mnemonic),
                .text(record.operands),
                .bool(record.hasBreakpoint),
                record.comment.map(Binding.text) ?? .null,
                record.irJSON.map(Binding.blob) ?? .null,
                structuredOperandsJSON.map(Binding.blob) ?? .null
            ]
        )

        var inserted = record
        inserted.id = sqlite3_last_insert_rowid(try requireConnection())
        return inserted
    }

    func instructions(functionID: Int64) throws -> [InstructionRecord] {
        try query(
            """
            SELECT id, function_id, address, bytes, mnemonic, operands, has_breakpoint, comment, ir_json,
                   structured_operands_json, length(structured_operands_json)
            FROM instructions
            WHERE function_id = ?
            ORDER BY address, id;
            """,
            bindings: [.int64(functionID)],
            map: Self.instructionRecord
        )
    }

    @discardableResult
    func insertBasicBlock(_ record: BasicBlockRecord) throws -> BasicBlockRecord {
        try run(
            """
            INSERT INTO basic_blocks (uuid, function_id, start_address, end_address, instruction_count)
            VALUES (?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(record.uuid.uuidString),
                .int64(record.functionID),
                .address(record.startAddress),
                .address(record.endAddress),
                .int64(Int64(record.instructionCount))
            ]
        )

        var inserted = record
        inserted.id = sqlite3_last_insert_rowid(try requireConnection())
        return inserted
    }

    func basicBlocks(functionID: Int64) throws -> [BasicBlockRecord] {
        try query(
            """
            SELECT id, uuid, function_id, start_address, end_address, instruction_count
            FROM basic_blocks
            WHERE function_id = ?
            ORDER BY start_address, id;
            """,
            bindings: [.int64(functionID)],
            map: Self.basicBlockRecord
        )
    }

    @discardableResult
    func insertXRef(_ record: XRefRecord) throws -> XRefRecord {
        try run(
            """
            INSERT INTO xrefs (uuid, binary_id, from_address, to_address, kind)
            VALUES (?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(record.uuid.uuidString),
                .int64(record.binaryID),
                .address(record.fromAddress),
                .address(record.toAddress),
                .text(record.kind)
            ]
        )

        var inserted = record
        inserted.id = sqlite3_last_insert_rowid(try requireConnection())
        return inserted
    }

    func xrefs(binaryID: Int64) throws -> [XRefRecord] {
        try query(
            """
            SELECT id, uuid, binary_id, from_address, to_address, kind
            FROM xrefs
            WHERE binary_id = ?
            ORDER BY from_address, to_address, id;
            """,
            bindings: [.int64(binaryID)],
            map: Self.xrefRecord
        )
    }

    @discardableResult
    func insertAddressOverride(_ record: AddressOverrideRecord) throws -> AddressOverrideRecord {
        try run(
            """
            INSERT INTO address_overrides (workspace_id, address, custom_name, custom_comment, tag, color_tag, is_data, signature_json, applied_type_name, switch_hint_json, operand_format, created_at, modified_at, mark_as_procedure, data_shape_json, is_undefined, patch_json, register_names_json, local_label, image_slot, appended_cave_json, stack_locals_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .int64(record.workspaceID),
                .address(record.address),
                record.customName.map(Binding.text) ?? .null,
                record.customComment.map(Binding.text) ?? .null,
                record.tag.map(Binding.text) ?? .null,
                record.colorTag.map(Binding.text) ?? .null,
                .int64(record.isData ? 1 : 0),
                record.signatureJSON.map(Binding.text) ?? .null,
                record.appliedTypeName.map(Binding.text) ?? .null,
                record.switchHintJSON.map(Binding.text) ?? .null,
                record.operandFormat.map(Binding.text) ?? .null,
                .text(Self.string(from: record.createdAt)),
                .text(Self.string(from: record.modifiedAt)),
                .int64(record.markAsProcedure ? 1 : 0),
                record.dataShapeJSON.map(Binding.text) ?? .null,
                .int64(record.isUndefined ? 1 : 0),
                record.patchJSON.map(Binding.text) ?? .null,
                record.registerNamesJSON.map(Binding.text) ?? .null,
                record.localLabel.map(Binding.text) ?? .null,
                .int64(Int64(record.imageSlot)),
                record.appendedCaveJSON.map(Binding.text) ?? .null,
                record.stackLocalsJSON.map(Binding.text) ?? .null
            ]
        )

        var inserted = record
        inserted.id = sqlite3_last_insert_rowid(try requireConnection())
        return inserted
    }

    func addressOverrides(workspaceID: Int64) throws -> [AddressOverrideRecord] {
        try query(
            """
            SELECT id, workspace_id, address, custom_name, custom_comment, tag, color_tag, is_data, signature_json, applied_type_name, switch_hint_json, operand_format, created_at, modified_at, mark_as_procedure, data_shape_json, is_undefined, patch_json, register_names_json, local_label, image_slot, appended_cave_json, stack_locals_json
            FROM address_overrides
            WHERE workspace_id = ?
            ORDER BY image_slot, address, id;
            """,
            bindings: [.int64(workspaceID)],
            map: Self.addressOverrideRecord
        )
    }

    @discardableResult
    func insertManualXRef(_ record: ManualXRefRecord) throws -> ManualXRefRecord {
        try run(
            """
            INSERT OR REPLACE INTO manual_xrefs (id, workspace_id, from_address, to_address, kind, is_suppression, created_at, modified_at, image_slot)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(record.id.uuidString),
                .int64(record.workspaceID),
                .address(record.fromAddress),
                .address(record.toAddress),
                .text(record.kind),
                .int64(record.isSuppression ? 1 : 0),
                .text(Self.string(from: record.createdAt)),
                .text(Self.string(from: record.modifiedAt)),
                .int64(Int64(record.imageSlot))
            ]
        )
        return record
    }

    func manualXRefs(workspaceID: Int64) throws -> [ManualXRefRecord] {
        try query(
            """
            SELECT id, workspace_id, from_address, to_address, kind, is_suppression, created_at, modified_at, image_slot
            FROM manual_xrefs
            WHERE workspace_id = ?
            ORDER BY image_slot, from_address, to_address, kind, id;
            """,
            bindings: [.int64(workspaceID)],
            map: Self.manualXRefRecord
        )
    }

    @discardableResult
    func insertBookmark(_ record: BookmarkRecord) throws -> BookmarkRecord {
        try run(
            """
            INSERT OR REPLACE INTO bookmarks (id, workspace_id, address, name, created_at, modified_at, image_slot)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(record.id.uuidString),
                .int64(record.workspaceID),
                .address(record.address),
                .text(record.name),
                .text(Self.string(from: record.createdAt)),
                .text(Self.string(from: record.modifiedAt)),
                .int64(Int64(record.imageSlot))
            ]
        )
        return record
    }

    func bookmarks(workspaceID: Int64) throws -> [BookmarkRecord] {
        try query(
            """
            SELECT id, workspace_id, address, name, created_at, modified_at, image_slot
            FROM bookmarks
            WHERE workspace_id = ?
            ORDER BY image_slot, address, id;
            """,
            bindings: [.int64(workspaceID)],
            map: Self.bookmarkRecord
        )
    }

    @discardableResult
    func insertSegmentOverride(_ record: SegmentOverrideRecord) throws -> SegmentOverrideRecord {
        try run(
            """
            INSERT OR REPLACE INTO segment_overrides (id, workspace_id, original_name, display_name, rebase_delta, created_at, modified_at, image_slot)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(record.id.uuidString),
                .int64(record.workspaceID),
                .text(record.originalName),
                record.displayName.map(Binding.text) ?? .null,
                .int64(record.rebaseDelta),
                .text(Self.string(from: record.createdAt)),
                .text(Self.string(from: record.modifiedAt)),
                .int64(Int64(record.imageSlot))
            ]
        )
        return record
    }

    func segmentOverrides(workspaceID: Int64) throws -> [SegmentOverrideRecord] {
        try query(
            """
            SELECT id, workspace_id, original_name, display_name, rebase_delta, created_at, modified_at, image_slot
            FROM segment_overrides
            WHERE workspace_id = ?
            ORDER BY image_slot, original_name, id;
            """,
            bindings: [.int64(workspaceID)],
            map: Self.segmentOverrideRecord
        )
    }

    func insertTypeDefinition(_ record: TypeDefinitionRecord) throws {
        // OR REPLACE: the authoring layer enforces unique names, but a hand-edited or
        // legacy .mscope could still carry two same-named types. Last-writer-wins here
        // keeps a stray duplicate from aborting the whole snapshot-write transaction.
        try run(
            """
            INSERT OR REPLACE INTO type_definitions (
              id, workspace_id, kind, name, fields_json, layout_rules_json, created_at, modified_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(record.id.uuidString),
                .int64(record.workspaceID),
                .text(record.kind),
                .text(record.name),
                .text(record.fieldsJSON),
                record.layoutRulesJSON.map(Binding.text) ?? .null,
                .text(Self.string(from: record.createdAt)),
                .text(Self.string(from: record.modifiedAt))
            ]
        )
    }

    func typeDefinitions(workspaceID: Int64) throws -> [TypeDefinitionRecord] {
        try query(
            """
            SELECT id, workspace_id, kind, name, fields_json, layout_rules_json, created_at, modified_at
            FROM type_definitions
            WHERE workspace_id = ?
            ORDER BY name, id;
            """,
            bindings: [.int64(workspaceID)],
            map: Self.typeDefinitionRecord
        )
    }

    private func typeCatalogLoadDiagnostics(
        workspaceID: Int64
    ) throws -> [WorkspaceTypeCatalogLoadDiagnostic] {
        try typeDefinitions(workspaceID: workspaceID).compactMap { record in
            guard record.layoutRulesJSON == nil else { return nil }
            return .legacyDefaultLayoutSubstitution(typeName: record.name)
        }
    }

    @discardableResult
    func upsertPhase2AssistantSessionRecord(
        _ record: Phase2AssistantSessionPersistenceRecord
    ) throws -> Phase2AssistantSessionPersistenceRecord {
        guard record.recordSchemaVersion == Phase2AssistantSessionPersistenceRecord.schemaVersion,
              record.sequence > 0,
              record.turnSequence > 0,
              (0...64).contains(record.providerToolCount),
              record.continuationCheckpoint == nil || record.continuationCheckpoint?.isStructurallyValid(
                  workspaceID: record.workspaceUUID,
                  conversationID: record.conversationID,
                  inferenceTurnID: record.inferenceTurnID,
                  turnSequence: record.turnSequence
              ) == true,
              record.contentSHA256 == Phase2AssistantSessionPersistenceRecord.contentSHA256(
                  id: record.id,
                  workspaceUUID: record.workspaceUUID,
                  documentID: record.documentID,
                  sequence: record.sequence,
                  conversationID: record.conversationID,
                  turnSequence: record.turnSequence,
                  inferenceTurnID: record.inferenceTurnID,
                  isLegacy: record.isLegacy,
                  intentID: record.intentID,
                  userGoal: record.userGoal,
                  status: record.status,
                  promptText: record.promptText,
                  answerText: record.answerText,
                  transcriptText: record.transcriptText,
                  contextDigest: record.contextDigest,
                  canonicalByteCount: record.canonicalByteCount,
                  providerToolCount: record.providerToolCount,
                  recordSchemaVersion: record.recordSchemaVersion,
                  createdAt: record.createdAt,
                  completedAt: record.completedAt,
                  continuationCheckpoint: record.continuationCheckpoint
        ) else {
            throw DatabaseError.invalidPhase2AssistantSessionRecord(record.id.uuidString)
        }
        if let checkpoint = record.continuationCheckpoint,
           try hasPhase2AssistantContinuationAuthorityCollision(
               excluding: record.id,
               checkpoint: checkpoint
           ) {
            throw DatabaseError.invalidPhase2AssistantSessionRecord(record.id.uuidString)
        }
        try run(
            """
            INSERT INTO phase2_assistant_session_records (
              id, workspace_id, workspace_uuid, document_id, sequence, conversation_id,
              turn_sequence, inference_turn_id, is_legacy, intent_id,
              user_goal, status, prompt_text, answer_text, transcript_text,
              context_digest, canonical_byte_count, provider_tool_count,
              continuation_checkpoint_json, shell_proposal_id, shell_execution_id,
              continuation_ordinal, continuation_request_id,
              record_schema_version, created_at, completed_at, content_sha256
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              workspace_id = excluded.workspace_id,
              workspace_uuid = excluded.workspace_uuid,
              document_id = excluded.document_id,
              sequence = excluded.sequence,
              conversation_id = excluded.conversation_id,
              turn_sequence = excluded.turn_sequence,
              inference_turn_id = excluded.inference_turn_id,
              is_legacy = excluded.is_legacy,
              intent_id = excluded.intent_id,
              user_goal = excluded.user_goal,
              status = excluded.status,
              prompt_text = excluded.prompt_text,
              answer_text = excluded.answer_text,
              transcript_text = excluded.transcript_text,
              context_digest = excluded.context_digest,
              canonical_byte_count = excluded.canonical_byte_count,
              provider_tool_count = excluded.provider_tool_count,
              continuation_checkpoint_json = excluded.continuation_checkpoint_json,
              shell_proposal_id = excluded.shell_proposal_id,
              shell_execution_id = excluded.shell_execution_id,
              continuation_ordinal = excluded.continuation_ordinal,
              continuation_request_id = excluded.continuation_request_id,
              record_schema_version = excluded.record_schema_version,
              created_at = excluded.created_at,
              completed_at = excluded.completed_at,
              content_sha256 = excluded.content_sha256;
            """,
            bindings: [
                .text(record.id.uuidString),
                .int64(record.workspaceID),
                .text(record.workspaceUUID.uuidString),
                .text(record.documentID.uuidString),
                .int64(Int64(record.sequence)),
                .text(record.conversationID.uuidString),
                .int64(Int64(record.turnSequence)),
                .text(record.inferenceTurnID.uuidString),
                .int64(record.isLegacy ? 1 : 0),
                .text(record.intentID),
                .text(record.userGoal),
                .text(record.status.rawValue),
                .text(record.promptText),
                record.answerText.map(Binding.text) ?? .null,
                .text(record.transcriptText),
                record.contextDigest.map(Binding.text) ?? .null,
                record.canonicalByteCount.map { .int64(Int64($0)) } ?? .null,
                .int64(Int64(record.providerToolCount)),
                record.continuationCheckpoint.map { .text($0.canonicalJSON) } ?? .null,
                record.continuationCheckpoint.map { .text($0.shellProposalID.uuidString) } ?? .null,
                record.continuationCheckpoint?.shellExecutionID.map { .text($0.uuidString) } ?? .null,
                record.continuationCheckpoint?.continuationOrdinal.map { .int64(Int64($0)) } ?? .null,
                record.continuationCheckpoint?.continuationRequestID.map { .text($0.uuidString) } ?? .null,
                .int64(Int64(record.recordSchemaVersion)),
                .text(Self.string(from: record.createdAt)),
                record.completedAt.map { Binding.text(Self.string(from: $0)) } ?? .null,
                .text(record.contentSHA256),
            ]
        )
        return record
    }

    private func hasPhase2AssistantContinuationAuthorityCollision(
        excluding recordID: UUID,
        checkpoint: Phase2AssistantContinuationCheckpointRecord
    ) throws -> Bool {
        let ids = [checkpoint.shellProposalID, checkpoint.shellExecutionID, checkpoint.continuationRequestID]
            .compactMap { $0?.uuidString }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let idBindings = ids.map(Binding.text)
        let collision = try first(
            """
            SELECT 1
            FROM phase2_assistant_session_records
            WHERE id != ?
              AND (
                shell_proposal_id IN (\(placeholders))
                OR shell_execution_id IN (\(placeholders))
                OR continuation_request_id IN (\(placeholders))
              )
            LIMIT 1;
            """,
            bindings: [.text(recordID.uuidString)] + idBindings + idBindings + idBindings,
            map: { _ in true }
        )
        return collision == true
    }

    func phase2AssistantSessionRecord(id: UUID) throws -> Phase2AssistantSessionPersistenceRecord? {
        try first(
            """
            SELECT id, workspace_id, workspace_uuid, document_id, sequence, conversation_id,
                   turn_sequence, inference_turn_id, is_legacy, intent_id,
                   user_goal, status, prompt_text, answer_text, transcript_text,
                   context_digest, canonical_byte_count, provider_tool_count,
                   continuation_checkpoint_json, shell_proposal_id, shell_execution_id,
                   continuation_ordinal, continuation_request_id,
                   record_schema_version, created_at, completed_at, content_sha256
            FROM phase2_assistant_session_records
            WHERE id = ?;
            """,
            bindings: [.text(id.uuidString)],
            map: Self.phase2AssistantSessionRecord
        )
    }

    func phase2AssistantSessionRecord(
        continuationRequestID: UUID
    ) throws -> Phase2AssistantSessionPersistenceRecord? {
        try first(
            """
            SELECT id, workspace_id, workspace_uuid, document_id, sequence, conversation_id,
                   turn_sequence, inference_turn_id, is_legacy, intent_id,
                   user_goal, status, prompt_text, answer_text, transcript_text,
                   context_digest, canonical_byte_count, provider_tool_count,
                   continuation_checkpoint_json, shell_proposal_id, shell_execution_id,
                   continuation_ordinal, continuation_request_id,
                   record_schema_version, created_at, completed_at, content_sha256
            FROM phase2_assistant_session_records
            WHERE continuation_request_id = ?;
            """,
            bindings: [.text(continuationRequestID.uuidString)],
            map: Self.phase2AssistantSessionRecord
        )
    }

    /// Atomic compare-and-transition gate for every durable continuation state change.
    /// The caller supplies a fully sealed replacement record; stale or duplicate transitions
    /// fail closed and never overwrite the winner.
    @discardableResult
    func transitionPhase2AssistantSessionRecord(
        id: UUID,
        expectedStatus: Phase2AssistantPersistedSessionStatus,
        expectedLogicalState: String? = nil,
        to replacement: Phase2AssistantSessionPersistenceRecord
    ) throws -> Bool {
        try transaction {
            guard replacement.id == id,
                  let current = try phase2AssistantSessionRecord(id: id),
                  current.status == expectedStatus,
                  expectedLogicalState == nil || current.continuationCheckpoint?.logicalState == expectedLogicalState else {
                return false
            }
            try upsertPhase2AssistantSessionRecord(replacement)
            return true
        }
    }

    /// Canonical assistant-session column list shared by the paged UI query and the
    /// unpaged persistence query so the two can never drift apart.
    private static let phase2AssistantSessionRecordColumnsSQL = """
        id, workspace_id, workspace_uuid, document_id, sequence, conversation_id,
        turn_sequence, inference_turn_id, is_legacy, intent_id,
        user_goal, status, prompt_text, answer_text, transcript_text,
        context_digest, canonical_byte_count, provider_tool_count,
        continuation_checkpoint_json, shell_proposal_id, shell_execution_id,
        continuation_ordinal, continuation_request_id,
        record_schema_version, created_at, completed_at, content_sha256
        """

    /// Paged read for UI surfaces. Persistence and package generation must use
    /// `allPhase2AssistantSessionRecords(workspaceID:)` instead — reading back
    /// through this paged default and then delete-reinserting on save silently
    /// destroyed history beyond the newest `limit` rows.
    func phase2AssistantSessionRecords(
        workspaceID: Int64,
        limit: Int = 50
    ) throws -> [Phase2AssistantSessionPersistenceRecord] {
        try query(
            """
            SELECT \(Self.phase2AssistantSessionRecordColumnsSQL)
            FROM phase2_assistant_session_records
            WHERE workspace_id = ?
            ORDER BY sequence DESC, created_at DESC, id
            LIMIT ?;
            """,
            bindings: [.int64(workspaceID), .int64(Int64(limit))],
            map: Self.phase2AssistantSessionRecord
        )
    }

    /// Unpaged persistence read: every assistant-session row for the workspace,
    /// intentionally with no `LIMIT` clause. `loadWorkspaceState` and
    /// `packageManifest` must see the complete history — the save path is
    /// delete-then-reinsert, so any cap here becomes silent permanent deletion
    /// on the next save. A future retention policy belongs at record creation,
    /// not in this query.
    func allPhase2AssistantSessionRecords(
        workspaceID: Int64
    ) throws -> [Phase2AssistantSessionPersistenceRecord] {
        try query(
            """
            SELECT \(Self.phase2AssistantSessionRecordColumnsSQL)
            FROM phase2_assistant_session_records
            WHERE workspace_id = ?
            ORDER BY sequence DESC, created_at DESC, id DESC;
            """,
            bindings: [.int64(workspaceID)],
            map: Self.phase2AssistantSessionRecord
        )
    }

    func nonterminalPhase2AssistantContinuationRecords(
        workspaceID: Int64,
        workspaceUUID: UUID,
        documentID: UUID
    ) throws -> [Phase2AssistantSessionPersistenceRecord] {
        let records = try query(
            """
            SELECT id, workspace_id, workspace_uuid, document_id, sequence, conversation_id,
                   turn_sequence, inference_turn_id, is_legacy, intent_id,
                   user_goal, status, prompt_text, answer_text, transcript_text,
                   context_digest, canonical_byte_count, provider_tool_count,
                   continuation_checkpoint_json, shell_proposal_id, shell_execution_id,
                   continuation_ordinal, continuation_request_id,
                   record_schema_version, created_at, completed_at, content_sha256
            FROM phase2_assistant_session_records
            WHERE workspace_id = ?
              AND workspace_uuid = ?
              AND document_id = ?
              AND status = ?
              AND continuation_checkpoint_json IS NOT NULL
            ORDER BY sequence ASC, created_at ASC, id;
            """,
            bindings: [
                .int64(workspaceID), .text(workspaceUUID.uuidString), .text(documentID.uuidString),
                .text(Phase2AssistantPersistedSessionStatus.outcomeUnknown.rawValue),
            ],
            map: Self.phase2AssistantSessionRecord
        )
        return records.filter { record in
            guard let rawState = record.continuationCheckpoint?.logicalState,
                  let state = Phase2AssistantShellContinuationState(rawValue: rawState) else {
                return true
            }
            return !state.isTerminal
        }
    }

    func deletePhase2AssistantSessionRecords(workspaceID: Int64) throws {
        try run(
            "DELETE FROM phase2_assistant_session_records WHERE workspace_id = ?;",
            bindings: [.int64(workspaceID)]
        )
    }

    func replacePhase2AssistantSessionRecords(
        workspaceID: Int64,
        records: [Phase2AssistantSessionPersistenceRecord]
    ) throws {
        try transaction {
            try deletePhase2AssistantSessionRecords(workspaceID: workspaceID)
            for record in records {
                try upsertPhase2AssistantSessionRecord(record)
            }
        }
    }

    @discardableResult
    func upsertPhase2RuntimeAuthorityRecord(
        _ record: Phase2RuntimeAuthorityPersistenceRecord
    ) throws -> Phase2RuntimeAuthorityPersistenceRecord {
        guard record.authorityRecord.isStructurallyValid else {
            throw DatabaseError.invalidPhase2RuntimeAuthority("structural")
        }
        try run(
            """
            INSERT INTO phase2_runtime_authority_records (
              id, workspace_id, workspace_uuid, document_id, session_id, surfaces_json,
              terminal_backend, pty_reuse_policy, debugger_authority_policy_json,
              provider_visible_shell_execution_enabled, record_schema_version, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              workspace_id = excluded.workspace_id,
              workspace_uuid = excluded.workspace_uuid,
              document_id = excluded.document_id,
              session_id = excluded.session_id,
              surfaces_json = excluded.surfaces_json,
              terminal_backend = excluded.terminal_backend,
              pty_reuse_policy = excluded.pty_reuse_policy,
              debugger_authority_policy_json = excluded.debugger_authority_policy_json,
              provider_visible_shell_execution_enabled = excluded.provider_visible_shell_execution_enabled,
              record_schema_version = excluded.record_schema_version,
              created_at = excluded.created_at;
            """,
            bindings: [
                .text(record.id.uuidString),
                .int64(record.workspaceID),
                .text(record.workspaceUUID.uuidString),
                .text(record.documentID.uuidString),
                .text(record.sessionID.uuidString),
                .text(try Self.encodeRuntimeAuthoritySurfaces(record.surfaces)),
                .text(record.terminalBackend.rawValue),
                .text(record.ptyReusePolicy.rawValue),
                .text(try Self.encodeDebuggerAuthorityPolicy(record.debuggerAuthorityPolicy)),
                .bool(record.providerVisibleShellExecutionEnabled),
                .int64(Int64(record.recordSchemaVersion)),
                .text(Self.string(from: record.createdAt)),
            ]
        )
        return record
    }

    func phase2RuntimeAuthorityRecords(
        workspaceID: Int64,
        limit: Int = 100
    ) throws -> [Phase2RuntimeAuthorityPersistenceRecord] {
        try query(
            """
            SELECT id, workspace_id, workspace_uuid, document_id, session_id, surfaces_json,
                   terminal_backend, pty_reuse_policy, debugger_authority_policy_json,
                   provider_visible_shell_execution_enabled, record_schema_version, created_at
            FROM phase2_runtime_authority_records
            WHERE workspace_id = ?
            ORDER BY created_at DESC, id
            LIMIT ?;
            """,
            bindings: [.int64(workspaceID), .int64(Int64(limit))],
            map: Self.phase2RuntimeAuthorityRecord
        )
    }

    func deletePhase2RuntimeAuthorityRecords(workspaceID: Int64) throws {
        try run(
            "DELETE FROM phase2_runtime_authority_records WHERE workspace_id = ?;",
            bindings: [.int64(workspaceID)]
        )
    }

    func replacePhase2RuntimeAuthorityRecords(
        workspaceID: Int64,
        records: [Phase2RuntimeAuthorityPersistenceRecord]
    ) throws {
        try transaction {
            try deletePhase2RuntimeAuthorityRecords(workspaceID: workspaceID)
            for record in records {
                try upsertPhase2RuntimeAuthorityRecord(record)
            }
        }
    }

    @discardableResult
    func upsertPhase2ShellSessionRecord(
        _ record: Phase2ShellSessionPersistenceRecord
    ) throws -> Phase2ShellSessionPersistenceRecord {
        guard record.recordSchemaVersion == Phase2ShellSessionPersistenceRecord.schemaVersion else {
            throw DatabaseError.invalidPhase2RuntimeAuthority("shell-session-schema")
        }
        try run(
            """
            INSERT INTO phase2_shell_sessions (
              workspace_id, workspace_uuid, document_id, shell_session_json,
              record_schema_version, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(workspace_id) DO UPDATE SET
              workspace_uuid = excluded.workspace_uuid,
              document_id = excluded.document_id,
              shell_session_json = excluded.shell_session_json,
              record_schema_version = excluded.record_schema_version,
              updated_at = excluded.updated_at;
            """,
            bindings: [
                .int64(record.workspaceID),
                .text(record.workspaceUUID.uuidString),
                .text(record.documentID.uuidString),
                .text(try Self.encodePhase2ShellSessionJSON(record.shellSession)),
                .int64(Int64(record.recordSchemaVersion)),
                .text(Self.string(from: record.updatedAt)),
            ]
        )
        return record
    }

    func phase2ShellSessionRecord(
        workspaceID: Int64
    ) throws -> Phase2ShellSessionPersistenceRecord? {
        try first(
            """
            SELECT workspace_id, workspace_uuid, document_id, shell_session_json,
                   record_schema_version, updated_at
            FROM phase2_shell_sessions
            WHERE workspace_id = ?;
            """,
            bindings: [.int64(workspaceID)],
            map: Self.phase2ShellSessionRecord
        )
    }

    func deletePhase2ShellSessionRecord(workspaceID: Int64) throws {
        try run(
            "DELETE FROM phase2_shell_sessions WHERE workspace_id = ?;",
            bindings: [.int64(workspaceID)]
        )
    }

    func replacePhase2ShellSessionRecord(
        workspaceID: Int64,
        record: Phase2ShellSessionPersistenceRecord?
    ) throws {
        try transaction {
            try deletePhase2ShellSessionRecord(workspaceID: workspaceID)
            if let record {
                try upsertPhase2ShellSessionRecord(record)
            }
        }
    }

    @discardableResult
    func insertControlFlowEdge(_ record: ControlFlowEdgeRecord) throws -> ControlFlowEdgeRecord {
        try run(
            """
            INSERT INTO control_flow_edges (uuid, binary_id, from_address, to_address, kind)
            VALUES (?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(record.uuid.uuidString),
                .int64(record.binaryID),
                .address(record.fromAddress),
                .address(record.toAddress),
                .text(record.kind)
            ]
        )

        var inserted = record
        inserted.id = sqlite3_last_insert_rowid(try requireConnection())
        return inserted
    }

    func controlFlowEdges(binaryID: Int64) throws -> [ControlFlowEdgeRecord] {
        try query(
            """
            SELECT id, uuid, binary_id, from_address, to_address, kind
            FROM control_flow_edges
            WHERE binary_id = ?
            ORDER BY from_address, to_address, id;
            """,
            bindings: [.int64(binaryID)],
            map: Self.controlFlowEdgeRecord
        )
    }

    @discardableResult
    func upsertWorkspaceSession(_ record: WorkspaceSessionRecord) throws -> WorkspaceSessionRecord {
        try run(
            """
            INSERT INTO workspace_sessions (
              workspace_id,
              selected_sidebar_item_id,
              selected_address,
              selected_tool,
              editor_mode,
              is_inspector_presented,
              sidebar_search_text,
              updated_at,
              focused_image_slot
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(workspace_id) DO UPDATE SET
              selected_sidebar_item_id = excluded.selected_sidebar_item_id,
              selected_address = excluded.selected_address,
              selected_tool = excluded.selected_tool,
              editor_mode = excluded.editor_mode,
              is_inspector_presented = excluded.is_inspector_presented,
              sidebar_search_text = excluded.sidebar_search_text,
              updated_at = excluded.updated_at,
              focused_image_slot = excluded.focused_image_slot;
            """,
            bindings: [
                .int64(record.workspaceID),
                record.selectedSidebarItemID.map(Binding.text) ?? .null,
                record.selectedAddress.map(Binding.address) ?? .null,
                .text(record.selectedTool.rawValue),
                .text(record.editorMode.rawValue),
                .bool(record.isInspectorPresented),
                .text(record.sidebarSearchText),
                .text(Self.string(from: record.updatedAt)),
                .int64(Int64(record.focusedImageSlot.rawValue))
            ]
        )

        return record
    }

    func workspaceSession(workspaceID: Int64) throws -> WorkspaceSessionRecord? {
        try first(
            """
            SELECT workspace_id, selected_sidebar_item_id, selected_address, selected_tool,
                   editor_mode, is_inspector_presented, sidebar_search_text, updated_at,
                   focused_image_slot
            FROM workspace_sessions
            WHERE workspace_id = ?;
            """,
            bindings: [.int64(workspaceID)],
            map: Self.workspaceSessionRecord
        )
    }

    @discardableResult
    func upsertWorkspaceDocument(_ record: WorkspaceDocumentRecord) throws -> WorkspaceDocumentRecord {
        try run(
            """
            INSERT INTO workspace_documents (
              workspace_id,
              document_id,
              package_path,
              last_opened_at,
              last_saved_at,
              is_dirty,
              file_version_identifier,
              conflict_detected_at,
              conflict_reason,
              input_copying_decision,
              bookmark_resolution_decision,
              bookmark_resolution_error,
              recent_document_state,
              recent_document_state_updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(workspace_id) DO UPDATE SET
              document_id = excluded.document_id,
              package_path = excluded.package_path,
              last_opened_at = excluded.last_opened_at,
              last_saved_at = excluded.last_saved_at,
              is_dirty = excluded.is_dirty,
              file_version_identifier = excluded.file_version_identifier,
              conflict_detected_at = excluded.conflict_detected_at,
              conflict_reason = excluded.conflict_reason,
              input_copying_decision = excluded.input_copying_decision,
              bookmark_resolution_decision = excluded.bookmark_resolution_decision,
              bookmark_resolution_error = excluded.bookmark_resolution_error,
              recent_document_state = excluded.recent_document_state,
              recent_document_state_updated_at = excluded.recent_document_state_updated_at;
            """,
            bindings: [
                .int64(record.workspaceID),
                .text(record.documentID.uuidString),
                .text(record.packagePath),
                .text(Self.string(from: record.lastOpenedAt)),
                record.lastSavedAt.map { Binding.text(Self.string(from: $0)) } ?? .null,
                .bool(record.isDirty),
                record.fileVersionIdentifier.map(Binding.text) ?? .null,
                record.conflictDetectedAt.map { Binding.text(Self.string(from: $0)) } ?? .null,
                record.conflictReason.map(Binding.text) ?? .null,
                .text(record.inputCopyingDecision.rawValue),
                .text(record.bookmarkResolutionDecision.rawValue),
                record.bookmarkResolutionError.map(Binding.text) ?? .null,
                .text(record.recentDocumentState.rawValue),
                record.recentDocumentStateUpdatedAt.map { Binding.text(Self.string(from: $0)) } ?? .null
            ]
        )

        return record
    }

    func workspaceDocument(workspaceID: Int64) throws -> WorkspaceDocumentRecord? {
        try first(
            """
            SELECT workspace_id, document_id, package_path, last_opened_at, last_saved_at,
                   is_dirty, file_version_identifier, conflict_detected_at, conflict_reason,
                   input_copying_decision, bookmark_resolution_decision, bookmark_resolution_error,
                   recent_document_state, recent_document_state_updated_at
            FROM workspace_documents
            WHERE workspace_id = ?;
            """,
            bindings: [.int64(workspaceID)],
            map: Self.workspaceDocumentRecord
        )
    }

    func workspaceDocument(packageURL: URL) throws -> WorkspaceDocumentRecord? {
        try first(
            """
            SELECT workspace_id, document_id, package_path, last_opened_at, last_saved_at,
                   is_dirty, file_version_identifier, conflict_detected_at, conflict_reason,
                   input_copying_decision, bookmark_resolution_decision, bookmark_resolution_error,
                   recent_document_state, recent_document_state_updated_at
            FROM workspace_documents
            WHERE package_path = ?;
            """,
            bindings: [.text(try Self.packagePath(from: packageURL))],
            map: Self.workspaceDocumentRecord
        )
    }

    func workspaceDocumentMetadata(workspaceID: Int64) throws -> WorkspaceDocumentMetadata? {
        guard let document = try workspaceDocument(workspaceID: workspaceID),
              let workspace = try workspace(id: workspaceID)
        else {
            return nil
        }
        return WorkspaceDocumentMetadata(workspace: workspace, document: document)
    }

    func workspaceDocumentMetadata(packageURL: URL) throws -> WorkspaceDocumentMetadata? {
        guard let document = try workspaceDocument(packageURL: packageURL),
              let workspace = try workspace(id: document.workspaceID)
        else {
            return nil
        }
        return WorkspaceDocumentMetadata(workspace: workspace, document: document)
    }

    func workspaceDocuments() throws -> [WorkspaceDocumentRecord] {
        try query(
            """
            SELECT workspace_id, document_id, package_path, last_opened_at, last_saved_at,
                   is_dirty, file_version_identifier, conflict_detected_at, conflict_reason,
                   input_copying_decision, bookmark_resolution_decision, bookmark_resolution_error,
                   recent_document_state, recent_document_state_updated_at
            FROM workspace_documents
            ORDER BY last_opened_at DESC, workspace_id DESC;
            """,
            map: Self.workspaceDocumentRecord
        )
    }

    func recentWorkspaceDocuments(limit: Int) throws -> [WorkspaceDocumentRecord] {
        guard limit > 0 else { return [] }

        return try query(
            """
            SELECT workspace_id, document_id, package_path, last_opened_at, last_saved_at,
                   is_dirty, file_version_identifier, conflict_detected_at, conflict_reason,
                   input_copying_decision, bookmark_resolution_decision, bookmark_resolution_error,
                   recent_document_state, recent_document_state_updated_at
            FROM workspace_documents
            ORDER BY last_opened_at DESC, workspace_id DESC
            LIMIT ?;
            """,
            bindings: [.int64(Int64(limit))],
            map: Self.workspaceDocumentRecord
        )
    }

    func recentWorkspaceDocumentMetadata(limit: Int) throws -> [WorkspaceDocumentMetadata] {
        let documents = try recentWorkspaceDocuments(limit: limit)
        return try documents.compactMap { document in
            guard let workspace = try workspace(id: document.workspaceID) else {
                return nil
            }
            return WorkspaceDocumentMetadata(workspace: workspace, document: document)
        }
    }

    @discardableResult
    func markWorkspaceDocumentDirty(
        workspaceID: Int64,
        conflictDetectedAt: Date? = nil,
        conflictReason: String? = nil
    ) throws -> WorkspaceDocumentRecord {
        try run(
            """
            UPDATE workspace_documents
            SET is_dirty = 1,
                conflict_detected_at = ?,
                conflict_reason = ?,
                recent_document_state = CASE
                    WHEN ? IS NOT NULL OR ? IS NOT NULL THEN ?
                    ELSE recent_document_state
                END,
                recent_document_state_updated_at = CASE
                    WHEN ? IS NOT NULL OR ? IS NOT NULL THEN ?
                    ELSE recent_document_state_updated_at
                END
            WHERE workspace_id = ?;
            """,
            bindings: [
                conflictDetectedAt.map { Binding.text(Self.string(from: $0)) } ?? .null,
                conflictReason.map(Binding.text) ?? .null,
                conflictDetectedAt.map { Binding.text(Self.string(from: $0)) } ?? .null,
                conflictReason.map(Binding.text) ?? .null,
                .text(WorkspaceRecentDocumentState.conflicted.rawValue),
                conflictDetectedAt.map { Binding.text(Self.string(from: $0)) } ?? .null,
                conflictReason.map(Binding.text) ?? .null,
                conflictDetectedAt.map { Binding.text(Self.string(from: $0)) } ?? .null,
                .int64(workspaceID)
            ]
        )

        guard let record = try workspaceDocument(workspaceID: workspaceID) else {
            throw DatabaseError.notFound
        }
        return record
    }

    @discardableResult
    func markWorkspaceDocumentOpened(
        workspaceID: Int64,
        packageURL: URL? = nil,
        openedAt: Date = Date(),
        recentDocumentState: WorkspaceRecentDocumentState = .available
    ) throws -> WorkspaceDocumentRecord {
        let canonicalPackagePath = try packageURL.map { try Self.packagePath(from: $0) }
        try run(
            """
            UPDATE workspace_documents
            SET package_path = COALESCE(?, package_path),
                last_opened_at = ?,
                recent_document_state = ?,
                recent_document_state_updated_at = ?
            WHERE workspace_id = ?;
            """,
            bindings: [
                canonicalPackagePath.map(Binding.text) ?? .null,
                .text(Self.string(from: openedAt)),
                .text(recentDocumentState.rawValue),
                .text(Self.string(from: openedAt)),
                .int64(workspaceID)
            ]
        )

        guard let record = try workspaceDocument(workspaceID: workspaceID) else {
            throw DatabaseError.notFound
        }
        return record
    }

    @discardableResult
    func markWorkspaceDocumentSaved(
        workspaceID: Int64,
        savedAt: Date,
        fileVersionIdentifier: String? = nil
    ) throws -> WorkspaceDocumentRecord {
        try run(
            """
            UPDATE workspace_documents
            SET last_saved_at = ?,
                is_dirty = 0,
                file_version_identifier = ?,
                conflict_detected_at = NULL,
                conflict_reason = NULL,
                bookmark_resolution_error = NULL,
                recent_document_state = ?,
                recent_document_state_updated_at = ?
            WHERE workspace_id = ?;
            """,
            bindings: [
                .text(Self.string(from: savedAt)),
                fileVersionIdentifier.map(Binding.text) ?? .null,
                .text(WorkspaceRecentDocumentState.available.rawValue),
                .text(Self.string(from: savedAt)),
                .int64(workspaceID)
            ]
        )

        guard let record = try workspaceDocument(workspaceID: workspaceID) else {
            throw DatabaseError.notFound
        }
        return record
    }

    @discardableResult
    func markWorkspaceDocumentBookmarkResolution(
        workspaceID: Int64,
        decision: WorkspaceBookmarkResolutionDecision,
        errorMessage: String? = nil
    ) throws -> WorkspaceDocumentRecord {
        try run(
            """
            UPDATE workspace_documents
            SET bookmark_resolution_decision = ?,
                bookmark_resolution_error = ?
            WHERE workspace_id = ?;
            """,
            bindings: [
                .text(decision.rawValue),
                errorMessage.map(Binding.text) ?? .null,
                .int64(workspaceID)
            ]
        )

        guard let record = try workspaceDocument(workspaceID: workspaceID) else {
            throw DatabaseError.notFound
        }
        return record
    }

    @discardableResult
    func markWorkspaceDocumentRecentState(
        workspaceID: Int64,
        state: WorkspaceRecentDocumentState,
        updatedAt: Date = Date()
    ) throws -> WorkspaceDocumentRecord {
        try run(
            """
            UPDATE workspace_documents
            SET recent_document_state = ?,
                recent_document_state_updated_at = ?
            WHERE workspace_id = ?;
            """,
            bindings: [
                .text(state.rawValue),
                .text(Self.string(from: updatedAt)),
                .int64(workspaceID)
            ]
        )

        guard let record = try workspaceDocument(workspaceID: workspaceID) else {
            throw DatabaseError.notFound
        }
        return record
    }

    @discardableResult
    func insertWorkspaceDocumentAutosaveDecision(
        _ record: WorkspaceDocumentAutosaveDecisionRecord
    ) throws -> WorkspaceDocumentAutosaveDecisionRecord {
        try run(
            """
            INSERT INTO workspace_document_autosave_decisions (
              uuid,
              workspace_id,
              document_id,
              package_path,
              decision,
              reason,
              file_version_identifier,
              decided_at,
              completed_at,
              error_message
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .text(record.uuid.uuidString),
                .int64(record.workspaceID),
                .text(record.documentID.uuidString),
                .text(record.packagePath),
                .text(record.decision.rawValue),
                record.reason.map(Binding.text) ?? .null,
                record.fileVersionIdentifier.map(Binding.text) ?? .null,
                .text(Self.string(from: record.decidedAt)),
                record.completedAt.map { Binding.text(Self.string(from: $0)) } ?? .null,
                record.errorMessage.map(Binding.text) ?? .null
            ]
        )

        var inserted = record
        inserted.id = sqlite3_last_insert_rowid(try requireConnection())
        return inserted
    }

    @discardableResult
    func recordWorkspaceDocumentAutosaveDecision(
        workspaceID: Int64,
        decision: WorkspaceDocumentAutosaveDecision,
        reason: String? = nil,
        decidedAt: Date = Date(),
        completedAt: Date? = nil,
        errorMessage: String? = nil,
        uuid: UUID = UUID()
    ) throws -> WorkspaceDocumentAutosaveDecisionRecord {
        guard let document = try workspaceDocument(workspaceID: workspaceID) else {
            throw DatabaseError.notFound
        }

        return try insertWorkspaceDocumentAutosaveDecision(
            WorkspaceDocumentAutosaveDecisionRecord(
                id: nil,
                uuid: uuid,
                workspaceID: workspaceID,
                documentID: document.documentID,
                packagePath: document.packagePath,
                decision: decision,
                reason: reason,
                fileVersionIdentifier: document.fileVersionIdentifier,
                decidedAt: decidedAt,
                completedAt: completedAt,
                errorMessage: errorMessage
            )
        )
    }

    func workspaceDocumentAutosaveDecisions(
        workspaceID: Int64
    ) throws -> [WorkspaceDocumentAutosaveDecisionRecord] {
        try query(
            """
            SELECT id, uuid, workspace_id, document_id, package_path, decision, reason,
                   file_version_identifier, decided_at, completed_at, error_message
            FROM workspace_document_autosave_decisions
            WHERE workspace_id = ?
            ORDER BY decided_at DESC, id DESC;
            """,
            bindings: [.int64(workspaceID)],
            map: Self.workspaceDocumentAutosaveDecisionRecord
        )
    }

    func recentWorkspaceDocumentAutosaveDecisions(
        limit: Int
    ) throws -> [WorkspaceDocumentAutosaveDecisionRecord] {
        guard limit > 0 else { return [] }

        return try query(
            """
            SELECT id, uuid, workspace_id, document_id, package_path, decision, reason,
                   file_version_identifier, decided_at, completed_at, error_message
            FROM workspace_document_autosave_decisions
            ORDER BY decided_at DESC, id DESC
            LIMIT ?;
            """,
            bindings: [.int64(Int64(limit))],
            map: Self.workspaceDocumentAutosaveDecisionRecord
        )
    }

    /// Create a NEW workspace identity (a fresh INSERT) and its session. This is the only
    /// insert path. Same-file re-save idempotency is the CALLER's responsibility via the
    /// stable workspace id (`saveWorkspaceState(workspaceID:)` / `replaceWorkspaceState(workspaceID:)`)
    /// — a display name is NEVER an overwrite key, so two workspaces may legally share a
    /// name. The production package write builds a throwaway in-memory database, so each
    /// Save / Save As is a clean create here.
    @discardableResult
    func createWorkspaceState(
        workspaceUUID: UUID = UUID(),
        workspaceName: String,
        snapshot: WorkspaceSnapshot,
        selectedSidebarItemID: String?,
        selectedAddress: UInt64?,
        selectedTool: WorkspaceTool,
        editorMode: EditorMode,
        isInspectorPresented: Bool,
        sidebarSearchText: String,
        focusedImageSlot: ImageSlot = .primary,
        now: Date = Date()
    ) throws -> PersistedWorkspace {
        try Self.validateArtifactIntegrityForSave(snapshot)
        return try transaction {
            let workspace = try saveSnapshot(
                workspaceUUID: workspaceUUID,
                workspaceName: workspaceName,
                snapshot: snapshot,
                now: now
            )
            guard let workspaceID = workspace.id else {
                throw DatabaseError.notFound
            }
            let session = try upsertWorkspaceSession(
                WorkspaceSessionRecord(
                    workspaceID: workspaceID,
                    selectedSidebarItemID: selectedSidebarItemID,
                    selectedAddress: selectedAddress,
                    selectedTool: selectedTool,
                    editorMode: editorMode,
                    isInspectorPresented: isInspectorPresented,
                    sidebarSearchText: sidebarSearchText,
                    updatedAt: now,
                    focusedImageSlot: focusedImageSlot
                )
            )
            return PersistedWorkspace(
                workspace: workspace,
                snapshot: snapshot,
                session: session,
                reconstructionState: .empty
            )
        }
    }

    /// Save into an EXISTING workspace identified by its stable id — the overwrite path
    /// used by in-place Save and autosave. Delete-then-insert under the same id, so it is
    /// idempotent and never collides on the global `binaries.uuid` index (the prior binary
    /// rows for this workspace are deleted first). Transactional: a failure rolls back
    /// without partially replacing authoring state.
    @discardableResult
    func saveWorkspaceState(
        workspaceID: Int64,
        workspaceName: String,
        snapshot: WorkspaceSnapshot,
        selectedSidebarItemID: String?,
        selectedAddress: UInt64?,
        selectedTool: WorkspaceTool,
        editorMode: EditorMode,
        isInspectorPresented: Bool,
        sidebarSearchText: String,
        focusedImageSlot: ImageSlot = .primary,
        now: Date = Date()
    ) throws -> PersistedWorkspace {
        try replaceWorkspaceState(
            workspaceID: workspaceID,
            workspaceName: workspaceName,
            snapshot: snapshot,
            selectedSidebarItemID: selectedSidebarItemID,
            selectedAddress: selectedAddress,
            selectedTool: selectedTool,
            editorMode: editorMode,
            isInspectorPresented: isInspectorPresented,
            sidebarSearchText: sidebarSearchText,
            focusedImageSlot: focusedImageSlot,
            now: now
        )
    }

    /// Convenience for a caller with no prior identity yet (a first save): a plain create.
    /// Kept so the bare `saveWorkspaceState(workspaceName:)` verb means "create a new
    /// workspace" rather than the old display-name-reuse overwrite behaviour.
    @discardableResult
    func saveWorkspaceState(
        workspaceName: String,
        snapshot: WorkspaceSnapshot,
        selectedSidebarItemID: String?,
        selectedAddress: UInt64?,
        selectedTool: WorkspaceTool,
        editorMode: EditorMode,
        isInspectorPresented: Bool,
        sidebarSearchText: String,
        focusedImageSlot: ImageSlot = .primary,
        now: Date = Date()
    ) throws -> PersistedWorkspace {
        try createWorkspaceState(
            workspaceName: workspaceName,
            snapshot: snapshot,
            selectedSidebarItemID: selectedSidebarItemID,
            selectedAddress: selectedAddress,
            selectedTool: selectedTool,
            editorMode: editorMode,
            isInspectorPresented: isInspectorPresented,
            sidebarSearchText: sidebarSearchText,
            focusedImageSlot: focusedImageSlot,
            now: now
        )
    }

    @discardableResult
    func replaceWorkspaceState(
        workspaceID: Int64,
        workspaceName: String,
        snapshot: WorkspaceSnapshot,
        selectedSidebarItemID: String?,
        selectedAddress: UInt64?,
        selectedTool: WorkspaceTool,
        editorMode: EditorMode,
        isInspectorPresented: Bool,
        sidebarSearchText: String,
        focusedImageSlot: ImageSlot = .primary,
        now: Date = Date()
    ) throws -> PersistedWorkspace {
        try Self.validateArtifactIntegrityForSave(snapshot)
        guard let existingWorkspace = try workspace(id: workspaceID) else {
            throw DatabaseError.notFound
        }
        _ = try loadLogicalBreakpointCatalog(
            workspaceID: workspaceID,
            workspaceUUID: existingWorkspace.uuid
        )
        _ = try loadLaunchProfileCatalog(
            workspaceID: workspaceID,
            workspaceUUID: existingWorkspace.uuid
        )
        return try transaction {
            guard var workspace = try workspace(id: workspaceID) else {
                throw DatabaseError.notFound
            }

            try updateWorkspaceName(id: workspaceID, name: workspaceName, modifiedAt: now)
            workspace.name = workspaceName
            workspace.modifiedAt = now

            try deleteSnapshotContents(workspaceID: workspaceID)
            try insertSnapshotContents(snapshot, into: workspaceID)

            let currentReconstruction = try loadReconstructionState(
                workspaceID: existingWorkspace.uuid
            )
            // Evidence rows are immutable audit facts. Live-image availability participates in
            // freshness projection and must never rewrite their terminal classifications.
            try pruneTerminalOwnerReplayRecords(workspaceID: existingWorkspace.uuid, state: currentReconstruction)
            let reconstructed = try currentReconstruction.pruningTerminalReplayRecordsForSave()

            let session = try upsertWorkspaceSession(
                WorkspaceSessionRecord(
                    workspaceID: workspaceID,
                    selectedSidebarItemID: selectedSidebarItemID,
                    selectedAddress: selectedAddress,
                    selectedTool: selectedTool,
                    editorMode: editorMode,
                    isInspectorPresented: isInspectorPresented,
                    sidebarSearchText: sidebarSearchText,
                    updatedAt: now,
                    focusedImageSlot: focusedImageSlot
                )
            )

            return PersistedWorkspace(
                workspace: workspace,
                snapshot: try loadSnapshot(workspaceID: workspaceID) ?? snapshot,
                session: session,
                reconstructionState: reconstructed
            )
        }
    }

    func loadWorkspaceState(workspaceID: Int64) throws -> PersistedWorkspace? {
        guard let workspace = try workspace(id: workspaceID),
              var snapshot = try loadSnapshotContents(workspaceID: workspaceID) else {
            return nil
        }

        let catalogAvailability: DebuggerLogicalBreakpointCatalogAvailability
        do {
            snapshot.logicalBreakpointCatalog = try loadLogicalBreakpointCatalog(
                workspaceID: workspaceID,
                workspaceUUID: workspace.uuid
            )
            catalogAvailability = .available
        } catch DatabaseError.logicalBreakpointCatalogUnavailable {
            snapshot.logicalBreakpointCatalog = .freshPristine()
            catalogAvailability = .unavailable
        }

        let launchProfileCatalogAvailability: DebuggerLaunchProfileCatalogAvailability
        do {
            snapshot.launchProfileCatalog = try loadLaunchProfileCatalog(
                workspaceID: workspaceID,
                workspaceUUID: workspace.uuid
            )
            launchProfileCatalogAvailability = .available
        } catch DatabaseError.launchProfileCatalogUnavailable {
            snapshot.launchProfileCatalog = .freshPristine()
            launchProfileCatalogAvailability = .unavailable
        }

        snapshot.savedWatchCatalog = try loadSavedWatchCatalog(
            workspaceID: workspaceID, workspaceUUID: workspace.uuid
        )
        let session = try workspaceSession(workspaceID: workspaceID)
            ?? defaultWorkspaceSession(
                workspaceID: workspaceID,
                snapshot: snapshot,
                updatedAt: workspace.modifiedAt
            )

        return PersistedWorkspace(
            workspace: workspace,
            snapshot: snapshot,
            session: session,
            reconstructionState: try loadReconstructionState(workspaceID: workspace.uuid),
            phase2ShellSessionRecord: try phase2ShellSessionRecord(workspaceID: workspaceID),
            assistantSessionRecords: try allPhase2AssistantSessionRecords(workspaceID: workspaceID),
            runtimeAuthorityRecords: try phase2RuntimeAuthorityRecords(workspaceID: workspaceID),
            logicalBreakpointCatalogAvailability: catalogAvailability,
            launchProfileCatalogAvailability: launchProfileCatalogAvailability,
            typeCatalogLoadDiagnostics: try typeCatalogLoadDiagnostics(workspaceID: workspaceID)
        )
    }

    func loadReconstructionState(workspaceID: UUID) throws -> ReconstructionWorkspaceState {
        guard try workspaceRecord(workspaceUUID: workspaceID) != nil else {
            throw DatabaseError.notFound
        }
        let stateBlobs = try query(
            """
            SELECT state_json
            FROM reconstruction_projects
            WHERE workspace_uuid = ?
            ORDER BY project_id;
            """,
            bindings: [.text(workspaceID.uuidString)],
            map: { Self.blobColumn($0, 0) }
        )
        guard let firstBlob = stateBlobs.first else {
            let orphanCount = try reconstructionRowCount(workspaceID: workspaceID)
            guard orphanCount == 0 else {
                throw DatabaseError.reconstructionStateInvalid(
                    "workspace has \(orphanCount) rows without a project authority row"
                )
            }
            return .empty
        }
        guard stateBlobs.allSatisfy({ $0 == firstBlob }) else {
            throw DatabaseError.reconstructionIdentityConflict(
                "project rows disagree about the canonical workspace state"
            )
        }
        do {
            let decoded = try JSONDecoder().decode(ReconstructionWorkspaceState.self, from: firstBlob)
            let state = try ReconstructionWorkspaceState(
                schemaVersion: decoded.schemaVersion,
                projects: decoded.projects,
                corpusManifests: decoded.corpusManifests,
                evidence: decoded.evidence,
                evidenceRelations: decoded.evidenceRelations,
                evidenceGaps: decoded.evidenceGaps,
                jobs: decoded.jobs,
                tasks: decoded.tasks,
                checkpoints: decoded.checkpoints,
                toolReceipts: decoded.toolReceipts,
                modelReceipts: decoded.modelReceipts,
                finalResults: decoded.finalResults
            )
            try validateReconstructionStateGraph(state)
            try validateReconstructionRowProjection(workspaceID: workspaceID, state: state)
            let normalized = try state.normalizedJobCreationOrder()
            try validateReconstructionStateGraph(normalized)
            let activeJobs = Set(normalized.jobs.filter { !$0.state.isTerminal }.map(\.jobID))
            // Portable snapshots carry active-job optimization data only. Terminal rows remain
            // in the owner journal until Save removes them; historical receipts are unchanged.
            return try normalized.replacingReplayRecords(ownerReplayEnvelopes(workspaceID: workspaceID)
                .filter { activeJobs.contains($0.jobID) })
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch let error as DatabaseError {
            throw error
        } catch {
            throw DatabaseError.reconstructionStateInvalid("decode-or-validation: \(error)")
        }
    }

    func replaceReconstructionState(
        workspaceID: UUID,
        state: ReconstructionWorkspaceState
    ) throws {
        guard try workspaceRecord(workspaceUUID: workspaceID) != nil else {
            throw DatabaseError.notFound
        }
        let normalized = try state.normalizedJobRecords()
        try validateReconstructionStateGraph(normalized)
        try transaction {
            try replaceReconstructionStateRows(workspaceID: workspaceID, state: normalized)
        }
    }

    func configureReconstructionAttachmentVault(rootURL: URL) {
        let standardized = rootURL.standardizedFileURL
        guard standardized != reconstructionAttachmentVaultRootURL else { return }
        reconstructionAttachmentVaultRootURL = standardized
        reconstructionAttachmentVault = ReconstructionDurableAttachmentVault(
            rootURL: standardized
        )
    }

    /// Binds sidecar vault operations to an already verified directory inode. The returned shared
    /// authority is retained by the runtime so close/retire can revoke escaped source tokens after
    /// database-owner quiescence. The vault duplicates the supplied descriptor; the caller closes
    /// its original after this method returns.
    func configureReconstructionAttachmentVault(
        rootURL: URL,
        pinnedRootDescriptor: Int32
    ) throws -> ReconstructionSidecarAttachmentAuthority {
        let standardized = rootURL.standardizedFileURL
        let authority = try ReconstructionSidecarAttachmentAuthority(
            pinnedRootDescriptor: pinnedRootDescriptor
        )
        let vault = ReconstructionDurableAttachmentVault(
            rootURL: standardized,
            attachmentAuthority: authority
        )
        let rootDescriptor = try authority.duplicateRootDescriptor()
        defer { _ = Darwin.close(rootDescriptor) }
        try vault.recoverCrashStageResiduesIfExclusivelyOwned(rootDescriptor: rootDescriptor)
        reconstructionAttachmentVaultRootURL = standardized
        reconstructionAttachmentVault = vault
        return authority
    }

    func publishDurableReconstructionAttachmentSources(
        _ sources: [ReconstructionAttachmentSource],
        for manifest: ReconstructionCorpusManifest
    ) throws -> [ReconstructionAttachmentSource] {
        try reconstructionAttachmentVault.publish(sources, for: manifest)
    }

    func availableDurableReconstructionAttachmentSources(
        workspaceID: UUID
    ) throws -> [ReconstructionAttachmentSource] {
        let state = try loadReconstructionState(workspaceID: workspaceID)
        let identities = try ReconstructionPackageCodec.contentRecords(in: state).map(
            \.contentIdentity
        )
        return try reconstructionAttachmentVault.availableSources(for: identities)
    }

    static func validateReconstructionProductionAttachmentSources(
        _ sources: [ReconstructionAttachmentSource]
    ) throws {
        for source in sources {
            try ReconstructionAttachmentDescriptorReader.validate(source)
        }
    }

    func captureReconstructionProductionRoundRows(
        workspaceID: UUID,
        jobID: UUID
    ) throws -> ReconstructionProductionRoundRows {
        try transaction {
            let state = try loadReconstructionState(workspaceID: workspaceID)
            guard let job = state.jobs.first(where: { $0.jobID == jobID }),
                  let checkpointID = job.currentCheckpointID,
                  let checkpoint = state.checkpoints.first(where: {
                      $0.checkpointID == checkpointID && $0.jobID == jobID
                  }),
                  let project = state.projects.first(where: {
                      $0.projectID == job.reconstructionProjectID
                  }),
                  let manifestSHA256 = project.currentCorpusManifestSHA256,
                  let manifest = state.corpusManifests.first(where: {
                      $0.reconstructionProjectID == project.projectID
                        && $0.canonicalSHA256 == manifestSHA256
                  }),
                  job.creationOrdinal != nil else {
                throw DatabaseError.reconstructionStateInvalid(
                    "production round committed authority"
                )
            }

            let tasks = state.tasks.filter { $0.identity.jobID == jobID }
            let toolReceipts = state.toolReceipts.filter { $0.jobID == jobID }
            let modelReceipts = state.modelReceipts.filter { $0.jobID == jobID }
            let taskCompletionAuthorities = try
                ReconstructionProductionModelRoundBudgetAuthority.taskCompletionAuthorities(
                    jobID: jobID,
                    checkpoints: state.checkpoints
                )
            let attachmentIdentities = Array(Set(manifest.artifacts.map(\.contentIdentity)))
            let attachmentSources = try reconstructionAttachmentVault.candidateSources(
                for: attachmentIdentities
            )

            let currentArtifacts = manifest.artifacts.map {
                ReconstructionArtifactCoordinate(
                    occurrenceID: $0.occurrenceID,
                    contentIdentity: $0.contentIdentity
                )
            }
            let currentArtifactSet = Set(currentArtifacts)
            var currentImageSet: Set<ReconstructionImageCoordinate> = []
            for task in tasks {
                guard let subject = task.identity.subject else { continue }
                switch subject {
                case .artifact(let artifact):
                    guard currentArtifactSet.contains(artifact) else {
                        throw DatabaseError.reconstructionStateInvalid(
                            "production round task artifact authority"
                        )
                    }
                case .image(let image):
                    guard currentArtifactSet.contains(image.artifact) else {
                        throw DatabaseError.reconstructionStateInvalid(
                            "production round task image authority"
                        )
                    }
                    currentImageSet.insert(image)
                case .function(let function):
                    guard currentArtifactSet.contains(function.artifact) else {
                        throw DatabaseError.reconstructionStateInvalid(
                            "production round task function authority"
                        )
                    }
                    currentImageSet.insert(try ReconstructionImageCoordinate(
                        artifact: function.artifact,
                        image: function.image,
                        analysisFingerprintSHA256: function.analysisFingerprintSHA256
                    ))
                }
            }

            struct ImageAuthorityKey: Hashable {
                let artifact: ReconstructionArtifactCoordinate
                let image: ReconstructionImageBinding
                let fingerprint: String
            }
            let currentImageKeys = Set(currentImageSet.map {
                ImageAuthorityKey(
                    artifact: $0.artifact,
                    image: $0.image,
                    fingerprint: $0.analysisFingerprintSHA256
                )
            })
            func subjectIsCurrent(_ subject: ReconstructionSubjectCoordinate) -> Bool {
                switch subject {
                case .artifact(let artifact):
                    return currentArtifactSet.contains(artifact)
                case .image(let image):
                    return currentImageKeys.contains(ImageAuthorityKey(
                        artifact: image.artifact,
                        image: image.image,
                        fingerprint: image.analysisFingerprintSHA256
                    ))
                case .function(let function):
                    return currentImageKeys.contains(ImageAuthorityKey(
                        artifact: function.artifact,
                        image: function.image,
                        fingerprint: function.analysisFingerprintSHA256
                    ))
                }
            }

            let scope = try reconstructionCheckpointProjectionScope(
                in: state,
                projectID: project.projectID
            )
            var currentFacetFingerprints: [
                ReconstructionSubjectCoordinate: [String: String]
            ] = [:]
            for record in scope.evidence where subjectIsCurrent(record.subject) {
                let fingerprints = Dictionary(uniqueKeysWithValues: record.facetDependencies.map {
                    ($0.facetIdentity, $0.fingerprintSHA256)
                })
                if let existing = currentFacetFingerprints[record.subject],
                   existing != fingerprints {
                    throw DatabaseError.reconstructionCheckpointConflict(
                        "production round facet authority changed"
                    )
                }
                currentFacetFingerprints[record.subject] = fingerprints
            }
            let freshnessAuthority = try ReconstructionFreshnessAuthority(
                corpusManifestSHA256: manifest.canonicalSHA256,
                currentArtifacts: currentArtifacts,
                currentImages: Array(currentImageSet),
                currentFacetFingerprints: currentFacetFingerprints
            )
            try validateReconstructionWorkspaceAnalysisAuthority(
                workspaceID: workspaceID,
                authority: freshnessAuthority
            )

            // Retain only the original authority needed by the two bounded source revisions.
            // Ordinary rounds do not pay for unrelated checkpoint history.
            let sourceCheckpointIDs = Set(scope.evidence.filter {
                $0.creatingJobID == job.jobID && $0.operationID == "reconstruction.source.revision"
            }.map(\.creatingCheckpointID))
            let oracleCheckpointIDs = Set(scope.evidence.filter {
                $0.creatingJobID == job.jobID && $0.operationID == "reconstruction.source.oracle"
            }.map(\.creatingCheckpointID))
            let evaluationCheckpointIDs = Set(scope.evidence.filter {
                $0.creatingJobID == job.jobID && $0.operationID == "reconstruction.source.evaluate"
            }.map(\.creatingCheckpointID))
            let sourceParentIDs = Set(state.checkpoints.filter {
                sourceCheckpointIDs.contains($0.checkpointID)
            }.compactMap(\.parentCheckpointID))
            guard sourceCheckpointIDs.count <= 2, oracleCheckpointIDs.count <= 1, evaluationCheckpointIDs.count <= 2 else {
                throw DatabaseError.reconstructionCheckpointConflict("source revision budget exceeded")
            }
            return ReconstructionProductionRoundRows(
                workspaceID: workspaceID,
                project: project,
                manifest: manifest,
                job: job,
                checkpoint: checkpoint,
                tasks: tasks,
                toolReceipts: toolReceipts,
                modelReceipts: modelReceipts,
                taskCompletionAuthorities: taskCompletionAuthorities,
                attachmentSources: attachmentSources,
                evidence: scope.evidence,
                evidenceRelations: scope.evidenceRelations,
                evidenceGaps: scope.evidenceGaps,
                checkpointRevisionsByID: scope.checkpointRevisionsByID,
                freshnessAuthority: freshnessAuthority,
                checkpointHistory: state.checkpoints.filter {
                    $0.jobID == job.jobID && (sourceCheckpointIDs.contains($0.checkpointID)
                        || sourceParentIDs.contains($0.checkpointID)
                        || oracleCheckpointIDs.contains($0.checkpointID)
                        || evaluationCheckpointIDs.contains($0.checkpointID))
                }
            )
        }
    }

    func commitReconstructionCorpus(
        workspaceID: UUID,
        mutation: ReconstructionCorpusMutation
    ) throws -> ReconstructionCommittedCorpus {
        try transaction {
            let state = try loadReconstructionState(workspaceID: workspaceID)
            var projects = state.projects
            let projectIndex: Int
            if let existingIndex = projects.firstIndex(where: {
                $0.projectID == mutation.projectID
            }) {
                projectIndex = existingIndex
            } else {
                guard mutation.expectedCurrentManifestSHA256 == nil else {
                    throw DatabaseError.reconstructionCheckpointConflict(
                        "new corpus project cannot have a parent manifest"
                    )
                }
                projectIndex = projects.count
                projects.append(try ReconstructionProjectRecord(
                    projectID: mutation.projectID,
                    name: "Reconstruction",
                    currentCorpusManifestSHA256: nil
                ))
            }
            let project = projects[projectIndex]
            guard project.currentCorpusManifestSHA256
                    == mutation.expectedCurrentManifestSHA256 else {
                throw DatabaseError.reconstructionCheckpointConflict(
                    "project corpus manifest changed"
                )
            }
            guard mutation.successorManifest.reconstructionProjectID
                    == mutation.projectID else {
                throw DatabaseError.reconstructionStateInvalid(
                    "successor corpus manifest project"
                )
            }
            let retainedHistory = try reconstructionCorpusHistoryIndex(in: state)
            if let retainedManifest = retainedHistory.manifest(
                projectID: mutation.projectID,
                canonicalSHA256: mutation.successorManifest.canonicalSHA256
            ), retainedManifest != mutation.successorManifest {
                throw DatabaseError.reconstructionIdentityConflict(
                    "corpus manifest digest"
                )
            }
            for successorOccurrence in mutation.successorManifest.artifacts {
                if let retainedOccurrence = retainedHistory.occurrencesByID[
                    successorOccurrence.occurrenceID
                ], retainedOccurrence.projectID != mutation.projectID
                    || retainedOccurrence.record != successorOccurrence {
                    throw DatabaseError.reconstructionIdentityConflict(
                        "artifact occurrence record"
                    )
                }
            }
            for successorRelation in mutation.successorManifest.relations {
                if let retainedRelation = retainedHistory.relationsByID[
                    successorRelation.relationID
                ], retainedRelation.projectID != mutation.projectID
                    || retainedRelation.record != successorRelation {
                    throw DatabaseError.reconstructionIdentityConflict(
                        "artifact relation record"
                    )
                }
            }
            guard try ReconstructionCorpusCanonicalizer.canonicalSHA256(
                of: mutation.successorManifest
            ) == mutation.successorManifest.canonicalSHA256 else {
                throw DatabaseError.reconstructionIdentityConflict("corpus manifest digest")
            }
            let committedSources = try Self.validatedReconstructionAttachmentSources(
                mutation.attachmentSources,
                for: mutation.successorManifest
            )

            projects[projectIndex] = try ReconstructionProjectRecord(
                projectID: project.projectID,
                schemaVersion: project.schemaVersion,
                name: project.name,
                currentCorpusManifestSHA256: mutation.successorManifest.canonicalSHA256
            )
            let corpusManifests: [ReconstructionCorpusManifest]
            if retainedHistory.manifest(
                projectID: mutation.projectID,
                canonicalSHA256: mutation.successorManifest.canonicalSHA256
            ) == nil {
                corpusManifests = state.corpusManifests + [mutation.successorManifest]
            } else {
                corpusManifests = state.corpusManifests
            }
            let candidate = try ReconstructionWorkspaceState(
                schemaVersion: state.schemaVersion,
                projects: projects,
                corpusManifests: corpusManifests,
                evidence: state.evidence,
                evidenceRelations: state.evidenceRelations,
                evidenceGaps: state.evidenceGaps,
                jobs: state.jobs,
                tasks: state.tasks,
                checkpoints: state.checkpoints,
                toolReceipts: state.toolReceipts,
                modelReceipts: state.modelReceipts,
                finalResults: state.finalResults
            )
            try validateReconstructionStateGraph(candidate)
            try replaceReconstructionStateRows(workspaceID: workspaceID, state: candidate)
            var committed = ReconstructionCommittedCorpus(
                state: candidate,
                attachmentSources: committedSources
            )
            committed.lifecycle = try reconstructionLifecycleTimestamps(workspaceID: workspaceID)
            return committed
        }
    }

    func commitReconstructionCheckpoint(
        workspaceID: UUID,
        mutation: ReconstructionCheckpointMutation
    ) throws -> ReconstructionCommittedCheckpoint {
        try transaction {
            let state = try loadReconstructionState(workspaceID: workspaceID)
            guard let jobIndex = state.jobs.firstIndex(where: { $0.jobID == mutation.jobID }) else {
                throw DatabaseError.reconstructionStateInvalid("mutation job is not persisted")
            }
            let job = state.jobs[jobIndex]
            guard job.currentCheckpointID == mutation.expectedParentCheckpointID,
                  let parent = state.checkpoints.first(where: {
                      $0.checkpointID == mutation.expectedParentCheckpointID
                  }),
                  parent.jobID == mutation.jobID,
                  parent.canonicalSHA256 == mutation.expectedParentCheckpointSHA256,
                  parent.revision == mutation.expectedParentRevision else {
                throw DatabaseError.reconstructionCheckpointConflict("parent identity changed")
            }
            let successor = mutation.successorCheckpoint
            guard successor.jobID == mutation.jobID,
                  successor.parentCheckpointID == parent.checkpointID,
                  successor.parentCheckpointSHA256 == parent.canonicalSHA256,
                  successor.revision == parent.revision + 1 else {
                throw DatabaseError.reconstructionCheckpointConflict("successor does not extend parent")
            }
            guard !state.checkpoints.contains(where: {
                $0.checkpointID == successor.checkpointID
                    || ($0.jobID == successor.jobID && $0.revision == successor.revision)
            }) else {
                throw DatabaseError.reconstructionIdentityConflict("successor checkpoint identity")
            }
            try validateReconstructionJobTransition(
                job: job,
                successorState: successor.coordinatorState,
                successorPauseContext: mutation.successorPauseContext
            )
            try admitReconstructionLoadedImages(
                workspaceID: workspaceID, state: state, job: job, parent: parent, mutation: mutation
            )
            try validateReconstructionWorkspaceAnalysisAuthority(
                workspaceID: workspaceID,
                authority: mutation.freshnessAuthority
            )

            var evidence = state.evidence
            let existingEvidenceIDs = Set(evidence.map(\.evidenceID))
            guard Set(mutation.evidence.map(\.evidenceID)).count == mutation.evidence.count,
                  mutation.evidence.allSatisfy({ !existingEvidenceIDs.contains($0.evidenceID) }) else {
                throw DatabaseError.reconstructionIdentityConflict("evidence ID")
            }
            guard mutation.evidence.allSatisfy({
                $0.creatingJobID == mutation.jobID
                    && $0.creatingCheckpointID == successor.checkpointID
            }) else {
                throw DatabaseError.reconstructionStateInvalid("new evidence provenance")
            }
            evidence.append(contentsOf: mutation.evidence)

            var evidenceRelations = state.evidenceRelations
            let existingRelationIDs = Set(evidenceRelations.map(\.relationID))
            guard Set(mutation.evidenceRelations.map(\.relationID)).count
                    == mutation.evidenceRelations.count,
                  mutation.evidenceRelations.allSatisfy({
                      !existingRelationIDs.contains($0.relationID)
                  }) else {
                throw DatabaseError.reconstructionIdentityConflict("evidence relation ID")
            }
            evidenceRelations.append(contentsOf: mutation.evidenceRelations)

            var evidenceGaps = state.evidenceGaps
            let existingGapIDs = Set(evidenceGaps.map(\.gapID))
            guard Set(mutation.evidenceGaps.map(\.gapID)).count
                    == mutation.evidenceGaps.count,
                  mutation.evidenceGaps.allSatisfy({
                      !existingGapIDs.contains($0.gapID)
                  }) else {
                throw DatabaseError.reconstructionIdentityConflict("evidence gap ID")
            }
            evidenceGaps.append(contentsOf: mutation.evidenceGaps)
            guard mutation.evidenceGaps.allSatisfy({
                ReconstructionOperationID(rawValue: $0.operationID) != nil
            }) else {
                throw DatabaseError.reconstructionStateInvalid("evidence gap operation ID")
            }

            var toolReceipts = state.toolReceipts
            var idempotentToolReceiptIDs: [UUID] = []
            for receipt in mutation.toolReceipts {
                guard receipt.jobID == mutation.jobID else {
                    throw DatabaseError.reconstructionStateInvalid("tool receipt job")
                }
                if let existing = toolReceipts.first(where: { $0.receiptID == receipt.receiptID }) {
                    guard try reconstructionCanonicalBytes(existing)
                            == reconstructionCanonicalBytes(receipt) else {
                        throw DatabaseError.reconstructionIdentityConflict(
                            "tool receipt \(receipt.receiptID.uuidString)"
                        )
                    }
                    idempotentToolReceiptIDs.append(receipt.receiptID)
                } else {
                    toolReceipts.append(receipt)
                }
            }

            var modelReceipts = state.modelReceipts
            var idempotentModelReceiptIDs: [UUID] = []
            for receipt in mutation.modelReceipts {
                guard receipt.jobID == mutation.jobID else {
                    throw DatabaseError.reconstructionStateInvalid("model receipt job")
                }
                if let existing = modelReceipts.first(where: { $0.receiptID == receipt.receiptID }) {
                    guard try reconstructionCanonicalBytes(existing)
                            == reconstructionCanonicalBytes(receipt) else {
                        throw DatabaseError.reconstructionIdentityConflict(
                            "model receipt \(receipt.receiptID.uuidString)"
                        )
                    }
                    idempotentModelReceiptIDs.append(receipt.receiptID)
                } else {
                    modelReceipts.append(receipt)
                }
            }

            var finalResults = state.finalResults
            let existingFinalResultIDs = Set(finalResults.map(\.resultID))
            let existingFinalResultJobIDs = Set(finalResults.map(\.jobID))
            let newFinalResultIDs = mutation.finalResults.map(\.resultID)
            guard Set(newFinalResultIDs).count == newFinalResultIDs.count,
                  mutation.finalResults.count <= 1,
                  mutation.finalResults.allSatisfy({ result in
                      result.jobID == mutation.jobID
                        && !existingFinalResultIDs.contains(result.resultID)
                        && !existingFinalResultJobIDs.contains(result.jobID)
                  }) else {
                throw DatabaseError.reconstructionIdentityConflict("final result identity")
            }
            finalResults.append(contentsOf: mutation.finalResults)

            var tasks = state.tasks
            let existingTaskIDs = Set(tasks.map { $0.identity.taskID })
            let newTaskIDs = mutation.newTasks.map { $0.identity.taskID }
            guard Set(newTaskIDs).count == newTaskIDs.count,
                  newTaskIDs.allSatisfy({ !existingTaskIDs.contains($0) }),
                  mutation.newTasks.allSatisfy({
                      $0.identity.jobID == mutation.jobID
                          && $0.state == .pending
                          && $0.diagnostic == nil
                  }) else {
                throw DatabaseError.reconstructionIdentityConflict("new task identity")
            }
            let availableTaskIDs = existingTaskIDs.union(newTaskIDs)
            guard mutation.newTasks.allSatisfy({ task in
                task.identity.dependencyTaskIDs.allSatisfy(availableTaskIDs.contains)
            }) else {
                throw DatabaseError.reconstructionStateInvalid("new task dependency")
            }
            tasks.append(contentsOf: mutation.newTasks)
            guard Set(mutation.taskTransitions.map(\.taskID)).count
                    == mutation.taskTransitions.count else {
                throw DatabaseError.reconstructionIdentityConflict("task transition ID")
            }
            for transition in mutation.taskTransitions {
                guard let index = tasks.firstIndex(where: {
                    $0.identity.taskID == transition.taskID
                }), tasks[index].identity.jobID == mutation.jobID else {
                    throw DatabaseError.reconstructionStateInvalid("task transition target")
                }
                guard tasks[index].state == transition.expectedState else {
                    throw DatabaseError.reconstructionCheckpointConflict(
                        "task \(transition.taskID.uuidString) state changed"
                    )
                }
                tasks[index] = ReconstructionTaskRecord(
                    identity: tasks[index].identity,
                    state: transition.successorState,
                    diagnostic: transition.diagnostic,
                    decompileBackend: transition.decompileBackend
                )
            }

            var jobs = state.jobs
            guard let creationOrdinal = job.creationOrdinal else {
                throw DatabaseError.reconstructionStateInvalid("job creation ordinal")
            }
            jobs[jobIndex] = try ReconstructionJobRecord(
                jobID: job.jobID,
                reconstructionProjectID: job.reconstructionProjectID,
                objective: job.objective,
                objectiveSHA256: job.objectiveSHA256,
                creationCorpusManifestSHA256: job.creationCorpusManifestSHA256,
                state: successor.coordinatorState,
                currentCheckpointID: successor.checkpointID,
                terminalReason: successor.terminalReason,
                budget: job.budget,
                creationOrdinal: creationOrdinal,
                pauseContext: mutation.successorPauseContext,
                focus: job.focus,
                sourceProfileID: job.sourceProfileID,
                featureScope: job.featureScope
            )
            guard tasks.filter({ $0.identity.jobID == job.jobID }).count <= job.budget.maxTasks,
                  evidence.filter({ $0.creatingJobID == job.jobID }).count
                    <= job.budget.maxEvidenceRecords,
                  successor.canonicalEncodedByteCount <= job.budget.maxEncodedBytes else {
                throw DatabaseError.reconstructionStateInvalid("job budget exceeded")
            }

            let candidate = try ReconstructionWorkspaceState(
                projects: state.projects,
                corpusManifests: state.corpusManifests,
                evidence: evidence,
                evidenceRelations: evidenceRelations,
                evidenceGaps: evidenceGaps,
                jobs: jobs,
                tasks: tasks,
                checkpoints: state.checkpoints + [successor],
                toolReceipts: toolReceipts,
                modelReceipts: modelReceipts,
                finalResults: finalResults
            )
            try validateReconstructionStateGraph(candidate)
            try validateReconstructionCheckpointProjection(
                candidate,
                job: jobs[jobIndex],
                successor: successor,
                authority: mutation.freshnessAuthority
            )
            try replaceReconstructionStateRows(workspaceID: workspaceID, state: candidate)
            var committed = ReconstructionCommittedCheckpoint(
                state: candidate,
                checkpoint: successor,
                idempotentToolReceiptIDs: ReconstructionValidation.sortedUUIDs(
                    idempotentToolReceiptIDs
                ),
                idempotentModelReceiptIDs: ReconstructionValidation.sortedUUIDs(
                    idempotentModelReceiptIDs
                )
            )
            committed.lifecycle = try reconstructionLifecycleTimestamps(workspaceID: workspaceID)
            return committed
        }
    }

    /// U06: admits one immutable feature scope for a job at its current checkpoint. Changes no job
    /// state, task or checkpoint; re-admitting the identical scope is idempotent, any other scope
    /// is a conflict. Every cited ID must be accepted-current under the supplied authority.
    func admitReconstructionFeatureScope(
        workspaceID: UUID,
        admission: ReconstructionFeatureScopeAdmission
    ) throws -> ReconstructionCommittedFeatureScope {
        try transaction {
            let state = try loadReconstructionState(workspaceID: workspaceID)
            let scope = admission.scope
            guard scope.jobID == admission.jobID,
                  let jobIndex = state.jobs.firstIndex(where: { $0.jobID == admission.jobID }) else {
                throw DatabaseError.reconstructionStateInvalid("feature scope job is not persisted")
            }
            let job = state.jobs[jobIndex]
            if job.featureScope == scope {
                var unchanged = ReconstructionCommittedFeatureScope(state: state, job: job)
                unchanged.lifecycle = try reconstructionLifecycleTimestamps(workspaceID: workspaceID)
                return unchanged
            }
            guard job.featureScope == nil else {
                throw DatabaseError.reconstructionIdentityConflict("feature scope")
            }
            guard job.state != .failed, job.state != .cancelled else {
                throw DatabaseError.reconstructionStateInvalid("feature scope job state")
            }
            guard job.currentCheckpointID == scope.admittedAtCheckpointID,
                  let checkpoint = state.checkpoints.first(where: {
                      $0.checkpointID == scope.admittedAtCheckpointID
                  }),
                  checkpoint.jobID == job.jobID,
                  checkpoint.canonicalSHA256 == scope.admittedAtCheckpointSHA256,
                  checkpoint.revision == scope.admittedAtCheckpointRevision,
                  checkpoint.evidenceFrontierSHA256 == scope.evidenceFrontierSHA256 else {
                throw DatabaseError.reconstructionCheckpointConflict("feature scope checkpoint changed")
            }
            guard scope.projectID == job.reconstructionProjectID,
                  scope.observationContract.isAdmitted,
                  scope.observationContract.sourceProfileID == job.sourceProfileID,
                  admission.freshnessAuthority.currentArtifacts.contains(scope.feature.artifact) else {
                throw DatabaseError.reconstructionStateInvalid("feature scope job binding")
            }
            try validateReconstructionWorkspaceAnalysisAuthority(
                workspaceID: workspaceID,
                authority: admission.freshnessAuthority
            )
            // The admitted checkpoint must still describe the current evidence graph.
            try validateReconstructionCheckpointProjection(
                state,
                job: job,
                successor: checkpoint,
                authority: admission.freshnessAuthority
            )

            let projectScope = try reconstructionCheckpointProjectionScope(
                in: state,
                projectID: job.reconstructionProjectID
            )
            let projection = try ReconstructionEvidenceProjector().project(
                records: projectScope.evidence,
                relations: projectScope.evidenceRelations.filter { $0.kind != .resolvesGap },
                authority: admission.freshnessAuthority
            )
            let classifications = Dictionary(uniqueKeysWithValues: projection.records.map {
                ($0.record.evidenceID, $0.classification)
            })
            guard ReconstructionFeatureScopeCurrency.of(scope, classifications: classifications) == .current else {
                throw DatabaseError.reconstructionCheckpointConflict("feature scope evidence is not accepted current")
            }
            let recordsByID = Dictionary(uniqueKeysWithValues: projectScope.evidence.map { ($0.evidenceID, $0) })
            do { try scope.validateScenarioBindings(recordsByID: recordsByID) }
            catch { throw DatabaseError.reconstructionStateInvalid("feature scope scenario") }
            guard let project = state.projects.first(where: { $0.projectID == scope.projectID }),
                  let manifest = state.corpusManifests.first(where: {
                      $0.reconstructionProjectID == scope.projectID
                        && $0.canonicalSHA256 == checkpoint.corpusManifestSHA256
                  }) else { throw DatabaseError.reconstructionStateInvalid("feature scope corpus") }
            // Reuse PR938's exact current-cut validation, including focus, supporting evidence,
            // task/receipt authority and the single scalar oracle. No attachment byte access.
            let rows = ReconstructionProductionRoundRows(workspaceID: workspaceID,
                project: project, manifest: manifest, job: job, checkpoint: checkpoint,
                tasks: state.tasks.filter { $0.identity.jobID == job.jobID },
                toolReceipts: state.toolReceipts.filter { $0.jobID == job.jobID },
                modelReceipts: [], taskCompletionAuthorities: [], attachmentSources: [],
                evidence: projectScope.evidence, evidenceRelations: projectScope.evidenceRelations,
                evidenceGaps: projectScope.evidenceGaps,
                checkpointRevisionsByID: projectScope.checkpointRevisionsByID,
                freshnessAuthority: admission.freshnessAuthority,
                checkpointHistory: state.checkpoints.filter { $0.jobID == job.jobID })
            let descriptor = try ReconstructionDatabaseOwner.operationDescriptor(for: scope, rows: rows)
            try ReconstructionDatabaseOwner.validateOperationDescriptor(descriptor, rows: rows)

            var jobs = state.jobs
            jobs[jobIndex] = try job.admitting(scope)
            let candidate = try ReconstructionWorkspaceState(
                schemaVersion: state.schemaVersion,
                projects: state.projects,
                corpusManifests: state.corpusManifests,
                evidence: state.evidence,
                evidenceRelations: state.evidenceRelations,
                evidenceGaps: state.evidenceGaps,
                jobs: jobs,
                tasks: state.tasks,
                checkpoints: state.checkpoints,
                toolReceipts: state.toolReceipts,
                modelReceipts: state.modelReceipts,
                finalResults: state.finalResults,
                replayRecords: state.replayRecords
            )
            try validateReconstructionStateGraph(candidate)
            try replaceReconstructionStateRows(workspaceID: workspaceID, state: candidate)
            var committed = ReconstructionCommittedFeatureScope(state: candidate, job: jobs[jobIndex])
            committed.lifecycle = try reconstructionLifecycleTimestamps(workspaceID: workspaceID)
            return committed
        }
    }

    func commitInitialReconstructionJob(
        workspaceID: UUID,
        mutation: ReconstructionInitialJobMutation
    ) throws -> ReconstructionCommittedInitialJob {
        try transaction {
            let state = try loadReconstructionState(workspaceID: workspaceID)
            guard !state.jobs.contains(where: { $0.jobID == mutation.jobID }) else {
                throw DatabaseError.reconstructionIdentityConflict("initial job ID")
            }
            guard mutation.sourceProfileID.map({
                ReconstructionSourceRevision.profileDisposition(for: $0) == .legacy
            }) ?? true else {
                throw DatabaseError.reconstructionStateInvalid("initial job source profile")
            }
            let objective = mutation.objective.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !objective.isEmpty else {
                throw DatabaseError.reconstructionStateInvalid("initial job objective")
            }
            guard let project = state.projects.first(where: {
                $0.projectID == mutation.projectID
            }), let manifestDigest = project.currentCorpusManifestSHA256,
            let manifest = state.corpusManifests.first(where: {
                $0.reconstructionProjectID == mutation.projectID
                    && $0.canonicalSHA256 == manifestDigest
            }) else {
                throw DatabaseError.reconstructionStateInvalid("initial job current corpus")
            }
            guard !mutation.selectedOccurrenceIDs.isEmpty,
                  Set(mutation.selectedOccurrenceIDs).count
                    == mutation.selectedOccurrenceIDs.count else {
                throw DatabaseError.reconstructionStateInvalid("initial job selected occurrences")
            }
            let occurrenceByID = Dictionary(uniqueKeysWithValues: manifest.artifacts.map {
                ($0.occurrenceID, $0)
            })
            guard mutation.selectedOccurrenceIDs.allSatisfy({ occurrenceByID[$0] != nil }) else {
                throw DatabaseError.reconstructionStateInvalid("initial job occurrence authority")
            }
            if let focus = mutation.focus {
                let artifact: ReconstructionArtifactCoordinate
                switch focus {
                case .artifact(let coordinate): artifact = coordinate
                case .function(let coordinate):
                    artifact = coordinate.artifact
                    guard state.evidence.contains(where: {
                        $0.subject == focus && $0.classification == .acceptedCurrent
                            && $0.supersededByEvidenceID == nil
                    }) else {
                        throw DatabaseError.reconstructionStateInvalid("initial job function focus evidence")
                    }
                    let image = try ReconstructionImageCoordinate(
                        artifact: coordinate.artifact, image: coordinate.image,
                        analysisFingerprintSHA256: coordinate.analysisFingerprintSHA256
                    )
                    let scope = try reconstructionCheckpointProjectionScope(
                        in: state, projectID: mutation.projectID
                    )
                    let records = scope.evidence.filter { $0.subject == focus }
                    var facets: [String: String]?
                    for record in records where record.classification == .acceptedCurrent
                        && record.supersededByEvidenceID == nil {
                        let candidate = Dictionary(uniqueKeysWithValues: record.facetDependencies.map {
                            ($0.facetIdentity, $0.fingerprintSHA256)
                        })
                        guard facets == nil || facets == candidate else {
                            throw DatabaseError.reconstructionStateInvalid("initial job focus facet authority")
                        }
                        facets = candidate
                    }
                    let authority = try ReconstructionFreshnessAuthority(
                        corpusManifestSHA256: manifestDigest,
                        currentArtifacts: manifest.artifacts.map {
                            ReconstructionArtifactCoordinate(occurrenceID: $0.occurrenceID,
                                contentIdentity: $0.contentIdentity)
                        }, currentImages: [image], currentFacetFingerprints: [focus: facets ?? [:]]
                    )
                    try validateReconstructionWorkspaceAnalysisAuthority(
                        workspaceID: workspaceID, authority: authority
                    )
                    let projection = try ReconstructionEvidenceProjector().project(
                        records: scope.evidence,
                        relations: scope.evidenceRelations.filter { $0.kind != .resolvesGap },
                        authority: authority
                    )
                    guard projection.records.contains(where: {
                        $0.record.subject == focus && $0.classification == .acceptedCurrent
                    }) else {
                        throw DatabaseError.reconstructionStateInvalid("initial job focus freshness")
                    }
                case .image:
                    throw DatabaseError.reconstructionStateInvalid("initial job focus kind")
                }
                guard mutation.selectedOccurrenceIDs.contains(artifact.occurrenceID),
                      occurrenceByID[artifact.occurrenceID]?.contentIdentity == artifact.contentIdentity else {
                    throw DatabaseError.reconstructionStateInvalid("initial job focus authority")
                }
            }

            let maximumOrdinal = state.jobs.compactMap(\.creationOrdinal).max() ?? 0
            let (creationOrdinal, ordinalOverflow) = maximumOrdinal.addingReportingOverflow(1)
            guard !ordinalOverflow else {
                throw DatabaseError.reconstructionStateInvalid("job creation ordinal exhausted")
            }

            var tasks: [ReconstructionTaskRecord] = []
            func appendTask(
                kind: ReconstructionTaskKind,
                subject: ReconstructionSubjectCoordinate,
                dependencies: [UUID]
            ) throws -> UUID {
                let taskID = UUID()
                let identity = try ReconstructionTaskIdentity.make(
                    taskID: taskID,
                    jobID: mutation.jobID,
                    kind: kind,
                    subject: subject,
                    dependencyTaskIDs: dependencies,
                    operationContractIdentity: "reconstruction.\(kind.rawValue).v1"
                )
                tasks.append(ReconstructionTaskRecord(
                    identity: identity,
                    state: .pending,
                    diagnostic: nil
                ))
                return taskID
            }
            for occurrenceID in mutation.selectedOccurrenceIDs.sorted(by: {
                $0.rawValue.uuidString < $1.rawValue.uuidString
            }) {
                guard let occurrence = occurrenceByID[occurrenceID] else { continue }
                let artifact = ReconstructionArtifactCoordinate(
                    occurrenceID: occurrence.occurrenceID,
                    contentIdentity: occurrence.contentIdentity
                )
                let subject = ReconstructionSubjectCoordinate.artifact(artifact)
                let ingestID = try appendTask(kind: .ingest, subject: subject, dependencies: [])
                let classifyID = try appendTask(
                    kind: .classify,
                    subject: subject,
                    dependencies: [ingestID]
                )
                _ = try appendTask(
                    kind: .discoverRelations,
                    subject: subject,
                    dependencies: [classifyID]
                )
                // Static binary analysis is eligible by acquired format, not POSIX launch
                // permission. Retain the legacy executable-mode path for existing corpora.
                if occurrence.executableMode
                    || [.machOImage, .dynamicLibrary, .objectFile].contains(occurrence.kind) {
                    _ = try appendTask(
                        kind: .loadBinary,
                        subject: subject,
                        dependencies: [ingestID]
                    )
                }
            }
            guard tasks.count <= mutation.budget.maxTasks else {
                throw DatabaseError.reconstructionStateInvalid("initial job task budget")
            }
            guard UInt64(try ReconstructionCanonicalJSON.encode(tasks).count)
                    <= mutation.budget.maxEncodedBytes else {
                throw DatabaseError.reconstructionStateInvalid(
                    "initial job task encoded byte budget"
                )
            }

            let evidenceFrontierSHA256 = try ReconstructionEvidenceFrontier.canonicalSHA256(
                corpusManifestSHA256: manifestDigest,
                records: [],
                projectedClassificationsByEvidenceID: [:],
                relations: [],
                gaps: [],
                checkpointRevisionsByID: [:]
            )
            let unresolvedGapSHA256 = try ReconstructionGapProjector().project(
                gaps: [],
                records: [],
                relations: [],
                projectedClassificationsByEvidenceID: [:]
            ).unresolvedGapFrontierSHA256
            let checkpoint = try ReconstructionCheckpoint.make(
                checkpointID: UUID(),
                jobID: mutation.jobID,
                revision: 0,
                parentCheckpointID: nil,
                parentCheckpointSHA256: nil,
                corpusManifestSHA256: manifestDigest,
                evidenceFrontierSHA256: evidenceFrontierSHA256,
                pendingTaskIDs: tasks.map { $0.identity.taskID },
                runningTaskIDs: [],
                completedTaskIDs: [],
                failedTaskIDs: [],
                blockedTaskIDs: [],
                unresolvedEvidenceGapSHA256: unresolvedGapSHA256,
                modelReceiptIDs: [],
                toolReceiptIDs: [],
                coordinatorState: .created,
                terminalReason: nil
            )
            guard checkpoint.canonicalEncodedByteCount <= mutation.budget.maxEncodedBytes else {
                throw DatabaseError.reconstructionStateInvalid("initial checkpoint byte budget")
            }
            let job = try ReconstructionJobRecord(
                jobID: mutation.jobID,
                reconstructionProjectID: mutation.projectID,
                objective: objective,
                objectiveSHA256: Self.sha256(Data(objective.utf8)),
                creationCorpusManifestSHA256: manifestDigest,
                state: .created,
                currentCheckpointID: checkpoint.checkpointID,
                terminalReason: nil,
                budget: mutation.budget,
                creationOrdinal: creationOrdinal,
                focus: mutation.focus,
                sourceProfileID: mutation.sourceProfileID
            )
            let tasksEncodedByteCount = UInt64(
                try ReconstructionCanonicalJSON.encode(tasks).count
            )
            let jobEncodedByteCount = UInt64(
                try ReconstructionCanonicalJSON.encode(job).count
            )
            let (taskAndCheckpointBytes, firstOverflow) = tasksEncodedByteCount
                .addingReportingOverflow(checkpoint.canonicalEncodedByteCount)
            let (initialAuthorityBytes, secondOverflow) = taskAndCheckpointBytes
                .addingReportingOverflow(jobEncodedByteCount)
            guard !firstOverflow, !secondOverflow,
                  initialAuthorityBytes <= mutation.budget.maxEncodedBytes else {
                throw DatabaseError.reconstructionStateInvalid(
                    "initial job authority encoded byte budget"
                )
            }
            let candidate = try ReconstructionWorkspaceState(
                projects: state.projects,
                corpusManifests: state.corpusManifests,
                evidence: state.evidence,
                evidenceRelations: state.evidenceRelations,
                evidenceGaps: state.evidenceGaps,
                jobs: state.jobs + [job],
                tasks: state.tasks + tasks,
                checkpoints: state.checkpoints + [checkpoint],
                toolReceipts: state.toolReceipts,
                modelReceipts: state.modelReceipts,
                finalResults: state.finalResults
            )
            try validateReconstructionStateGraph(candidate)
            try replaceReconstructionStateRows(workspaceID: workspaceID, state: candidate)
            var committed = ReconstructionCommittedInitialJob(
                state: candidate,
                job: job,
                checkpoint: checkpoint
            )
            committed.lifecycle = try reconstructionLifecycleTimestamps(workspaceID: workspaceID)
            return committed
        }
    }

    private static func validatedReconstructionAttachmentSources(
        _ sources: [ReconstructionAttachmentSource],
        for manifest: ReconstructionCorpusManifest
    ) throws -> [ReconstructionAttachmentSource] {
        var expectedByDigest: [String: ReconstructionContentIdentity] = [:]
        for occurrence in manifest.artifacts {
            let identity = occurrence.contentIdentity
            if let existing = expectedByDigest[identity.digest], existing != identity {
                throw DatabaseError.reconstructionIdentityConflict("content digest")
            }
            expectedByDigest[identity.digest] = identity
        }

        var sourceByDigest: [String: ReconstructionAttachmentSource] = [:]
        for source in sources {
            guard expectedByDigest[source.contentIdentity.digest]
                    == source.contentIdentity else {
                throw DatabaseError.reconstructionAttachmentSourcesUnavailable
            }
            try validateReconstructionAttachmentSourceBytes(source)
            if let existing = sourceByDigest[source.contentIdentity.digest] {
                if source.verifiedURL.absoluteString < existing.verifiedURL.absoluteString {
                    sourceByDigest[source.contentIdentity.digest] = source
                }
            } else {
                sourceByDigest[source.contentIdentity.digest] = source
            }
        }
        guard sourceByDigest.count == expectedByDigest.count else {
            throw DatabaseError.reconstructionAttachmentSourcesUnavailable
        }
        return sourceByDigest.values.sorted {
            $0.contentIdentity.digest < $1.contentIdentity.digest
        }
    }

    private static func validateReconstructionAttachmentSourceBytes(
        _ source: ReconstructionAttachmentSource
    ) throws {
        try ReconstructionAttachmentDescriptorReader.validate(source)
    }

    func reconstructionWorkspaceID(containingJobID jobID: UUID) throws -> UUID {
        let values = try query(
            """
            SELECT workspace_uuid
            FROM reconstruction_jobs
            WHERE job_id = ?
            ORDER BY workspace_uuid
            LIMIT 2;
            """,
            bindings: [.text(jobID.uuidString)],
            map: { statement in
                let rawWorkspaceID = try Self.textColumn(statement, 0)
                guard let workspaceID = UUID(uuidString: rawWorkspaceID),
                      workspaceID.uuidString == rawWorkspaceID else {
                    throw DatabaseError.invalidUUID(rawWorkspaceID)
                }
                return workspaceID
            }
        )
        guard values.count == 1, let value = values.first else {
            if values.isEmpty { throw DatabaseError.notFound }
            throw DatabaseError.reconstructionIdentityConflict(
                "job \(jobID.uuidString) belongs to multiple workspaces"
            )
        }
        return value
    }

    private func replaceReconstructionStateRows(
        workspaceID: UUID,
        state: ReconstructionWorkspaceState
    ) throws {
        try validateReconstructionStateGraph(state)
        try restoreOwnerReplayEnvelopes(workspaceID: workspaceID, state: state)
        let state = try state.replacingReplayRecords(nil)
        let workspace = workspaceID.uuidString
        let priorLifecycle = try reconstructionLifecycleRows(workspaceID: workspaceID)
        let lifecycleNow = UInt64(max(0, (Date().timeIntervalSince1970 * 1_000).rounded(.down)))
        for table in [
            "reconstruction_final_results",
            "reconstruction_checkpoint_tasks",
            "reconstruction_evidence_relations",
            "reconstruction_evidence_citations",
            "reconstruction_evidence",
            "reconstruction_model_receipts",
            "reconstruction_tool_receipts",
            "reconstruction_checkpoints",
            "reconstruction_tasks",
            "reconstruction_jobs",
            "reconstruction_artifact_relations",
            "reconstruction_artifact_roles",
            "reconstruction_artifact_occurrences",
            "reconstruction_artifact_contents",
            "reconstruction_projects",
        ] {
            try run("DELETE FROM \(table) WHERE workspace_uuid = ?;", bindings: [.text(workspace)])
        }
        try triggerReconstructionMutationFailureForTesting(after: .deletedRows)
        guard !state.projects.isEmpty else { return }

        let stateJSON = try reconstructionCanonicalBytes(state)
        let corpusHistory = try reconstructionCorpusHistoryIndex(in: state)
        for project in state.projects {
            try run(
                """
                INSERT INTO reconstruction_projects (
                  workspace_uuid, project_id, current_manifest_sha256, record_json, state_json
                ) VALUES (?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(workspace), .text(project.projectID.uuidString),
                    Self.optionalTextBinding(project.currentCorpusManifestSHA256),
                    .blob(try reconstructionCanonicalBytes(project)), .blob(stateJSON),
                ]
            )
        }
        try triggerReconstructionMutationFailureForTesting(after: .insertedProjects)

        var contentsByDigest: [String: ReconstructionContentIdentity] = [:]
        for occurrenceEntry in corpusHistory.occurrencesByID.values {
            let occurrence = occurrenceEntry.record
            if let existing = contentsByDigest[occurrence.contentIdentity.digest],
               existing != occurrence.contentIdentity {
                throw DatabaseError.reconstructionIdentityConflict(
                    "content \(occurrence.contentIdentity.digest)"
                )
            }
            contentsByDigest[occurrence.contentIdentity.digest] = occurrence.contentIdentity
        }
        for content in contentsByDigest.values.sorted(by: { $0.digest < $1.digest }) {
            try run(
                """
                INSERT INTO reconstruction_artifact_contents (
                  workspace_uuid, content_sha256, algorithm, byte_count, record_json
                ) VALUES (?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(workspace), .text(content.digest), .text(content.algorithm.rawValue),
                    .uint64(content.byteCount), .blob(try reconstructionCanonicalBytes(content)),
                ]
            )
        }
        try triggerReconstructionMutationFailureForTesting(after: .insertedArtifactContents)
        let occurrenceEntries = corpusHistory.occurrencesByID.values.sorted {
            let lhsProjectID = $0.projectID.uuidString
            let rhsProjectID = $1.projectID.uuidString
            if lhsProjectID != rhsProjectID { return lhsProjectID < rhsProjectID }
            return $0.record.occurrenceID.rawValue.uuidString
                < $1.record.occurrenceID.rawValue.uuidString
        }
        for occurrenceEntry in occurrenceEntries {
            let project = occurrenceEntry.projectID.uuidString
            let occurrence = occurrenceEntry.record
            try run(
                """
                INSERT INTO reconstruction_artifact_occurrences (
                  workspace_uuid, project_id, occurrence_id, content_sha256, kind,
                  executable_mode, record_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(workspace), .text(project),
                    .text(occurrence.occurrenceID.rawValue.uuidString),
                    .text(occurrence.contentIdentity.digest), .text(occurrence.kind.rawValue),
                    .bool(occurrence.executableMode),
                    .blob(try reconstructionCanonicalBytes(occurrence)),
                ]
            )
            for (ordinal, role) in occurrence.roles.enumerated() {
                try run(
                    """
                    INSERT INTO reconstruction_artifact_roles (
                      workspace_uuid, project_id, occurrence_id, role, ordinal
                    ) VALUES (?, ?, ?, ?, ?);
                    """,
                    bindings: [
                        .text(workspace), .text(project),
                        .text(occurrence.occurrenceID.rawValue.uuidString),
                        .text(role.rawValue), .int64(Int64(ordinal)),
                    ]
                )
            }
        }
        let relationEntries = corpusHistory.relationsByID.values.sorted {
            let lhsProjectID = $0.projectID.uuidString
            let rhsProjectID = $1.projectID.uuidString
            if lhsProjectID != rhsProjectID { return lhsProjectID < rhsProjectID }
            return $0.record.relationID.uuidString < $1.record.relationID.uuidString
        }
        for relationEntry in relationEntries {
            let project = relationEntry.projectID.uuidString
            let relation = relationEntry.record
            try run(
                """
                INSERT INTO reconstruction_artifact_relations (
                  workspace_uuid, project_id, relation_id, kind, source_occurrence_id,
                  target_occurrence_id, canonical_sha256, record_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(workspace), .text(project), .text(relation.relationID.uuidString),
                    .text(relation.kind.rawValue),
                    .text(relation.sourceOccurrenceID.rawValue.uuidString),
                    Self.optionalTextBinding(relation.targetOccurrenceID?.rawValue.uuidString),
                    .text(relation.canonicalSHA256),
                    .blob(try reconstructionCanonicalBytes(relation)),
                ]
            )
        }
        try triggerReconstructionMutationFailureForTesting(after: .insertedArtifactGraph)

        for job in state.jobs {
            try run(
                """
                INSERT INTO reconstruction_jobs (
                  workspace_uuid, job_id, project_id, current_checkpoint_id, state, record_json,
                  created_at_ms, started_at_ms, finished_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(workspace), .text(job.jobID.uuidString),
                    .text(job.reconstructionProjectID.uuidString),
                    Self.optionalTextBinding(job.currentCheckpointID?.uuidString),
                    .text(job.state.rawValue), .blob(try reconstructionCanonicalBytes(job)),
                ] + Self.lifecycleBindings(Self.stampedLifecycle(
                    prior: priorLifecycle.jobs[job.jobID],
                    initial: job.state == .created, terminal: job.state.isTerminal, now: lifecycleNow))
            )
        }
        try triggerReconstructionMutationFailureForTesting(after: .insertedJobs)
        for task in state.tasks {
            try run(
                """
                INSERT INTO reconstruction_tasks (
                  workspace_uuid, task_id, job_id, state, record_json,
                  created_at_ms, started_at_ms, finished_at_ms
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(workspace), .text(task.identity.taskID.uuidString),
                    .text(task.identity.jobID.uuidString), .text(task.state.rawValue),
                    .blob(try reconstructionCanonicalBytes(task)),
                ] + Self.lifecycleBindings(Self.stampedLifecycle(
                    prior: priorLifecycle.tasks[task.identity.taskID],
                    initial: task.state == .pending,
                    terminal: [.completed, .failed, .cancelled].contains(task.state), now: lifecycleNow))
            )
        }
        try triggerReconstructionMutationFailureForTesting(after: .insertedTasks)
        for checkpoint in state.checkpoints {
            try run(
                """
                INSERT INTO reconstruction_checkpoints (
                  workspace_uuid, checkpoint_id, job_id, revision, parent_checkpoint_id,
                  canonical_sha256, record_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(workspace), .text(checkpoint.checkpointID.uuidString),
                    .text(checkpoint.jobID.uuidString), .uint64(checkpoint.revision),
                    Self.optionalTextBinding(checkpoint.parentCheckpointID?.uuidString),
                    .text(checkpoint.canonicalSHA256),
                    .blob(try reconstructionCanonicalBytes(checkpoint)),
                ]
            )
            let buckets: [(String, [UUID])] = [
                ("pending", checkpoint.pendingTaskIDs),
                ("running", checkpoint.runningTaskIDs),
                ("completed", checkpoint.completedTaskIDs),
                ("failed", checkpoint.failedTaskIDs),
                ("blocked", checkpoint.blockedTaskIDs),
            ]
            for (bucket, taskIDs) in buckets {
                for (ordinal, taskID) in taskIDs.enumerated() {
                    try run(
                        """
                        INSERT INTO reconstruction_checkpoint_tasks (
                          workspace_uuid, checkpoint_id, task_id, state_bucket, ordinal
                        ) VALUES (?, ?, ?, ?, ?);
                        """,
                        bindings: [
                            .text(workspace), .text(checkpoint.checkpointID.uuidString),
                            .text(taskID.uuidString), .text(bucket), .int64(Int64(ordinal)),
                        ]
                    )
                }
            }
        }
        try triggerReconstructionMutationFailureForTesting(after: .insertedCheckpoints)
        for receipt in state.toolReceipts {
            try run(
                """
                INSERT INTO reconstruction_tool_receipts (
                  workspace_uuid, receipt_id, job_id, task_id, canonical_sha256, record_json
                ) VALUES (?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(workspace), .text(receipt.receiptID.uuidString),
                    .text(receipt.jobID.uuidString), .text(receipt.taskID.uuidString),
                    .text(receipt.canonicalSHA256),
                    .blob(try reconstructionCanonicalBytes(receipt)),
                ]
            )
        }
        try triggerReconstructionMutationFailureForTesting(after: .insertedToolReceipts)
        for receipt in state.modelReceipts {
            try run(
                """
                INSERT INTO reconstruction_model_receipts (
                  workspace_uuid, receipt_id, job_id, task_id, canonical_sha256, record_json
                ) VALUES (?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(workspace), .text(receipt.receiptID.uuidString),
                    .text(receipt.jobID.uuidString), .text(receipt.taskID.uuidString),
                    .text(receipt.canonicalSHA256),
                    .blob(try reconstructionCanonicalBytes(receipt)),
                ]
            )
        }
        try triggerReconstructionMutationFailureForTesting(after: .insertedModelReceipts)
        for result in state.finalResults {
            try run(
                """
                INSERT INTO reconstruction_final_results (
                  workspace_uuid, result_id, job_id, task_id, checkpoint_id,
                  checkpoint_revision, request_id, request_identity_sha256, kind,
                  payload_byte_count, payload_sha256, producer_canonical_sha256,
                  model_receipt_id, canonical_sha256, record_json
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(workspace), .text(result.resultID.uuidString),
                    .text(result.jobID.uuidString), .text(result.taskID.uuidString),
                    .text(result.checkpointID.uuidString), .uint64(result.checkpointRevision),
                    .text(result.requestID.uuidString), .text(result.requestIdentitySHA256),
                    .text(result.kind.rawValue), .uint64(result.payloadByteCount),
                    .text(result.payloadSHA256), .text(result.producer.canonicalSHA256),
                    .text(result.modelReceiptID.uuidString), .text(result.canonicalSHA256),
                    .blob(try reconstructionCanonicalBytes(result)),
                ]
            )
        }
        try triggerReconstructionFinalResultMutationFailureForTesting(
            after: .insertedFinalResults
        )
        for item in state.evidence {
            try run(
                """
                INSERT INTO reconstruction_evidence (
                  workspace_uuid, evidence_id, classification, payload_sha256, record_json
                ) VALUES (?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(workspace), .text(item.evidenceID.uuidString),
                    .text(item.classification.rawValue), .text(item.payloadSHA256),
                    .blob(try reconstructionCanonicalBytes(item)),
                ]
            )
            for citation in item.citations {
                try run(
                    """
                    INSERT INTO reconstruction_evidence_citations (
                      workspace_uuid, evidence_id, citation_id, source_evidence_id, record_json
                    ) VALUES (?, ?, ?, ?, ?);
                    """,
                    bindings: [
                        .text(workspace), .text(item.evidenceID.uuidString),
                        .text(citation.citationID.uuidString),
                        Self.optionalTextBinding(citation.sourceEvidenceID?.uuidString),
                        .blob(try reconstructionCanonicalBytes(citation)),
                    ]
                )
            }
        }
        try triggerReconstructionMutationFailureForTesting(after: .insertedEvidence)
        for relation in state.evidenceRelations {
            try run(
                """
                INSERT INTO reconstruction_evidence_relations (
                  workspace_uuid, relation_id, kind, source_evidence_id,
                  target_evidence_id, record_json
                ) VALUES (?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(workspace), .text(relation.relationID.uuidString),
                    .text(relation.kind.rawValue), .text(relation.sourceEvidenceID.uuidString),
                    .text(relation.targetEvidenceID.uuidString),
                    .blob(try reconstructionCanonicalBytes(relation)),
                ]
            )
        }
        try triggerReconstructionMutationFailureForTesting(after: .insertedEvidenceRelations)
    }

    private func triggerReconstructionMutationFailureForTesting(
        after phase: ReconstructionMutationPhase
    ) throws {
        guard reconstructionMutationFailureForTesting == phase else { return }
        reconstructionMutationFailureForTesting = nil
        throw DatabaseError.reconstructionInjectedFailure(phase.rawValue)
    }

    private func triggerReconstructionSidecarBootstrapFailureForTesting(
        after phase: ReconstructionSidecarBootstrapPhase
    ) throws {
        guard reconstructionSidecarBootstrapFailureForTesting == phase else { return }
        reconstructionSidecarBootstrapFailureForTesting = nil
        throw DatabaseError.reconstructionInjectedFailure("sidecar-\(phase.rawValue)")
    }

    private func triggerReconstructionFinalResultMutationFailureForTesting(
        after phase: ReconstructionFinalResultMutationPhase
    ) throws {
        guard reconstructionFinalResultMutationFailureForTesting == phase else { return }
        reconstructionFinalResultMutationFailureForTesting = nil
        throw DatabaseError.reconstructionInjectedFailure("final-result-\(phase.rawValue)")
    }

    private func reconstructionCorpusHistoryIndex(
        in state: ReconstructionWorkspaceState
    ) throws -> ReconstructionCorpusHistoryIndex {
        do {
            return try ReconstructionCorpusHistoryIndex(
                projects: state.projects,
                manifests: state.corpusManifests
            )
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch let failure as ReconstructionCorpusHistoryIndex.Failure {
            if failure.isIdentityConflict {
                throw DatabaseError.reconstructionIdentityConflict(failure.graphReason)
            }
            throw DatabaseError.reconstructionStateInvalid(failure.graphReason)
        }
    }

    private func validateReconstructionStateGraph(
        _ state: ReconstructionWorkspaceState
    ) throws {
        for job in state.jobs {
            try Task.checkCancellation()
            guard Self.sha256(Data(job.objective.utf8)) == job.objectiveSHA256 else {
                throw DatabaseError.reconstructionStateInvalid("job objective digest")
            }
        }
        do {
            try ReconstructionPackageCodec.validateGraph(state)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch let error as ReconstructionPackageValidationError {
            let reason: String
            switch error {
            case .stateGraphInvalid(let graphReason):
                reason = graphReason
            default:
                reason = error.errorDescription ?? String(describing: error)
            }
            throw DatabaseError.reconstructionStateInvalid("package-v3 graph: \(reason)")
        } catch {
            throw DatabaseError.reconstructionStateInvalid(
                "package-v3 graph: \(String(describing: error))"
            )
        }

        let projects = Dictionary(uniqueKeysWithValues: state.projects.map { ($0.projectID, $0) })
        let corpusHistory = try reconstructionCorpusHistoryIndex(in: state)
        var contentByDigest: [String: ReconstructionContentIdentity] = [:]
        for occurrenceEntry in corpusHistory.occurrencesByID.values {
            let identity = occurrenceEntry.record.contentIdentity
            if let existing = contentByDigest[identity.digest], existing != identity {
                throw DatabaseError.reconstructionIdentityConflict("content digest")
            }
            contentByDigest[identity.digest] = identity
        }

        func validateSubject(_ subject: ReconstructionSubjectCoordinate) throws {
            let artifact: ReconstructionArtifactCoordinate
            switch subject {
            case .artifact(let value): artifact = value
            case .image(let value): artifact = value.artifact
            case .function(let value): artifact = value.artifact
            }
            guard let occurrence = corpusHistory.occurrencesByID[artifact.occurrenceID]?.record,
                  occurrence.contentIdentity == artifact.contentIdentity else {
                throw DatabaseError.reconstructionStateInvalid("subject artifact coordinate")
            }
        }

        let jobs = Dictionary(uniqueKeysWithValues: state.jobs.map { ($0.jobID, $0) })
        let tasks = Dictionary(uniqueKeysWithValues: state.tasks.map { ($0.identity.taskID, $0) })
        let checkpoints = Dictionary(
            uniqueKeysWithValues: state.checkpoints.map { ($0.checkpointID, $0) }
        )
        let evidence = Dictionary(uniqueKeysWithValues: state.evidence.map { ($0.evidenceID, $0) })
        let evidenceGaps = Dictionary(
            uniqueKeysWithValues: state.evidenceGaps.map { ($0.gapID, $0) }
        )
        let toolReceipts = Dictionary(
            uniqueKeysWithValues: state.toolReceipts.map { ($0.receiptID, $0) }
        )
        let modelReceipts = Dictionary(
            uniqueKeysWithValues: state.modelReceipts.map { ($0.receiptID, $0) }
        )

        for job in state.jobs {
            guard projects[job.reconstructionProjectID] != nil,
                  corpusHistory.manifest(
                      projectID: job.reconstructionProjectID,
                      canonicalSHA256: job.creationCorpusManifestSHA256
                  ) != nil else {
                throw DatabaseError.reconstructionStateInvalid("job project or creation manifest")
            }
            if let focus = job.focus {
                let artifact: ReconstructionArtifactCoordinate
                switch focus {
                case .artifact(let coordinate): artifact = coordinate
                case .function(let coordinate): artifact = coordinate.artifact
                case .image:
                    throw DatabaseError.reconstructionStateInvalid("job focus kind")
                }
                guard corpusHistory.contains(focus, projectID: job.reconstructionProjectID,
                    manifestSHA256: job.creationCorpusManifestSHA256),
                    state.tasks.contains(where: {
                        $0.identity.jobID == job.jobID && $0.identity.kind == .ingest
                            && $0.identity.subject == .artifact(artifact)
                            && $0.identity.dependencyTaskIDs.isEmpty
                    }) else {
                    throw DatabaseError.reconstructionStateInvalid("job focus creation manifest")
                }
                if case .function = focus {
                    guard state.evidence.contains(where: { $0.subject == focus }) else {
                        throw DatabaseError.reconstructionStateInvalid("job function focus evidence")
                    }
                }
            }
            if let current = job.currentCheckpointID {
                guard checkpoints[current]?.jobID == job.jobID else {
                    throw DatabaseError.reconstructionStateInvalid("job current checkpoint")
                }
            }
        }
        for task in state.tasks {
            guard jobs[task.identity.jobID] != nil else {
                throw DatabaseError.reconstructionStateInvalid("task job")
            }
            for dependency in task.identity.dependencyTaskIDs {
                guard tasks[dependency]?.identity.jobID == task.identity.jobID else {
                    throw DatabaseError.reconstructionStateInvalid("task dependency")
                }
            }
            if let subject = task.identity.subject { try validateSubject(subject) }
        }
        for job in state.jobs {
            let chain = state.checkpoints
                .filter { $0.jobID == job.jobID }
                .sorted { $0.revision < $1.revision }
            for (index, checkpoint) in chain.enumerated() {
                guard checkpoint.revision == UInt64(index) else {
                    throw DatabaseError.reconstructionStateInvalid("checkpoint revision chain")
                }
                if index > 0 {
                    let prior = chain[index - 1]
                    guard checkpoint.parentCheckpointID == prior.checkpointID,
                          checkpoint.parentCheckpointSHA256 == prior.canonicalSHA256 else {
                        throw DatabaseError.reconstructionStateInvalid("checkpoint parent chain")
                    }
                }
                let frontier = checkpoint.pendingTaskIDs + checkpoint.runningTaskIDs
                    + checkpoint.completedTaskIDs + checkpoint.failedTaskIDs
                    + checkpoint.blockedTaskIDs
                guard frontier.allSatisfy({ tasks[$0]?.identity.jobID == job.jobID }),
                      checkpoint.toolReceiptIDs.allSatisfy({
                          toolReceipts[$0]?.jobID == job.jobID
                      }),
                      checkpoint.modelReceiptIDs.allSatisfy({
                          modelReceipts[$0]?.jobID == job.jobID
                      }),
                      corpusHistory.manifest(
                          projectID: job.reconstructionProjectID,
                          canonicalSHA256: checkpoint.corpusManifestSHA256
                      ) != nil else {
                    throw DatabaseError.reconstructionStateInvalid("checkpoint frontier")
                }
            }
            if let currentID = job.currentCheckpointID,
               let current = checkpoints[currentID] {
                let stateByTask = Dictionary(uniqueKeysWithValues: [
                    (ReconstructionTaskState.pending, Set(current.pendingTaskIDs)),
                    (.running, Set(current.runningTaskIDs)),
                    (.completed, Set(current.completedTaskIDs)),
                    (.failed, Set(current.failedTaskIDs)),
                    (.blocked, Set(current.blockedTaskIDs)),
                ])
                for task in state.tasks where task.identity.jobID == job.jobID {
                    if let expected = stateByTask[task.state],
                       !expected.contains(task.identity.taskID) {
                        throw DatabaseError.reconstructionStateInvalid("current task frontier")
                    }
                }
            }
        }
        do {
            try ReconstructionPackageCodec.validateCumulativeReceiptFrontiers(
                checkpoints: state.checkpoints,
                toolReceipts: toolReceipts,
                modelReceipts: modelReceipts
            )
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            throw DatabaseError.reconstructionStateInvalid("checkpoint receipt frontier")
        }
        for record in state.evidence {
            try validateSubject(record.subject)
            guard jobs[record.creatingJobID] != nil,
                  tasks[record.creatingTaskID]?.identity.jobID == record.creatingJobID,
                  checkpoints[record.creatingCheckpointID]?.jobID == record.creatingJobID,
                  record.modelReceiptID.map({ modelReceipts[$0] != nil }) ?? true,
                  record.toolReceiptID.map({ toolReceipts[$0] != nil }) ?? true,
                  record.supersedesEvidenceID.map({ evidence[$0] != nil }) ?? true,
                  record.supersededByEvidenceID.map({ evidence[$0] != nil }) ?? true else {
                throw DatabaseError.reconstructionStateInvalid("evidence provenance")
            }
            for citation in record.citations {
                guard citation.sourceEvidenceID.map({ evidence[$0] != nil }) ?? true else {
                    throw DatabaseError.reconstructionStateInvalid("evidence citation source")
                }
                if let subject = citation.subject { try validateSubject(subject) }
            }
        }
        for relation in state.evidenceRelations {
            guard evidence[relation.sourceEvidenceID] != nil else {
                throw DatabaseError.reconstructionStateInvalid("evidence relation endpoint")
            }
            if relation.kind == .resolvesGap {
                guard evidenceGaps[relation.targetEvidenceID] != nil else {
                    throw DatabaseError.reconstructionStateInvalid(
                        "evidence relation gap endpoint"
                    )
                }
            } else if evidence[relation.targetEvidenceID] == nil {
                throw DatabaseError.reconstructionStateInvalid("evidence relation endpoint")
            }
        }
        for gap in state.evidenceGaps { try validateSubject(gap.subject) }
        for receipt in state.toolReceipts {
            guard jobs[receipt.jobID] != nil,
                  tasks[receipt.taskID]?.identity.jobID == receipt.jobID,
                  receipt.outputEvidenceIDs.allSatisfy({ evidence[$0] != nil }),
                  state.checkpoints.contains(where: {
                      $0.jobID == receipt.jobID && $0.revision == receipt.checkpointRevision
                  }) else {
                throw DatabaseError.reconstructionStateInvalid("tool receipt references")
            }
        }
        for receipt in state.modelReceipts {
            guard jobs[receipt.jobID] != nil,
                  tasks[receipt.taskID]?.identity.jobID == receipt.jobID,
                  receipt.acceptedEvidenceIDs.allSatisfy({ evidence[$0] != nil }),
                  state.checkpoints.contains(where: {
                      $0.jobID == receipt.jobID && $0.revision == receipt.checkpointRevision
                  }) else {
                throw DatabaseError.reconstructionStateInvalid("model receipt references")
            }
        }
    }

    /// Validates the job state and its durable pause authority as one atomic transition.
    /// Checkpoint mutations may record progress without moving an active state, but they may not
    /// rewrite a paused or terminal state in place.
    private func validateReconstructionJobTransition(
        job: ReconstructionJobRecord,
        successorState: ReconstructionJobState,
        successorPauseContext: ReconstructionJobPauseContext?
    ) throws {
        let conflict = DatabaseError.reconstructionCheckpointConflict(
            "job state or pause context transition"
        )
        if successorState == job.state {
            guard ReconstructionJobState.activeStates.contains(job.state),
                  job.pauseContext == nil,
                  successorPauseContext == nil else {
                throw conflict
            }
            return
        }

        do {
            if job.state == .paused {
                guard let pauseContext = job.pauseContext,
                      successorPauseContext == nil else {
                    throw conflict
                }
                if successorState == .cancelled || successorState == .failed {
                    try ReconstructionJobStateMachine.transition(
                        from: job.state,
                        to: successorState,
                        resumeTarget: nil
                    )
                } else {
                    try ReconstructionJobStateMachine.transition(
                        from: job.state,
                        to: successorState,
                        resumeTarget: pauseContext.resumeTarget
                    )
                }
            } else if successorState == .paused {
                guard job.pauseContext == nil,
                      let pauseContext = successorPauseContext else {
                    throw conflict
                }
                try ReconstructionJobStateMachine.transition(
                    from: job.state,
                    to: successorState,
                    resumeTarget: pauseContext.resumeTarget
                )
            } else {
                guard job.pauseContext == nil,
                      successorPauseContext == nil else {
                    throw conflict
                }
                try ReconstructionJobStateMachine.transition(
                    from: job.state,
                    to: successorState,
                    resumeTarget: nil
                )
            }
        } catch is ReconstructionJobStateTransitionError {
            throw conflict
        }
    }

    private struct ReconstructionCheckpointProjectionScope {
        let evidence: [ReconstructionEvidenceRecord]
        let evidenceRelations: [ReconstructionEvidenceRelation]
        let evidenceGaps: [ReconstructionEvidenceGap]
        let checkpointRevisionsByID: [UUID: UInt64]
    }

    private struct ReconstructionLoadRequestIdentity: Encodable {
        let schemaVersion = 1
        let jobID: UUID
        let task: ReconstructionTaskIdentity
        let checkpointID: UUID
        let checkpointRevision: UInt64
        let checkpointSHA256: String
        let corpusManifestSHA256: String
    }

    private struct ReconstructionLoadEvidencePayload: Decodable {
        struct Projection: Decodable {
            let taskID: UUID
            let taskKind: ReconstructionTaskKind
            let artifact: ReconstructionArtifactCoordinate
            let image: ReconstructionImageBinding
            let analysisFingerprintSHA256: String
        }
        let schemaVersion: Int
        let task: ReconstructionTaskIdentity
        let outcome: String
        let projection: Projection?
    }

    /// This is part of the existing checkpoint transaction. Failed receipt, evidence or frontier
    /// validation rolls ordinary image rows back together with the reconstruction mutation.
    private func admitReconstructionLoadedImages(
        workspaceID: UUID, state: ReconstructionWorkspaceState, job: ReconstructionJobRecord,
        parent: ReconstructionCheckpoint, mutation: ReconstructionCheckpointMutation
    ) throws {
        guard !mutation.analysisImports.isEmpty else { return }
        let invalid = DatabaseError.reconstructionCheckpointConflict("load image admission authority changed")
        guard mutation.analysisImports.count <= job.budget.maxTasks,
              Set(mutation.analysisImports.map(\.taskID)).count == mutation.analysisImports.count,
              let workspaceRowID = try workspaceRecord(workspaceUUID: workspaceID)?.id,
              let manifest = state.corpusManifests.first(where: {
                  $0.reconstructionProjectID == job.reconstructionProjectID
                      && $0.canonicalSHA256 == mutation.successorCheckpoint.corpusManifestSHA256
              }) else { throw invalid }
        for admission in mutation.analysisImports {
            try Task.checkCancellation()
            let detached = admission.snapshot
            let imageCoordinate = try ReconstructionImageCoordinate(
                artifact: detached.artifact, image: detached.image,
                analysisFingerprintSHA256: detached.analysisInputFingerprintSHA256)
            guard let task = state.tasks.first(where: { $0.identity.taskID == admission.taskID }),
                  task.identity.jobID == job.jobID, task.identity.kind == .loadBinary,
                  task.state == .pending || task.state == .running,
                  task.identity.subject == .artifact(detached.artifact)
                    || task.identity.subject == .image(imageCoordinate),
                  manifest.artifacts.contains(where: {
                      $0.occurrenceID == detached.artifact.occurrenceID
                          && $0.contentIdentity == detached.artifact.contentIdentity
                  }),
                  mutation.taskTransitions.contains(where: {
                      $0.taskID == admission.taskID && $0.expectedState == task.state
                          && $0.successorState == .completed
                  }),
                  mutation.freshnessAuthority.currentImages.contains(imageCoordinate),
                  let receipt = mutation.toolReceipts.first(where: {
                      $0.taskID == admission.taskID && $0.jobID == job.jobID
                          && $0.checkpointRevision == mutation.successorCheckpoint.revision
                          && $0.terminalState == .completed
                          && $0.producer.operationIdentity == ReconstructionOperationID.imagesPage.rawValue
                  }),
                  receipt.requestIdentitySHA256 == (try ReconstructionCanonicalJSON.sha256(of:
                    ReconstructionLoadRequestIdentity(jobID: job.jobID, task: task.identity,
                        checkpointID: parent.checkpointID, checkpointRevision: parent.revision,
                        checkpointSHA256: parent.canonicalSHA256,
                        corpusManifestSHA256: parent.corpusManifestSHA256))),
                  let evidence = mutation.evidence.first(where: {
                      $0.creatingTaskID == admission.taskID && $0.creatingJobID == job.jobID
                          && $0.creatingCheckpointID == mutation.successorCheckpoint.checkpointID
                          && $0.toolReceiptID == receipt.receiptID
                          && $0.operationID == ReconstructionOperationID.imagesPage.rawValue
                          && $0.classification == .acceptedCurrent
                          && receipt.outputEvidenceIDs.contains($0.evidenceID)
                  }),
                  let payload = try? JSONDecoder().decode(ReconstructionLoadEvidencePayload.self, from: evidence.payload),
                  payload.schemaVersion == 1, payload.task == task.identity, payload.outcome == "completed",
                  payload.projection?.taskID == admission.taskID,
                  payload.projection?.taskKind == .loadBinary,
                  payload.projection?.artifact == detached.artifact,
                  payload.projection?.image == detached.image,
                  payload.projection?.analysisFingerprintSHA256 == detached.analysisInputFingerprintSHA256,
                  detached.workspace.binaries.count == 1,
                  let binary = detached.workspace.binary(in: detached.image.imageSlot),
                  binary.id == detached.image.binaryID,
                  binary.selectedSliceIndex == detached.image.selectedSliceIndex,
                  binary.artifactIdentity == detached.image.machOIdentity,
                  let analysis = detached.workspace.analysis(in: binary.slot),
                  !analysis.imageBytes.isEmpty,
                  UInt64(analysis.imageBytes.count) <= ReconstructionPackageLayout.maximumCorpusAttachmentBytes,
                  let recorded = analysis.analysisInputFingerprint else { throw invalid }
            try detached.workspace.validateInvariants()
            let recomputed = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)
            guard recomputed == recorded,
                  recomputed.overallSHA256 == detached.analysisInputFingerprintSHA256,
                  Self.reconstructionArchitecture(binary.architecture) == detached.image.architecture else { throw invalid }
            var verifiedMachO: MachOSliceArtifactReconstruction?
            if let identity = binary.artifactIdentity {
                let rebuilt = try MachOSliceArtifactReconstructor.reconstruct(selectedSliceBytes: analysis.imageBytes)
                guard rebuilt.identity == identity, rebuilt.preferredSegmentLayout == binary.preferredSegmentLayout,
                      binary.artifactIntegrityState == .verified else { throw invalid }
                verifiedMachO = rebuilt
            }
            let existing = try binaries(workspaceID: workspaceRowID)
            if let same = existing.first(where: { $0.uuid == binary.id }) {
                guard same.imageSlot == binary.slot.rawValue,
                      same.hexBytes == analysis.imageBytes,
                      try Self.decodeAnalysisInputFingerprintJSON(same.analysisInputFingerprintJSON) == recomputed else {
                    throw invalid
                }
                continue
            }
            guard !existing.contains(where: { $0.imageSlot == binary.slot.rawValue }) else {
                throw DatabaseError.reconstructionCheckpointConflict("load image primary slot already belongs to another image")
            }
            let actualMachO = try verifiedMachO
                ?? MachOSliceArtifactReconstructor.reconstruct(selectedSliceBytes: analysis.imageBytes)
            guard let identity = binary.artifactIdentity,
                  identity == actualMachO.identity,
                  binary.preferredSegmentLayout == actualMachO.preferredSegmentLayout,
                  binary.artifactIntegrityState == .verified,
                  actualMachO.identity.architectureVariant.rawValue == detached.image.architecture.rawValue,
                  actualMachO.identity.architectureVariant == .arm64
                    || actualMachO.identity.architectureVariant == .arm64e else {
                throw DatabaseError.reconstructionCheckpointConflict(
                    "fresh load admission requires verified thin ARM64 Mach-O identity and layout"
                )
            }
            guard detached.image.imageSlot == .primary,
                  detached.image.architecture == .arm64 || detached.image.architecture == .arm64e,
                  binary.selectedSliceIndex == nil, binary.elfArchiveMemberIdentity == nil,
                  binary.machOSelectedSliceFact?.containerKind == .thin,
                  UInt64(analysis.imageBytes.count) == detached.artifact.contentIdentity.byteCount,
                  recomputed.imageBytesSHA256 == detached.artifact.contentIdentity.digest else {
                throw DatabaseError.reconstructionCheckpointConflict(
                    "fresh load admission supports one complete thin ARM64 artifact; subset and archive images are unsupported"
                )
            }
            let sources = try reconstructionAttachmentVault.availableSources(for: [detached.artifact.contentIdentity])
            guard let source = sources.first, source.verifiedURL.path == binary.path else { throw invalid }
            try ReconstructionAttachmentDescriptorReader.validate(source)
            let inserted = try insertBinary(BinaryRecord(id: nil, uuid: binary.id, workspaceID: workspaceRowID,
                name: binary.name, path: binary.path, originalPathBookmark: binary.originalPathBookmark,
                kind: binary.kind, architecture: binary.architecture, fileHash: recomputed.imageBytesSHA256,
                fileSize: Int64(analysis.imageBytes.count), hexBytes: analysis.imageBytes,
                isBundle: binary.kind.localizedCaseInsensitiveContains("bundle"), imageSlot: binary.slot.rawValue,
                selectedSliceIndex: binary.selectedSliceIndex,
                machOSelectedSliceFact: binary.machOSelectedSliceFact,
                analysisInputFingerprintJSON: try Self.encodeAnalysisInputFingerprintJSON(recomputed),
                metadata: binary.metadata, elfArchiveMemberIdentity: binary.elfArchiveMemberIdentity))
            guard let binaryRowID = inserted.id else { throw DatabaseError.notFound }
            try insertAnalysisContents(analysis, into: binaryRowID)
        }
    }

    private func validateReconstructionWorkspaceAnalysisAuthority(
        workspaceID: UUID,
        authority: ReconstructionFreshnessAuthority
    ) throws {
        guard let workspaceRowID = try workspaceRecord(workspaceUUID: workspaceID)?.id else {
            throw DatabaseError.notFound
        }
        let persistedBinaries = try binaries(workspaceID: workspaceRowID)
        let binariesByID = Dictionary(uniqueKeysWithValues: persistedBinaries.map {
            ($0.uuid, $0)
        })
        for coordinate in authority.currentImages {
            try Task.checkCancellation()
            let image = coordinate.image
            guard let binary = binariesByID[image.binaryID],
                  binary.imageSlot == image.imageSlot.rawValue,
                  binary.selectedSliceIndex == image.selectedSliceIndex,
                  Self.reconstructionArchitecture(binary.architecture) == image.architecture,
                  let fingerprint = try Self.decodeAnalysisInputFingerprintJSON(
                      binary.analysisInputFingerprintJSON
                  ),
                  fingerprint.binaryID == binary.uuid,
                  fingerprint.binaryID == image.binaryID,
                  fingerprint.imageSlot == image.imageSlot,
                  fingerprint.binaryName == binary.name,
                  fingerprint.binaryPath == binary.path,
                  fingerprint.selectedSliceIndex == image.selectedSliceIndex,
                  fingerprint.elfArchiveMemberIdentity == binary.elfArchiveMemberIdentity,
                  fingerprint.artifactIdentity == image.machOIdentity,
                  binary.fileSize >= 0,
                  UInt64(binary.fileSize) == fingerprint.imageByteCount,
                  binary.fileHash == fingerprint.imageBytesSHA256,
                  fingerprint.overallSHA256 == coordinate.analysisFingerprintSHA256 else {
                throw DatabaseError.reconstructionCheckpointConflict(
                    "workspace analysis authority changed"
                )
            }
        }
    }

    private static func reconstructionArchitecture(
        _ rawValue: String
    ) -> ReconstructionArchitecture {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ReconstructionArchitecture(rawValue: normalized) ?? .unknown
    }

    private func reconstructionCheckpointProjectionScope(
        in state: ReconstructionWorkspaceState,
        projectID: UUID
    ) throws -> ReconstructionCheckpointProjectionScope {
        let history = try reconstructionCorpusHistoryIndex(in: state)
        let jobsByID = Dictionary(uniqueKeysWithValues: state.jobs.map { ($0.jobID, $0) })
        let checkpointsByID = Dictionary(
            uniqueKeysWithValues: state.checkpoints.map { ($0.checkpointID, $0) }
        )

        func subjectProjectID(_ subject: ReconstructionSubjectCoordinate) throws -> UUID {
            let artifact: ReconstructionArtifactCoordinate
            switch subject {
            case .artifact(let value): artifact = value
            case .image(let value): artifact = value.artifact
            case .function(let value): artifact = value.artifact
            }
            guard let occurrence = history.occurrencesByID[artifact.occurrenceID],
                  occurrence.record.contentIdentity == artifact.contentIdentity else {
                throw DatabaseError.reconstructionStateInvalid(
                    "checkpoint subject project authority"
                )
            }
            return occurrence.projectID
        }

        var projectEvidence: [ReconstructionEvidenceRecord] = []
        projectEvidence.reserveCapacity(state.evidence.count)
        var evidenceProjectByID: [UUID: UUID] = [:]
        for record in state.evidence {
            try Task.checkCancellation()
            guard let creatingJob = jobsByID[record.creatingJobID] else {
                throw DatabaseError.reconstructionStateInvalid(
                    "checkpoint evidence project authority"
                )
            }
            let subjectProject = try subjectProjectID(record.subject)
            guard subjectProject == creatingJob.reconstructionProjectID else {
                throw DatabaseError.reconstructionStateInvalid(
                    "checkpoint foreign evidence authority"
                )
            }
            evidenceProjectByID[record.evidenceID] = creatingJob.reconstructionProjectID
            if creatingJob.reconstructionProjectID == projectID {
                projectEvidence.append(record)
            }
        }

        var projectGaps: [ReconstructionEvidenceGap] = []
        projectGaps.reserveCapacity(state.evidenceGaps.count)
        for gap in state.evidenceGaps {
            try Task.checkCancellation()
            if try subjectProjectID(gap.subject) == projectID {
                projectGaps.append(gap)
            }
        }

        let projectEvidenceIDs = Set(projectEvidence.map(\.evidenceID))
        let projectGapIDs = Set(projectGaps.map(\.gapID))
        for record in projectEvidence {
            guard record.citations.allSatisfy({ citation in
                citation.sourceEvidenceID.map(projectEvidenceIDs.contains) ?? true
            }),
            record.supersedesEvidenceID.map(projectEvidenceIDs.contains) ?? true,
            record.supersededByEvidenceID.map(projectEvidenceIDs.contains) ?? true else {
                throw DatabaseError.reconstructionStateInvalid(
                    "checkpoint foreign evidence dependency authority"
                )
            }
        }
        for receipt in state.toolReceipts {
            guard let receiptProject = jobsByID[receipt.jobID]?.reconstructionProjectID,
                  receipt.outputEvidenceIDs.allSatisfy({
                      evidenceProjectByID[$0] == receiptProject
                  }) else {
                throw DatabaseError.reconstructionStateInvalid(
                    "checkpoint foreign tool receipt authority"
                )
            }
        }
        for receipt in state.modelReceipts {
            guard let receiptProject = jobsByID[receipt.jobID]?.reconstructionProjectID,
                  receipt.acceptedEvidenceIDs.allSatisfy({
                      evidenceProjectByID[$0] == receiptProject
                  }) else {
                throw DatabaseError.reconstructionStateInvalid(
                    "checkpoint foreign model receipt authority"
                )
            }
        }
        var projectRelations: [ReconstructionEvidenceRelation] = []
        projectRelations.reserveCapacity(state.evidenceRelations.count)
        for relation in state.evidenceRelations {
            try Task.checkCancellation()
            let sourceIsInProject = projectEvidenceIDs.contains(relation.sourceEvidenceID)
            let targetIsInProject = relation.kind == .resolvesGap
                ? projectGapIDs.contains(relation.targetEvidenceID)
                : projectEvidenceIDs.contains(relation.targetEvidenceID)
            guard sourceIsInProject == targetIsInProject else {
                throw DatabaseError.reconstructionStateInvalid(
                    "checkpoint foreign relation authority"
                )
            }
            if sourceIsInProject { projectRelations.append(relation) }
        }

        var revisions: [UUID: UInt64] = [:]
        for checkpointID in Set(projectEvidence.map(\.creatingCheckpointID)) {
            try Task.checkCancellation()
            guard let checkpoint = checkpointsByID[checkpointID],
                  jobsByID[checkpoint.jobID]?.reconstructionProjectID == projectID else {
                throw DatabaseError.reconstructionStateInvalid(
                    "evidence checkpoint revision authority"
                )
            }
            revisions[checkpointID] = checkpoint.revision
        }
        return ReconstructionCheckpointProjectionScope(
            evidence: projectEvidence,
            evidenceRelations: projectRelations,
            evidenceGaps: projectGaps,
            checkpointRevisionsByID: revisions
        )
    }

    private func validateReconstructionCheckpointProjection(
        _ state: ReconstructionWorkspaceState,
        job: ReconstructionJobRecord,
        successor: ReconstructionCheckpoint,
        authority: ReconstructionFreshnessAuthority
    ) throws {
        do {
            try Task.checkCancellation()
            guard authority.corpusManifestSHA256 == job.creationCorpusManifestSHA256,
                  authority.corpusManifestSHA256 == successor.corpusManifestSHA256 else {
                throw DatabaseError.reconstructionStateInvalid(
                    "checkpoint freshness authority corpus"
                )
            }

            let history = try reconstructionCorpusHistoryIndex(in: state)
            guard let retainedManifest = history.manifest(
                projectID: job.reconstructionProjectID,
                canonicalSHA256: successor.corpusManifestSHA256
            ) else {
                throw DatabaseError.reconstructionStateInvalid(
                    "checkpoint freshness authority manifest"
                )
            }
            let retainedArtifacts = Set(retainedManifest.artifacts.map {
                ReconstructionArtifactCoordinate(
                    occurrenceID: $0.occurrenceID,
                    contentIdentity: $0.contentIdentity
                )
            })
            guard Set(authority.currentArtifacts) == retainedArtifacts else {
                throw DatabaseError.reconstructionStateInvalid(
                    "checkpoint freshness authority artifacts"
                )
            }

            let projectScope = try reconstructionCheckpointProjectionScope(
                in: state,
                projectID: job.reconstructionProjectID
            )

            // A resolves-gap target occupies the gap UUID domain. It is intentionally absent from
            // the evidence dependency graph, then restored for the explicit gap projection below.
            let evidenceRelations = projectScope.evidenceRelations.filter {
                $0.kind != .resolvesGap
            }
            let evidenceProjection = try ReconstructionEvidenceProjector().project(
                records: projectScope.evidence,
                relations: evidenceRelations,
                authority: authority
            )
            let projectedClassifications = Dictionary(
                uniqueKeysWithValues: evidenceProjection.records.map {
                    ($0.record.evidenceID, $0.classification)
                }
            )

            let evidenceFrontierSHA256 = try ReconstructionEvidenceFrontier.canonicalSHA256(
                corpusManifestSHA256: authority.corpusManifestSHA256,
                records: projectScope.evidence,
                projectedClassificationsByEvidenceID: projectedClassifications,
                relations: projectScope.evidenceRelations,
                gaps: projectScope.evidenceGaps,
                checkpointRevisionsByID: projectScope.checkpointRevisionsByID
            )
            guard evidenceFrontierSHA256 == successor.evidenceFrontierSHA256 else {
                throw DatabaseError.reconstructionCheckpointConflict(
                    "evidence frontier changed"
                )
            }

            let gapProjection = try ReconstructionGapProjector().project(
                gaps: projectScope.evidenceGaps,
                records: projectScope.evidence,
                relations: projectScope.evidenceRelations,
                projectedClassificationsByEvidenceID: projectedClassifications
            )
            guard gapProjection.unresolvedGapFrontierSHA256
                    == successor.unresolvedEvidenceGapSHA256 else {
                throw DatabaseError.reconstructionCheckpointConflict(
                    "unresolved evidence gap frontier changed"
                )
            }
            try Task.checkCancellation()
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch let error as DatabaseError {
            throw error
        } catch {
            throw DatabaseError.reconstructionStateInvalid(
                "checkpoint evidence projection: \(String(describing: error))"
            )
        }
    }

    /// The durable job/task lifecycle timestamps of one workspace (see
    /// `ensureReconstructionLifecycleTimestampSchema`). Rows without any observed time are omitted.
    func reconstructionLifecycleTimestamps(workspaceID: UUID) throws -> ReconstructionLifecycleTimestamps {
        let rows = try reconstructionLifecycleRows(workspaceID: workspaceID)
        return .init(jobs: rows.jobs.compactMapValues { $0.times.isEmpty ? nil : $0.times },
                     tasks: rows.tasks.compactMapValues { $0.times.isEmpty ? nil : $0.times })
    }

    private struct ReconstructionLifecycleRow {
        let state: String
        let times: ReconstructionLifecycleTimes
    }

    private func reconstructionLifecycleRows(
        workspaceID: UUID
    ) throws -> (jobs: [UUID: ReconstructionLifecycleRow], tasks: [UUID: ReconstructionLifecycleRow]) {
        func read(_ table: String, idColumn: String) throws -> [UUID: ReconstructionLifecycleRow] {
            let rows: [(UUID, ReconstructionLifecycleRow)] = try query(
                """
                SELECT \(idColumn), state, created_at_ms, started_at_ms, finished_at_ms
                FROM \(table) WHERE workspace_uuid = ?;
                """,
                bindings: [.text(workspaceID.uuidString)],
                map: { statement in
                    let raw = try Self.textColumn(statement, 0)
                    guard let id = UUID(uuidString: raw) else { throw DatabaseError.invalidUUID(raw) }
                    func time(_ index: Int32) -> UInt64? {
                        sqlite3_column_type(statement, index) == SQLITE_NULL
                            ? nil : UInt64(clamping: sqlite3_column_int64(statement, index))
                    }
                    return (id, ReconstructionLifecycleRow(state: try Self.textColumn(statement, 1),
                        times: .init(createdAtMilliseconds: time(2), startedAtMilliseconds: time(3),
                                     finishedAtMilliseconds: time(4))))
                }
            )
            return Dictionary(rows, uniquingKeysWith: { first, _ in first })
        }
        return (try read("reconstruction_jobs", idColumn: "job_id"),
                try read("reconstruction_tasks", idColumn: "task_id"))
    }

    /// Lifecycle of a row being (re)written: a row first seen in a non-terminal state is created
    /// now (and started now unless it is still in its initial state); a row first seen already
    /// terminal is an imported/replayed copy whose lifecycle was not observed (all nil). An
    /// existing row keeps its times, gains `started` when it leaves the initial state and
    /// `finished` when it becomes terminal, and loses `finished` if it is resumed. Rows from before
    /// the columns existed (no `created`) stay nil rather than gaining a misleading partial clock.
    private static func stampedLifecycle(
        prior: ReconstructionLifecycleRow?, initial: Bool, terminal: Bool, now: UInt64
    ) -> ReconstructionLifecycleTimes {
        guard let prior else {
            if terminal { return .init() }
            return .init(createdAtMilliseconds: now, startedAtMilliseconds: initial ? nil : now)
        }
        guard prior.times.createdAtMilliseconds != nil else { return prior.times }
        var times = prior.times
        if !initial, times.startedAtMilliseconds == nil { times.startedAtMilliseconds = now }
        times.finishedAtMilliseconds = terminal ? (times.finishedAtMilliseconds ?? now) : nil
        return times
    }

    private static func lifecycleBindings(_ times: ReconstructionLifecycleTimes) -> [Binding] {
        [times.createdAtMilliseconds, times.startedAtMilliseconds, times.finishedAtMilliseconds].map {
            $0.map { .int64(Int64(clamping: $0)) } ?? .null
        }
    }

    private func validateReconstructionRowProjection(
        workspaceID: UUID,
        state: ReconstructionWorkspaceState
    ) throws {
        let expected = try expectedReconstructionProjectionRows(
            workspaceID: workspaceID,
            state: state
        )
        let actual = try reconstructionProjectionRows(workspaceID: workspaceID)
        for table in Self.reconstructionProjectionColumns.keys.sorted() {
            guard Self.reconstructionProjectionRowCounts(actual[table] ?? [])
                    == Self.reconstructionProjectionRowCounts(expected[table] ?? []) else {
                throw DatabaseError.reconstructionIdentityConflict("\(table) projected rows")
            }
        }
    }

    private func expectedReconstructionProjectionRows(
        workspaceID: UUID,
        state: ReconstructionWorkspaceState
    ) throws -> [String: [[ReconstructionProjectionCell]]] {
        let workspace = workspaceID.uuidString
        let stateJSON = try reconstructionCanonicalBytes(state)
        let corpusHistory = try reconstructionCorpusHistoryIndex(in: state)
        var expected: [String: [[ReconstructionProjectionCell]]] = Dictionary(
            uniqueKeysWithValues: Self.reconstructionProjectionColumns.keys.map { ($0, []) }
        )
        expected["reconstruction_projects"] = try state.projects.map { project in
            [
                .text(workspace), .text(project.projectID.uuidString),
                Self.reconstructionProjectionText(project.currentCorpusManifestSHA256),
                .blob(try reconstructionCanonicalBytes(project)), .blob(stateJSON),
            ]
        }

        var contents: [String: ReconstructionContentIdentity] = [:]
        for occurrenceEntry in corpusHistory.occurrencesByID.values {
            let occurrence = occurrenceEntry.record
            contents[occurrence.contentIdentity.digest] = occurrence.contentIdentity
        }
        expected["reconstruction_artifact_contents"] = try contents.values.map { content in
            [
                .text(workspace), .text(content.digest), .text(content.algorithm.rawValue),
                try reconstructionProjectionInteger(content.byteCount),
                .blob(try reconstructionCanonicalBytes(content)),
            ]
        }

        for occurrenceEntry in corpusHistory.occurrencesByID.values {
            let project = occurrenceEntry.projectID.uuidString
            let occurrence = occurrenceEntry.record
            expected["reconstruction_artifact_occurrences", default: []].append([
                .text(workspace), .text(project),
                .text(occurrence.occurrenceID.rawValue.uuidString),
                .text(occurrence.contentIdentity.digest), .text(occurrence.kind.rawValue),
                .integer(occurrence.executableMode ? 1 : 0),
                .blob(try reconstructionCanonicalBytes(occurrence)),
            ])
            for (ordinal, role) in occurrence.roles.enumerated() {
                expected["reconstruction_artifact_roles", default: []].append([
                    .text(workspace), .text(project),
                    .text(occurrence.occurrenceID.rawValue.uuidString), .text(role.rawValue),
                    .integer(Int64(ordinal)),
                ])
            }
        }
        for relationEntry in corpusHistory.relationsByID.values {
            let project = relationEntry.projectID.uuidString
            let relation = relationEntry.record
            expected["reconstruction_artifact_relations", default: []].append([
                .text(workspace), .text(project), .text(relation.relationID.uuidString),
                .text(relation.kind.rawValue),
                .text(relation.sourceOccurrenceID.rawValue.uuidString),
                Self.reconstructionProjectionText(
                    relation.targetOccurrenceID?.rawValue.uuidString
                ),
                .text(relation.canonicalSHA256),
                .blob(try reconstructionCanonicalBytes(relation)),
            ])
        }

        expected["reconstruction_jobs"] = try state.jobs.map { job in
            [
                .text(workspace), .text(job.jobID.uuidString),
                .text(job.reconstructionProjectID.uuidString),
                Self.reconstructionProjectionText(job.currentCheckpointID?.uuidString),
                .text(job.state.rawValue), .blob(try reconstructionCanonicalBytes(job)),
            ]
        }
        expected["reconstruction_tasks"] = try state.tasks.map { task in
            [
                .text(workspace), .text(task.identity.taskID.uuidString),
                .text(task.identity.jobID.uuidString), .text(task.state.rawValue),
                .blob(try reconstructionCanonicalBytes(task)),
            ]
        }
        expected["reconstruction_checkpoints"] = try state.checkpoints.map { checkpoint in
            [
                .text(workspace), .text(checkpoint.checkpointID.uuidString),
                .text(checkpoint.jobID.uuidString),
                try reconstructionProjectionInteger(checkpoint.revision),
                Self.reconstructionProjectionText(checkpoint.parentCheckpointID?.uuidString),
                .text(checkpoint.canonicalSHA256),
                .blob(try reconstructionCanonicalBytes(checkpoint)),
            ]
        }
        for checkpoint in state.checkpoints {
            let buckets: [(String, [UUID])] = [
                ("pending", checkpoint.pendingTaskIDs),
                ("running", checkpoint.runningTaskIDs),
                ("completed", checkpoint.completedTaskIDs),
                ("failed", checkpoint.failedTaskIDs),
                ("blocked", checkpoint.blockedTaskIDs),
            ]
            for (bucket, taskIDs) in buckets {
                for (ordinal, taskID) in taskIDs.enumerated() {
                    expected["reconstruction_checkpoint_tasks", default: []].append([
                        .text(workspace), .text(checkpoint.checkpointID.uuidString),
                        .text(taskID.uuidString), .text(bucket), .integer(Int64(ordinal)),
                    ])
                }
            }
        }

        expected["reconstruction_tool_receipts"] = try state.toolReceipts.map { receipt in
            [
                .text(workspace), .text(receipt.receiptID.uuidString),
                .text(receipt.jobID.uuidString), .text(receipt.taskID.uuidString),
                .text(receipt.canonicalSHA256),
                .blob(try reconstructionCanonicalBytes(receipt)),
            ]
        }
        expected["reconstruction_model_receipts"] = try state.modelReceipts.map { receipt in
            [
                .text(workspace), .text(receipt.receiptID.uuidString),
                .text(receipt.jobID.uuidString), .text(receipt.taskID.uuidString),
                .text(receipt.canonicalSHA256),
                .blob(try reconstructionCanonicalBytes(receipt)),
            ]
        }
        expected["reconstruction_final_results"] = try state.finalResults.map { result in
            [
                .text(workspace), .text(result.resultID.uuidString),
                .text(result.jobID.uuidString), .text(result.taskID.uuidString),
                .text(result.checkpointID.uuidString),
                try reconstructionProjectionInteger(result.checkpointRevision),
                .text(result.requestID.uuidString), .text(result.requestIdentitySHA256),
                .text(result.kind.rawValue),
                try reconstructionProjectionInteger(result.payloadByteCount),
                .text(result.payloadSHA256), .text(result.producer.canonicalSHA256),
                .text(result.modelReceiptID.uuidString), .text(result.canonicalSHA256),
                .blob(try reconstructionCanonicalBytes(result)),
            ]
        }
        for item in state.evidence {
            expected["reconstruction_evidence", default: []].append([
                .text(workspace), .text(item.evidenceID.uuidString),
                .text(item.classification.rawValue), .text(item.payloadSHA256),
                .blob(try reconstructionCanonicalBytes(item)),
            ])
            for citation in item.citations {
                expected["reconstruction_evidence_citations", default: []].append([
                    .text(workspace), .text(item.evidenceID.uuidString),
                    .text(citation.citationID.uuidString),
                    Self.reconstructionProjectionText(citation.sourceEvidenceID?.uuidString),
                    .blob(try reconstructionCanonicalBytes(citation)),
                ])
            }
        }
        expected["reconstruction_evidence_relations"] = try state.evidenceRelations.map {
            relation in
            [
                .text(workspace), .text(relation.relationID.uuidString),
                .text(relation.kind.rawValue), .text(relation.sourceEvidenceID.uuidString),
                .text(relation.targetEvidenceID.uuidString),
                .blob(try reconstructionCanonicalBytes(relation)),
            ]
        }
        return expected
    }

    private func reconstructionProjectionRows(
        workspaceID: UUID
    ) throws -> [String: [[ReconstructionProjectionCell]]] {
        var result: [String: [[ReconstructionProjectionCell]]] = [:]
        for table in Self.reconstructionProjectionColumns.keys.sorted() {
            guard let columns = Self.reconstructionProjectionColumns[table] else { continue }
            result[table] = try query(
                "SELECT \(columns.joined(separator: ", ")) FROM \(table) WHERE workspace_uuid = ?;",
                bindings: [.text(workspaceID.uuidString)]
            ) { statement in
                try columns.indices.map { index in
                    try Self.reconstructionProjectionCell(statement, Int32(index))
                }
            }
        }
        return result
    }

    private func reconstructionProjectionInteger(
        _ value: UInt64
    ) throws -> ReconstructionProjectionCell {
        guard let signed = Int64(exactly: value) else {
            throw DatabaseError.invalidAddress(value)
        }
        return .integer(signed)
    }

    private static func reconstructionProjectionText(
        _ value: String?
    ) -> ReconstructionProjectionCell {
        value.map(ReconstructionProjectionCell.text) ?? .null
    }

    private static func reconstructionProjectionCell(
        _ statement: OpaquePointer,
        _ index: Int32
    ) throws -> ReconstructionProjectionCell {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return .null
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, index).bitPattern)
        case SQLITE_TEXT:
            return .text(try textColumn(statement, index))
        case SQLITE_BLOB:
            return .blob(blobColumn(statement, index))
        default:
            throw DatabaseError.reconstructionIdentityConflict(
                "unsupported SQLite projection storage class"
            )
        }
    }

    private static func reconstructionProjectionRowCounts(
        _ rows: [[ReconstructionProjectionCell]]
    ) -> [[ReconstructionProjectionCell]: Int] {
        rows.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    private static func reconstructionProjectionSnapshot(
        _ rowsByTable: [String: [[ReconstructionProjectionCell]]]
    ) -> [String] {
        rowsByTable.keys.sorted().flatMap { table in
            (rowsByTable[table] ?? []).map { row in
                let cells = row.map { cell -> String in
                    switch cell {
                    case .null:
                        return "n"
                    case .integer(let value):
                        return "i:\(value)"
                    case .real(let bitPattern):
                        return "r:\(bitPattern)"
                    case .text(let value):
                        return "t:\(Data(value.utf8).base64EncodedString())"
                    case .blob(let value):
                        return "b:\(value.base64EncodedString())"
                    }
                }.joined(separator: ",")
                return "\(table):\(cells)"
            }.sorted()
        }
    }

    private func reconstructionRowCount(workspaceID: UUID) throws -> Int {
        var count = 0
        for table in [
            "reconstruction_projects", "reconstruction_artifact_contents",
            "reconstruction_artifact_occurrences", "reconstruction_artifact_roles",
            "reconstruction_artifact_relations", "reconstruction_evidence",
            "reconstruction_evidence_citations", "reconstruction_evidence_relations",
            "reconstruction_tool_receipts", "reconstruction_model_receipts",
            "reconstruction_jobs", "reconstruction_tasks", "reconstruction_checkpoints",
            "reconstruction_checkpoint_tasks", "reconstruction_final_results",
        ] {
            count += try first(
                "SELECT COUNT(*) FROM \(table) WHERE workspace_uuid = ?;",
                bindings: [.text(workspaceID.uuidString)],
                map: { Int(sqlite3_column_int64($0, 0)) }
            ) ?? 0
        }
        return count
    }

    private func reconstructionCanonicalBytes<T: Encodable>(_ value: T) throws -> Data {
        do { return try ReconstructionCanonicalJSON.encode(value) }
        catch { throw DatabaseError.reconstructionStateInvalid("canonical encoding: \(error)") }
    }

    private static func optionalTextBinding(_ value: String?) -> Binding {
        value.map(Binding.text) ?? .null
    }

    func workspaceRecord(workspaceUUID: UUID) throws -> WorkspaceRecord? {
        try first(
            """
            SELECT id, uuid, name, created_at, modified_at
            FROM workspaces
            WHERE uuid = ?;
            """,
            bindings: [.text(workspaceUUID.uuidString)],
            map: Self.workspaceRecord
        )
    }

    func packageManifest(
        workspaceID: Int64,
        documentID: UUID = UUID(),
        inputCopyingDecision: WorkspaceInputCopyingDecision = .copyInputsIntoPackage,
        bookmarkResolutionDecision: WorkspaceBookmarkResolutionDecision = .resolveStoredBookmarks,
        phase2ShellSession: WorkspacePackagePhase2ShellSession? = nil
    ) throws -> WorkspacePackageManifest? {
        guard let projection = try packageProjection(workspaceID: workspaceID) else { return nil }
        return try packageManifest(
            projection: projection,
            documentID: documentID,
            inputCopyingDecision: inputCopyingDecision,
            bookmarkResolutionDecision: bookmarkResolutionDecision,
            phase2ShellSession: phase2ShellSession
        )
    }

    func packageComponents(
        workspaceID: Int64,
        documentID: UUID,
        inputCopyingDecision: WorkspaceInputCopyingDecision,
        bookmarkResolutionDecision: WorkspaceBookmarkResolutionDecision,
        phase2ShellSession: WorkspacePackagePhase2ShellSession?
    ) throws -> WorkspacePackageComponents {
        guard let projection = try packageProjection(workspaceID: workspaceID) else {
            throw DatabaseError.notFound
        }
        let manifest = try packageManifest(
            projection: projection,
            documentID: documentID,
            inputCopyingDecision: inputCopyingDecision,
            bookmarkResolutionDecision: bookmarkResolutionDecision,
            phase2ShellSession: phase2ShellSession
        )
        var attachmentsByBinaryID: [UUID: Data] = [:]
        for binary in projection.binaryRecords {
            if let hexBytes = binary.hexBytes {
                attachmentsByBinaryID[binary.uuid] = hexBytes
            } else if binary.fileSize == 0 {
                attachmentsByBinaryID[binary.uuid] = Data()
            } else {
                throw DatabaseError.missingPackageAttachmentData(binary.uuid)
            }
        }
        return WorkspacePackageComponents(
            manifest: manifest,
            attachmentsByBinaryID: attachmentsByBinaryID
        )
    }

    private struct WorkspacePackageProjection {
        let workspaceID: Int64
        let persistedWorkspace: PersistedWorkspace
        let binaryRecords: [BinaryRecord]
    }

    private func packageProjection(
        workspaceID: Int64
    ) throws -> WorkspacePackageProjection? {
        guard let persistedWorkspace = try loadWorkspaceState(workspaceID: workspaceID) else {
            return nil
        }
        guard persistedWorkspace.logicalBreakpointCatalogAvailability == .available else {
            throw DatabaseError.logicalBreakpointCatalogUnavailable
        }
        guard persistedWorkspace.launchProfileCatalogAvailability == .available else {
            throw DatabaseError.launchProfileCatalogUnavailable
        }
        try Self.validateArtifactIntegrityForSave(persistedWorkspace.snapshot)
        return WorkspacePackageProjection(
            workspaceID: workspaceID,
            persistedWorkspace: persistedWorkspace,
            binaryRecords: try binaries(workspaceID: workspaceID)
        )
    }

    private func packageManifest(
        projection: WorkspacePackageProjection,
        documentID: UUID,
        inputCopyingDecision: WorkspaceInputCopyingDecision,
        bookmarkResolutionDecision: WorkspaceBookmarkResolutionDecision,
        phase2ShellSession: WorkspacePackagePhase2ShellSession?
    ) throws -> WorkspacePackageManifest {
        let persistedWorkspace = projection.persistedWorkspace
        let binaries = projection.binaryRecords.map { binary in
            let attachmentData = binary.hexBytes
            return WorkspacePackageBinary(
                id: binary.uuid,
                displayName: binary.name,
                originalPath: binary.path,
                originalPathBookmark: binary.originalPathBookmark,
                attachmentRelativePath: MacScopeDocumentPackage.attachmentRelativePath(
                    for: binary.uuid,
                    originalPath: binary.path
                ),
                kind: binary.kind,
                architecture: binary.architecture,
                fileHash: attachmentData.map(MacScopeDocumentPackage.fileHash(for:)) ?? binary.fileHash,
                fileSize: attachmentData.map { Int64($0.count) } ?? binary.fileSize,
                metadata: binary.metadata == .empty ? nil : binary.metadata,
                selectedSliceIndex: binary.selectedSliceIndex,
                machOSelectedSliceFact: binary.machOSelectedSliceFact,
                elfArchiveMemberIdentity: binary.elfArchiveMemberIdentity,
                slot: ImageSlot(rawValue: binary.imageSlot)
            )
        }
        let writesVersion2 = binaries.count > 1 || binaries.contains { $0.slot != .primary }
        let formatVersion = writesVersion2
            ? WorkspacePackageManifest.multiImageFormatVersion
            : WorkspacePackageManifest.currentFormatVersion
        let imageAnalyses: [WorkspacePackageImageAnalysis]? = writesVersion2
            ? binaries.map { binary in
                // A bucketless binary is valid (see the DB-save note); export it as an empty image.
                let imageAnalysis = persistedWorkspace.snapshot.analysis(in: binary.slot) ?? ImageAnalysis()
                return WorkspacePackageImageAnalysis(
                    binaryID: binary.id,
                    imageSlot: binary.slot,
                    analysis: WorkspacePackageAnalysis(imageAnalysis: imageAnalysis)
                )
            }
            : nil

        return WorkspacePackageManifest(
            formatVersion: formatVersion,
            documentID: documentID,
            workspaceUUID: persistedWorkspace.workspace.uuid,
            workspaceName: persistedWorkspace.workspace.name,
            createdAt: persistedWorkspace.workspace.createdAt,
            modifiedAt: persistedWorkspace.workspace.modifiedAt,
            inputCopyingDecision: inputCopyingDecision,
            bookmarkResolutionDecision: bookmarkResolutionDecision,
            binaries: binaries,
            analysis: writesVersion2
                ? WorkspacePackageAnalysis(authoringFrom: persistedWorkspace.snapshot)
                : WorkspacePackageAnalysis(snapshot: persistedWorkspace.snapshot),
            imageAnalyses: imageAnalyses,
            session: WorkspacePackageSession(
                selectedSidebarItemID: persistedWorkspace.session.selectedSidebarItemID,
                selectedAddress: persistedWorkspace.session.selectedAddress,
                selectedTool: persistedWorkspace.session.selectedTool,
                editorMode: persistedWorkspace.session.editorMode,
                isInspectorPresented: persistedWorkspace.session.isInspectorPresented,
                sidebarSearchText: persistedWorkspace.session.sidebarSearchText,
                updatedAt: persistedWorkspace.session.updatedAt,
                focusedImageSlot: persistedWorkspace.session.focusedImageSlot,
                phase2ShellSession: phase2ShellSession
                    ?? persistedWorkspace.phase2ShellSessionRecord?.shellSession
            ),
            assistantSessionRecords: try allPhase2AssistantSessionRecords(
                workspaceID: projection.workspaceID
            )
                .sorted { lhs, rhs in
                    if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
                    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                .map(Self.workspacePackageAssistantSessionRecord),
            runtimeAuthorityRecords: try phase2RuntimeAuthorityRecords(
                workspaceID: projection.workspaceID
            )
                .sorted { $0.createdAt < $1.createdAt }
                .map(Self.workspacePackageRuntimeAuthorityRecord),
            // HS-2: stamp the analyzer that wrote this workspace.
            analyzer: .current
        )
    }

    static func withVerifiedReconstructionAttachmentSourceErrorMapping<Value>(
        _ operation: () throws -> Value
    ) throws -> Value {
        do {
            return try operation()
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch let error as DatabaseError {
            throw error
        } catch {
            throw DatabaseError.reconstructionAttachmentSourcesUnavailable
        }
    }

    private func verifiedReconstructionAttachmentSources(
        workspaceID: Int64,
        state: ReconstructionWorkspaceState,
        fileManager: FileManager
    ) throws -> [ReconstructionAttachmentSource] {
        let expectedContents = try ReconstructionPackageCodec.contentRecords(in: state)
        guard !expectedContents.isEmpty else { return [] }

        return try Self.withVerifiedReconstructionAttachmentSourceErrorMapping {
            guard let workspace = try workspace(id: workspaceID),
                  let document = try workspaceDocument(workspaceID: workspaceID),
                  !document.packagePath.isEmpty else {
                throw DatabaseError.reconstructionAttachmentSourcesUnavailable
            }
            let sourceRoot = try Self.canonicalPackageURL(
                from: URL(fileURLWithPath: document.packagePath, isDirectory: true),
                fileManager: fileManager
            )
            let package = try MacScopeDocumentPackage.openPackage(
                from: sourceRoot,
                fileManager: fileManager
            )
            guard package.manifest.workspaceUUID == workspace.uuid,
                  package.manifest.documentID == document.documentID,
                  package.reconstructionState == state else {
                throw DatabaseError.reconstructionAttachmentSourcesUnavailable
            }

            let expectedByDigest = Dictionary(
                uniqueKeysWithValues: expectedContents.map {
                    ($0.contentIdentity.digest, $0.contentIdentity)
                }
            )
            let sources = package.reconstructionAttachmentSources
            guard sources.count == expectedByDigest.count,
                  sources.allSatisfy({ source in
                      expectedByDigest[source.contentIdentity.digest] == source.contentIdentity
                  }) else {
                throw DatabaseError.reconstructionAttachmentSourcesUnavailable
            }
            return sources.sorted {
                $0.contentIdentity.digest < $1.contentIdentity.digest
            }
        }
    }

    @discardableResult
    func writePackage(
        workspaceID: Int64,
        documentID: UUID = UUID(),
        to packageURL: URL,
        inputCopyingDecision: WorkspaceInputCopyingDecision = .copyInputsIntoPackage,
        bookmarkResolutionDecision: WorkspaceBookmarkResolutionDecision = .resolveStoredBookmarks,
        phase2ShellSession: WorkspacePackagePhase2ShellSession? = nil,
        fileManager: FileManager = .default
    ) throws -> WorkspacePackageManifest {
        let packageRoot = try Self.canonicalPackageURL(
            from: packageURL,
            fileManager: fileManager
        )
        let components = try packageComponents(
            workspaceID: workspaceID,
            documentID: documentID,
            inputCopyingDecision: inputCopyingDecision,
            bookmarkResolutionDecision: bookmarkResolutionDecision,
            phase2ShellSession: phase2ShellSession
        )
        let reconstructionState = try loadReconstructionState(
            workspaceID: components.manifest.workspaceUUID
        )
        let prepared = try MacScopeDocumentPackage.preparedManifest(
            components.manifest,
            reconstructionState: reconstructionState
        )
        let reconstructionAttachmentSources = try verifiedReconstructionAttachmentSources(
            workspaceID: workspaceID,
            state: reconstructionState,
            fileManager: fileManager
        )

        // Return the manifest actually written (v4 with its instruction sidecar descriptor).
        let manifest = try MacScopeDocumentPackage.writePackage(
            prepared,
            attachmentsByBinaryID: components.attachmentsByBinaryID,
            reconstructionState: reconstructionState,
            reconstructionAttachmentSources: reconstructionAttachmentSources,
            to: packageRoot,
            fileManager: fileManager
        )
        try upsertWorkspaceDocument(
            WorkspaceDocumentRecord(
                workspaceID: workspaceID,
                documentID: manifest.documentID,
                packagePath: packageRoot.path,
                lastOpenedAt: manifest.modifiedAt,
                lastSavedAt: manifest.modifiedAt,
                isDirty: false,
                inputCopyingDecision: inputCopyingDecision,
                bookmarkResolutionDecision: bookmarkResolutionDecision,
                recentDocumentState: .available,
                recentDocumentStateUpdatedAt: manifest.modifiedAt
            )
        )
        return manifest
    }

    @discardableResult
    func importPackage(
        from packageURL: URL,
        fileManager: FileManager = .default,
        openedAt: Date = Date()
    ) throws -> PersistedWorkspace {
        let packageRoot = try Self.canonicalPackageURL(
            from: packageURL,
            fileManager: fileManager
        )
        let package = try MacScopeDocumentPackage.openPackage(
            from: packageRoot,
            fileManager: fileManager
        )
        let importPayload = try packageImportPayload(from: package)

        return try transaction {
            let workspace = try insertWorkspace(
                WorkspaceRecord(
                    id: nil,
                    uuid: importPayload.workspaceUUID,
                    name: importPayload.workspaceName,
                    createdAt: importPayload.createdAt,
                    modifiedAt: importPayload.modifiedAt
                )
            )
            guard let workspaceID = workspace.id else {
                throw DatabaseError.notFound
            }

            try insertSnapshotContents(
                importPayload.snapshot,
                into: workspaceID,
                binaryDataByID: importPayload.attachmentsByBinaryID
            )
            try replaceReconstructionStateRows(
                workspaceID: workspace.uuid,
                state: importPayload.reconstructionState
            )
            if importPayload.launchProfileCatalogAvailability == .unavailable {
                try run(
                    "DELETE FROM launch_profile_catalogs WHERE workspace_id = ?;",
                    bindings: [.int64(workspaceID)]
                )
            }

            let sessionRecord: WorkspaceSessionRecord
            if let packageSession = importPayload.session {
                sessionRecord = WorkspaceSessionRecord(
                    workspaceID: workspaceID,
                    selectedSidebarItemID: packageSession.selectedSidebarItemID,
                    selectedAddress: packageSession.selectedAddress,
                    selectedTool: packageSession.selectedTool,
                    editorMode: packageSession.editorMode,
                    isInspectorPresented: packageSession.isInspectorPresented,
                    sidebarSearchText: packageSession.sidebarSearchText,
                    updatedAt: packageSession.updatedAt,
                    focusedImageSlot: packageSession.focusedImageSlot
                )
            } else {
                sessionRecord = defaultWorkspaceSession(
                    workspaceID: workspaceID,
                    snapshot: importPayload.snapshot,
                    updatedAt: importPayload.modifiedAt
                )
            }

            _ = try upsertWorkspaceSession(sessionRecord)
            for record in importPayload.assistantSessionRecords {
                try upsertPhase2AssistantSessionRecord(
                    Self.phase2AssistantSessionPersistenceRecord(
                        from: record,
                        workspaceID: workspaceID,
                        workspaceUUID: workspace.uuid,
                        documentID: importPayload.documentID
                    )
                )
            }
            for record in importPayload.runtimeAuthorityRecords {
                try upsertPhase2RuntimeAuthorityRecord(
                    Self.phase2RuntimeAuthorityPersistenceRecord(
                        from: record,
                        workspaceID: workspaceID,
                        workspaceUUID: workspace.uuid,
                        documentID: importPayload.documentID
                    )
                )
            }
            if let shellSession = importPayload.session?.phase2ShellSession {
                try upsertPhase2ShellSessionRecord(
                    Phase2ShellSessionPersistenceRecord(
                        workspaceID: workspaceID,
                        workspaceUUID: workspace.uuid,
                        documentID: importPayload.documentID,
                        shellSession: shellSession,
                        updatedAt: importPayload.modifiedAt
                    )
                )
            }
            try upsertWorkspaceDocument(
                WorkspaceDocumentRecord(
                    workspaceID: workspaceID,
                    documentID: importPayload.documentID,
                    packagePath: packageRoot.path,
                    lastOpenedAt: openedAt,
                    lastSavedAt: importPayload.modifiedAt,
                    isDirty: false,
                    inputCopyingDecision: importPayload.inputCopyingDecision,
                    bookmarkResolutionDecision: importPayload.bookmarkResolutionDecision,
                    recentDocumentState: .available,
                    recentDocumentStateUpdatedAt: openedAt
                )
            )
            guard var persisted = try loadWorkspaceState(workspaceID: workspaceID) else {
                throw DatabaseError.notFound
            }
            // HS-2b: carry the open path's repairs so restoring this import notifies and rebuilds.
            persisted.analysisRepairs = package.analysisRepairs
            return persisted
        }
    }

    private struct PackageImportPayload {
        var documentID: UUID
        var workspaceUUID: UUID
        var workspaceName: String
        var createdAt: Date
        var modifiedAt: Date
        var inputCopyingDecision: WorkspaceInputCopyingDecision
        var bookmarkResolutionDecision: WorkspaceBookmarkResolutionDecision
        var snapshot: WorkspaceSnapshot
        var attachmentsByBinaryID: [UUID: Data]
        var session: WorkspacePackageSession?
        var assistantSessionRecords: [WorkspacePackageAssistantSessionRecord]
        var runtimeAuthorityRecords: [WorkspacePackageRuntimeAuthorityRecord]
        var launchProfileCatalogAvailability: DebuggerLaunchProfileCatalogAvailability
        var reconstructionState: ReconstructionWorkspaceState
    }

    private func packageImportPayload(
        from package: WorkspacePackageContents
    ) throws -> PackageImportPayload {
        guard try packageIdentifierCollisionExists(in: package) else {
            return PackageImportPayload(
                documentID: package.manifest.documentID,
                workspaceUUID: package.manifest.workspaceUUID,
                workspaceName: package.manifest.workspaceName,
                createdAt: package.manifest.createdAt,
                modifiedAt: package.manifest.modifiedAt,
                inputCopyingDecision: package.manifest.inputCopyingDecision,
                bookmarkResolutionDecision: package.manifest.bookmarkResolutionDecision,
                snapshot: package.snapshot,
                attachmentsByBinaryID: package.attachmentsByBinaryID,
                session: package.session,
                assistantSessionRecords: package.manifest.assistantSessionRecords,
                runtimeAuthorityRecords: package.manifest.runtimeAuthorityRecords,
                launchProfileCatalogAvailability: package.launchProfileCatalogAvailability,
                reconstructionState: package.reconstructionState
            )
        }

        guard package.reconstructionState == .empty else {
            throw DatabaseError.reconstructionIdentityConflict(
                "package v3 import requires graph-wide identity remapping"
            )
        }

        let binaryIDMap = Self.uuidMap(for: package.snapshot.binaries.map(\.id))
        let imageAnalyses = package.snapshot.binaries.compactMap { package.snapshot.analysis(in: $0.slot) }
        let functionIDMap = Self.uuidMap(for: imageAnalyses.flatMap(\.functions).map(\.id))
        let symbolIDMap = Self.uuidMap(for: imageAnalyses.flatMap(\.symbols).map(\.id))
        let importIDMap = Self.uuidMap(for: imageAnalyses.flatMap(\.imports).map(\.id))
        let indirectSymbolIDMap = Self.uuidMap(for: imageAnalyses.flatMap(\.indirectSymbols).map(\.id))
        let exportIDMap = Self.uuidMap(for: imageAnalyses.flatMap(\.exports).map(\.id))
        let stringLiteralIDMap = Self.uuidMap(for: imageAnalyses.flatMap(\.stringLiterals).map(\.id))
        let basicBlockIDMap = Self.uuidMap(for: imageAnalyses.flatMap(\.basicBlocks).map(\.id))
        let xrefIDMap = Self.uuidMap(for: imageAnalyses.flatMap(\.xrefs).map(\.id))
        let controlFlowEdgeIDMap = Self.uuidMap(for: imageAnalyses.flatMap(\.controlFlowEdges).map(\.id))
        let typeDefinitionIDMap = Self.uuidMap(for: package.snapshot.typeDefinitions.map(\.id))
        let manualXRefIDMap = Self.uuidMap(for: package.snapshot.manualXRefs.map(\.id))
        let bookmarkIDMap = Self.uuidMap(for: package.snapshot.bookmarks.map(\.id))
        let segmentOverrideIDMap = Self.uuidMap(for: package.snapshot.segmentOverrides.map(\.id))
        let runtimeAuthorityRecordIDMap = Self.uuidMap(for: package.manifest.runtimeAuthorityRecords.map(\.id))

        var remappedAttachments: [UUID: Data] = [:]
        for (binaryID, data) in package.attachmentsByBinaryID {
            remappedAttachments[binaryIDMap[binaryID] ?? binaryID] = data
        }

        var remappedAnalysesBySlot: [ImageSlot: ImageAnalysis] = [:]
        for binary in package.snapshot.binaries {
            guard var analysis = package.snapshot.analysis(in: binary.slot) else { continue }
            analysis.functions = analysis.functions.map { function in
                FunctionSummary(
                    id: functionIDMap[function.id] ?? function.id,
                    name: function.name,
                    startAddress: function.startAddress,
                    endAddress: function.endAddress,
                    confidence: function.confidence,
                    noReturnProvenance: function.noReturnProvenance
                )
            }
            analysis.symbols = analysis.symbols.map { symbol in
                SymbolSummary(
                    id: symbolIDMap[symbol.id] ?? symbol.id,
                    name: symbol.name,
                    address: symbol.address,
                    kind: symbol.kind,
                    libraryName: symbol.libraryName,
                    rawLinkageName: symbol.rawLinkageName
                )
            }
            analysis.imports = analysis.imports.map { importedSymbol in
                ImportSummary(
                    id: importIDMap[importedSymbol.id] ?? importedSymbol.id,
                    name: importedSymbol.name,
                    libraryName: importedSymbol.libraryName,
                    libraryOrdinal: importedSymbol.libraryOrdinal
                )
            }
            analysis.indirectSymbols = analysis.indirectSymbols.map { indirectSymbol in
                IndirectSymbolSummary(
                    id: indirectSymbolIDMap[indirectSymbol.id] ?? indirectSymbol.id,
                    kind: indirectSymbol.kind,
                    sourceSection: indirectSymbol.sourceSection,
                    address: indirectSymbol.address,
                    entrySize: indirectSymbol.entrySize,
                    tableIndex: indirectSymbol.tableIndex,
                    rawSymbolIndex: indirectSymbol.rawSymbolIndex,
                    symbolIndex: indirectSymbol.symbolIndex,
                    symbolName: indirectSymbol.symbolName,
                    libraryOrdinal: indirectSymbol.libraryOrdinal,
                    libraryName: indirectSymbol.libraryName,
                    isLocal: indirectSymbol.isLocal,
                    isAbsolute: indirectSymbol.isAbsolute
                )
            }
            analysis.exports = analysis.exports.map { exportedSymbol in
                ExportSummary(
                    id: exportIDMap[exportedSymbol.id] ?? exportedSymbol.id,
                    name: exportedSymbol.name,
                    address: exportedSymbol.address,
                    source: exportedSymbol.source,
                    terminalFlags: exportedSymbol.terminalFlags
                )
            }
            analysis.stringLiterals = analysis.stringLiterals.map { stringLiteral in
                StringLiteralSummary(
                    id: stringLiteralIDMap[stringLiteral.id] ?? stringLiteral.id,
                    value: stringLiteral.value,
                    address: stringLiteral.address,
                    sourceSection: stringLiteral.sourceSection,
                    byteLength: stringLiteral.byteLength
                )
            }
            analysis.basicBlocks = analysis.basicBlocks.map { basicBlock in
                BasicBlockSummary(
                    id: basicBlockIDMap[basicBlock.id] ?? basicBlock.id,
                    functionID: functionIDMap[basicBlock.functionID] ?? basicBlock.functionID,
                    startAddress: basicBlock.startAddress,
                    endAddress: basicBlock.endAddress,
                    instructionCount: basicBlock.instructionCount
                )
            }
            analysis.xrefs = analysis.xrefs.map { xref in
                XRef(
                    id: xrefIDMap[xref.id] ?? xref.id,
                    from: xref.from,
                    to: xref.to,
                    kind: xref.kind
                )
            }
            analysis.controlFlowEdges = analysis.controlFlowEdges.map { edge in
                ControlFlowEdge(
                    id: controlFlowEdgeIDMap[edge.id] ?? edge.id,
                    from: edge.from,
                    to: edge.to,
                    kind: edge.kind
                )
            }
            remappedAnalysesBySlot[binary.slot] = analysis
        }

        let remappedSnapshot = WorkspaceSnapshot(
            binaries: package.snapshot.binaries.map { binary in
                BinaryImage(
                    id: binaryIDMap[binary.id] ?? binary.id,
                    name: binary.name,
                    path: binary.path,
                    kind: binary.kind,
                    architecture: binary.architecture,
                    originalPathBookmark: binary.originalPathBookmark,
                    metadata: binary.metadata,
                    selectedSliceIndex: binary.selectedSliceIndex,
                    machOSelectedSliceFact: binary.machOSelectedSliceFact,
                    elfArchiveMemberIdentity: binary.elfArchiveMemberIdentity,
                    artifactIdentity: binary.artifactIdentity,
                    preferredSegmentLayout: binary.preferredSegmentLayout,
                    artifactIntegrityState: binary.artifactIntegrityState,
                    resolvedExecutablePath: binary.resolvedExecutablePath,
                    slot: binary.slot
                )
            },
            analysisBySlot: remappedAnalysesBySlot,
            addressOverrides: package.snapshot.addressOverrides,
            importedPrototypes: package.snapshot.importedPrototypes,
            typeDefinitions: package.snapshot.typeDefinitions.map { definition in
                var definition = definition
                definition.id = typeDefinitionIDMap[definition.id] ?? definition.id
                return definition
            },
            manualXRefs: package.snapshot.manualXRefs.map { manual in
                var manual = manual
                manual.id = manualXRefIDMap[manual.id] ?? manual.id
                return manual
            },
            bookmarks: package.snapshot.bookmarks.map { bookmark in
                var bookmark = bookmark
                bookmark.id = bookmarkIDMap[bookmark.id] ?? bookmark.id
                return bookmark
            },
            segmentOverrides: package.snapshot.segmentOverrides.map { override in
                var override = override
                override.id = segmentOverrideIDMap[override.id] ?? override.id
                return override
            },
            launchProfileCatalog: package.snapshot.launchProfileCatalog,
            savedWatchCatalog: package.snapshot.savedWatchCatalog,
            sourceLinkState: package.snapshot.sourceLinkState.isEmpty ? Data() : try SourceLinkWorkspaceState
                .decode(package.snapshot.sourceLinkState)
                .remappingBinaryIDs(binaryIDMap, markerIDs: stringLiteralIDMap).encoded()
        )

        return PackageImportPayload(
            documentID: package.manifest.documentID,
            workspaceUUID: UUID(),
            workspaceName: package.manifest.workspaceName,
            createdAt: package.manifest.createdAt,
            modifiedAt: package.manifest.modifiedAt,
            inputCopyingDecision: package.manifest.inputCopyingDecision,
            bookmarkResolutionDecision: package.manifest.bookmarkResolutionDecision,
            snapshot: remappedSnapshot,
            attachmentsByBinaryID: remappedAttachments,
            session: package.session.map {
                Self.remapSession(
                    $0,
                    binaryIDMap: binaryIDMap,
                    functionIDMap: functionIDMap,
                    xrefIDMap: xrefIDMap
                )
            },
            assistantSessionRecords: package.manifest.assistantSessionRecords,
            runtimeAuthorityRecords: package.manifest.runtimeAuthorityRecords.map { record in
                var record = record
                record.id = runtimeAuthorityRecordIDMap[record.id] ?? record.id
                return record
            },
            launchProfileCatalogAvailability: package.launchProfileCatalogAvailability,
            reconstructionState: package.reconstructionState
        )
    }

    private func packageIdentifierCollisionExists(
        in package: WorkspacePackageContents
    ) throws -> Bool {
        if try uuidExists(package.manifest.workspaceUUID, in: "workspaces") {
            return true
        }
        if try package.snapshot.binaries.contains(where: { try uuidExists($0.id, in: "binaries") }) {
            return true
        }
        for binary in package.snapshot.binaries {
            guard let analysis = package.snapshot.analysis(in: binary.slot) else { continue }
            if try analysis.functions.contains(where: { try uuidExists($0.id, in: "functions") }) { return true }
            if try analysis.symbols.contains(where: { try uuidExists($0.id, in: "symbols") }) { return true }
            if try analysis.imports.contains(where: { try uuidExists($0.id, in: "imports") }) { return true }
            if try analysis.indirectSymbols.contains(where: { try uuidExists($0.id, in: "indirect_symbols") }) { return true }
            if try analysis.exports.contains(where: { try uuidExists($0.id, in: "exports") }) { return true }
            if try analysis.stringLiterals.contains(where: { try uuidExists($0.id, in: "string_literals") }) { return true }
            if try analysis.basicBlocks.contains(where: { try uuidExists($0.id, in: "basic_blocks") }) { return true }
            if try analysis.xrefs.contains(where: { try uuidExists($0.id, in: "xrefs") }) { return true }
            if try analysis.controlFlowEdges.contains(where: { try uuidExists($0.id, in: "control_flow_edges") }) { return true }
        }
        if try package.snapshot.typeDefinitions.contains(where: { try textIDExists($0.id, in: "type_definitions") }) { return true }
        if try package.snapshot.manualXRefs.contains(where: { try textIDExists($0.id, in: "manual_xrefs") }) { return true }
        if try package.snapshot.bookmarks.contains(where: { try textIDExists($0.id, in: "bookmarks") }) { return true }
        if try package.snapshot.segmentOverrides.contains(where: { try textIDExists($0.id, in: "segment_overrides") }) { return true }
        if try package.manifest.runtimeAuthorityRecords.contains(where: {
            try textIDExists($0.id, in: "phase2_runtime_authority_records")
        }) { return true }
        return false
    }

    private static func workspacePackageAssistantSessionRecord(
        from record: Phase2AssistantSessionPersistenceRecord
    ) -> WorkspacePackageAssistantSessionRecord {
        WorkspacePackageAssistantSessionRecord(
            id: record.id,
            sequence: record.sequence,
            conversationID: record.conversationID,
            turnSequence: record.turnSequence,
            inferenceTurnID: record.inferenceTurnID,
            isLegacy: record.isLegacy,
            intentID: record.intentID,
            userGoal: record.userGoal,
            status: record.status.rawValue,
            promptText: record.promptText,
            answerText: record.answerText,
            transcriptText: record.transcriptText,
            contextDigest: record.contextDigest,
            canonicalByteCount: record.canonicalByteCount,
            providerToolCount: record.providerToolCount,
            recordSchemaVersion: record.recordSchemaVersion,
            createdAt: record.createdAt,
            completedAt: record.completedAt,
            continuationCheckpoint: record.continuationCheckpoint,
            contentSHA256: record.contentSHA256
        )
    }

    private static func workspacePackageRuntimeAuthorityRecord(
        from record: Phase2RuntimeAuthorityPersistenceRecord
    ) -> WorkspacePackageRuntimeAuthorityRecord {
        WorkspacePackageRuntimeAuthorityRecord(
            id: record.id,
            sessionID: record.sessionID,
            surfaces: record.surfaces,
            terminalBackend: record.terminalBackend,
            ptyReusePolicy: record.ptyReusePolicy,
            debuggerAuthorityPolicy: record.debuggerAuthorityPolicy,
            providerVisibleShellExecutionEnabled: record.providerVisibleShellExecutionEnabled,
            recordSchemaVersion: record.recordSchemaVersion,
            createdAt: record.createdAt
        )
    }

    private static func phase2AssistantSessionPersistenceRecord(
        from record: WorkspacePackageAssistantSessionRecord,
        workspaceID: Int64,
        workspaceUUID: UUID,
        documentID: UUID
    ) throws -> Phase2AssistantSessionPersistenceRecord {
        guard let status = Phase2AssistantPersistedSessionStatus(rawValue: record.status) else {
            throw DatabaseError.invalidPhase2AssistantSessionStatus(record.status)
        }
        return Phase2AssistantSessionPersistenceRecord(
            id: record.id,
            workspaceID: workspaceID,
            workspaceUUID: workspaceUUID,
            documentID: documentID,
            sequence: record.sequence,
            conversationID: record.conversationID,
            turnSequence: record.turnSequence,
            inferenceTurnID: record.inferenceTurnID,
            isLegacy: record.isLegacy,
            intentID: record.intentID,
            userGoal: record.userGoal,
            status: status,
            promptText: record.promptText,
            answerText: record.answerText,
            transcriptText: record.transcriptText,
            contextDigest: record.contextDigest,
            canonicalByteCount: record.canonicalByteCount,
            providerToolCount: record.providerToolCount,
            recordSchemaVersion: Phase2AssistantSessionPersistenceRecord.schemaVersion,
            createdAt: record.createdAt,
            completedAt: record.completedAt,
            continuationCheckpoint: record.continuationCheckpoint
        )
    }

    private static func phase2RuntimeAuthorityPersistenceRecord(
        from record: WorkspacePackageRuntimeAuthorityRecord,
        workspaceID: Int64,
        workspaceUUID: UUID,
        documentID: UUID
    ) -> Phase2RuntimeAuthorityPersistenceRecord {
        Phase2RuntimeAuthorityPersistenceRecord(
            id: record.id,
            workspaceID: workspaceID,
            workspaceUUID: workspaceUUID,
            documentID: documentID,
            sessionID: record.sessionID,
            surfaces: record.surfaces,
            terminalBackend: record.terminalBackend,
            ptyReusePolicy: record.ptyReusePolicy,
            debuggerAuthorityPolicy: record.debuggerAuthorityPolicy,
            providerVisibleShellExecutionEnabled: record.providerVisibleShellExecutionEnabled,
            recordSchemaVersion: record.recordSchemaVersion,
            createdAt: record.createdAt
        )
    }

    private func uuidExists(_ uuid: UUID, in tableName: String) throws -> Bool {
        try first(
            "SELECT 1 FROM \(tableName) WHERE uuid = ? LIMIT 1;",
            bindings: [.text(uuid.uuidString)],
            map: { _ in true }
        ) ?? false
    }

    private func textIDExists(_ uuid: UUID, in tableName: String) throws -> Bool {
        try first(
            "SELECT 1 FROM \(tableName) WHERE id = ? LIMIT 1;",
            bindings: [.text(uuid.uuidString)],
            map: { _ in true }
        ) ?? false
    }

    private static func uuidMap(for ids: [UUID]) -> [UUID: UUID] {
        var map: [UUID: UUID] = [:]
        for id in ids where map[id] == nil {
            map[id] = UUID()
        }
        return map
    }

    private static func remapSession(
        _ session: WorkspacePackageSession,
        binaryIDMap: [UUID: UUID],
        functionIDMap: [UUID: UUID],
        xrefIDMap: [UUID: UUID]
    ) -> WorkspacePackageSession {
        WorkspacePackageSession(
            selectedSidebarItemID: remapSidebarItemID(
                session.selectedSidebarItemID,
                binaryIDMap: binaryIDMap,
                functionIDMap: functionIDMap,
                xrefIDMap: xrefIDMap
            ),
            selectedAddress: session.selectedAddress,
            selectedTool: session.selectedTool,
            editorMode: session.editorMode,
            isInspectorPresented: session.isInspectorPresented,
            sidebarSearchText: session.sidebarSearchText,
            updatedAt: session.updatedAt,
            focusedImageSlot: session.focusedImageSlot
        )
    }

    private static func remapSidebarItemID(
        _ itemID: String?,
        binaryIDMap: [UUID: UUID],
        functionIDMap: [UUID: UUID],
        xrefIDMap: [UUID: UUID]
    ) -> String? {
        guard let itemID else { return nil }
        let parts = itemID.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return itemID }

        let prefix = String(parts[0])
        let rawID = String(parts[1])
        guard let uuid = UUID(uuidString: rawID) else { return itemID }

        switch prefix {
        case "binary":
            return "binary:\((binaryIDMap[uuid] ?? uuid).uuidString)"
        case "function", "symbol":
            return "\(prefix):\((functionIDMap[uuid] ?? uuid).uuidString)"
        case "xref":
            return "xref:\((xrefIDMap[uuid] ?? uuid).uuidString)"
        default:
            return itemID
        }
    }

    @discardableResult
    func upsertPluginTrustDecision(_ record: PluginTrustRecord) throws -> PluginTrustRecord {
        try run(
            """
            INSERT INTO plugin_trust_decisions (plugin_identifier, decision, manifest_hash, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(plugin_identifier) DO UPDATE SET
              decision = excluded.decision,
              manifest_hash = excluded.manifest_hash,
              updated_at = excluded.updated_at;
            """,
            bindings: [
                .text(record.identifier),
                .text(record.decision.rawValue),
                record.manifestHash.map(Binding.text) ?? .null,
                .text(Self.string(from: record.updatedAt))
            ]
        )

        return record
    }

    func pluginTrustDecision(identifier: String) throws -> PluginTrustRecord? {
        try first(
            """
            SELECT plugin_identifier, decision, manifest_hash, updated_at
            FROM plugin_trust_decisions
            WHERE plugin_identifier = ?;
            """,
            bindings: [.text(identifier)],
            map: Self.pluginTrustRecord
        )
    }

    func pluginTrustDecisions() throws -> [PluginTrustRecord] {
        try query(
            """
            SELECT plugin_identifier, decision, manifest_hash, updated_at
            FROM plugin_trust_decisions
            ORDER BY plugin_identifier;
            """,
            map: Self.pluginTrustRecord
        )
    }

    func deletePluginTrustDecision(identifier: String) throws {
        try run(
            "DELETE FROM plugin_trust_decisions WHERE plugin_identifier = ?;",
            bindings: [.text(identifier)]
        )
    }

    @discardableResult
    func upsertPluginExternalRun(_ record: PluginExternalRunRecord) throws -> PluginExternalRunRecord {
        try run(
            """
            INSERT INTO plugin_external_runs (
              request_id,
              plugin_identifier,
              display_name,
              executable_path,
              manifest_hash,
              status,
              started_at,
              completed_at,
              termination_status,
              stdout,
              stderr,
              log,
              error_message
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(request_id) DO UPDATE SET
              plugin_identifier = excluded.plugin_identifier,
              display_name = excluded.display_name,
              executable_path = excluded.executable_path,
              manifest_hash = excluded.manifest_hash,
              status = excluded.status,
              started_at = excluded.started_at,
              completed_at = excluded.completed_at,
              termination_status = excluded.termination_status,
              stdout = excluded.stdout,
              stderr = excluded.stderr,
              log = excluded.log,
              error_message = excluded.error_message;
            """,
            bindings: [
                .text(record.requestID.uuidString),
                .text(record.pluginIdentifier),
                .text(record.displayName),
                .text(record.executablePath),
                record.manifestHash.map(Binding.text) ?? .null,
                .text(record.status.rawValue),
                .text(Self.string(from: record.startedAt)),
                record.completedAt.map { Binding.text(Self.string(from: $0)) } ?? .null,
                record.terminationStatus.map { Binding.int64(Int64($0)) } ?? .null,
                .text(record.stdout),
                .text(record.stderr),
                .text(record.log),
                record.errorMessage.map(Binding.text) ?? .null
            ]
        )

        return record
    }

    func pluginExternalRun(requestID: UUID) throws -> PluginExternalRunRecord? {
        try first(
            """
            SELECT request_id, plugin_identifier, display_name, executable_path, manifest_hash,
                   status, started_at, completed_at, termination_status, stdout, stderr, log,
                   error_message
            FROM plugin_external_runs
            WHERE request_id = ?;
            """,
            bindings: [.text(requestID.uuidString)],
            map: Self.pluginExternalRunRecord
        )
    }

    func pluginExternalRuns() throws -> [PluginExternalRunRecord] {
        try query(
            """
            SELECT request_id, plugin_identifier, display_name, executable_path, manifest_hash,
                   status, started_at, completed_at, termination_status, stdout, stderr, log,
                   error_message
            FROM plugin_external_runs
            ORDER BY started_at, request_id;
            """,
            map: Self.pluginExternalRunRecord
        )
    }

    func pluginExternalRuns(pluginIdentifier: String) throws -> [PluginExternalRunRecord] {
        try query(
            """
            SELECT request_id, plugin_identifier, display_name, executable_path, manifest_hash,
                   status, started_at, completed_at, termination_status, stdout, stderr, log,
                   error_message
            FROM plugin_external_runs
            WHERE plugin_identifier = ?
            ORDER BY started_at, request_id;
            """,
            bindings: [.text(pluginIdentifier)],
            map: Self.pluginExternalRunRecord
        )
    }

    func deletePluginExternalRun(requestID: UUID) throws {
        try run(
            "DELETE FROM plugin_external_runs WHERE request_id = ?;",
            bindings: [.text(requestID.uuidString)]
        )
    }

    private static func validateArtifactIntegrityForSave(
        _ snapshot: WorkspaceSnapshot
    ) throws {
        for binary in snapshot.binaries.sorted(by: { $0.slot.rawValue < $1.slot.rawValue }) {
            if case .contradictoryEvidence = binary.artifactIntegrityState {
                throw DatabaseError.artifactIntegrityRequiresReimport(binaryID: binary.id)
            }
            guard let archive = binary.elfArchiveMemberIdentity else { continue }
            guard BinaryImage.isValidArchiveMemberIdentity(archive),
                  binary.selectedSliceIndex == nil,
                  binary.machOSelectedSliceFact == nil else {
                throw DatabaseError.archiveIdentityRequiresReimport(binaryID: binary.id)
            }
            let analysis = snapshot.analysis(in: binary.slot) ?? ImageAnalysis()
            let payload = analysis.imageBytes.isEmpty ? analysis.hexBytes : analysis.imageBytes
            guard archive.member.byteCount == payload.count,
                  archive.member.sha256 == MacScopeDocumentPackage.fileHash(for: payload) else {
                throw DatabaseError.archiveIdentityRequiresReimport(binaryID: binary.id)
            }
        }
    }

    @discardableResult
    func saveSnapshot(
        workspaceUUID: UUID = UUID(),
        workspaceName: String,
        snapshot: WorkspaceSnapshot,
        now: Date = Date()
    ) throws -> WorkspaceRecord {
        try Self.validateArtifactIntegrityForSave(snapshot)
        let workspace = try insertWorkspace(
            WorkspaceRecord(
                id: nil,
                uuid: workspaceUUID,
                name: workspaceName,
                createdAt: now,
                modifiedAt: now
            )
        )
        guard let workspaceID = workspace.id else { return workspace }

        try insertSnapshotContents(snapshot, into: workspaceID)
        return workspace
    }

    private func insertSnapshotContents(
        _ snapshot: WorkspaceSnapshot,
        into workspaceID: Int64,
        binaryDataByID: [UUID: Data]? = nil
    ) throws {
        try Self.validateArtifactIntegrityForSave(snapshot)
        try snapshot.validateInvariants()

        // `binaries.hex_bytes` is the historical column name, but the value stored here is the
        // FULL selected-slice payload for this image. `hexBytes` is only its bounded UI prefix and
        // is used as a compatibility fallback when a package-reloaded analysis has no imageBytes.
        // Persist in deterministic slot order so DB order and the reconstructed identity spine are
        // stable even if an in-memory caller supplied the binary array in a different order.
        for binary in snapshot.binaries.sorted(by: { $0.slot.rawValue < $1.slot.rawValue }) {
            // A binary without an analysis bucket is a VALID snapshot (the compat init routes derived
            // data only to the primary slot, and `validateInvariants` permits bucketless binaries).
            // Persist it as an empty image — lossless, since derived data is recomputed on reanalysis
            // and a reloaded snapshot already carries empty derived tables until then.
            let analysis = snapshot.analysis(in: binary.slot) ?? ImageAnalysis()
            let snapshotPayload = analysis.imageBytes.isEmpty ? analysis.hexBytes : analysis.imageBytes
            let binaryData = binaryDataByID?[binary.id] ?? snapshotPayload
            let insertedBinary = try insertBinary(
                BinaryRecord(
                    id: nil,
                    uuid: binary.id,
                    workspaceID: workspaceID,
                    name: binary.name,
                    path: binary.path,
                    originalPathBookmark: binary.originalPathBookmark,
                    kind: binary.kind,
                    architecture: binary.architecture,
                    fileHash: MacScopeDocumentPackage.fileHash(for: binaryData),
                    fileSize: Int64(binaryData.count),
                    hexBytes: binaryData,
                    isBundle: binary.kind.localizedCaseInsensitiveContains("bundle"),
                    imageSlot: binary.slot.rawValue,
                    selectedSliceIndex: binary.selectedSliceIndex,
                    machOSelectedSliceFact: binary.machOSelectedSliceFact,
                    analysisInputFingerprintJSON: try Self.encodeAnalysisInputFingerprintJSON(
                        analysis.analysisInputFingerprint
                    ),
                    metadata: binary.metadata,
                    elfArchiveMemberIdentity: binary.elfArchiveMemberIdentity
                )
            )
            guard let binaryID = insertedBinary.id else {
                throw DatabaseError.notFound
            }
            try insertAnalysisContents(analysis, into: binaryID)
        }

        // User-authored overrides are workspace-scoped (not binary-scoped) and
        // persisted so renames/comments/tags/colors survive reload. Persist them
        // BEFORE the no-binary early return — they do not depend on binaryID, and a
        // workspace with no binary should still keep its authoring. Empty overrides
        // are skipped.
        let prototypeJSON = String(decoding: try JSONEncoder().encode(
            ImportedPrototypeEntry.entries(from: snapshot.importedPrototypes)), as: UTF8.self)
        try run("INSERT OR REPLACE INTO imported_function_prototypes (workspace_id, prototypes_json) VALUES (?, ?);",
                bindings: [.int64(workspaceID), .text(prototypeJSON)])
        let overrideTimestamp = Date()
        for (key, override) in snapshot.addressOverrides where !override.isEmpty {
            try insertAddressOverride(
                AddressOverrideRecord(
                    id: nil,
                    workspaceID: workspaceID,
                    address: key.address,
                    imageSlot: key.slot.rawValue,
                    customName: override.customName,
                    customComment: override.customComment,
                    tag: override.tag,
                    colorTag: override.colorTag?.rawValue,
                    isData: override.isData,
                    signatureJSON: Self.encodeSignature(override.signature),
                    appliedTypeName: override.appliedTypeName,
                    switchHintJSON: Self.encodeSwitchHint(override.switchHint),
                    operandFormat: override.operandFormat?.rawValue,
                    markAsProcedure: override.markAsProcedure,
                    dataShapeJSON: Self.encodeDataShape(override.dataShape),
                    isUndefined: override.isUndefined,
                    patchJSON: Self.encodePatch(override.patch),
                    appendedCaveJSON: try Self.encodeAppendedCave(override.appendedExecutableCave),
                    registerNamesJSON: Self.encodeRegisterNames(override.registerNames),
                    stackLocalsJSON: Self.encodeStackLocals(override.stackLocals),
                    localLabel: override.localLabel,
                    createdAt: overrideTimestamp,
                    modifiedAt: overrideTimestamp
                )
            )
        }

        // Manual xref edits + bookmarks are workspace-scoped (not binary-scoped), like the
        // overrides — persist them before the no-binary early return so a workspace with no
        // binary keeps them. Each uses INSERT OR REPLACE so a repeat edit (same endpoints /
        // same address) never collides with its UNIQUE index and aborts the whole save.
        for manual in snapshot.manualXRefs {
            try insertManualXRef(
                ManualXRefRecord(
                    id: manual.id,
                    workspaceID: workspaceID,
                    fromAddress: manual.from,
                    toAddress: manual.to,
                    kind: manual.kind,
                    isSuppression: manual.isSuppression,
                    imageSlot: manual.imageSlot.rawValue,
                    createdAt: overrideTimestamp,
                    modifiedAt: overrideTimestamp
                )
            )
        }
        for bookmark in snapshot.bookmarks {
            try insertBookmark(
                BookmarkRecord(
                    id: bookmark.id,
                    workspaceID: workspaceID,
                    address: bookmark.address,
                    imageSlot: bookmark.imageSlot.rawValue,
                    name: bookmark.name,
                    createdAt: overrideTimestamp,
                    modifiedAt: overrideTimestamp
                )
            )
        }
        // Segment/section display overrides are workspace-scoped like the bookmarks above.
        // INSERT OR REPLACE so a repeat override on the same section never collides with the
        // UNIQUE(workspace_id, original_name) index. Empty overrides are skipped.
        for override in snapshot.segmentOverrides where !override.isEmpty {
            try insertSegmentOverride(
                SegmentOverrideRecord(
                    id: override.id,
                    workspaceID: workspaceID,
                    originalName: override.originalName,
                    imageSlot: override.imageSlot.rawValue,
                    displayName: override.displayName,
                    rebaseDelta: override.rebaseDelta,
                    createdAt: overrideTimestamp,
                    modifiedAt: overrideTimestamp
                )
            )
        }

        // The type catalog is workspace-global (not binary-scoped), so persist it
        // before the no-binary early return alongside the overrides.
        for type in snapshot.typeDefinitions {
            try insertTypeDefinition(
                TypeDefinitionRecord(
                    id: type.id,
                    workspaceID: workspaceID,
                    kind: type.kind.rawValue,
                    name: type.name,
                    fieldsJSON: try WorkspaceTypeDefinitionDatabaseCodec.encodeFields(type.fields),
                    layoutRulesJSON: try WorkspaceTypeDefinitionDatabaseCodec.encodeTypeLayout(type),
                    createdAt: overrideTimestamp,
                    modifiedAt: overrideTimestamp
                )
            )
        }

        guard let workspaceUUID = try workspace(id: workspaceID)?.uuid else {
            throw DatabaseError.notFound
        }
        try insertLogicalBreakpointCatalog(
            snapshot.logicalBreakpointCatalog,
            workspaceID: workspaceID,
            workspaceUUID: workspaceUUID,
            timestamp: Self.string(from: overrideTimestamp)
        )
        try insertLaunchProfileCatalog(
            snapshot.launchProfileCatalog,
            workspaceID: workspaceID,
            workspaceUUID: workspaceUUID
        )
        try insertSavedWatchCatalog(snapshot.savedWatchCatalog,
                                   workspaceID: workspaceID, workspaceUUID: workspaceUUID)
        guard snapshot.sourceLinkState.count <= 1_048_576 else {
            throw DatabaseError.stepFailed("Source evidence exceeds its storage bound.")
        }
        if !snapshot.sourceLinkState.isEmpty {
            try run("INSERT INTO source_link_states (workspace_id, state_blob) VALUES (?, ?);",
                    bindings: [.int64(workspaceID), .blob(snapshot.sourceLinkState)])
        }

    }

    private func insertSavedWatchCatalog(
        _ catalog: WorkspaceSavedWatchCatalog, workspaceID: Int64, workspaceUUID: UUID
    ) throws {
        let bytes = try catalog.canonicalBytes()
        try run("""
            INSERT INTO saved_watch_catalogs
              (workspace_id, workspace_uuid, catalog_blob, catalog_sha256) VALUES (?, ?, ?, ?);
            """, bindings: [.int64(workspaceID), .text(workspaceUUID.uuidString),
                             .blob(bytes), .text(Self.sha256(bytes))])
    }

    private func loadSavedWatchCatalog(
        workspaceID: Int64, workspaceUUID: UUID
    ) throws -> WorkspaceSavedWatchCatalog {
        let rows = try query("""
            SELECT workspace_uuid, catalog_blob, catalog_sha256, length(catalog_blob)
            FROM saved_watch_catalogs WHERE workspace_id = \(workspaceID);
            """) { statement in
            // Validate SQLite's storage class and declared extent before asking for a blob
            // pointer or copying Data. Hostile databases need not honor our CREATE constraints.
            guard sqlite3_column_type(statement, 0) == SQLITE_TEXT,
                  sqlite3_column_type(statement, 1) == SQLITE_BLOB,
                  sqlite3_column_type(statement, 2) == SQLITE_TEXT,
                  sqlite3_column_type(statement, 3) == SQLITE_INTEGER else {
                throw WorkspaceSavedWatchValidationError.invalid
            }
            let byteCount = sqlite3_column_int64(statement, 3)
            guard byteCount > 0, byteCount <= 32_768,
                  sqlite3_column_bytes(statement, 0) == 36,
                  sqlite3_column_bytes(statement, 2) == 64,
                  Int64(sqlite3_column_bytes(statement, 1)) == byteCount else {
                throw WorkspaceSavedWatchValidationError.invalid
            }
            return (try Self.textColumn(statement, 0), Self.blobColumn(statement, 1),
                    try Self.textColumn(statement, 2))
        }
        guard let row = rows.first else { throw WorkspaceSavedWatchValidationError.invalid }
        guard rows.count == 1, row.0 == workspaceUUID.uuidString,
              Self.sha256(row.1) == row.2 else { throw WorkspaceSavedWatchValidationError.invalid }
        return try .decodeCanonicalBytes(row.1)
    }

    private func insertLogicalBreakpointCatalog(
        _ catalog: DebuggerLogicalBreakpointCatalog,
        workspaceID: Int64,
        workspaceUUID: UUID,
        timestamp: String
    ) throws {
        let catalogBytes = try DebuggerLogicalBreakpointCanonicalCodec.encodeCatalog(catalog)
        try run(
            """
            INSERT INTO logical_breakpoint_catalogs (
              workspace_id, workspace_uuid, catalog_uuid, revision,
              specification_count, catalog_sha256
            ) VALUES (?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .int64(workspaceID),
                .text(workspaceUUID.uuidString),
                .text(catalog.catalogID.uuidString),
                .uint64(catalog.revision),
                .int64(Int64(catalog.specifications.count)),
                .text(Self.sha256(catalogBytes)),
            ]
        )
        for specification in catalog.specifications {
            let bytes = try DebuggerLogicalBreakpointCanonicalCodec.encodeSpecification(specification)
            guard let json = String(data: bytes, encoding: .utf8) else {
                throw DatabaseError.logicalBreakpointCatalogUnavailable
            }
            try run(
                """
                INSERT INTO logical_breakpoints (
                  id, workspace_id, revision, specification_version,
                  specification_byte_count, specification_sha256, specification_json,
                  created_at, modified_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    .text(specification.id.rawValue.uuidString),
                    .int64(workspaceID),
                    .uint64(specification.revision.rawValue),
                    .int64(Int64(DebuggerLogicalBreakpointSpecification.schemaVersion)),
                    .int64(Int64(bytes.count)),
                    .text(Self.sha256(bytes)),
                    .text(json),
                    .text(timestamp),
                    .text(timestamp),
                ]
            )
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func insertLaunchProfileCatalog(
        _ catalog: DebuggerLaunchProfileCatalog,
        workspaceID: Int64,
        workspaceUUID: UUID
    ) throws {
        let canonical = try DebuggerLaunchProfileCanonicalCodec.encodeCatalog(catalog)
        guard canonical.count <= DebuggerLaunchProfileCanonicalCodec.maximumCatalogBytes else {
            throw DatabaseError.launchProfileCatalogUnavailable
        }
        try run(
            """
            INSERT INTO launch_profile_catalogs (
              workspace_id, workspace_uuid, catalog_uuid, revision, profile_count,
              selected_profile_uuid, catalog_version, catalog_byte_count,
              catalog_sha256, catalog_blob
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            bindings: [
                .int64(workspaceID),
                .text(workspaceUUID.uuidString),
                .text(catalog.catalogID.uuidString),
                .uint64(catalog.revision),
                .int64(Int64(catalog.profiles.count)),
                catalog.selectedProfileID.map { .text($0.rawValue.uuidString) } ?? .null,
                .int64(Int64(DebuggerLaunchProfileCatalog.schemaVersion)),
                .int64(Int64(canonical.count)),
                .text(Self.sha256(canonical)),
                .blob(canonical),
            ]
        )
    }

    private struct LaunchProfileCatalogRow {
        let workspaceID: Int64
        let workspaceUUID: String
        let catalogUUID: String
        let revision: Int64
        let profileCount: Int64
        let selectedProfileUUID: String?
        let catalogVersion: Int64
        let declaredByteCount: Int64
        let actualByteCount: Int64
        let sha256: String
        let canonical: Data
        let storageIsExact: Bool
    }

    private func loadLaunchProfileCatalog(
        workspaceID: Int64,
        workspaceUUID: UUID
    ) throws -> DebuggerLaunchProfileCatalog {
        guard let row = try first(
            """
            SELECT workspace_id, workspace_uuid, catalog_uuid, revision, profile_count,
                   selected_profile_uuid, catalog_version, catalog_byte_count,
                   length(catalog_blob), catalog_sha256, catalog_blob,
                   typeof(workspace_id) = 'integer'
                     AND typeof(workspace_uuid) = 'text'
                     AND typeof(catalog_uuid) = 'text'
                     AND typeof(revision) = 'integer'
                     AND typeof(profile_count) = 'integer'
                     AND (typeof(selected_profile_uuid) = 'null'
                          OR typeof(selected_profile_uuid) = 'text')
                     AND typeof(catalog_version) = 'integer'
                     AND typeof(catalog_byte_count) = 'integer'
                     AND typeof(catalog_sha256) = 'text'
                     AND typeof(catalog_blob) = 'blob'
            FROM launch_profile_catalogs
            WHERE workspace_id = ?;
            """,
            bindings: [.int64(workspaceID)],
            map: { statement in
                LaunchProfileCatalogRow(
                    workspaceID: try Self.launchProfileIntegerColumn(statement, 0),
                    workspaceUUID: try Self.textColumn(statement, 1),
                    catalogUUID: try Self.textColumn(statement, 2),
                    revision: try Self.launchProfileIntegerColumn(statement, 3),
                    profileCount: try Self.launchProfileIntegerColumn(statement, 4),
                    selectedProfileUUID: Self.optionalTextColumn(statement, 5),
                    catalogVersion: try Self.launchProfileIntegerColumn(statement, 6),
                    declaredByteCount: try Self.launchProfileIntegerColumn(statement, 7),
                    actualByteCount: try Self.launchProfileIntegerColumn(statement, 8),
                    sha256: try Self.textColumn(statement, 9),
                    canonical: Self.blobColumn(statement, 10),
                    storageIsExact: sqlite3_column_int64(statement, 11) == 1
                )
            }
        ) else {
            throw DatabaseError.launchProfileCatalogUnavailable
        }

        guard row.storageIsExact,
              row.workspaceID == workspaceID,
              row.workspaceUUID == workspaceUUID.uuidString,
              let catalogID = UUID(uuidString: row.catalogUUID),
              catalogID.uuidString == row.catalogUUID,
              row.revision > 0,
              row.profileCount >= 0,
              row.profileCount <= Int64(DebuggerLaunchProfileCatalog.maximumProfileCount),
              row.catalogVersion == Int64(DebuggerLaunchProfileCatalog.schemaVersion),
              row.declaredByteCount > 0,
              row.declaredByteCount <= Int64(DebuggerLaunchProfileCanonicalCodec.maximumCatalogBytes),
              row.actualByteCount == row.declaredByteCount,
              row.canonical.count == Int(row.actualByteCount),
              Self.isLowercaseSHA256(row.sha256),
              Self.sha256(row.canonical) == row.sha256
        else {
            throw DatabaseError.launchProfileCatalogUnavailable
        }
        if let selected = row.selectedProfileUUID {
            guard let selectedID = UUID(uuidString: selected), selectedID.uuidString == selected else {
                throw DatabaseError.launchProfileCatalogUnavailable
            }
        }

        do {
            let catalog = try DebuggerLaunchProfileCanonicalCodec.decodeCatalog(row.canonical)
            guard catalog.catalogID == catalogID,
                  catalog.revision == UInt64(row.revision),
                  catalog.profiles.count == Int(row.profileCount),
                  catalog.selectedProfileID?.rawValue.uuidString == row.selectedProfileUUID
            else {
                throw DatabaseError.launchProfileCatalogUnavailable
            }
            return catalog
        } catch let error as DatabaseError {
            throw error
        } catch {
            throw DatabaseError.launchProfileCatalogUnavailable
        }
    }

    private static func launchProfileIntegerColumn(
        _ statement: OpaquePointer,
        _ index: Int32
    ) throws -> Int64 {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else {
            throw DatabaseError.launchProfileCatalogUnavailable
        }
        return sqlite3_column_int64(statement, index)
    }

    private struct LogicalBreakpointCatalogRow {
        let workspaceID: Int64
        let workspaceUUID: String
        let catalogUUID: String
        let revision: Int64
        let specificationCount: Int64
        let catalogSHA256: String
    }

    private struct LogicalBreakpointSpecificationMetadata {
        let id: String
        let workspaceID: Int64
        let revision: Int64
        let version: Int64
        let declaredByteCount: Int64
        let actualByteCount: Int64
        let sha256: String
        let textStorageIsExact: Bool
    }

    private func loadLogicalBreakpointCatalog(
        workspaceID: Int64,
        workspaceUUID: UUID
    ) throws -> DebuggerLogicalBreakpointCatalog {
        guard let row = try first(
            """
            SELECT workspace_id, workspace_uuid, catalog_uuid, revision,
                   specification_count, catalog_sha256
            FROM logical_breakpoint_catalogs
            WHERE workspace_id = ?
              AND typeof(workspace_id) = 'integer'
              AND typeof(workspace_uuid) = 'text'
              AND typeof(catalog_uuid) = 'text'
              AND typeof(catalog_sha256) = 'text';
            """,
            bindings: [.int64(workspaceID)],
            map: { statement in
                LogicalBreakpointCatalogRow(
                    workspaceID: try Self.logicalBreakpointIntegerColumn(statement, 0),
                    workspaceUUID: try Self.textColumn(statement, 1),
                    catalogUUID: try Self.textColumn(statement, 2),
                    revision: try Self.logicalBreakpointIntegerColumn(statement, 3),
                    specificationCount: try Self.logicalBreakpointIntegerColumn(statement, 4),
                    catalogSHA256: try Self.textColumn(statement, 5)
                )
            }
        ) else {
            throw DatabaseError.logicalBreakpointCatalogUnavailable
        }
        guard row.workspaceID == workspaceID,
              row.workspaceUUID == workspaceUUID.uuidString,
              let catalogID = UUID(uuidString: row.catalogUUID),
              catalogID.uuidString == row.catalogUUID,
              row.revision > 0,
              row.revision <= Int64.max,
              row.specificationCount >= 0,
              row.specificationCount <= 4_096,
              Self.isLowercaseSHA256(row.catalogSHA256)
        else {
            throw DatabaseError.logicalBreakpointCatalogUnavailable
        }

        let metadata = try query(
            """
            SELECT id, workspace_id, revision, specification_version,
                   specification_byte_count, length(CAST(specification_json AS BLOB)),
                   specification_sha256,
                   typeof(id) = 'text'
                     AND typeof(specification_sha256) = 'text'
                     AND typeof(specification_json) = 'text'
                     AND typeof(created_at) = 'text'
                     AND typeof(modified_at) = 'text'
            FROM logical_breakpoints
            WHERE workspace_id = ?
            ORDER BY id;
            """,
            bindings: [.int64(workspaceID)]
        ) { statement in
            LogicalBreakpointSpecificationMetadata(
                id: try Self.textColumn(statement, 0),
                workspaceID: try Self.logicalBreakpointIntegerColumn(statement, 1),
                revision: try Self.logicalBreakpointIntegerColumn(statement, 2),
                version: try Self.logicalBreakpointIntegerColumn(statement, 3),
                declaredByteCount: try Self.logicalBreakpointIntegerColumn(statement, 4),
                actualByteCount: try Self.logicalBreakpointIntegerColumn(statement, 5),
                sha256: try Self.textColumn(statement, 6),
                textStorageIsExact: sqlite3_column_int64(statement, 7) == 1
            )
        }
        guard metadata.count == Int(row.specificationCount) else {
            throw DatabaseError.logicalBreakpointCatalogUnavailable
        }
        var totalBytes: Int64 = 0
        for item in metadata {
            let sum = totalBytes.addingReportingOverflow(item.actualByteCount)
            guard UUID(uuidString: item.id)?.uuidString == item.id,
                  item.workspaceID == workspaceID,
                  item.textStorageIsExact,
                  item.revision > 0,
                  item.revision <= row.revision,
                  item.version == Int64(DebuggerLogicalBreakpointSpecification.schemaVersion),
                  item.declaredByteCount > 0,
                  item.declaredByteCount <= 16 * 1_024,
                  item.actualByteCount == item.declaredByteCount,
                  Self.isLowercaseSHA256(item.sha256),
                  !sum.overflow,
                  sum.partialValue <= 8 * 1_024 * 1_024
            else {
                throw DatabaseError.logicalBreakpointCatalogUnavailable
            }
            totalBytes = sum.partialValue
        }

        let payloads = try query(
            """
            SELECT id, specification_json
            FROM logical_breakpoints
            WHERE workspace_id = ?
            ORDER BY id;
            """,
            bindings: [.int64(workspaceID)]
        ) { statement in
            (try Self.textColumn(statement, 0), try Self.textColumn(statement, 1))
        }
        var specifications: [DebuggerLogicalBreakpointSpecification] = []
        specifications.reserveCapacity(payloads.count)
        do {
            for (index, payload) in payloads.enumerated() {
                let bytes = Data(payload.1.utf8)
                let item = metadata[index]
                guard payload.0 == item.id, Self.sha256(bytes) == item.sha256 else {
                    throw DatabaseError.logicalBreakpointCatalogUnavailable
                }
                let specification = try DebuggerLogicalBreakpointCanonicalCodec.decodeSpecification(bytes)
                guard specification.id.rawValue.uuidString == item.id,
                      specification.revision.rawValue == UInt64(item.revision)
                else {
                    throw DatabaseError.logicalBreakpointCatalogUnavailable
                }
                specifications.append(specification)
            }
            let catalog = try DebuggerLogicalBreakpointCatalog(
                catalogID: catalogID,
                revision: UInt64(row.revision),
                specifications: specifications
            )
            let canonical = try DebuggerLogicalBreakpointCanonicalCodec.encodeCatalog(catalog)
            guard Self.sha256(canonical) == row.catalogSHA256 else {
                throw DatabaseError.logicalBreakpointCatalogUnavailable
            }
            return catalog
        } catch let error as DatabaseError {
            throw error
        } catch {
            throw DatabaseError.logicalBreakpointCatalogUnavailable
        }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }

    /// Logical-breakpoint receipts are authority metadata, so SQLite's permissive numeric
    /// coercion is never acceptable: a text/blob/real value must not be interpreted as INTEGER.
    private static func logicalBreakpointIntegerColumn(
        _ statement: OpaquePointer,
        _ index: Int32
    ) throws -> Int64 {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else {
            throw DatabaseError.logicalBreakpointCatalogUnavailable
        }
        return sqlite3_column_int64(statement, index)
    }

    /// Confirmed repair boundary for a corrupt catalog. Analysis and unrelated authoring remain
    /// untouched; only the catalog authority is invalidated and replaced with a fresh coordinate.
    func discardCorruptLogicalBreakpointCatalog(
        workspaceID: Int64
    ) throws -> DebuggerLogicalBreakpointCatalog {
        try transaction {
            guard let workspace = try workspace(id: workspaceID) else {
                throw DatabaseError.notFound
            }
            // A coercible non-INTEGER child key does not compare equal to the INTEGER binding.
            // Remove only children that purport to belong to this repaired workspace; repair of
            // one catalog must not mutate an unrelated workspace's independently corrupt receipt.
            try run(
                """
                DELETE FROM logical_breakpoints
                WHERE workspace_id = ?
                   OR (typeof(workspace_id) != 'integer'
                       AND CAST(workspace_id AS INTEGER) = ?);
                """,
                bindings: [.int64(workspaceID), .int64(workspaceID)]
            )
            try run(
                "DELETE FROM logical_breakpoint_catalogs WHERE workspace_id = ?;",
                bindings: [.int64(workspaceID)]
            )
            let repaired = DebuggerLogicalBreakpointCatalog.freshPristine()
            try insertLogicalBreakpointCatalog(
                repaired,
                workspaceID: workspaceID,
                workspaceUUID: workspace.uuid,
                timestamp: Self.string(from: Date())
            )
            return repaired
        }
    }

    /// Confirmed repair boundary for launch-profile authority. Only the one invalid catalog row
    /// is replaced; analysis, logical breakpoints, and unrelated authoring remain untouched.
    func discardCorruptLaunchProfileCatalog(
        workspaceID: Int64
    ) throws -> DebuggerLaunchProfileCatalog {
        try transaction {
            guard let workspace = try workspace(id: workspaceID) else {
                throw DatabaseError.notFound
            }
            try run(
                """
                DELETE FROM launch_profile_catalogs
                WHERE workspace_id = ?
                   OR (typeof(workspace_id) != 'integer'
                       AND CAST(workspace_id AS INTEGER) = ?);
                """,
                bindings: [.int64(workspaceID), .int64(workspaceID)]
            )
            let repaired = DebuggerLaunchProfileCatalog.freshPristine()
            try insertLaunchProfileCatalog(
                repaired,
                workspaceID: workspaceID,
                workspaceUUID: workspace.uuid
            )
            return repaired
        }
    }

    func legacyBreakpointCountForTesting(workspaceID: Int64) throws -> Int {
        try scalarInt(
            """
            SELECT COUNT(DISTINCT b.uuid || ':' || printf('%016llx', i.address))
            FROM instructions AS i
            JOIN functions AS f ON f.id = i.function_id
            JOIN binaries AS b ON b.id = f.binary_id
            WHERE b.workspace_id = \(workspaceID) AND i.has_breakpoint = 1;
            """
        )
    }

    /// Persists the table-backed subset of one image's derived analysis under exactly one
    /// `binary_id`. Function row maps are intentionally local to this call: two images may contain
    /// the same virtual addresses, but their instructions/blocks must resolve only against their
    /// own function rows.
    private func insertAnalysisContents(_ analysis: ImageAnalysis, into binaryID: Int64) throws {
        try insertConstantCFStrings(analysis.constantStrings, binaryID: binaryID)
        var functionIDsByAddressRange: [(record: FunctionRecord, id: Int64)] = []
        var functionIDsByUUID: [UUID: Int64] = [:]
        for function in analysis.functions {
            let insertedFunction = try insertFunction(
                FunctionRecord(
                    id: nil,
                    uuid: function.id,
                    binaryID: binaryID,
                    startAddress: function.startAddress,
                    endAddress: function.endAddress,
                    symbolName: function.name,
                    demangledName: nil,
                    confidence: function.confidence,
                    noReturnProvenance: function.noReturnProvenance?.rawValue
                )
            )
            if let functionID = insertedFunction.id {
                functionIDsByAddressRange.append((insertedFunction, functionID))
                functionIDsByUUID[function.id] = functionID
            }
        }

        for symbol in analysis.symbols {
            try insertSymbol(
                SymbolRecord(
                    id: nil,
                    uuid: symbol.id,
                    binaryID: binaryID,
                    name: symbol.name,
                    address: symbol.address,
                    kind: symbol.kind,
                    libraryName: symbol.libraryName,
                    rawLinkageName: symbol.rawLinkageName
                )
            )
        }

        for importedSymbol in analysis.imports {
            try insertImport(
                ImportRecord(
                    id: nil,
                    uuid: importedSymbol.id,
                    binaryID: binaryID,
                    name: importedSymbol.name,
                    libraryName: importedSymbol.libraryName,
                    libraryOrdinal: importedSymbol.libraryOrdinal
                )
            )
        }

        for indirectSymbol in analysis.indirectSymbols {
            try insertIndirectSymbol(
                IndirectSymbolRecord(
                    id: nil,
                    uuid: indirectSymbol.id,
                    binaryID: binaryID,
                    kind: indirectSymbol.kind,
                    sourceSection: indirectSymbol.sourceSection,
                    address: indirectSymbol.address,
                    entrySize: indirectSymbol.entrySize,
                    tableIndex: indirectSymbol.tableIndex,
                    rawSymbolIndex: indirectSymbol.rawSymbolIndex,
                    symbolIndex: indirectSymbol.symbolIndex,
                    symbolName: indirectSymbol.symbolName,
                    libraryOrdinal: indirectSymbol.libraryOrdinal,
                    libraryName: indirectSymbol.libraryName,
                    isLocal: indirectSymbol.isLocal,
                    isAbsolute: indirectSymbol.isAbsolute
                )
            )
        }

        for exportedSymbol in analysis.exports {
            try insertExport(
                ExportRecord(
                    id: nil,
                    uuid: exportedSymbol.id,
                    binaryID: binaryID,
                    name: exportedSymbol.name,
                    address: exportedSymbol.address,
                    source: exportedSymbol.source,
                    terminalFlags: exportedSymbol.terminalFlags
                )
            )
        }

        for stringLiteral in analysis.stringLiterals {
            try insertStringLiteral(
                StringLiteralRecord(
                    id: nil,
                    uuid: stringLiteral.id,
                    binaryID: binaryID,
                    value: stringLiteral.value,
                    address: stringLiteral.address,
                    sourceSection: stringLiteral.sourceSection,
                    byteLength: stringLiteral.byteLength
                )
            )
        }

        // WS-5: dSYM-imported source lines are not byte-derivable, so persist them per binary.
        for sourceLine in analysis.sourceLines {
            let tablePathKind: String?
            let tablePathValue: String?
            switch sourceLine.tablePath {
            case .absoluteUTF8(let value):
                tablePathKind = "absoluteUTF8"
                tablePathValue = value
            case .compilationDirectoryRelativeUTF8(let value):
                tablePathKind = "compilationDirectoryRelativeUTF8"
                tablePathValue = value
            case nil:
                tablePathKind = nil
                tablePathValue = nil
            }
            try run(
                """
                INSERT INTO source_lines (
                  binary_id, address, file, line, column, is_end_sequence,
                  debug_artifact_uuid, debug_artifact_macho_sha256,
                  debug_artifact_macho_byte_count, line_program_unit_offset,
                  file_table_index, table_path_kind, table_path
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """,
                bindings: [
                    .int64(binaryID),
                    .address(sourceLine.address),
                    sourceLine.file.map(Binding.text) ?? .null,
                    .int64(Int64(sourceLine.line)),
                    .int64(Int64(sourceLine.column)),
                    .int64(sourceLine.endSequence ? 1 : 0),
                    sourceLine.debugArtifactUUID.map { .text($0.uuidString) } ?? .null,
                    sourceLine.debugArtifactMachOSHA256.map(Binding.text) ?? .null,
                    sourceLine.debugArtifactMachOByteCount.map(Binding.uint64) ?? .null,
                    sourceLine.lineProgramUnitOffset.map(Binding.uint64) ?? .null,
                    sourceLine.fileTableIndex.map { .int64(Int64($0)) } ?? .null,
                    tablePathKind.map(Binding.text) ?? .null,
                    tablePathValue.map(Binding.text) ?? .null
                ]
            )
        }

        let functionRanges = FunctionRangeIndex(functionIDsByAddressRange)
        for instruction in analysis.instructions {
            guard let functionID = functionRanges.functionID(for: instruction.address) else {
                continue
            }

            try insertInstruction(
                InstructionRecord(
                    id: nil,
                    functionID: functionID,
                    address: instruction.address,
                    bytes: Self.data(fromHexByteString: instruction.bytes),
                    mnemonic: instruction.mnemonic,
                    operands: instruction.operands,
                    hasBreakpoint: instruction.hasBreakpoint,
                    comment: instruction.comment,
                    irJSON: nil,
                    structuredOperands: instruction.structuredOperands
                )
            )
        }

        for basicBlock in analysis.basicBlocks {
            guard let functionID = functionIDsByUUID[basicBlock.functionID] else {
                continue
            }

            try insertBasicBlock(
                BasicBlockRecord(
                    id: nil,
                    uuid: basicBlock.id,
                    functionID: functionID,
                    startAddress: basicBlock.startAddress,
                    endAddress: basicBlock.endAddress,
                    instructionCount: basicBlock.instructionCount
                )
            )
        }

        for xref in analysis.xrefs {
            try insertXRef(
                XRefRecord(
                    id: nil,
                    uuid: xref.id,
                    binaryID: binaryID,
                    fromAddress: xref.from,
                    toAddress: xref.to,
                    kind: xref.kind
                )
            )
        }

        for edge in analysis.controlFlowEdges {
            try insertControlFlowEdge(
                ControlFlowEdgeRecord(
                    id: nil,
                    uuid: edge.id,
                    binaryID: binaryID,
                    fromAddress: edge.from,
                    toAddress: edge.to,
                    kind: edge.kind
                )
            )
        }
    }

    private func deleteSnapshotContents(workspaceID: Int64) throws {
        try run("DELETE FROM source_link_states WHERE workspace_id = ?;", bindings: [.int64(workspaceID)])
        try run("DELETE FROM imported_function_prototypes WHERE workspace_id = ?;", bindings: [.int64(workspaceID)])
        try run("DELETE FROM saved_watch_catalogs WHERE workspace_id = ?;",
                bindings: [.int64(workspaceID)])
        try run(
            "DELETE FROM launch_profile_catalogs WHERE workspace_id = ?;",
            bindings: [.int64(workspaceID)]
        )
        try run(
            "DELETE FROM logical_breakpoint_catalogs WHERE workspace_id = ?;",
            bindings: [.int64(workspaceID)]
        )
        try run(
            "DELETE FROM binaries WHERE workspace_id = ?;",
            bindings: [.int64(workspaceID)]
        )
        // Overrides cascade from `workspaces`, not `binaries`, so deleting binaries
        // leaves them behind. Clear them explicitly on the in-place re-save path or
        // the plain re-INSERT collides with idx_address_overrides_workspace_address
        // (UNIQUE) and aborts the save — the normal case once a workspace carries
        // any rename/comment/tag/color.
        try run(
            "DELETE FROM address_overrides WHERE workspace_id = ?;",
            bindings: [.int64(workspaceID)]
        )
        // Same shape as the overrides: type_definitions cascades from workspaces
        // and has UNIQUE(workspace_id, name), so it must be cleared before re-INSERT
        // on the in-place re-save path or the second save aborts.
        try run(
            "DELETE FROM type_definitions WHERE workspace_id = ?;",
            bindings: [.int64(workspaceID)]
        )
        // manual_xrefs + bookmarks cascade from workspaces and carry UNIQUE indexes too,
        // so the in-place re-save must clear them before re-INSERT or the second save
        // aborts (the same v22 footgun as the overrides/types tables above).
        try run(
            "DELETE FROM manual_xrefs WHERE workspace_id = ?;",
            bindings: [.int64(workspaceID)]
        )
        try run(
            "DELETE FROM bookmarks WHERE workspace_id = ?;",
            bindings: [.int64(workspaceID)]
        )
        // segment_overrides cascades from workspaces and carries UNIQUE(workspace_id,
        // original_name), so the in-place re-save must clear it before re-INSERT or the
        // second save aborts (the same v22/v23 footgun as the tables above).
        try run(
            "DELETE FROM segment_overrides WHERE workspace_id = ?;",
            bindings: [.int64(workspaceID)]
        )
    }

    private static func reconstructArtifactEvidence(
        for record: BinaryRecord
    ) -> (
        reconstruction: MachOSliceArtifactReconstruction?,
        state: MachOSliceArtifactIntegrityState,
        diagnostic: String?
    ) {
        let appearsMachO = record.kind.localizedCaseInsensitiveContains("mach-o")
            || record.kind.localizedCaseInsensitiveContains("app bundle")
        guard appearsMachO else { return (nil, .unavailable, nil) }
        guard record.fileSize >= 0 else {
            let message = "Selected-slice attachment has a negative persisted byte count."
            return (nil, .contradictoryEvidence(diagnostic: message), message)
        }
        guard let bytes = record.hexBytes else {
            if record.fileSize == 0 { return (nil, .unavailable, nil) }
            let message = "Selected-slice attachment bytes are missing for a nonzero persisted byte count."
            return (nil, .contradictoryEvidence(diagnostic: message), message)
        }
        if bytes.isEmpty, record.fileSize == 0 { return (nil, .unavailable, nil) }
        guard Int64(bytes.count) == record.fileSize else {
            let message = "Selected-slice attachment byte count disagrees with persisted evidence."
            return (nil, .contradictoryEvidence(diagnostic: message), message)
        }
        let isCanonicalDigest = record.fileHash.utf8.count == 64
            && record.fileHash.unicodeScalars.allSatisfy { scalar in
                (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
            }
        guard isCanonicalDigest,
              record.fileHash == MacScopeDocumentPackage.fileHash(for: bytes) else {
            let message = "Selected-slice attachment digest disagrees with persisted evidence."
            return (nil, .contradictoryEvidence(diagnostic: message), message)
        }
        do {
            let reconstruction = try MachOSliceArtifactReconstructor
                .reconstructOrMarkUnavailableForAnonymousObject(
                    selectedSliceBytes: bytes
                )
            return (
                reconstruction,
                reconstruction == nil ? .unavailable : .verified,
                nil
            )
        } catch {
            let message = "Selected-slice attachment cannot be reconstructed as a complete Mach-O slice."
            return (nil, .contradictoryEvidence(diagnostic: message), message)
        }
    }

    func loadSnapshot(workspaceID: Int64) throws -> WorkspaceSnapshot? {
        guard var snapshot = try loadSnapshotContents(workspaceID: workspaceID),
              let workspace = try workspace(id: workspaceID) else {
            return nil
        }
        snapshot.logicalBreakpointCatalog = try loadLogicalBreakpointCatalog(
            workspaceID: workspaceID,
            workspaceUUID: workspace.uuid
        )
        snapshot.launchProfileCatalog = try loadLaunchProfileCatalog(
            workspaceID: workspaceID,
            workspaceUUID: workspace.uuid
        )
        snapshot.savedWatchCatalog = try loadSavedWatchCatalog(
            workspaceID: workspaceID, workspaceUUID: workspace.uuid
        )
        return snapshot
    }

    private func loadSnapshotContents(workspaceID: Int64) throws -> WorkspaceSnapshot? {
        guard try workspace(id: workspaceID) != nil else {
            return nil
        }

        let binaryRecords = try binaries(workspaceID: workspaceID)
        var integrityDiagnosticsBySlot: [ImageSlot: AnalysisDiagnostic] = [:]
        let binaryImages = binaryRecords.map { record in
            let evidence = Self.reconstructArtifactEvidence(for: record)
            let slot = ImageSlot(rawValue: record.imageSlot)
            if let diagnostic = evidence.diagnostic {
                integrityDiagnosticsBySlot[slot] = AnalysisDiagnostic(
                    severity: .error,
                    address: 0,
                    kind: .loaderTruncation,
                    message: diagnostic
                )
            }
            return BinaryImage(
                id: record.uuid,
                name: record.name,
                path: record.path,
                kind: record.kind,
                architecture: record.architecture,
                originalPathBookmark: record.originalPathBookmark,
                metadata: record.metadata,
                selectedSliceIndex: record.selectedSliceIndex,
                machOSelectedSliceFact: record.machOSelectedSliceFact,
                elfArchiveMemberIdentity: record.elfArchiveMemberIdentity,
                artifactIdentity: evidence.reconstruction?.identity,
                preferredSegmentLayout: evidence.reconstruction?.preferredSegmentLayout,
                artifactIntegrityState: evidence.state,
                resolvedExecutablePath: nil,
                slot: slot
            )
        }

        var analysisBySlot: [ImageSlot: ImageAnalysis] = [:]
        for binary in binaryRecords {
            guard let binaryID = binary.id else {
                throw DatabaseError.notFound
            }
            let slot = ImageSlot(rawValue: binary.imageSlot)
            let functionRecords = try functions(binaryID: binaryID)
            var functionSummaries = functionRecords.map {
                // Prefer an explicitly stored demangled name; otherwise attempt a display-time
                // C++/Swift demangling of the raw symbol name, falling back to a synthesized name.
                let displayName = $0.demangledName
                    ?? $0.symbolName.map(Demangler.displayName(for:))
                    ?? "sub_\($0.startAddress.hexAddress)"
                return FunctionSummary(
                    id: $0.uuid,
                    name: displayName,
                    startAddress: $0.startAddress,
                    endAddress: $0.endAddress ?? $0.startAddress,
                    confidence: $0.confidence,
                    // An unknown raw value (a newer build's provenance) loads as "not known".
                    noReturnProvenance: $0.noReturnProvenance.flatMap(AnalysisNoReturnProvenance.init(rawValue:))
                )
            }
            let symbolSummaries = try symbols(binaryID: binaryID).map {
                SymbolSummary(
                    id: $0.uuid,
                    // Display-time demangling of C++/Swift mangled names. The
                    // stored `name` column is left untouched; only the shown
                    // name is transformed (falls back to the raw name on nil).
                    name: Demangler.displayName(for: $0.name),
                    address: $0.address,
                    kind: $0.kind,
                    libraryName: $0.libraryName,
                    rawLinkageName: $0.rawLinkageName
                )
            }
            let importSummaries = try imports(binaryID: binaryID).map {
                ImportSummary(
                    id: $0.uuid,
                    name: $0.name,
                    libraryName: $0.libraryName,
                    libraryOrdinal: $0.libraryOrdinal
                )
            }
            let indirectSymbolSummaries = try indirectSymbols(binaryID: binaryID).map {
                IndirectSymbolSummary(
                    id: $0.uuid,
                    kind: $0.kind,
                    sourceSection: $0.sourceSection,
                    address: $0.address,
                    entrySize: $0.entrySize,
                    tableIndex: $0.tableIndex,
                    rawSymbolIndex: $0.rawSymbolIndex,
                    symbolIndex: $0.symbolIndex,
                    symbolName: $0.symbolName,
                    libraryOrdinal: $0.libraryOrdinal,
                    libraryName: $0.libraryName,
                    isLocal: $0.isLocal,
                    isAbsolute: $0.isAbsolute
                )
            }
            let exportSummaries = try exports(binaryID: binaryID).map {
                ExportSummary(
                    id: $0.uuid,
                    name: $0.name,
                    address: $0.address,
                    source: $0.source,
                    terminalFlags: $0.terminalFlags
                )
            }
            let stringLiteralSummaries = try stringLiterals(binaryID: binaryID).map {
                StringLiteralSummary(
                    id: $0.uuid,
                    value: $0.value,
                    address: $0.address,
                    sourceSection: $0.sourceSection,
                    byteLength: $0.byteLength
                )
            }
            let sourceLineEntries = try sourceLines(binaryID: binaryID)

            var basicBlockRows: [BasicBlockSummary] = []
            var instructionRows: [InstructionRow] = []
            var fallbackHexBytes = Data()
            for function in functionRecords {
                guard let functionID = function.id else { continue }
                basicBlockRows.append(contentsOf: try basicBlocks(functionID: functionID).map {
                    BasicBlockSummary(
                        id: $0.uuid,
                        functionID: function.uuid,
                        startAddress: $0.startAddress,
                        endAddress: $0.endAddress,
                        instructionCount: $0.instructionCount
                    )
                })

                let records = try instructions(functionID: functionID)
                instructionRows.append(contentsOf: records.map {
                    InstructionRow(
                        address: $0.address,
                        bytes: Self.hexByteString(from: $0.bytes),
                        mnemonic: $0.mnemonic,
                        operands: $0.operands,
                        hasBreakpoint: $0.hasBreakpoint,
                        comment: $0.comment,
                        structuredOperands: $0.structuredOperands
                    )
                })
                for record in records {
                    fallbackHexBytes.append(record.bytes)
                }
            }

            let xrefRows = try xrefs(binaryID: binaryID).map {
                XRef(
                    id: $0.uuid,
                    from: $0.fromAddress,
                    to: $0.toAddress,
                    kind: $0.kind
                )
            }
            let controlFlowEdgeRows = try controlFlowEdges(binaryID: binaryID).map {
                ControlFlowEdge(
                    id: $0.uuid,
                    from: $0.fromAddress,
                    to: $0.toAddress,
                    kind: $0.kind
                )
            }

            basicBlockRows.sort { $0.startAddress < $1.startAddress }
            instructionRows.sort { $0.address < $1.address }
            functionSummaries.sort { $0.startAddress < $1.startAddress }

            let storedPayload = binary.hexBytes ?? Data()
            let boundedHexBytes = storedPayload.isEmpty
                ? Data(fallbackHexBytes.prefix(WorkspaceSnapshot.hexViewByteWindow))
                : Data(storedPayload.prefix(WorkspaceSnapshot.hexViewByteWindow))
            analysisBySlot[slot] = ImageAnalysis(
                functions: functionSummaries,
                symbols: symbolSummaries,
                imports: importSummaries,
                indirectSymbols: indirectSymbolSummaries,
                exports: exportSummaries,
                stringLiterals: stringLiteralSummaries,
                basicBlocks: basicBlockRows,
                instructions: instructionRows,
                xrefs: xrefRows.sorted { $0.from < $1.from },
                controlFlowEdges: controlFlowEdgeRows.sorted { $0.from < $1.from },
                hexBytes: boundedHexBytes,
                constantStrings: ImageConstantStringProvider.build(
                    stringLiterals: stringLiteralSummaries, cfStrings: try constantCFStrings(binaryID: binaryID)
                ),
                sourceLines: sourceLineEntries,
                imageBytes: storedPayload,
                diagnostics: integrityDiagnosticsBySlot[slot].map { [$0] } ?? [],
                analysisInputFingerprint: try Self.decodeAnalysisInputFingerprintJSON(
                    binary.analysisInputFingerprintJSON
                )
            )
        }

        var overrideMap: [ImageAddress: AddressOverride] = [:]
        for record in try addressOverrides(workspaceID: workspaceID) {
            let override = AddressOverride(
                customName: record.customName,
                customComment: record.customComment,
                tag: record.tag,
                colorTag: record.colorTag.flatMap(ColorTag.init(rawValue:)),
                isData: record.isData,
                signature: Self.decodeSignature(record.signatureJSON),
                appliedTypeName: record.appliedTypeName,
                switchHint: Self.decodeSwitchHint(record.switchHintJSON),
                operandFormat: record.operandFormat.flatMap(OperandFormat.init(rawValue:)),
                markAsProcedure: record.markAsProcedure,
                dataShape: Self.decodeDataShape(record.dataShapeJSON),
                isUndefined: record.isUndefined,
                patch: Self.decodePatch(record.patchJSON),
                appendedExecutableCave: try Self.decodeAppendedCave(record.appendedCaveJSON),
                registerNames: Self.decodeRegisterNames(record.registerNamesJSON),
                stackLocals: Self.decodeStackLocals(record.stackLocalsJSON),
                localLabel: record.localLabel
            )
            if !override.isEmpty {
                overrideMap[ImageAddress(slot: ImageSlot(rawValue: record.imageSlot), address: record.address)] = override
            }
        }

        let typeCatalog: [TypeDefinition] = try typeDefinitions(workspaceID: workspaceID).map { record in
            guard let kind = TypeKind(rawValue: record.kind) else {
                throw DatabaseError.corruptRow(
                    table: "type_definitions",
                    rowIdentity: record.id.uuidString,
                    field: "kind"
                )
            }
            let fields: [FieldDef]
            do {
                fields = try WorkspaceTypeDefinitionDatabaseCodec.decodeFields(record.fieldsJSON)
            } catch {
                throw DatabaseError.corruptRow(
                    table: "type_definitions",
                    rowIdentity: record.id.uuidString,
                    field: "fields_json"
                )
            }
            let layout: (rules: AggregateLayoutRules, vectorByteSize: Int?, enumValuesIncomplete: Bool?)
            var provenance: TypeInferenceProvenance?
            if let layoutRulesJSON = record.layoutRulesJSON {
                do {
                    layout = try WorkspaceTypeDefinitionDatabaseCodec.decodeTypeLayout(layoutRulesJSON)
                    provenance = try WorkspaceTypeDefinitionDatabaseCodec.decodeInferenceProvenance(layoutRulesJSON)
                } catch {
                    throw DatabaseError.corruptRow(
                        table: "type_definitions",
                        rowIdentity: record.id.uuidString,
                        field: "layout_rules_json"
                    )
                }
            } else {
                layout = (.default, nil, nil)
            }
            return TypeDefinition(
                id: record.id,
                kind: kind,
                name: record.name,
                fields: fields,
                layoutRules: layout.rules,
                vectorByteSize: layout.vectorByteSize,
                enumValuesIncomplete: layout.enumValuesIncomplete,
                inferenceProvenance: provenance
            )
        }

        let manualXRefRecords: [ManualXRef] = try manualXRefs(workspaceID: workspaceID).map { record in
            ManualXRef(id: record.id, from: record.fromAddress, to: record.toAddress, kind: record.kind,
                       isSuppression: record.isSuppression, imageSlot: ImageSlot(rawValue: record.imageSlot))
        }
        let bookmarkRecords: [Bookmark] = try bookmarks(workspaceID: workspaceID).map { record in
            Bookmark(id: record.id, address: record.address, imageSlot: ImageSlot(rawValue: record.imageSlot), name: record.name)
        }
        let segmentOverrideRecords: [SegmentOverride] = try segmentOverrides(workspaceID: workspaceID).map { record in
            SegmentOverride(id: record.id, originalName: record.originalName, imageSlot: ImageSlot(rawValue: record.imageSlot),
                            displayName: record.displayName, rebaseDelta: record.rebaseDelta)
        }

        return WorkspaceSnapshot(
            binaries: binaryImages,
            analysisBySlot: analysisBySlot,
            addressOverrides: overrideMap,
            importedPrototypes: try loadImportedPrototypes(workspaceID: workspaceID),
            typeDefinitions: typeCatalog,
            manualXRefs: manualXRefRecords,
            bookmarks: bookmarkRecords,
            segmentOverrides: segmentOverrideRecords,
            sourceLinkState: try loadSourceLinkState(workspaceID: workspaceID)
        )
    }

    private func loadSourceLinkState(workspaceID: Int64) throws -> Data {
        let rows = try query(
            "SELECT state_blob, length(state_blob) FROM source_link_states WHERE workspace_id = ?;",
            bindings: [.int64(workspaceID)]
        ) { statement in
            guard sqlite3_column_type(statement, 0) == SQLITE_BLOB,
                  sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
                  sqlite3_column_int64(statement, 1) <= 1_048_576 else {
                throw DatabaseError.stepFailed("Source evidence has invalid storage or exceeds its bound.")
            }
            return Self.blobColumn(statement, 0)
        }
        return rows.first ?? Data()
    }

    private func loadImportedPrototypes(workspaceID: Int64) throws -> [ImageAddress: FunctionSignatureOverride] {
        let rows = try query("SELECT prototypes_json FROM imported_function_prototypes WHERE workspace_id = ?;",
                             bindings: [.int64(workspaceID)]) { statement in
            try Self.textColumn(statement, 0)
        }
        guard let json = rows.first else { return [:] }
        return ImportedPrototypeEntry.map(from: try JSONDecoder().decode(
            [ImportedPrototypeEntry].self, from: Data(json.utf8)))
    }

    enum Binding {
        case address(UInt64)
        case blob(Data)
        case bool(Bool)
        case double(Double)
        case int64(Int64)
        case null
        case text(String)
        case uint64(UInt64)
    }

    /// JSON-encodes a function signature override for the `signature_json` column.
    /// Empty/nil overrides store NULL so a no-op signature never lingers.
    private static func encodeSignature(_ signature: FunctionSignatureOverride?) -> String? {
        guard let signature, !signature.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(signature) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decodes the `signature_json` column leniently — malformed JSON degrades to
    /// nil rather than failing the whole snapshot load.
    private static func decodeSignature(_ json: String?) -> FunctionSignatureOverride? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(FunctionSignatureOverride.self, from: data)
    }

    /// JSON-encodes a switch hint for the `switch_hint_json` column. Empty/nil
    /// hints store NULL so a no-op declaration never lingers.
    private static func encodeSwitchHint(_ hint: SwitchHintOverride?) -> String? {
        guard let hint, !hint.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(hint) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decodes the `switch_hint_json` column leniently — malformed JSON degrades to
    /// nil rather than failing the whole snapshot load.
    private static func decodeSwitchHint(_ json: String?) -> SwitchHintOverride? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SwitchHintOverride.self, from: data)
    }

    /// JSON-encodes a data shape for the `data_shape_json` column. Empty/nil shapes
    /// store NULL so a cleared shape never lingers.
    private static func encodeDataShape(_ shape: DataShapeOverride?) -> String? {
        guard let shape, !shape.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(shape) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decodes the `data_shape_json` column leniently — malformed JSON degrades to
    /// nil rather than failing the whole snapshot load.
    private static func decodeDataShape(_ json: String?) -> DataShapeOverride? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DataShapeOverride.self, from: data)
    }

    /// JSON-encodes a byte patch for the `patch_json` column. Empty/nil patches store
    /// NULL so a cleared patch never lingers.
    private static func encodePatch(_ patch: BytePatch?) -> String? {
        guard let patch, !patch.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(patch) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decodes the `patch_json` column leniently — malformed JSON degrades to nil rather
    /// than failing the whole snapshot load.
    private static func decodePatch(_ json: String?) -> BytePatch? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(BytePatch.self, from: data)
    }

    private static func encodeAppendedCave(_ cave: AppendedExecutableCaveAuthoring?) throws -> String? {
        guard let cave else { return nil }
        guard cave.isWellFormed else {
            throw DatabaseError.corruptRow(table: "address_overrides", rowIdentity: "new", field: "appended_cave_json")
        }
        return String(data: try JSONEncoder().encode(cave), encoding: .utf8)
    }

    private static func decodeAppendedCave(_ json: String?) throws -> AppendedExecutableCaveAuthoring? {
        guard let json else { return nil }
        guard let data = json.data(using: .utf8),
              let cave = try? JSONDecoder().decode(AppendedExecutableCaveAuthoring.self, from: data),
              cave.isWellFormed else {
            throw DatabaseError.corruptRow(table: "address_overrides", rowIdentity: "unknown", field: "appended_cave_json")
        }
        return cave
    }

    /// Encodes a register-name map (register-id → display-name) for the `register_names_json`
    /// column. An empty/nil map (after pruning blanks) stores NULL so a cleared rename never
    /// lingers, mirroring the other optional override columns.
    private static func encodeRegisterNames(_ names: [String: String]?) -> String? {
        guard let names else { return nil }
        let pruned = AddressOverride.prunedRegisterNames(names)
        guard !pruned.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(pruned) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// DP04 C1: the `stack_locals_json` column (authoring key → name/type). Sorted keys keep
    /// the stored JSON deterministic; an empty map stores NULL.
    private static func encodeStackLocals(_ locals: [String: StackLocalOverride]?) -> String? {
        guard let locals else { return nil }
        let pruned = AddressOverride.prunedStackLocals(locals)
        guard !pruned.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(pruned) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decodes `stack_locals_json` leniently, like `register_names_json`.
    private static func decodeStackLocals(_ json: String?) -> [String: StackLocalOverride]? {
        guard let json, let data = json.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: StackLocalOverride].self, from: data) else { return nil }
        let pruned = AddressOverride.prunedStackLocals(map)
        return pruned.isEmpty ? nil : pruned
    }

    /// Decodes the `register_names_json` column leniently — malformed JSON degrades to nil.
    private static func decodeRegisterNames(_ json: String?) -> [String: String]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        guard let map = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        let pruned = AddressOverride.prunedRegisterNames(map)
        return pruned.isEmpty ? nil : pruned
    }

    private static func encodeRuntimeAuthoritySurfaces(
        _ surfaces: Set<Phase2RuntimeAuthoritySurface>
    ) throws -> String {
        let values = surfaces.map(\.rawValue).sorted()
        let data = try JSONEncoder().encode(values)
        guard let string = String(data: data, encoding: .utf8) else {
            throw DatabaseError.invalidPhase2RuntimeAuthority("surfaces-json-encoding")
        }
        return string
    }

    private static func decodeRuntimeAuthoritySurfaces(
        _ json: String
    ) throws -> Set<Phase2RuntimeAuthoritySurface> {
        guard let data = json.data(using: .utf8) else {
            throw DatabaseError.invalidPhase2RuntimeAuthority("surfaces-json-utf8")
        }
        let values = try JSONDecoder().decode([String].self, from: data)
        var surfaces = Set<Phase2RuntimeAuthoritySurface>()
        for value in values {
            guard let surface = Phase2RuntimeAuthoritySurface(rawValue: value) else {
                throw DatabaseError.invalidPhase2RuntimeAuthority(value)
            }
            surfaces.insert(surface)
        }
        return surfaces
    }

    private static func encodeDebuggerAuthorityPolicy(
        _ policy: Phase2DebuggerAuthorityToolPolicy
    ) throws -> String {
        let data = try JSONEncoder().encode(policy)
        guard let string = String(data: data, encoding: .utf8) else {
            throw DatabaseError.invalidPhase2RuntimeAuthority("debugger-policy-json-encoding")
        }
        return string
    }

    private static func decodeDebuggerAuthorityPolicy(
        _ json: String
    ) throws -> Phase2DebuggerAuthorityToolPolicy {
        guard let data = json.data(using: .utf8) else {
            throw DatabaseError.invalidPhase2RuntimeAuthority("debugger-policy-json-utf8")
        }
        let policy = try JSONDecoder().decode(Phase2DebuggerAuthorityToolPolicy.self, from: data)
        guard policy.isStructurallyValid else {
            throw DatabaseError.invalidPhase2RuntimeAuthority("debugger-policy-structural")
        }
        return policy
    }

    private static func encodePhase2ShellSessionJSON(
        _ session: WorkspacePackagePhase2ShellSession
    ) throws -> String {
        let data = try JSONEncoder().encode(session)
        guard let string = String(data: data, encoding: .utf8) else {
            throw DatabaseError.invalidPhase2RuntimeAuthority("shell-session-json-encoding")
        }
        return string
    }

    private static func decodePhase2ShellSessionJSON(
        _ json: String
    ) throws -> WorkspacePackagePhase2ShellSession {
        guard let data = json.data(using: .utf8) else {
            throw DatabaseError.invalidPhase2RuntimeAuthority("shell-session-json-utf8")
        }
        return try JSONDecoder().decode(WorkspacePackagePhase2ShellSession.self, from: data)
    }

    private static func string(from date: Date) -> String {
        dateFormatter().string(from: date)
    }

    private static func date(from string: String) -> Date? {
        dateFormatter().date(from: string)
    }

    private static func dateFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(try requireConnection(), sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastErrorMessage()
            sqlite3_free(errorMessage)
            throw DatabaseError.stepFailed(message)
        }
    }

    func withOwnerReplayTransaction<T>(_ body: () throws -> T) throws -> T {
        try transaction(body)
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let value = try body()
            try execute("COMMIT;")
            return value
        } catch {
            let original = error
            do {
                if transactionRollbackFailureForTesting {
                    transactionRollbackFailureForTesting = false
                    throw DatabaseError.stepFailed("Injected transaction rollback failure.")
                }
                try execute("ROLLBACK;")
            } catch let rollbackError {
                invalidateConnectionAfterRollbackFailure()
                throw DatabaseError.transactionRollbackFailed(
                    original: String(describing: original),
                    rollback: String(describing: rollbackError)
                )
            }
            throw original
        }
    }

    /// An unsuccessful rollback leaves SQLite's transaction state unknown to this object. Clear
    /// the handle before requesting close so no subsequent API can accidentally reuse it; close_v2
    /// also handles any SQLite-owned cleanup that remains after an I/O-level rollback failure.
    private func invalidateConnectionAfterRollbackFailure() {
        guard let connection else { return }
        finalizeRunStatements()
        self.connection = nil
        _ = sqlite3_close_v2(connection)
    }

    func run(_ sql: String, bindings: [Binding] = []) throws {
        // `run` steps once to completion with no callbacks, so a cached statement is never in use
        // when it is handed out again. Past the limit (dynamic SQL), statements are not kept.
        let cached = runStatements[sql]
        let statement = try cached ?? prepare(sql)
        let keeps = cached != nil || runStatements.count < Self.runStatementLimit
        if cached == nil, keeps { runStatements[sql] = statement }
        defer {
            if keeps {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            } else {
                sqlite3_finalize(statement)
            }
        }
        try bind(bindings, to: statement)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.stepFailed(lastErrorMessage())
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        guard let value = try first(sql, bindings: [], map: { Int(sqlite3_column_int($0, 0)) }) else {
            throw DatabaseError.notFound
        }
        return value
    }

    private func first<T>(
        _ sql: String,
        bindings: [Binding] = [],
        map: (OpaquePointer) throws -> T
    ) throws -> T? {
        let values: [T] = try query(sql, bindings: bindings, map: map)
        return values.first
    }

    func query<T>(
        _ sql: String,
        bindings: [Binding] = [],
        map: (OpaquePointer) throws -> T
    ) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)

        var values: [T] = []
        while true {
            let status = sqlite3_step(statement)
            switch status {
            case SQLITE_ROW:
                values.append(try map(statement))
            case SQLITE_DONE:
                return values
            default:
                throw DatabaseError.stepFailed(lastErrorMessage())
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(try requireConnection(), sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError.prepareFailed(lastErrorMessage())
        }
        return statement
    }

    private func bind(_ bindings: [Binding], to statement: OpaquePointer) throws {
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32

            switch binding {
            case .address(let value):
                result = sqlite3_bind_int64(statement, index, Int64(bitPattern: value))
            case .blob(let data):
                if data.isEmpty {
                    result = sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    result = data.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(data.count), Self.sqliteTransient)
                    }
                }
            case .bool(let value):
                result = sqlite3_bind_int64(statement, index, value ? 1 : 0)
            case .double(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .int64(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
            case .uint64(let value):
                guard value <= UInt64(Int64.max) else {
                    throw DatabaseError.invalidAddress(value)
                }
                result = sqlite3_bind_int64(statement, index, Int64(value))
            }

            guard result == SQLITE_OK else {
                throw DatabaseError.bindFailed(lastErrorMessage())
            }
        }
    }

    func requireConnection() throws -> OpaquePointer {
        guard let connection else {
            throw DatabaseError.openFailed("Database connection is closed.")
        }
        return connection
    }

    private func lastErrorMessage() -> String {
        guard let connection else { return "Database connection is closed." }
        return String(cString: sqlite3_errmsg(connection))
    }

    /// Address → function row for one image's instruction insert: the first function (in
    /// analysis order) whose range contains the address, else the first function. Lane AG: the
    /// former per-instruction linear scan made Save O(instructions × functions) — about 4e9 range
    /// checks for a vim-scale import in Debug. When the ranges are pairwise disjoint (the normal
    /// case) at most one range contains any address, so a binary search over start-sorted ranges
    /// returns the same row; overlapping ranges keep the ordered linear scan.
    struct FunctionRangeIndex {
        private let ranges: [(record: FunctionRecord, id: Int64)]
        private let disjointByStart: [(start: UInt64, end: UInt64, id: Int64)]?

        init(_ ranges: [(record: FunctionRecord, id: Int64)]) {
            self.ranges = ranges
            let sorted = ranges
                .map { (start: $0.record.startAddress, end: $0.record.endAddress ?? UInt64.max, id: $0.id) }
                .sorted { $0.start < $1.start }
            var disjoint = true
            var index = 1
            while index < sorted.count {
                if sorted[index - 1].end > sorted[index].start {
                    disjoint = false
                    break
                }
                index += 1
            }
            disjointByStart = disjoint ? sorted : nil
        }

        func functionID(for address: UInt64) -> Int64? {
            guard let sorted = disjointByStart else {
                return ranges.first { item in
                    address >= item.record.startAddress
                        && address < (item.record.endAddress ?? UInt64.max)
                }?.id ?? ranges.first?.id
            }
            var low = 0
            var high = sorted.count
            while low < high {
                let middle = (low + high) / 2
                if sorted[middle].start <= address { low = middle + 1 } else { high = middle }
            }
            if low > 0, address < sorted[low - 1].end { return sorted[low - 1].id }
            return ranges.first?.id
        }
    }

    private func defaultWorkspaceSession(
        workspaceID: Int64,
        snapshot: WorkspaceSnapshot,
        updatedAt: Date
    ) -> WorkspaceSessionRecord {
        WorkspaceSessionRecord(
            workspaceID: workspaceID,
            selectedSidebarItemID: snapshot.binaries.first.map { "binary:\($0.id.uuidString)" },
            selectedAddress: snapshot.instructions.first?.address,
            selectedTool: .project,
            editorMode: .disassembly,
            isInspectorPresented: true,
            sidebarSearchText: "",
            updatedAt: updatedAt,
            focusedImageSlot: snapshot.primarySlot
        )
    }

    private static func canonicalPackageURL(
        from url: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try WorkspaceDocumentLocation.canonicalized(
            from: url,
            fileManager: fileManager
        ).canonicalURL
    }

    private static func isCanonicalAbsolutePackagePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/" else { return false }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path == path
    }

    private static func packagePath(
        from url: URL,
        fileManager: FileManager = .default
    ) throws -> String {
        try canonicalPackageURL(from: url, fileManager: fileManager).path
    }

    private static func workspaceRecord(from statement: OpaquePointer) throws -> WorkspaceRecord {
        let uuidString = try textColumn(statement, 1)
        let createdAtString = try textColumn(statement, 3)
        let modifiedAtString = try textColumn(statement, 4)

        guard let uuid = UUID(uuidString: uuidString) else {
            throw DatabaseError.invalidUUID(uuidString)
        }
        guard let createdAt = date(from: createdAtString) else {
            throw DatabaseError.invalidDate(createdAtString)
        }
        guard let modifiedAt = date(from: modifiedAtString) else {
            throw DatabaseError.invalidDate(modifiedAtString)
        }

        return WorkspaceRecord(
            id: sqlite3_column_int64(statement, 0),
            uuid: uuid,
            name: try textColumn(statement, 2),
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )
    }

    private static func binaryRecord(from statement: OpaquePointer) throws -> BinaryRecord {
        let uuidString = try textColumn(statement, 1)
        guard let uuid = UUID(uuidString: uuidString) else {
            throw DatabaseError.invalidUUID(uuidString)
        }

        let record = BinaryRecord(
            id: sqlite3_column_int64(statement, 0),
            uuid: uuid,
            workspaceID: sqlite3_column_int64(statement, 2),
            name: try textColumn(statement, 3),
            path: try textColumn(statement, 4),
            originalPathBookmark: optionalBlobColumn(statement, 5),
            kind: try textColumn(statement, 6),
            architecture: try textColumn(statement, 7),
            fileHash: try textColumn(statement, 8),
            fileSize: sqlite3_column_int64(statement, 9),
            hexBytes: optionalBlobColumn(statement, 10),
            isBundle: sqlite3_column_int64(statement, 11) != 0,
            imageSlot: Int(sqlite3_column_int64(statement, 12)),
            selectedSliceIndex: optionalIntColumn(statement, 13),
            machOSelectedSliceFact: try decodeMachOSelectedSliceFactJSON(
                optionalTextColumn(statement, 17)
            ),
            analysisInputFingerprintJSON: optionalTextColumn(statement, 14),
            metadata: try decodeBinaryMetadataJSON(optionalTextColumn(statement, 15)),
            elfArchiveMemberIdentity: try decodeELFArchiveMemberIdentityJSON(
                optionalTextColumn(statement, 16)
            )
        )
        if let archive = record.elfArchiveMemberIdentity {
            guard record.selectedSliceIndex == nil,
                  record.machOSelectedSliceFact == nil,
                  record.fileSize == Int64(archive.member.byteCount),
                  record.fileHash == archive.member.sha256,
                  record.hexBytes.map({
                      $0.count == archive.member.byteCount
                          && MacScopeDocumentPackage.fileHash(for: $0) == archive.member.sha256
                  }) ?? (record.fileSize == 0) else {
                throw DatabaseError.corruptRow(
                    table: "binaries",
                    rowIdentity: uuid.uuidString,
                    field: "elf_archive_member_identity_json"
                )
            }
        }
        let fingerprint = try decodeAnalysisInputFingerprintJSON(
            record.analysisInputFingerprintJSON
        )
        if let fingerprint,
           fingerprint.elfArchiveMemberIdentity != record.elfArchiveMemberIdentity {
            // The fingerprint and binary row are independent persisted anchors for an archive
            // selection. Once either anchor says this image came from an outer archive, deleting
            // or changing the other cannot silently downgrade the record to an ordinary ELF.
            // A genuinely legacy row has no fingerprint (or has nil in both anchors) and remains
            // readable through the compatibility defaults above.
            throw DatabaseError.corruptRow(
                table: "binaries",
                rowIdentity: uuid.uuidString,
                field: "elf_archive_member_identity_json"
            )
        }
        if let fingerprint {
            let hasPersistedMetadataFacet = fingerprint.facets.contains {
                $0.kind == .machOLoadMetadata
            }
            // Schema-v41 stores empty metadata canonically as SQL NULL. Fingerprints written
            // before loader-metadata persistence can therefore have neither a metadata facet nor
            // metadata JSON; that is a valid legacy absence, not corruption. Once either anchor
            // is present, however, require the independent attachment-bound comparison so deleting
            // either a GNU build ID or its facet alone cannot silently downgrade a current row.
            if (hasPersistedMetadataFacet || record.metadata != .empty),
               try !AnalysisFingerprintBuilder.persistedELFLoadMetadataMatchesFingerprint(
                attachmentData: record.hexBytes ?? Data(),
                persistedKind: record.kind,
                metadata: record.metadata,
                fingerprint: fingerprint
               ) {
                throw DatabaseError.corruptRow(
                    table: "binaries",
                    rowIdentity: uuid.uuidString,
                    field: "binary_metadata_json"
                )
            }
        }
        return record
    }

    private static func encodeMachOSelectedSliceFactJSON(
        _ fact: MachOSelectedSliceFact?
    ) throws -> String? {
        guard let fact else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(fact)
        guard let json = String(data: data, encoding: .utf8) else {
            throw DatabaseError.stepFailed("Could not encode Mach-O selected-slice fact as UTF-8.")
        }
        return json
    }

    private static func decodeMachOSelectedSliceFactJSON(
        _ json: String?
    ) throws -> MachOSelectedSliceFact? {
        guard let json else { return nil }
        guard let data = json.data(using: .utf8) else {
            throw DatabaseError.stepFailed("Could not decode Mach-O selected-slice fact as UTF-8.")
        }
        return try JSONDecoder().decode(MachOSelectedSliceFact.self, from: data)
    }

    private static func encodeBinaryMetadataJSON(
        _ metadata: BinaryMetadataSummary
    ) throws -> String? {
        guard metadata != .empty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(metadata)
        guard let json = String(data: data, encoding: .utf8) else {
            throw DatabaseError.stepFailed("Could not encode binary metadata JSON as UTF-8.")
        }
        return json
    }

    private static func decodeBinaryMetadataJSON(
        _ json: String?
    ) throws -> BinaryMetadataSummary {
        guard let json else { return .empty }
        guard let data = json.data(using: .utf8) else {
            throw DatabaseError.stepFailed("Could not decode binary metadata JSON as UTF-8.")
        }
        return try JSONDecoder().decode(BinaryMetadataSummary.self, from: data)
    }

    private static func encodeELFArchiveMemberIdentityJSON(
        _ selection: ELFArchiveMemberSelection?
    ) throws -> String? {
        guard let selection else { return nil }
        guard BinaryImage.isValidArchiveMemberIdentity(selection) else {
            throw DatabaseError.stepFailed("ELF archive member identity is malformed.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(selection)
        guard let json = String(data: data, encoding: .utf8) else {
            throw DatabaseError.stepFailed("Could not encode ELF archive member identity JSON as UTF-8.")
        }
        return json
    }

    private static func decodeELFArchiveMemberIdentityJSON(
        _ json: String?
    ) throws -> ELFArchiveMemberSelection? {
        guard let json else { return nil }
        guard let data = json.data(using: .utf8) else {
            throw DatabaseError.stepFailed("Could not decode ELF archive member identity JSON as UTF-8.")
        }
        let selection = try JSONDecoder().decode(ELFArchiveMemberSelection.self, from: data)
        guard BinaryImage.isValidArchiveMemberIdentity(selection) else {
            throw DatabaseError.stepFailed("Persisted ELF archive member identity is malformed.")
        }
        return selection
    }

    private static func encodeAnalysisInputFingerprintJSON(
        _ fingerprint: AnalysisInputFingerprint?
    ) throws -> String? {
        guard let fingerprint else { return nil }
        let data = try JSONEncoder().encode(fingerprint)
        guard let json = String(data: data, encoding: .utf8) else {
            throw DatabaseError.stepFailed("Could not encode analysis input fingerprint JSON as UTF-8.")
        }
        return json
    }

    private static func decodeAnalysisInputFingerprintJSON(
        _ json: String?
    ) throws -> AnalysisInputFingerprint? {
        guard let json else { return nil }
        guard let data = json.data(using: .utf8) else {
            throw DatabaseError.stepFailed("Could not decode analysis input fingerprint JSON as UTF-8.")
        }
        return try JSONDecoder().decode(AnalysisInputFingerprint.self, from: data)
    }

    private static func functionRecord(from statement: OpaquePointer) throws -> FunctionRecord {
        let uuidString = try textColumn(statement, 1)
        guard let uuid = UUID(uuidString: uuidString) else {
            throw DatabaseError.invalidUUID(uuidString)
        }

        return FunctionRecord(
            id: sqlite3_column_int64(statement, 0),
            uuid: uuid,
            binaryID: sqlite3_column_int64(statement, 2),
            startAddress: try addressColumn(statement, 3, field: "functions.start_address"),
            endAddress: try optionalAddressColumn(statement, 4, field: "functions.end_address"),
            symbolName: optionalTextColumn(statement, 5),
            demangledName: optionalTextColumn(statement, 6),
            confidence: sqlite3_column_double(statement, 7),
            noReturnProvenance: optionalTextColumn(statement, 8)
        )
    }

    private static func symbolRecord(from statement: OpaquePointer) throws -> SymbolRecord {
        let uuidString = try textColumn(statement, 1)
        guard let uuid = UUID(uuidString: uuidString) else {
            throw DatabaseError.invalidUUID(uuidString)
        }

        return SymbolRecord(
            id: sqlite3_column_int64(statement, 0),
            uuid: uuid,
            binaryID: sqlite3_column_int64(statement, 2),
            name: try textColumn(statement, 3),
            address: try optionalAddressColumn(statement, 4, field: "symbols.address"),
            kind: try textColumn(statement, 5),
            libraryName: optionalTextColumn(statement, 6),
            rawLinkageName: optionalTextColumn(statement, 7)
        )
    }

    private static func importRecord(from statement: OpaquePointer) throws -> ImportRecord {
        let uuidString = try textColumn(statement, 1)
        guard let uuid = UUID(uuidString: uuidString) else {
            throw DatabaseError.invalidUUID(uuidString)
        }

        return ImportRecord(
            id: sqlite3_column_int64(statement, 0),
            uuid: uuid,
            binaryID: sqlite3_column_int64(statement, 2),
            name: try textColumn(statement, 3),
            libraryName: optionalTextColumn(statement, 4),
            libraryOrdinal: optionalIntColumn(statement, 5)
        )
    }

    private static func indirectSymbolRecord(from statement: OpaquePointer) throws -> IndirectSymbolRecord {
        let uuidString = try textColumn(statement, 1)
        guard let uuid = UUID(uuidString: uuidString) else {
            throw DatabaseError.invalidUUID(uuidString)
        }

        return IndirectSymbolRecord(
            id: sqlite3_column_int64(statement, 0),
            uuid: uuid,
            binaryID: sqlite3_column_int64(statement, 2),
            kind: try textColumn(statement, 3),
            sourceSection: try textColumn(statement, 4),
            address: try addressColumn(statement, 5, field: "indirect_symbols.address"),
            entrySize: try nonnegativeUInt32Column(statement, 6, field: "indirect_symbols.entry_size"),
            tableIndex: try nonnegativeUInt32Column(statement, 7, field: "indirect_symbols.table_index"),
            rawSymbolIndex: try nonnegativeUInt32Column(statement, 8, field: "indirect_symbols.raw_symbol_index"),
            symbolIndex: optionalIntColumn(statement, 9),
            symbolName: optionalTextColumn(statement, 10),
            libraryOrdinal: optionalIntColumn(statement, 11),
            libraryName: optionalTextColumn(statement, 12),
            isLocal: sqlite3_column_int64(statement, 13) != 0,
            isAbsolute: sqlite3_column_int64(statement, 14) != 0
        )
    }

    private static func exportRecord(from statement: OpaquePointer) throws -> ExportRecord {
        let uuidString = try textColumn(statement, 1)
        guard let uuid = UUID(uuidString: uuidString) else {
            throw DatabaseError.invalidUUID(uuidString)
        }

        return ExportRecord(
            id: sqlite3_column_int64(statement, 0),
            uuid: uuid,
            binaryID: sqlite3_column_int64(statement, 2),
            name: try textColumn(statement, 3),
            address: try optionalAddressColumn(statement, 4, field: "exports.address"),
            source: try textColumn(statement, 5),
            terminalFlags: try optionalAddressColumn(statement, 6, field: "exports.terminal_flags")
        )
    }

    private static func instructionRecord(from statement: OpaquePointer) throws -> InstructionRecord {
        InstructionRecord(
            id: sqlite3_column_int64(statement, 0),
            functionID: sqlite3_column_int64(statement, 1),
            address: try addressColumn(statement, 2, field: "instructions.address"),
            bytes: blobColumn(statement, 3),
            mnemonic: try textColumn(statement, 4),
            operands: try textColumn(statement, 5),
            hasBreakpoint: sqlite3_column_int64(statement, 6) != 0,
            comment: optionalTextColumn(statement, 7),
            irJSON: optionalBlobColumn(statement, 8),
            structuredOperands: try instructionOperandsColumn(statement, payloadIndex: 9, lengthIndex: 10)
        )
    }

    private static func basicBlockRecord(from statement: OpaquePointer) throws -> BasicBlockRecord {
        let uuidString = try textColumn(statement, 1)
        guard let uuid = UUID(uuidString: uuidString) else {
            throw DatabaseError.invalidUUID(uuidString)
        }

        return BasicBlockRecord(
            id: sqlite3_column_int64(statement, 0),
            uuid: uuid,
            functionID: sqlite3_column_int64(statement, 2),
            startAddress: try addressColumn(statement, 3, field: "basic_blocks.start_address"),
            endAddress: try addressColumn(statement, 4, field: "basic_blocks.end_address"),
            instructionCount: Int(sqlite3_column_int64(statement, 5))
        )
    }

    private static func xrefRecord(from statement: OpaquePointer) throws -> XRefRecord {
        let uuidString = try textColumn(statement, 1)
        guard let uuid = UUID(uuidString: uuidString) else {
            throw DatabaseError.invalidUUID(uuidString)
        }

        return XRefRecord(
            id: sqlite3_column_int64(statement, 0),
            uuid: uuid,
            binaryID: sqlite3_column_int64(statement, 2),
            fromAddress: try addressColumn(statement, 3, field: "xrefs.from_address"),
            toAddress: try addressColumn(statement, 4, field: "xrefs.to_address"),
            kind: try textColumn(statement, 5)
        )
    }

    private static func controlFlowEdgeRecord(from statement: OpaquePointer) throws -> ControlFlowEdgeRecord {
        let uuidString = try textColumn(statement, 1)
        guard let uuid = UUID(uuidString: uuidString) else {
            throw DatabaseError.invalidUUID(uuidString)
        }

        return ControlFlowEdgeRecord(
            id: sqlite3_column_int64(statement, 0),
            uuid: uuid,
            binaryID: sqlite3_column_int64(statement, 2),
            fromAddress: try addressColumn(statement, 3, field: "control_flow_edges.from_address"),
            toAddress: try addressColumn(statement, 4, field: "control_flow_edges.to_address"),
            kind: try textColumn(statement, 5)
        )
    }

    private static func addressOverrideRecord(from statement: OpaquePointer) throws -> AddressOverrideRecord {
        let createdAtString = try textColumn(statement, 12)
        guard let createdAt = date(from: createdAtString) else {
            throw DatabaseError.invalidDate(createdAtString)
        }
        let modifiedAtString = try textColumn(statement, 13)
        guard let modifiedAt = date(from: modifiedAtString) else {
            throw DatabaseError.invalidDate(modifiedAtString)
        }

        return AddressOverrideRecord(
            id: sqlite3_column_int64(statement, 0),
            workspaceID: sqlite3_column_int64(statement, 1),
            address: try addressColumn(statement, 2, field: "address_overrides.address"),
            imageSlot: Int(sqlite3_column_int64(statement, 20)),
            customName: optionalTextColumn(statement, 3),
            customComment: optionalTextColumn(statement, 4),
            tag: optionalTextColumn(statement, 5),
            colorTag: optionalTextColumn(statement, 6),
            isData: sqlite3_column_int64(statement, 7) != 0,
            signatureJSON: optionalTextColumn(statement, 8),
            appliedTypeName: optionalTextColumn(statement, 9),
            switchHintJSON: optionalTextColumn(statement, 10),
            operandFormat: optionalTextColumn(statement, 11),
            markAsProcedure: sqlite3_column_int64(statement, 14) != 0,
            dataShapeJSON: optionalTextColumn(statement, 15),
            isUndefined: sqlite3_column_int64(statement, 16) != 0,
            patchJSON: optionalTextColumn(statement, 17),
            appendedCaveJSON: optionalTextColumn(statement, 21),
            registerNamesJSON: optionalTextColumn(statement, 18),
            stackLocalsJSON: optionalTextColumn(statement, 22),
            localLabel: optionalTextColumn(statement, 19),
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )
    }

    private static func manualXRefRecord(from statement: OpaquePointer) throws -> ManualXRefRecord {
        let createdAtString = try textColumn(statement, 6)
        guard let createdAt = date(from: createdAtString) else {
            throw DatabaseError.invalidDate(createdAtString)
        }
        let modifiedAtString = try textColumn(statement, 7)
        guard let modifiedAt = date(from: modifiedAtString) else {
            throw DatabaseError.invalidDate(modifiedAtString)
        }
        return ManualXRefRecord(
            // A malformed id degrades to a fresh UUID — manual xrefs match on endpoints,
            // not id, so identity stability isn't load-bearing.
            id: UUID(uuidString: try textColumn(statement, 0)) ?? UUID(),
            workspaceID: sqlite3_column_int64(statement, 1),
            fromAddress: try addressColumn(statement, 2, field: "manual_xrefs.from_address"),
            toAddress: try addressColumn(statement, 3, field: "manual_xrefs.to_address"),
            kind: try textColumn(statement, 4),
            isSuppression: sqlite3_column_int64(statement, 5) != 0,
            imageSlot: Int(sqlite3_column_int64(statement, 8)),
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )
    }

    private static func bookmarkRecord(from statement: OpaquePointer) throws -> BookmarkRecord {
        let createdAtString = try textColumn(statement, 4)
        guard let createdAt = date(from: createdAtString) else {
            throw DatabaseError.invalidDate(createdAtString)
        }
        let modifiedAtString = try textColumn(statement, 5)
        guard let modifiedAt = date(from: modifiedAtString) else {
            throw DatabaseError.invalidDate(modifiedAtString)
        }
        return BookmarkRecord(
            id: UUID(uuidString: try textColumn(statement, 0)) ?? UUID(),
            workspaceID: sqlite3_column_int64(statement, 1),
            address: try addressColumn(statement, 2, field: "bookmarks.address"),
            imageSlot: Int(sqlite3_column_int64(statement, 6)),
            name: try textColumn(statement, 3),
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )
    }

    private static func segmentOverrideRecord(from statement: OpaquePointer) throws -> SegmentOverrideRecord {
        let createdAtString = try textColumn(statement, 5)
        guard let createdAt = date(from: createdAtString) else {
            throw DatabaseError.invalidDate(createdAtString)
        }
        let modifiedAtString = try textColumn(statement, 6)
        guard let modifiedAt = date(from: modifiedAtString) else {
            throw DatabaseError.invalidDate(modifiedAtString)
        }
        return SegmentOverrideRecord(
            // A malformed id degrades to a fresh UUID — segment overrides match on the
            // original section name, not id, so identity stability isn't load-bearing.
            id: UUID(uuidString: try textColumn(statement, 0)) ?? UUID(),
            workspaceID: sqlite3_column_int64(statement, 1),
            originalName: try textColumn(statement, 2),
            imageSlot: Int(sqlite3_column_int64(statement, 7)),
            displayName: optionalTextColumn(statement, 3),
            rebaseDelta: sqlite3_column_int64(statement, 4),
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )
    }

    private static func typeDefinitionRecord(from statement: OpaquePointer) throws -> TypeDefinitionRecord {
        let createdAtString = try textColumn(statement, 6)
        guard let createdAt = date(from: createdAtString) else {
            throw DatabaseError.invalidDate(createdAtString)
        }
        let modifiedAtString = try textColumn(statement, 7)
        guard let modifiedAt = date(from: modifiedAtString) else {
            throw DatabaseError.invalidDate(modifiedAtString)
        }
        return TypeDefinitionRecord(
            // A malformed id degrades to a fresh UUID — types are referenced by
            // name, not id, so identity stability isn't load-bearing.
            id: UUID(uuidString: try textColumn(statement, 0)) ?? UUID(),
            workspaceID: sqlite3_column_int64(statement, 1),
            kind: try textColumn(statement, 2),
            name: try textColumn(statement, 3),
            fieldsJSON: try textColumn(statement, 4),
            layoutRulesJSON: optionalTextColumn(statement, 5),
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )
    }

    private static func workspaceSessionRecord(from statement: OpaquePointer) throws -> WorkspaceSessionRecord {
        let selectedToolValue = try textColumn(statement, 3)
        guard let selectedTool = WorkspaceTool(rawValue: selectedToolValue) else {
            throw DatabaseError.invalidWorkspaceTool(selectedToolValue)
        }

        let editorModeValue = try textColumn(statement, 4)
        guard let editorMode = EditorMode(rawValue: editorModeValue) else {
            throw DatabaseError.invalidEditorMode(editorModeValue)
        }

        let updatedAtString = try textColumn(statement, 7)
        guard let updatedAt = date(from: updatedAtString) else {
            throw DatabaseError.invalidDate(updatedAtString)
        }

        return WorkspaceSessionRecord(
            workspaceID: sqlite3_column_int64(statement, 0),
            selectedSidebarItemID: optionalTextColumn(statement, 1),
            selectedAddress: try optionalAddressColumn(
                statement, 2, field: "workspace_sessions.selected_address"
            ),
            selectedTool: selectedTool,
            editorMode: editorMode,
            isInspectorPresented: sqlite3_column_int64(statement, 5) != 0,
            sidebarSearchText: try textColumn(statement, 6),
            updatedAt: updatedAt,
            focusedImageSlot: ImageSlot(rawValue: Int(sqlite3_column_int64(statement, 8)))
        )
    }

    private static func workspaceDocumentRecord(from statement: OpaquePointer) throws -> WorkspaceDocumentRecord {
        let documentIDString = try textColumn(statement, 1)
        guard let documentID = UUID(uuidString: documentIDString) else {
            throw DatabaseError.invalidUUID(documentIDString)
        }

        let lastOpenedAtString = try textColumn(statement, 3)
        guard let lastOpenedAt = date(from: lastOpenedAtString) else {
            throw DatabaseError.invalidDate(lastOpenedAtString)
        }

        let inputCopyingDecisionValue = try textColumn(statement, 9)
        guard let inputCopyingDecision = WorkspaceInputCopyingDecision(rawValue: inputCopyingDecisionValue) else {
            throw DatabaseError.invalidWorkspaceInputCopyingDecision(inputCopyingDecisionValue)
        }

        let bookmarkResolutionDecisionValue = try textColumn(statement, 10)
        guard let bookmarkResolutionDecision = WorkspaceBookmarkResolutionDecision(rawValue: bookmarkResolutionDecisionValue) else {
            throw DatabaseError.invalidWorkspaceBookmarkResolutionDecision(bookmarkResolutionDecisionValue)
        }

        let recentDocumentStateValue = try textColumn(statement, 12)
        guard let recentDocumentState = WorkspaceRecentDocumentState(rawValue: recentDocumentStateValue) else {
            throw DatabaseError.invalidWorkspaceRecentDocumentState(recentDocumentStateValue)
        }

        return WorkspaceDocumentRecord(
            workspaceID: sqlite3_column_int64(statement, 0),
            documentID: documentID,
            packagePath: try textColumn(statement, 2),
            lastOpenedAt: lastOpenedAt,
            lastSavedAt: try optionalDateColumn(statement, 4),
            isDirty: sqlite3_column_int64(statement, 5) != 0,
            fileVersionIdentifier: optionalTextColumn(statement, 6),
            conflictDetectedAt: try optionalDateColumn(statement, 7),
            conflictReason: optionalTextColumn(statement, 8),
            inputCopyingDecision: inputCopyingDecision,
            bookmarkResolutionDecision: bookmarkResolutionDecision,
            bookmarkResolutionError: optionalTextColumn(statement, 11),
            recentDocumentState: recentDocumentState,
            recentDocumentStateUpdatedAt: try optionalDateColumn(statement, 13)
        )
    }

    private static func workspaceDocumentAutosaveDecisionRecord(
        from statement: OpaquePointer
    ) throws -> WorkspaceDocumentAutosaveDecisionRecord {
        let uuidString = try textColumn(statement, 1)
        guard let uuid = UUID(uuidString: uuidString) else {
            throw DatabaseError.invalidUUID(uuidString)
        }

        let documentIDString = try textColumn(statement, 3)
        guard let documentID = UUID(uuidString: documentIDString) else {
            throw DatabaseError.invalidUUID(documentIDString)
        }

        let decisionValue = try textColumn(statement, 5)
        guard let decision = WorkspaceDocumentAutosaveDecision(rawValue: decisionValue) else {
            throw DatabaseError.invalidWorkspaceDocumentAutosaveDecision(decisionValue)
        }

        let decidedAtString = try textColumn(statement, 8)
        guard let decidedAt = date(from: decidedAtString) else {
            throw DatabaseError.invalidDate(decidedAtString)
        }

        return WorkspaceDocumentAutosaveDecisionRecord(
            id: sqlite3_column_int64(statement, 0),
            uuid: uuid,
            workspaceID: sqlite3_column_int64(statement, 2),
            documentID: documentID,
            packagePath: try textColumn(statement, 4),
            decision: decision,
            reason: optionalTextColumn(statement, 6),
            fileVersionIdentifier: optionalTextColumn(statement, 7),
            decidedAt: decidedAt,
            completedAt: try optionalDateColumn(statement, 9),
            errorMessage: optionalTextColumn(statement, 10)
        )
    }

    private static func pluginTrustRecord(from statement: OpaquePointer) throws -> PluginTrustRecord {
        let decisionValue = try textColumn(statement, 1)
        guard let decision = PluginTrustDecision(rawValue: decisionValue) else {
            throw DatabaseError.invalidPluginTrustDecision(decisionValue)
        }
        let updatedAtString = try textColumn(statement, 3)
        guard let updatedAt = date(from: updatedAtString) else {
            throw DatabaseError.invalidDate(updatedAtString)
        }

        return PluginTrustRecord(
            identifier: try textColumn(statement, 0),
            decision: decision,
            manifestHash: optionalTextColumn(statement, 2),
            updatedAt: updatedAt
        )
    }

    private static func phase2AssistantSessionRecord(
        from statement: OpaquePointer
    ) throws -> Phase2AssistantSessionPersistenceRecord {
        let idString = try textColumn(statement, 0)
        guard let id = UUID(uuidString: idString), id.uuidString == idString else {
            throw DatabaseError.invalidUUID(idString)
        }
        let workspaceUUIDString = try textColumn(statement, 2)
        guard let workspaceUUID = UUID(uuidString: workspaceUUIDString),
              workspaceUUID.uuidString == workspaceUUIDString else {
            throw DatabaseError.invalidUUID(workspaceUUIDString)
        }
        let documentIDString = try textColumn(statement, 3)
        guard let documentID = UUID(uuidString: documentIDString),
              documentID.uuidString == documentIDString else {
            throw DatabaseError.invalidUUID(documentIDString)
        }
        let conversationIDString = try textColumn(statement, 5)
        guard let conversationID = UUID(uuidString: conversationIDString),
              conversationID.uuidString == conversationIDString else {
            throw DatabaseError.invalidUUID(conversationIDString)
        }
        let inferenceTurnIDString = try textColumn(statement, 7)
        guard let inferenceTurnID = UUID(uuidString: inferenceTurnIDString),
              inferenceTurnID.uuidString == inferenceTurnIDString else {
            throw DatabaseError.invalidUUID(inferenceTurnIDString)
        }
        let statusValue = try textColumn(statement, 11)
        guard let status = Phase2AssistantPersistedSessionStatus(rawValue: statusValue) else {
            throw DatabaseError.invalidPhase2AssistantSessionStatus(statusValue)
        }
        let checkpoint: Phase2AssistantContinuationCheckpointRecord?
        if let checkpointJSON = optionalTextColumn(statement, 18) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            checkpoint = try decoder.decode(
                Phase2AssistantContinuationCheckpointRecord.self,
                from: Data(checkpointJSON.utf8)
            )
            guard checkpoint?.isStructurallyValid == true,
                  optionalTextColumn(statement, 19) == checkpoint?.shellProposalID.uuidString,
                  optionalTextColumn(statement, 20) == checkpoint?.shellExecutionID?.uuidString,
                  optionalIntColumn(statement, 21) == checkpoint?.continuationOrdinal,
                  optionalTextColumn(statement, 22) == checkpoint?.continuationRequestID?.uuidString else {
                throw DatabaseError.invalidPhase2AssistantSessionRecord(idString)
            }
        } else {
            checkpoint = nil
            guard optionalTextColumn(statement, 19) == nil,
                  optionalTextColumn(statement, 20) == nil,
                  optionalIntColumn(statement, 21) == nil,
                  optionalTextColumn(statement, 22) == nil else {
                throw DatabaseError.invalidPhase2AssistantSessionRecord(idString)
            }
        }
        let createdAtString = try textColumn(statement, 24)
        guard let createdAt = date(from: createdAtString) else {
            throw DatabaseError.invalidDate(createdAtString)
        }
        let completedAt: Date?
        if let completedAtString = optionalTextColumn(statement, 25) {
            guard let date = date(from: completedAtString) else {
                throw DatabaseError.invalidDate(completedAtString)
            }
            completedAt = date
        } else {
            completedAt = nil
        }

        let record = Phase2AssistantSessionPersistenceRecord(
            id: id,
            workspaceID: sqlite3_column_int64(statement, 1),
            workspaceUUID: workspaceUUID,
            documentID: documentID,
            sequence: Int(sqlite3_column_int64(statement, 4)),
            conversationID: conversationID,
            turnSequence: Int(sqlite3_column_int64(statement, 6)),
            inferenceTurnID: inferenceTurnID,
            isLegacy: sqlite3_column_int64(statement, 8) != 0,
            intentID: try textColumn(statement, 9),
            userGoal: try textColumn(statement, 10),
            status: status,
            promptText: try textColumn(statement, 12),
            answerText: optionalTextColumn(statement, 13),
            transcriptText: try textColumn(statement, 14),
            contextDigest: optionalTextColumn(statement, 15),
            canonicalByteCount: optionalIntColumn(statement, 16),
            providerToolCount: Int(sqlite3_column_int64(statement, 17)),
            recordSchemaVersion: Int(sqlite3_column_int64(statement, 23)),
            createdAt: createdAt,
            completedAt: completedAt,
            continuationCheckpoint: checkpoint,
            contentSHA256: try textColumn(statement, 26)
        )
        guard record.recordSchemaVersion == Phase2AssistantSessionPersistenceRecord.schemaVersion,
              record.contentSHA256 == Phase2AssistantSessionPersistenceRecord.contentSHA256(
                  id: record.id,
                  workspaceUUID: record.workspaceUUID,
                  documentID: record.documentID,
                  sequence: record.sequence,
                  conversationID: record.conversationID,
                  turnSequence: record.turnSequence,
                  inferenceTurnID: record.inferenceTurnID,
                  isLegacy: record.isLegacy,
                  intentID: record.intentID,
                  userGoal: record.userGoal,
                  status: record.status,
                  promptText: record.promptText,
                  answerText: record.answerText,
                  transcriptText: record.transcriptText,
                  contextDigest: record.contextDigest,
                  canonicalByteCount: record.canonicalByteCount,
                  providerToolCount: record.providerToolCount,
                  recordSchemaVersion: record.recordSchemaVersion,
                  createdAt: record.createdAt,
                  completedAt: record.completedAt,
                  continuationCheckpoint: record.continuationCheckpoint
              ) else {
            throw DatabaseError.invalidPhase2AssistantSessionRecord(record.id.uuidString)
        }
        return record
    }

    private static func phase2AssistantSessionRecordV1(
        from statement: OpaquePointer
    ) throws -> Phase2AssistantSessionPersistenceRecord {
        let idString = try textColumn(statement, 0)
        guard let id = UUID(uuidString: idString), id.uuidString == idString else {
            throw DatabaseError.invalidUUID(idString)
        }
        let workspaceUUIDString = try textColumn(statement, 2)
        guard let workspaceUUID = UUID(uuidString: workspaceUUIDString),
              workspaceUUID.uuidString == workspaceUUIDString else {
            throw DatabaseError.invalidUUID(workspaceUUIDString)
        }
        let documentIDString = try textColumn(statement, 3)
        guard let documentID = UUID(uuidString: documentIDString),
              documentID.uuidString == documentIDString else {
            throw DatabaseError.invalidUUID(documentIDString)
        }
        let statusValue = try textColumn(statement, 7)
        guard let status = Phase2AssistantPersistedSessionStatus(rawValue: statusValue) else {
            throw DatabaseError.invalidPhase2AssistantSessionStatus(statusValue)
        }
        let createdAtString = try textColumn(statement, 15)
        guard let createdAt = date(from: createdAtString) else {
            throw DatabaseError.invalidDate(createdAtString)
        }
        return Phase2AssistantSessionPersistenceRecord(
            id: id,
            workspaceID: sqlite3_column_int64(statement, 1),
            workspaceUUID: workspaceUUID,
            documentID: documentID,
            sequence: Int(sqlite3_column_int64(statement, 4)),
            conversationID: id,
            turnSequence: 1,
            inferenceTurnID: id,
            isLegacy: true,
            intentID: try textColumn(statement, 5),
            userGoal: try textColumn(statement, 6),
            status: status,
            promptText: try textColumn(statement, 8),
            answerText: optionalTextColumn(statement, 9),
            transcriptText: try textColumn(statement, 10),
            contextDigest: optionalTextColumn(statement, 11),
            canonicalByteCount: optionalIntColumn(statement, 12),
            providerToolCount: Int(sqlite3_column_int64(statement, 13)),
            createdAt: createdAt,
            completedAt: try optionalDateColumn(statement, 16)
        )
    }

    private static func phase2AssistantSessionRecordV2(
        from statement: OpaquePointer
    ) throws -> Phase2AssistantSessionPersistenceRecord {
        let idString = try textColumn(statement, 0)
        let workspaceUUIDString = try textColumn(statement, 2)
        let documentIDString = try textColumn(statement, 3)
        let conversationIDString = try textColumn(statement, 5)
        let inferenceTurnIDString = try textColumn(statement, 7)
        guard let id = UUID(uuidString: idString), id.uuidString == idString,
              let workspaceUUID = UUID(uuidString: workspaceUUIDString), workspaceUUID.uuidString == workspaceUUIDString,
              let documentID = UUID(uuidString: documentIDString), documentID.uuidString == documentIDString,
              let conversationID = UUID(uuidString: conversationIDString), conversationID.uuidString == conversationIDString,
              let inferenceTurnID = UUID(uuidString: inferenceTurnIDString), inferenceTurnID.uuidString == inferenceTurnIDString,
              let status = Phase2AssistantPersistedSessionStatus(rawValue: try textColumn(statement, 11)),
              let createdAt = date(from: try textColumn(statement, 19)) else {
            throw DatabaseError.invalidPhase2AssistantSessionRecord(idString)
        }
        let completedAt = try optionalDateColumn(statement, 20)
        let oldHash = contentSHA256ForAssistantV2(
            id: id, workspaceUUID: workspaceUUID, documentID: documentID,
            sequence: Int(sqlite3_column_int64(statement, 4)), conversationID: conversationID,
            turnSequence: Int(sqlite3_column_int64(statement, 6)), inferenceTurnID: inferenceTurnID,
            isLegacy: sqlite3_column_int64(statement, 8) != 0, intentID: try textColumn(statement, 9),
            userGoal: try textColumn(statement, 10), status: status, promptText: try textColumn(statement, 12),
            answerText: optionalTextColumn(statement, 13), transcriptText: try textColumn(statement, 14),
            contextDigest: optionalTextColumn(statement, 15), canonicalByteCount: optionalIntColumn(statement, 16),
            providerToolCount: Int(sqlite3_column_int64(statement, 17)), createdAt: createdAt, completedAt: completedAt
        )
        guard Int(sqlite3_column_int64(statement, 18)) == 2,
              try textColumn(statement, 21) == oldHash else {
            throw DatabaseError.invalidPhase2AssistantSessionRecord(idString)
        }
        return Phase2AssistantSessionPersistenceRecord(
            id: id, workspaceID: sqlite3_column_int64(statement, 1), workspaceUUID: workspaceUUID,
            documentID: documentID, sequence: Int(sqlite3_column_int64(statement, 4)),
            conversationID: conversationID, turnSequence: Int(sqlite3_column_int64(statement, 6)),
            inferenceTurnID: inferenceTurnID, isLegacy: sqlite3_column_int64(statement, 8) != 0,
            intentID: try textColumn(statement, 9), userGoal: try textColumn(statement, 10), status: status,
            promptText: try textColumn(statement, 12), answerText: optionalTextColumn(statement, 13),
            transcriptText: try textColumn(statement, 14), contextDigest: optionalTextColumn(statement, 15),
            canonicalByteCount: optionalIntColumn(statement, 16),
            providerToolCount: Int(sqlite3_column_int64(statement, 17)), createdAt: createdAt, completedAt: completedAt
        )
    }

    private static func contentSHA256ForAssistantV2(
        id: UUID, workspaceUUID: UUID, documentID: UUID, sequence: Int,
        conversationID: UUID, turnSequence: Int, inferenceTurnID: UUID, isLegacy: Bool,
        intentID: String, userGoal: String, status: Phase2AssistantPersistedSessionStatus,
        promptText: String, answerText: String?, transcriptText: String, contextDigest: String?,
        canonicalByteCount: Int?, providerToolCount: Int, createdAt: Date, completedAt: Date?
    ) -> String {
        Phase2AssistantSessionPersistenceRecord.contentSHA256(
            id: id, workspaceUUID: workspaceUUID, documentID: documentID, sequence: sequence,
            conversationID: conversationID, turnSequence: turnSequence, inferenceTurnID: inferenceTurnID,
            isLegacy: isLegacy, intentID: intentID, userGoal: userGoal, status: status,
            promptText: promptText, answerText: answerText, transcriptText: transcriptText,
            contextDigest: contextDigest, canonicalByteCount: canonicalByteCount,
            providerToolCount: providerToolCount, recordSchemaVersion: 2,
            createdAt: createdAt, completedAt: completedAt
        )
    }

    private static func phase2RuntimeAuthorityRecord(
        from statement: OpaquePointer
    ) throws -> Phase2RuntimeAuthorityPersistenceRecord {
        let idString = try textColumn(statement, 0)
        guard let id = UUID(uuidString: idString), id.uuidString == idString else {
            throw DatabaseError.invalidUUID(idString)
        }
        let workspaceUUIDString = try textColumn(statement, 2)
        guard let workspaceUUID = UUID(uuidString: workspaceUUIDString),
              workspaceUUID.uuidString == workspaceUUIDString else {
            throw DatabaseError.invalidUUID(workspaceUUIDString)
        }
        let documentIDString = try textColumn(statement, 3)
        guard let documentID = UUID(uuidString: documentIDString),
              documentID.uuidString == documentIDString else {
            throw DatabaseError.invalidUUID(documentIDString)
        }
        let sessionIDString = try textColumn(statement, 4)
        guard let sessionID = UUID(uuidString: sessionIDString),
              sessionID.uuidString == sessionIDString else {
            throw DatabaseError.invalidUUID(sessionIDString)
        }
        let terminalBackendValue = try textColumn(statement, 6)
        guard let terminalBackend = Phase2TerminalEmulationBackend(rawValue: terminalBackendValue) else {
            throw DatabaseError.invalidPhase2RuntimeAuthority(terminalBackendValue)
        }
        let ptyReusePolicyValue = try textColumn(statement, 7)
        guard let ptyReusePolicy = Phase2TerminalPTYReusePolicy(rawValue: ptyReusePolicyValue) else {
            throw DatabaseError.invalidPhase2RuntimeAuthority(ptyReusePolicyValue)
        }
        let createdAtString = try textColumn(statement, 11)
        guard let createdAt = date(from: createdAtString) else {
            throw DatabaseError.invalidDate(createdAtString)
        }
        let record = Phase2RuntimeAuthorityPersistenceRecord(
            id: id,
            workspaceID: sqlite3_column_int64(statement, 1),
            workspaceUUID: workspaceUUID,
            documentID: documentID,
            sessionID: sessionID,
            surfaces: try decodeRuntimeAuthoritySurfaces(try textColumn(statement, 5)),
            terminalBackend: terminalBackend,
            ptyReusePolicy: ptyReusePolicy,
            debuggerAuthorityPolicy: try decodeDebuggerAuthorityPolicy(try textColumn(statement, 8)),
            providerVisibleShellExecutionEnabled: sqlite3_column_int64(statement, 9) != 0,
            recordSchemaVersion: Int(sqlite3_column_int64(statement, 10)),
            createdAt: createdAt
        )
        guard record.authorityRecord.isStructurallyValid else {
            throw DatabaseError.invalidPhase2RuntimeAuthority("structural")
        }
        return record
    }

    private static func phase2ShellSessionRecord(
        from statement: OpaquePointer
    ) throws -> Phase2ShellSessionPersistenceRecord {
        let workspaceUUIDString = try textColumn(statement, 1)
        guard let workspaceUUID = UUID(uuidString: workspaceUUIDString),
              workspaceUUID.uuidString == workspaceUUIDString else {
            throw DatabaseError.invalidUUID(workspaceUUIDString)
        }
        let documentIDString = try textColumn(statement, 2)
        guard let documentID = UUID(uuidString: documentIDString),
              documentID.uuidString == documentIDString else {
            throw DatabaseError.invalidUUID(documentIDString)
        }
        let updatedAtString = try textColumn(statement, 5)
        guard let updatedAt = date(from: updatedAtString) else {
            throw DatabaseError.invalidDate(updatedAtString)
        }
        let record = Phase2ShellSessionPersistenceRecord(
            workspaceID: sqlite3_column_int64(statement, 0),
            workspaceUUID: workspaceUUID,
            documentID: documentID,
            shellSession: try decodePhase2ShellSessionJSON(try textColumn(statement, 3)),
            recordSchemaVersion: Int(sqlite3_column_int64(statement, 4)),
            updatedAt: updatedAt
        )
        guard record.recordSchemaVersion == Phase2ShellSessionPersistenceRecord.schemaVersion else {
            throw DatabaseError.invalidPhase2RuntimeAuthority("shell-session-schema")
        }
        return record
    }

    private static func pluginExternalRunRecord(from statement: OpaquePointer) throws -> PluginExternalRunRecord {
        let requestIDString = try textColumn(statement, 0)
        guard let requestID = UUID(uuidString: requestIDString) else {
            throw DatabaseError.invalidUUID(requestIDString)
        }

        let statusValue = try textColumn(statement, 5)
        guard let status = PluginExternalRunStatus(rawValue: statusValue) else {
            throw DatabaseError.invalidPluginExternalRunStatus(statusValue)
        }

        let startedAtString = try textColumn(statement, 6)
        guard let startedAt = date(from: startedAtString) else {
            throw DatabaseError.invalidDate(startedAtString)
        }

        let completedAt: Date?
        if let completedAtString = optionalTextColumn(statement, 7) {
            guard let date = date(from: completedAtString) else {
                throw DatabaseError.invalidDate(completedAtString)
            }
            completedAt = date
        } else {
            completedAt = nil
        }

        return PluginExternalRunRecord(
            requestID: requestID,
            pluginIdentifier: try textColumn(statement, 1),
            displayName: try textColumn(statement, 2),
            executablePath: try textColumn(statement, 3),
            manifestHash: optionalTextColumn(statement, 4),
            status: status,
            startedAt: startedAt,
            completedAt: completedAt,
            terminationStatus: optionalInt32Column(statement, 8),
            stdout: try textColumn(statement, 9),
            stderr: try textColumn(statement, 10),
            log: try textColumn(statement, 11),
            errorMessage: optionalTextColumn(statement, 12)
        )
    }

    static func textColumn(_ statement: OpaquePointer, _ index: Int32) throws -> String {
        guard let text = sqlite3_column_text(statement, index) else {
            throw DatabaseError.stepFailed("Expected non-null text column at index \(index).")
        }
        return String(cString: text)
    }

    private static func optionalTextColumn(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let text = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: text)
    }

    private static func optionalExactTextColumn(
        _ statement: OpaquePointer,
        _ index: Int32
    ) -> String? {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private static func optionalDateColumn(_ statement: OpaquePointer, _ index: Int32) throws -> Date? {
        guard let string = optionalTextColumn(statement, index) else {
            return nil
        }
        guard let value = date(from: string) else {
            throw DatabaseError.invalidDate(string)
        }
        return value
    }

    static func addressColumn(
        _ statement: OpaquePointer,
        _ index: Int32,
        field: String
    ) throws -> UInt64 {
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else {
            throw DatabaseError.stepFailed("Expected INTEGER storage for \(field).")
        }
        return UInt64(bitPattern: sqlite3_column_int64(statement, index))
    }

    private static func optionalAddressColumn(
        _ statement: OpaquePointer,
        _ index: Int32,
        field: String
    ) throws -> UInt64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return try addressColumn(statement, index, field: field)
    }

    private static func optionalNonnegativeUInt64Column(
        _ statement: OpaquePointer,
        _ index: Int32,
        field: String
    ) throws -> UInt64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else {
            throw DatabaseError.invalidUnsignedInteger(
                field: field,
                value: sqlite3_column_int64(statement, index)
            )
        }
        let value = sqlite3_column_int64(statement, index)
        guard value >= 0 else {
            throw DatabaseError.invalidUnsignedInteger(field: field, value: value)
        }
        return UInt64(value)
    }

    private static func nonnegativeUInt32Column(
        _ statement: OpaquePointer,
        _ index: Int32,
        field: String
    ) throws -> UInt32 {
        let value = sqlite3_column_int64(statement, index)
        guard let converted = UInt32(exactly: value) else {
            throw DatabaseError.invalidUnsignedInteger(field: field, value: value)
        }
        return converted
    }

    private static func optionalNonnegativeUInt32Column(
        _ statement: OpaquePointer,
        _ index: Int32,
        field: String
    ) throws -> UInt32? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        guard sqlite3_column_type(statement, index) == SQLITE_INTEGER else { return nil }
        let value = sqlite3_column_int64(statement, index)
        guard let converted = UInt32(exactly: value) else {
            throw DatabaseError.invalidUnsignedInteger(field: field, value: value)
        }
        return converted
    }

    private static func optionalIntColumn(_ statement: OpaquePointer, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Int(sqlite3_column_int64(statement, index))
    }

    private static func optionalInt32Column(_ statement: OpaquePointer, _ index: Int32) -> Int32? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return Int32(exactly: sqlite3_column_int64(statement, index))
    }

    private static func blobColumn(_ statement: OpaquePointer, _ index: Int32) -> Data {
        let byteCount = Int(sqlite3_column_bytes(statement, index))
        guard byteCount > 0, let bytes = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: bytes, count: byteCount)
    }

    private static func optionalBlobColumn(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return blobColumn(statement, index)
    }

    private static func hexByteString(from data: Data) -> String {
        HexByteFormatter.spacedHex([UInt8](data))
    }

    private static func data(fromHexByteString string: String) -> Data {
        let bytes = string.split(separator: " ").compactMap { UInt8($0, radix: 16) }
        return Data(bytes)
    }
}
