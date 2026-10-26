import CryptoKit
import Darwin
import Foundation

struct ReconstructionContainerManifestBuilder {
    private static let maximumClassifierPrefixBytes: UInt64 = 1_048_576
    static let maximumSupportedRelativePathUTF8Bytes = 16 * 1_024

    private enum HardLimit {
        static let maximumDepth = 128
        static let maximumEntries = 100_000
        static let maximumRelativePathUTF8Bytes =
            ReconstructionContainerManifestBuilder.maximumSupportedRelativePathUTF8Bytes
        static let maximumEncodedBytes = 64 * 1_024 * 1_024
        static let maximumFileBytes = ReconstructionPackageLayout.maximumCorpusAttachmentBytes
        static let maximumTotalContentBytes = ReconstructionPackageLayout.maximumCorpusAttachmentBytes
        static let maximumStructuralFactPrefixOperations = 1_000_000
        static let maximumStructuralFactPrefixUTF8Bytes = 64 * 1_024 * 1_024
    }

    struct Limits: Sendable {
        let maximumDepth: Int
        let maximumEntries: Int
        let maximumRelativePathUTF8Bytes: Int
        let maximumEncodedBytes: Int
        let maximumFileBytes: UInt64
        let maximumTotalContentBytes: UInt64
        let maximumStructuralFactPrefixOperations: Int
        let maximumStructuralFactPrefixUTF8Bytes: Int

        init(
            maximumDepth: Int,
            maximumEntries: Int,
            maximumRelativePathUTF8Bytes: Int,
            maximumEncodedBytes: Int,
            maximumFileBytes: UInt64 = ReconstructionPackageLayout.maximumCorpusAttachmentBytes,
            maximumTotalContentBytes: UInt64 = ReconstructionPackageLayout.maximumCorpusAttachmentBytes,
            maximumStructuralFactPrefixOperations: Int = HardLimit.maximumStructuralFactPrefixOperations,
            maximumStructuralFactPrefixUTF8Bytes: Int = HardLimit.maximumStructuralFactPrefixUTF8Bytes
        ) {
            self.maximumDepth = maximumDepth
            self.maximumEntries = maximumEntries
            self.maximumRelativePathUTF8Bytes = maximumRelativePathUTF8Bytes
            self.maximumEncodedBytes = maximumEncodedBytes
            self.maximumFileBytes = maximumFileBytes
            self.maximumTotalContentBytes = maximumTotalContentBytes
            self.maximumStructuralFactPrefixOperations = maximumStructuralFactPrefixOperations
            self.maximumStructuralFactPrefixUTF8Bytes = maximumStructuralFactPrefixUTF8Bytes
        }
    }

    /// Immutable, already-captured evidence for one immediate container child. The importer uses
    /// this value to build a manifest without granting the builder another read of the live tree.
    struct CapturedEntry: Sendable {
        let relativePath: String
        let kind: ReconstructionArtifactKind
        let contentIdentity: ReconstructionContentIdentity?
        let executableMode: Bool
        let symbolicLinkTarget: String?

        init(
            relativePath: String,
            kind: ReconstructionArtifactKind,
            contentIdentity: ReconstructionContentIdentity?,
            executableMode: Bool,
            symbolicLinkTarget: String?
        ) {
            self.relativePath = relativePath
            self.kind = kind
            self.contentIdentity = contentIdentity
            self.executableMode = executableMode
            self.symbolicLinkTarget = symbolicLinkTarget
        }
    }

    struct Result: Sendable {
        let canonicalManifestBytes: Data
        let contentIdentity: ReconstructionContentIdentity
        let attachmentSource: ReconstructionAttachmentSource
    }

    struct TestHooks {
        let forcedReaddirFailureAfterEntryCount: Int?
        let beforeOpeningEntry: ((String) -> Void)?
        let afterRegularFileRead: ((String) -> Void)?
        let afterSymbolicLinkRead: ((String) -> Void)?
        let afterDirectoryTraversal: ((String) -> Void)?
        let afterAttachmentCreation: ((URL) -> Void)?
        let afterStructuralFactPrefix: ((String) -> Void)?

