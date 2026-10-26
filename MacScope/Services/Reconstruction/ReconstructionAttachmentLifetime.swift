import Darwin
import Foundation

enum ReconstructionAttachmentLifetimeError: Error {
    case invalidOwnedObject
}

/// An identity-bound lease for a task-created filesystem object.
///
/// The lease retains both the creator's object descriptor and a descriptor for the object's
/// parent directory. Cleanup therefore never needs to rediscover either authority through a
/// mutable absolute path. A directory cleanup is descriptor-relative and every child is removed
/// without following symbolic links; a pathname that no longer names the observed inode is left
/// behind as an orphan.
final class ReconstructionAttachmentLifetime:
    ReconstructionAttachmentSourceLifetimeToken,
    @unchecked Sendable
{
    struct CreationIdentity: Equatable, Sendable {
        private let device: UInt64
        private let inode: UInt64
        private let fileType: UInt32

        init(descriptor: Int32) throws {
            var metadata = stat()
            guard Darwin.fstat(descriptor, &metadata) == 0 else {
                throw ReconstructionAttachmentLifetimeError.invalidOwnedObject
            }
            let identity = Self(metadata: metadata)
            guard identity.isSupportedOwnedObject else {
                throw ReconstructionAttachmentLifetimeError.invalidOwnedObject
            }
            self = identity
        }

        init(metadata: stat) {
            device = UInt64(truncatingIfNeeded: metadata.st_dev)
            inode = UInt64(truncatingIfNeeded: metadata.st_ino)
            fileType = UInt32(metadata.st_mode) & UInt32(S_IFMT)
        }

        fileprivate var isDirectory: Bool {
            fileType == UInt32(S_IFDIR)
        }

        private var isSupportedOwnedObject: Bool {
            fileType == UInt32(S_IFREG) || isDirectory
        }
    }

    struct CleanupHooks: Sendable {
        let afterAtomicDetach: @Sendable (URL) -> Void
        let beforeRemovingVerifiedDetachedObject: @Sendable (URL) -> Void

        init(
            afterAtomicDetach: @escaping @Sendable (URL) -> Void = { _ in },
            beforeRemovingVerifiedDetachedObject: @escaping @Sendable (URL) -> Void = { _ in }
        ) {
            self.afterAtomicDetach = afterAtomicDetach
            self.beforeRemovingVerifiedDetachedObject = beforeRemovingVerifiedDetachedObject
        }
    }

    private struct OwnedObject {
        let url: URL
        let entryName: String
        let parentDescriptor: Int32
        let creatorDescriptor: Int32
        let creationIdentity: CreationIdentity
        let removesDirectoryContents: Bool
        let retainedLifetime: (any ReconstructionAttachmentSourceLifetimeToken)?
    }

    private struct RemovalBudget {
        private static let maximumDepth = 32
        private static let maximumEntries = 100_000

        private(set) var remainingEntries = maximumEntries

        mutating func admitEntry(atDepth depth: Int) -> Bool {
            guard depth <= Self.maximumDepth, remainingEntries > 0 else { return false }
            remainingEntries -= 1
            return true
        }
    }

    private enum ExclusiveRenameResult {
        case success
        case failure(Int32)
    }

    private let lock = NSLock()
    private let cleanupHooks: CleanupHooks
    private var ownedObject: OwnedObject?

    /// Compatibility initializer for callers that already captured an identity. New creator code
    /// should pass the still-open creator descriptor to the throwing initializer below.
    convenience init(
        owning url: URL,
        creationIdentity: CreationIdentity,
        cleanupHooks: CleanupHooks = .init()
    ) {
        let standardizedURL = url.standardizedFileURL
        let flags = Self.openFlags(for: creationIdentity)
        let descriptor = standardizedURL.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, flags) } ?? -1
        }
        guard descriptor >= 0 else {
            self.init(ownedObject: nil, cleanupHooks: cleanupHooks)
            return
        }
        defer { _ = Darwin.close(descriptor) }
        do {
            let observedIdentity = try CreationIdentity(descriptor: descriptor)
            guard observedIdentity == creationIdentity else {
                self.init(ownedObject: nil, cleanupHooks: cleanupHooks)
                return
            }
            let owned = try Self.makeOwnedObject(
                url: standardizedURL,
                creatorDescriptor: descriptor,
                parentDescriptor: nil,
                creationIdentity: creationIdentity,
                removesDirectoryContents: true,
                retainedLifetime: nil
            )
            self.init(ownedObject: owned, cleanupHooks: cleanupHooks)
        } catch {
            self.init(ownedObject: nil, cleanupHooks: cleanupHooks)
        }
    }

    /// Captures cleanup authority from descriptors held by the creator. Both descriptors are
    /// duplicated, so the caller remains free to close its originals immediately after return.
    convenience init(
        owning url: URL,
        creatorDescriptor: Int32,
        parentDescriptor: Int32? = nil,
        retaining retainedLifetime: (any ReconstructionAttachmentSourceLifetimeToken)? = nil,
        removingDirectoryContents: Bool = true,
        cleanupHooks: CleanupHooks = .init()
    ) throws {
        let creationIdentity = try CreationIdentity(descriptor: creatorDescriptor)
        let owned = try Self.makeOwnedObject(
            url: url.standardizedFileURL,
            creatorDescriptor: creatorDescriptor,
            parentDescriptor: parentDescriptor,
            creationIdentity: creationIdentity,
            removesDirectoryContents: removingDirectoryContents,
            retainedLifetime: retainedLifetime
        )
        self.init(ownedObject: owned, cleanupHooks: cleanupHooks)
    }

    private init(ownedObject: OwnedObject?, cleanupHooks: CleanupHooks) {
        self.ownedObject = ownedObject
        self.cleanupHooks = cleanupHooks
    }

    deinit {
        discard()
    }

    func discard() {
        guard let owned = takeOwnedObject() else { return }
        defer {
            _ = Darwin.close(owned.creatorDescriptor)
            _ = Darwin.close(owned.parentDescriptor)
            withExtendedLifetime(owned.retainedLifetime) {}
        }
        guard let quarantineName = detachToUniqueQuarantine(owned) else { return }
        let quarantineURL = owned.url.deletingLastPathComponent()
            .appendingPathComponent(quarantineName, isDirectory: owned.creationIdentity.isDirectory)
        cleanupHooks.afterAtomicDetach(quarantineURL)

        guard let detachedDescriptor = Self.openDetachedObject(
            named: quarantineName,
            in: owned.parentDescriptor,
            identity: owned.creationIdentity
        ) else {
            restoreMismatch(named: quarantineName, for: owned)
            return
        }
        defer { _ = Darwin.close(detachedDescriptor) }
        guard Self.identity(of: detachedDescriptor) == owned.creationIdentity else {
            restoreMismatch(named: quarantineName, for: owned)
            return
        }

        cleanupHooks.beforeRemovingVerifiedDetachedObject(quarantineURL)

        // The hook models the final adversarial window. Never operate on the detached name again
        // unless it still denotes the creator's exact inode and type.
        guard Self.identity(
            named: quarantineName,
            in: owned.parentDescriptor
        ) == owned.creationIdentity else {
            return
        }

        if owned.creationIdentity.isDirectory {
            var budget = RemovalBudget()
            if owned.removesDirectoryContents {
                Self.removeDirectoryContents(
                    descriptor: detachedDescriptor,
                    depth: 0,
                    budget: &budget
                )
            }
            guard Self.identity(
                named: quarantineName,
                in: owned.parentDescriptor
            ) == owned.creationIdentity else {
                return
            }
            let removalStatus = quarantineName.withCString {
                Darwin.unlinkat(owned.parentDescriptor, $0, AT_REMOVEDIR)
            }
            if removalStatus != 0 {
                restoreMismatch(named: quarantineName, for: owned)
            }
        } else {
            let removalStatus = quarantineName.withCString {
                Darwin.unlinkat(owned.parentDescriptor, $0, 0)
            }
            if removalStatus != 0 {
                restoreMismatch(named: quarantineName, for: owned)
            }
        }
    }

    /// Transfers responsibility away from this lease without touching the filesystem. Used only
    /// when a creator atomically moves the same open object to a new descriptor-bound lease.
    func relinquishWithoutCleanup() {
        guard let owned = takeOwnedObject() else { return }
        _ = Darwin.close(owned.creatorDescriptor)
        _ = Darwin.close(owned.parentDescriptor)
        withExtendedLifetime(owned.retainedLifetime) {}
    }

    private func takeOwnedObject() -> OwnedObject? {
        lock.lock()
        defer { lock.unlock() }
        let owned = ownedObject
        ownedObject = nil
        return owned
    }

    private func detachToUniqueQuarantine(_ owned: OwnedObject) -> String? {
        for _ in 0..<8 {
            let quarantineName = ".MacScope-ReconstructionCleanup-\(UUID().uuidString)"
            switch Self.renameExclusively(
                from: owned.entryName,
                in: owned.parentDescriptor,
                to: quarantineName,
                in: owned.parentDescriptor
            ) {
            case .success:
                return quarantineName
            case .failure(EEXIST):
                continue
            case .failure:
                return nil
            }
        }
        return nil
    }

    private func restoreMismatch(named quarantineName: String, for owned: OwnedObject) {
        _ = Self.renameExclusively(
            from: quarantineName,
            in: owned.parentDescriptor,
            to: owned.entryName,
            in: owned.parentDescriptor
        )
    }

    private static func makeOwnedObject(
        url: URL,
        creatorDescriptor: Int32,
        parentDescriptor: Int32?,
        creationIdentity: CreationIdentity,
        removesDirectoryContents: Bool,
        retainedLifetime: (any ReconstructionAttachmentSourceLifetimeToken)?
    ) throws -> OwnedObject {
        let entryName = url.lastPathComponent
        guard !entryName.isEmpty,
              entryName != ".",
              entryName != "..",
              !entryName.contains("/") else {
            throw ReconstructionAttachmentLifetimeError.invalidOwnedObject
        }
        let creatorDuplicate = Darwin.fcntl(creatorDescriptor, F_DUPFD_CLOEXEC, 0)
        guard creatorDuplicate >= 0 else {
            throw ReconstructionAttachmentLifetimeError.invalidOwnedObject
        }
        let parentDuplicate: Int32
        if let parentDescriptor {
            parentDuplicate = Darwin.fcntl(parentDescriptor, F_DUPFD_CLOEXEC, 0)
        } else {
            parentDuplicate = url.deletingLastPathComponent()
                .withUnsafeFileSystemRepresentation { path in
                    path.map {
                        Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                    } ?? -1
                }
        }
        guard parentDuplicate >= 0 else {
            _ = Darwin.close(creatorDuplicate)
            throw ReconstructionAttachmentLifetimeError.invalidOwnedObject
        }
        return OwnedObject(
            url: url,
            entryName: entryName,
            parentDescriptor: parentDuplicate,
            creatorDescriptor: creatorDuplicate,
            creationIdentity: creationIdentity,
            removesDirectoryContents: removesDirectoryContents,
            retainedLifetime: retainedLifetime
        )
    }

    private static func openFlags(for identity: CreationIdentity) -> Int32 {
        var flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        if identity.isDirectory {
            flags |= O_DIRECTORY
        }
        return flags
    }

    private static func openDetachedObject(
        named name: String,
        in parentDescriptor: Int32,
        identity: CreationIdentity
    ) -> Int32? {
        let descriptor = name.withCString {
            Darwin.openat(parentDescriptor, $0, openFlags(for: identity))
        }
        return descriptor >= 0 ? descriptor : nil
    }

    private static func identity(of descriptor: Int32) -> CreationIdentity? {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else { return nil }
        return CreationIdentity(metadata: metadata)
    }

    private static func identity(named name: String, in parentDescriptor: Int32) -> CreationIdentity? {
        var metadata = stat()
        let status = name.withCString {
            Darwin.fstatat(parentDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard status == 0 else { return nil }
        return CreationIdentity(metadata: metadata)
    }

    @discardableResult
    private static func renameExclusively(
        from sourceName: String,
        in sourceParentDescriptor: Int32,
        to destinationName: String,
        in destinationParentDescriptor: Int32
    ) -> ExclusiveRenameResult {
        let status = sourceName.withCString { sourcePath in
            destinationName.withCString { destinationPath in
                Darwin.renameatx_np(
                    sourceParentDescriptor,
                    sourcePath,
                    destinationParentDescriptor,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        return status == 0 ? .success : .failure(errno)
    }

    private static func removeDirectoryContents(
        descriptor: Int32,
        depth: Int,
        budget: inout RemovalBudget
    ) {
        guard let names = directoryEntryNames(
            descriptor: descriptor,
            maximumCount: budget.remainingEntries
        ) else {
            return
        }
        for name in names {
            guard budget.admitEntry(atDepth: depth) else { return }
            guard let expectedIdentity = identity(named: name, in: descriptor) else { continue }
            if expectedIdentity.isDirectory {
                guard let childDescriptor = openDetachedObject(
                    named: name,
                    in: descriptor,
                    identity: expectedIdentity
                ) else {
                    continue
                }
                defer { _ = Darwin.close(childDescriptor) }
                guard identity(of: childDescriptor) == expectedIdentity else { continue }
                removeDirectoryContents(
                    descriptor: childDescriptor,
                    depth: depth + 1,
                    budget: &budget
                )
                guard identity(named: name, in: descriptor) == expectedIdentity else { continue }
                _ = name.withCString { Darwin.unlinkat(descriptor, $0, AT_REMOVEDIR) }
                continue
            }

            // Non-directory entries are never recursively traversed. The second identity read
            // bounds a replacement race to one directory entry rather than an unrelated tree.
            guard identity(named: name, in: descriptor) == expectedIdentity else { continue }
            _ = name.withCString { Darwin.unlinkat(descriptor, $0, 0) }
        }
    }

    private static func directoryEntryNames(
        descriptor: Int32,
        maximumCount: Int
    ) -> [String]? {
        let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0, let directory = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            return nil
        }
        defer { _ = Darwin.closedir(directory) }

        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." {
                guard names.count < maximumCount else { return nil }
                names.append(name)
            }
        }
        guard errno == 0 else { return nil }
        return names
    }
}