        init(
            forcedReaddirFailureAfterEntryCount: Int? = nil,
            beforeOpeningEntry: ((String) -> Void)? = nil,
            afterRegularFileRead: ((String) -> Void)? = nil,
            afterSymbolicLinkRead: ((String) -> Void)? = nil,
            afterDirectoryTraversal: ((String) -> Void)? = nil,
            afterAttachmentCreation: ((URL) -> Void)? = nil,
            afterStructuralFactPrefix: ((String) -> Void)? = nil
        ) {
            self.forcedReaddirFailureAfterEntryCount = forcedReaddirFailureAfterEntryCount
            self.beforeOpeningEntry = beforeOpeningEntry
            self.afterRegularFileRead = afterRegularFileRead
            self.afterSymbolicLinkRead = afterSymbolicLinkRead
            self.afterDirectoryTraversal = afterDirectoryTraversal
            self.afterAttachmentCreation = afterAttachmentCreation
            self.afterStructuralFactPrefix = afterStructuralFactPrefix
        }
    }

    private let testHooks: TestHooks

    init(testHooks: TestHooks = .init()) {
        self.testHooks = testHooks
    }

    func buildCapturedManifest(
        entries: [CapturedEntry],
        limits: Limits,
        cancellation: ReconstructionCancellation
    ) throws -> Result {
        try validate(limits)
        let manifest = try canonicalizeCapturedEntries(
            entries,
            limits: limits,
            cancellation: cancellation,
            enforceContentLimits: true
        )
        return try materializeResult(manifest, cancellation: cancellation)
    }

    private enum BuilderError: Error {
        case invalidLimit
        case invalidRoot
        case invalidEntry
        case entryLimitExceeded
        case depthLimitExceeded
        case pathLimitExceeded
        case encodedByteLimitExceeded
        case contentByteLimitExceeded
        case structuralFactPrefixLimitExceeded
        case changedDuringRead
        case emptyRegularFile
        case attachmentMaterializationFailed
        case readdirFailed
    }

    private struct CanonicalManifest: Encodable {
        let schemaVersion = 1
        let entries: [CanonicalEntry]
    }

    private struct CanonicalEntry: Encodable {
        let relativePath: String
        let kind: ReconstructionArtifactKind
        let contentIdentity: ReconstructionContentIdentity?
        let executableMode: Bool
        let symbolicLinkTarget: String?
    }

    private struct CanonicalizedManifest {
        let bytes: Data
        let contentIdentity: ReconstructionContentIdentity
    }

    private struct MaterializedAttachment {
        let url: URL
        let lifetime: ReconstructionAttachmentLifetime
    }

    private struct DirectoryResult {
        let manifest: CanonicalizedManifest
        let structuralFacts: [ReconstructionVerifiedContainerFact]
        let filesystemFacts: [CapturedFilesystemFact]
    }

    private struct CapturedFilesystemFact {
        let rawPathComponents: [String]
        let snapshot: FileSnapshot
        let symbolicLinkTarget: String?
    }

    private final class TraversalBudget {
        private(set) var remainingEntries: Int
        private var reservedEncodedBytes = 0
        private let maximumEncodedBytes: Int
        private var remainingContentBytes: UInt64
        private let maximumFileBytes: UInt64
        private var remainingStructuralFactPrefixOperations: Int
        private var remainingStructuralFactPrefixUTF8Bytes: Int

        init(limits: Limits) {
            remainingEntries = limits.maximumEntries
            maximumEncodedBytes = limits.maximumEncodedBytes
            remainingContentBytes = limits.maximumTotalContentBytes
            maximumFileBytes = limits.maximumFileBytes
            remainingStructuralFactPrefixOperations = limits.maximumStructuralFactPrefixOperations
            remainingStructuralFactPrefixUTF8Bytes = limits.maximumStructuralFactPrefixUTF8Bytes
        }

        func admitEntry(relativePath: String) throws {
            guard remainingEntries > 0 else { throw BuilderError.entryLimitExceeded }
            remainingEntries -= 1
            let pathBound = try checkedProduct(relativePath.utf8.count, 6)
            let entryBound = try checkedSum(256, pathBound)
            reservedEncodedBytes = try checkedSum(reservedEncodedBytes, entryBound)
            guard reservedEncodedBytes <= maximumEncodedBytes else {
                throw BuilderError.encodedByteLimitExceeded
            }
        }

        func admitLinkText(_ target: String) throws {
            let targetBound = try checkedProduct(target.utf8.count, 6)
            reservedEncodedBytes = try checkedSum(reservedEncodedBytes, targetBound)
            guard reservedEncodedBytes <= maximumEncodedBytes else {
                throw BuilderError.encodedByteLimitExceeded
            }
        }

        func admitRegularFile(byteCount: Int64) throws {
            guard byteCount >= 0 else { throw BuilderError.invalidEntry }
            let byteCount = UInt64(byteCount)
            guard byteCount <= maximumFileBytes,
                  byteCount <= remainingContentBytes else {
                throw BuilderError.contentByteLimitExceeded
            }
            remainingContentBytes -= byteCount
        }

        func admitStructuralFactPrefix(relativePath: String) throws {
            guard remainingStructuralFactPrefixOperations > 0 else {
                throw BuilderError.structuralFactPrefixLimitExceeded
            }
            let byteCount = relativePath.utf8.count
            guard byteCount <= remainingStructuralFactPrefixUTF8Bytes else {
                throw BuilderError.structuralFactPrefixLimitExceeded
            }
            remainingStructuralFactPrefixOperations -= 1
            remainingStructuralFactPrefixUTF8Bytes -= byteCount
        }

        private func checkedProduct(_ lhs: Int, _ rhs: Int) throws -> Int {
            let result = lhs.multipliedReportingOverflow(by: rhs)
            guard !result.overflow else { throw BuilderError.encodedByteLimitExceeded }
            return result.partialValue
        }

        private func checkedSum(_ lhs: Int, _ rhs: Int) throws -> Int {
            let result = lhs.addingReportingOverflow(rhs)
            guard !result.overflow else { throw BuilderError.encodedByteLimitExceeded }
            return result.partialValue
        }
    }

    private struct FileSnapshot: Equatable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let linkCount: UInt64
        let byteCount: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64

        init?(_ value: stat, requireRegular: Bool) {
            guard value.st_size >= 0,
                  !requireRegular || (value.st_mode & S_IFMT) == S_IFREG else {
                return nil
            }
            device = UInt64(truncatingIfNeeded: value.st_dev)
            inode = UInt64(truncatingIfNeeded: value.st_ino)
            mode = UInt32(truncatingIfNeeded: value.st_mode)
            linkCount = UInt64(truncatingIfNeeded: value.st_nlink)
            byteCount = value.st_size
            modificationSeconds = Int64(value.st_mtimespec.tv_sec)
            modificationNanoseconds = Int64(value.st_mtimespec.tv_nsec)
            changeSeconds = Int64(value.st_ctimespec.tv_sec)
            changeNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        }
    }

    func build(
        rootURL: URL,
        limits: Limits,
        cancellation: ReconstructionCancellation
    ) async throws -> Result {
        try validate(limits)
        try Task.checkCancellation()
        try cancellation.check()
        let rootDescriptor = try openDirectory(at: rootURL)
        defer { Darwin.close(rootDescriptor) }
        let budget = TraversalBudget(limits: limits)

        let directory = try buildDirectory(
            descriptor: rootDescriptor,
            relativePrefix: "",
            rawPathComponents: [],
            depth: 0,
            limits: limits,
            budget: budget,
            cancellation: cancellation
        )
        try verifyCapturedFacts(
            directory.filesystemFacts,
            relativeTo: rootDescriptor,
            cancellation: cancellation
        )
        return try materializeResult(directory.manifest, cancellation: cancellation)
    }

    private func validate(_ limits: Limits) throws {
        guard limits.maximumDepth >= 0,
              limits.maximumEntries > 0,
              limits.maximumRelativePathUTF8Bytes > 0,
              limits.maximumEncodedBytes > 0,
              limits.maximumFileBytes > 0,
              limits.maximumTotalContentBytes > 0,
              limits.maximumStructuralFactPrefixOperations > 0,
              limits.maximumStructuralFactPrefixUTF8Bytes > 0,
              limits.maximumDepth <= HardLimit.maximumDepth,
              limits.maximumEntries <= HardLimit.maximumEntries,
              limits.maximumRelativePathUTF8Bytes <= HardLimit.maximumRelativePathUTF8Bytes,
              limits.maximumEncodedBytes <= HardLimit.maximumEncodedBytes,
              limits.maximumFileBytes <= HardLimit.maximumFileBytes,
              limits.maximumTotalContentBytes <= HardLimit.maximumTotalContentBytes,
              limits.maximumStructuralFactPrefixOperations
                <= HardLimit.maximumStructuralFactPrefixOperations,
              limits.maximumStructuralFactPrefixUTF8Bytes
                <= HardLimit.maximumStructuralFactPrefixUTF8Bytes else {
            throw BuilderError.invalidLimit
        }
    }

    private func buildDirectory(
        descriptor: Int32,
        relativePrefix: String,
        rawPathComponents: [String],
        depth: Int,
        limits: Limits,
        budget: TraversalBudget,
        cancellation: ReconstructionCancellation
    ) throws -> DirectoryResult {
        try Task.checkCancellation()
        try cancellation.check()
        let beforeDirectory = try snapshot(of: descriptor, expectedType: UInt32(S_IFDIR))
        let names = try entryNames(in: descriptor, maximumCount: budget.remainingEntries)

        var immediateEntries: [CapturedEntry] = []
        immediateEntries.reserveCapacity(names.count)
        var structuralFacts: [ReconstructionVerifiedContainerFact] = []
        structuralFacts.reserveCapacity(names.count)
        var filesystemFacts = [CapturedFilesystemFact(
            rawPathComponents: rawPathComponents,
            snapshot: beforeDirectory,
            symbolicLinkTarget: nil
        )]
        var canonicalNames = Set<String>()
        for rawName in names {
            try Task.checkCancellation()
            try cancellation.check()
            let name = try normalizedComponent(rawName)
            guard canonicalNames.insert(name).inserted else { throw BuilderError.invalidEntry }
            let relativePath = relativePrefix.isEmpty ? name : "\(relativePrefix)/\(name)"
            let childRawPathComponents = rawPathComponents + [rawName]
            guard relativePath.utf8.count <= limits.maximumRelativePathUTF8Bytes else {
                throw BuilderError.pathLimitExceeded
            }
            try budget.admitEntry(relativePath: relativePath)
            testHooks.beforeOpeningEntry?(relativePath)

            let entry = try snapshot(named: rawName, in: descriptor)

            switch entry.mode & UInt32(S_IFMT) {
            case UInt32(S_IFLNK):
                let target = try symbolicLinkTarget(named: rawName, in: descriptor)
                try budget.admitLinkText(target)
                testHooks.afterSymbolicLinkRead?(relativePath)
                try verifySnapshot(entry, named: rawName, in: descriptor)
                immediateEntries.append(CapturedEntry(
                    relativePath: name,
                    kind: .symbolicLink,
                    contentIdentity: nil,
                    executableMode: false,
                    symbolicLinkTarget: target
                ))
                structuralFacts.append(ReconstructionVerifiedContainerFact(
                    relativePath: name,
                    nodeKind: .symbolicLink,
                    artifactKind: .symbolicLink,
                    executableMode: false
                ))
                filesystemFacts.append(CapturedFilesystemFact(
                    rawPathComponents: childRawPathComponents,
                    snapshot: entry,
                    symbolicLinkTarget: target
                ))

            case UInt32(S_IFDIR):
                guard depth < limits.maximumDepth else { throw BuilderError.depthLimitExceeded }
                let childDescriptor = try openDirectory(named: rawName, relativeTo: descriptor)
                let child: DirectoryResult
                do {
                    defer { Darwin.close(childDescriptor) }
                    guard try snapshot(of: childDescriptor, expectedType: UInt32(S_IFDIR)) == entry else {
                        throw BuilderError.changedDuringRead
                    }
                    child = try buildDirectory(
                        descriptor: childDescriptor,
                        relativePrefix: relativePath,
                        rawPathComponents: childRawPathComponents,
                        depth: depth + 1,
                        limits: limits,
                        budget: budget,
                        cancellation: cancellation
                    )
                }
                try verifySnapshot(entry, named: rawName, in: descriptor)
                let kind = ReconstructionArtifactClassifier().classifyContainer(
                    originalName: name,
                    verifiedFacts: child.structuralFacts
                )
                let executableMode = isExecutable(mode: entry.mode)
                immediateEntries.append(CapturedEntry(
                    relativePath: name,
                    kind: kind,
                    contentIdentity: child.manifest.contentIdentity,
                    executableMode: executableMode,
                    symbolicLinkTarget: nil
                ))
                structuralFacts.append(ReconstructionVerifiedContainerFact(
                    relativePath: name,
                    nodeKind: .directory,
                    artifactKind: kind,
                    executableMode: executableMode
                ))
                for fact in child.structuralFacts {
                    try Task.checkCancellation()
                    try cancellation.check()
                    let prefixedPath = "\(name)/\(fact.relativePath)"
                    try budget.admitStructuralFactPrefix(relativePath: prefixedPath)
                    structuralFacts.append(ReconstructionVerifiedContainerFact(
                        relativePath: prefixedPath,
                        nodeKind: fact.nodeKind,
                        artifactKind: fact.artifactKind,
                        executableMode: fact.executableMode
                    ))
                    testHooks.afterStructuralFactPrefix?(prefixedPath)
                }
                filesystemFacts.append(contentsOf: child.filesystemFacts)

            case UInt32(S_IFREG):
                let content = try readRegularFile(
                    named: rawName,
                    in: descriptor,
                    expectedSnapshot: entry,
                    relativePath: relativePath,
                    budget: budget,
                    cancellation: cancellation
                )
                let classification = ReconstructionArtifactClassifier().classifyVerifiedRegularFile(
                    originalName: name,
                    verifiedPrefix: content.verifiedPrefix,
                    verifiedByteCount: content.identity.byteCount,
                    completeSample: content.completeSample
                )
                let executableMode = isExecutable(mode: entry.mode)
                immediateEntries.append(CapturedEntry(
                    relativePath: name,
                    kind: classification.kind,
                    contentIdentity: content.identity,
                    executableMode: executableMode,
                    symbolicLinkTarget: nil
                ))
                structuralFacts.append(ReconstructionVerifiedContainerFact(
                    relativePath: name,
                    nodeKind: .regularFile,
                    artifactKind: classification.kind,
                    executableMode: executableMode
                ))
                filesystemFacts.append(CapturedFilesystemFact(
                    rawPathComponents: childRawPathComponents,
                    snapshot: entry,
                    symbolicLinkTarget: nil
                ))

            default:
                throw BuilderError.invalidEntry
            }
        }

        testHooks.afterDirectoryTraversal?(relativePrefix)
        guard try snapshot(of: descriptor, expectedType: UInt32(S_IFDIR)) == beforeDirectory else {
            throw BuilderError.changedDuringRead
        }
        let immediateManifest = try canonicalizeCapturedEntries(
            immediateEntries,
            limits: limits,
            cancellation: cancellation,
            enforceContentLimits: false
        )
        return DirectoryResult(
            manifest: immediateManifest,
            structuralFacts: structuralFacts,
            filesystemFacts: filesystemFacts
        )
    }

    private func entryNames(in descriptor: Int32, maximumCount: Int) throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0, let directory = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw BuilderError.invalidRoot
        }
        defer { Darwin.closedir(directory) }

        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN)) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." {
                guard names.count < maximumCount else { throw BuilderError.entryLimitExceeded }
                names.append(name)
                if let forced = testHooks.forcedReaddirFailureAfterEntryCount,
                   names.count >= forced {
                    throw BuilderError.readdirFailed
                }
            }
        }
        guard errno == 0 else { throw BuilderError.readdirFailed }
        return names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    private func snapshot(named name: String, in descriptor: Int32) throws -> FileSnapshot {
        var metadata = stat()
        guard name.withCString({
            Darwin.fstatat(descriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }) == 0,
        let snapshot = FileSnapshot(metadata, requireRegular: false) else {
            throw BuilderError.invalidEntry
        }
        return snapshot
    }

    private func snapshot(of descriptor: Int32, expectedType: UInt32) throws -> FileSnapshot {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              UInt32(metadata.st_mode & S_IFMT) == expectedType,
              let snapshot = FileSnapshot(metadata, requireRegular: false) else {
            throw BuilderError.invalidEntry
        }
        return snapshot
    }

    private func verifySnapshot(
        _ expected: FileSnapshot,
        named name: String,
        in descriptor: Int32
    ) throws {
        guard try snapshot(named: name, in: descriptor) == expected else {
            throw BuilderError.changedDuringRead
        }
    }

    private func verifyCapturedFacts(
        _ facts: [CapturedFilesystemFact],
        relativeTo rootDescriptor: Int32,
        cancellation: ReconstructionCancellation
    ) throws {
        for fact in facts {
            try Task.checkCancellation()
            try cancellation.check()
            guard let name = fact.rawPathComponents.last else {
                guard try snapshot(
                    of: rootDescriptor,
                    expectedType: fact.snapshot.mode & UInt32(S_IFMT)
                ) == fact.snapshot else {
                    throw BuilderError.changedDuringRead
                }
                continue
            }

            var parentDescriptor = Darwin.dup(rootDescriptor)
            guard parentDescriptor >= 0 else { throw BuilderError.invalidRoot }
            defer { Darwin.close(parentDescriptor) }
            for component in fact.rawPathComponents.dropLast() {
                try Task.checkCancellation()
                try cancellation.check()
                let childDescriptor = try openDirectory(
                    named: component,
                    relativeTo: parentDescriptor
                )
                Darwin.close(parentDescriptor)
                parentDescriptor = childDescriptor
            }

            guard try snapshot(named: name, in: parentDescriptor) == fact.snapshot else {
                throw BuilderError.changedDuringRead
            }
            if let symbolicLinkTarget = fact.symbolicLinkTarget {
                guard try self.symbolicLinkTarget(
                    named: name,
                    in: parentDescriptor
                ) == symbolicLinkTarget else {
                    throw BuilderError.changedDuringRead
                }
            }
        }
    }

    private func normalizedComponent(_ component: String) throws -> String {
        let normalized = component.precomposedStringWithCanonicalMapping
        guard !normalized.isEmpty,
              normalized != ".",
              normalized != "..",
              !normalized.contains("/"),
              !normalized.unicodeScalars.contains(where: { $0.value == 0 || $0.value < 0x20 || $0.value == 0x7f }) else {
            throw BuilderError.invalidEntry
        }
        return normalized
    }

    private func openDirectory(at url: URL) throws -> Int32 {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw BuilderError.invalidRoot }
        return descriptor
    }

    private func openDirectory(named name: String, relativeTo descriptor: Int32) throws -> Int32 {
        let child = name.withCString {
            Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard child >= 0 else { throw BuilderError.invalidEntry }
        return child
    }

    private func readRegularFile(
        named name: String,
        in parentDescriptor: Int32,
        expectedSnapshot: FileSnapshot,
        relativePath: String,
        budget: TraversalBudget,
        cancellation: ReconstructionCancellation
    ) throws -> (
        identity: ReconstructionContentIdentity,
        verifiedPrefix: Data,
        completeSample: Bool
    ) {
        let descriptor = name.withCString {
            Darwin.openat(parentDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw BuilderError.invalidEntry }
        defer { Darwin.close(descriptor) }

        var beforeValue = stat()
        guard Darwin.fstat(descriptor, &beforeValue) == 0,
              let before = FileSnapshot(beforeValue, requireRegular: true),
              before == expectedSnapshot,
              before.byteCount > 0 else {
            throw BuilderError.emptyRegularFile
        }
        try budget.admitRegularFile(byteCount: before.byteCount)

        var hasher = SHA256()
        var total: UInt64 = 0
        let prefixLimit = min(UInt64(before.byteCount), Self.maximumClassifierPrefixBytes)
        var verifiedPrefix = Data()
        verifiedPrefix.reserveCapacity(Int(prefixLimit))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            try cancellation.check()
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                let chunk = Data(buffer.prefix(Int(count)))
                hasher.update(data: chunk)
                total += UInt64(count)
                if UInt64(verifiedPrefix.count) < prefixLimit {
                    let remaining = Int(prefixLimit - UInt64(verifiedPrefix.count))
                    verifiedPrefix.append(chunk.prefix(remaining))
                }
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            throw BuilderError.invalidEntry
        }

        testHooks.afterRegularFileRead?(relativePath)
        var afterValue = stat()
        guard Darwin.fstat(descriptor, &afterValue) == 0,
              let after = FileSnapshot(afterValue, requireRegular: true),
              before == after,
              total == UInt64(after.byteCount) else {
            throw BuilderError.changedDuringRead
        }
        try verifySnapshot(expectedSnapshot, named: name, in: parentDescriptor)
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (
            try ReconstructionContentIdentity(algorithm: .sha256, digest: digest, byteCount: total),
            verifiedPrefix,
            UInt64(verifiedPrefix.count) == total
        )
    }

    private func symbolicLinkTarget(named name: String, in descriptor: Int32) throws -> String {
        var buffer = [CChar](repeating: 0, count: 16 * 1_024)
        let count = name.withCString { linkName in
            Darwin.readlinkat(descriptor, linkName, &buffer, buffer.count)
        }
        guard count >= 0, count < buffer.count else { throw BuilderError.invalidEntry }
        let data = Data(buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) })
        guard let target = String(data: data, encoding: .utf8) else { throw BuilderError.invalidEntry }
        return target
    }

    private func encode(
        entries: [CanonicalEntry],
        limits: Limits,
        cancellation: ReconstructionCancellation
    ) throws -> Data {
        try Task.checkCancellation()
        try cancellation.check()
        let bytes = try ReconstructionCanonicalJSON.encode(CanonicalManifest(entries: entries))
        try Task.checkCancellation()
        try cancellation.check()
        guard bytes.count <= limits.maximumEncodedBytes else {
            throw BuilderError.encodedByteLimitExceeded
        }
        return bytes
    }

    private func canonicalizeCapturedEntries(
        _ entries: [CapturedEntry],
        limits: Limits,
        cancellation: ReconstructionCancellation,
        enforceContentLimits: Bool
    ) throws -> CanonicalizedManifest {
        try Task.checkCancellation()
        try cancellation.check()
        let budget = TraversalBudget(limits: limits)
        var canonicalNames = Set<String>()
        var canonicalEntries: [CanonicalEntry] = []
        canonicalEntries.reserveCapacity(entries.count)

        for entry in entries {
            try Task.checkCancellation()
            try cancellation.check()
            let relativePath = try normalizedComponent(entry.relativePath)
            guard !relativePath.contains("/"),
                  canonicalNames.insert(relativePath).inserted else {
                throw BuilderError.invalidEntry
            }
            guard relativePath.utf8.count <= limits.maximumRelativePathUTF8Bytes else {
                throw BuilderError.pathLimitExceeded
            }
            try budget.admitEntry(relativePath: relativePath)

            if entry.kind == .symbolicLink {
                guard entry.contentIdentity == nil,
                      !entry.executableMode,
                      let target = entry.symbolicLinkTarget,
                      !target.isEmpty,
                      !target.unicodeScalars.contains(where: { $0.value == 0 }) else {
                    throw BuilderError.invalidEntry
                }
                try budget.admitLinkText(target)
            } else {
                guard let identity = entry.contentIdentity,
                      entry.symbolicLinkTarget == nil else {
                    throw BuilderError.invalidEntry
                }
                if enforceContentLimits {
                    guard identity.byteCount <= UInt64(Int64.max) else {
                        throw BuilderError.contentByteLimitExceeded
                    }
                    try budget.admitRegularFile(byteCount: Int64(identity.byteCount))
                }
            }

            canonicalEntries.append(CanonicalEntry(
                relativePath: relativePath,
                kind: entry.kind,
                contentIdentity: entry.contentIdentity,
                executableMode: entry.executableMode,
                symbolicLinkTarget: entry.symbolicLinkTarget
            ))
        }
        return try canonicalizeEntries(
            canonicalEntries,
            limits: limits,
            cancellation: cancellation
        )
    }

    private func canonicalizeEntries(
        _ entries: [CanonicalEntry],
        limits: Limits,
        cancellation: ReconstructionCancellation
    ) throws -> CanonicalizedManifest {
        try Task.checkCancellation()
        try cancellation.check()
        let ordered = entries.sorted { lhs, rhs in
            lhs.relativePath.utf8.lexicographicallyPrecedes(rhs.relativePath.utf8)
        }
        let bytes = try encode(
            entries: ordered,
            limits: limits,
            cancellation: cancellation
        )
        let identity = try ReconstructionContentIdentity(
            algorithm: .sha256,
            digest: sha256(bytes),
            byteCount: UInt64(bytes.count)
        )
        try Task.checkCancellation()
        try cancellation.check()
        return CanonicalizedManifest(bytes: bytes, contentIdentity: identity)
    }

    private func materializeResult(
        _ manifest: CanonicalizedManifest,
        cancellation: ReconstructionCancellation
    ) throws -> Result {
        try Task.checkCancellation()
        try cancellation.check()
        let materialized = try materializeAttachment(
            manifest.bytes,
            cancellation: cancellation
        )
        let attachmentLifetime = materialized.lifetime
        do {
            try Task.checkCancellation()
            try cancellation.check()
        } catch {
            attachmentLifetime.discard()
            throw error
        }
        return Result(
            canonicalManifestBytes: manifest.bytes,
            contentIdentity: manifest.contentIdentity,
            attachmentSource: ReconstructionAttachmentSource(
                contentIdentity: manifest.contentIdentity,
                verifiedURL: materialized.url,
                lifetimeToken: attachmentLifetime
            )
        )
    }

    private func materializeAttachment(
        _ bytes: Data,
        cancellation: ReconstructionCancellation
    ) throws -> MaterializedAttachment {
        try Task.checkCancellation()
        try cancellation.check()
        let temporaryDirectoryURL = FileManager.default.temporaryDirectory.standardizedFileURL
        let parentDescriptor = temporaryDirectoryURL.withUnsafeFileSystemRepresentation { path in
            path.map {
                Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            } ?? -1
        }
        guard parentDescriptor >= 0 else {
            throw BuilderError.attachmentMaterializationFailed
        }
        defer { Darwin.close(parentDescriptor) }
        var createdName: String?
        var descriptor: Int32 = -1
        for _ in 0..<8 {
            let candidate = "MacScope-ReconstructionManifest-\(UUID().uuidString)"
            descriptor = candidate.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                    0o600
                )
            }
            if descriptor >= 0 {
                createdName = candidate
                break
            }
            if errno != EEXIST { break }
        }
        guard descriptor >= 0, let createdName else {
            throw BuilderError.attachmentMaterializationFailed
        }
        let url = temporaryDirectoryURL.appendingPathComponent(createdName)
        let lifetime: ReconstructionAttachmentLifetime
        do {
            lifetime = try ReconstructionAttachmentLifetime(
                owning: url,
                creatorDescriptor: descriptor,
                parentDescriptor: parentDescriptor
            )
        } catch {
            Darwin.close(descriptor)
            // Without a retained creator descriptor there is no safe pathname cleanup. Preserve
            // the private empty inode as an orphan instead of risking an unrelated replacement.
            throw BuilderError.attachmentMaterializationFailed
        }
        var keep = false
        defer {
            Darwin.close(descriptor)
            if !keep { lifetime.discard() }
        }
        testHooks.afterAttachmentCreation?(url)
        guard Darwin.fchmod(descriptor, S_IRUSR | S_IRGRP | S_IROTH) == 0 else {
            throw BuilderError.attachmentMaterializationFailed
        }
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            try cancellation.check()
            let count = bytes.withUnsafeBytes { rawBuffer -> Int in
                Darwin.write(descriptor, rawBuffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw BuilderError.attachmentMaterializationFailed }
            offset += count
        }
        guard Darwin.fsync(descriptor) == 0 else { throw BuilderError.attachmentMaterializationFailed }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size == bytes.count else {
            throw BuilderError.attachmentMaterializationFailed
        }
        try Task.checkCancellation()
        try cancellation.check()
        keep = true
        return MaterializedAttachment(url: url, lifetime: lifetime)
    }

    private func isExecutable(mode: UInt32) -> Bool {
        mode & UInt32(S_IXUSR | S_IXGRP | S_IXOTH) != 0
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
