import Darwin
import Foundation

/// A run-owned stage, captured from admitted bytes. It owns files, never a process or checkpoint.
/// Callers validate before and after the existing broker lease; changed bytes invalidate results.
struct ReconstructionSourceExecutionStage: Sendable {
    enum Failure: Error { case unsafeRoot, invalidFile, changedIdentity, writeFailed }
    struct FileIdentity: Hashable, Sendable {
        let device: Int32
        let inode: UInt64
        let byteCount: Int
        let sha256: String
    }
    let profileID: String
    let root: URL
    enum SourceAuthority: Hashable, Sendable {
        case admittedRevision(revisionSHA256: String)
        case trustedOriginal(sourceSHA256: String)
    }
    let sourceAuthority: SourceAuthority
    var revisionSHA256: String? {
        if case let .admittedRevision(value) = sourceAuthority { return value }
        return nil
    }
    let source: FileIdentity
    let harness: FileIdentity
    private let rootDevice: Int32
    private let rootInode: UInt64

    static func create(revision: ReconstructionSourceRevision,
                       authority: ReconstructionSourceRevisionAuthority,
                       harness: ReconstructionSourceBehaviorHarness,
                       parent: URL) throws -> Self {
        try Task.checkCancellation()
        _ = try ReconstructionSourceRevisionAdmission.decodeAndValidate(
            payload: ReconstructionSourceRevisionAdmission.encode(revision), authority: authority)
        return try stage(sourceUTF8: revision.sourceUTF8, expectedSourceSHA256: revision.sourceSHA256,
                         sourceAuthority: .admittedRevision(revisionSHA256: revision.revisionSHA256), profileID: revision.profileID,
                         harness: harness, parent: parent)
    }

    /// Owner-qualified immutable original bytes only. This does not admit a model revision or
    /// establish an oracle: successful independent execution must establish that authority later.
    static func createOriginalAuthority(sourceUTF8: Data, expectedSourceSHA256: String,
                                        harness: ReconstructionSourceBehaviorHarness,
                                        parent: URL, profileID: String = ReconstructionSourceProfile.scalarU32V1.rawValue) throws -> Self {
        try stage(sourceUTF8: sourceUTF8, expectedSourceSHA256: expectedSourceSHA256,
                  sourceAuthority: .trustedOriginal(sourceSHA256: expectedSourceSHA256), profileID: profileID,
                  harness: harness, parent: parent)
    }

    private static func stage(sourceUTF8: Data, expectedSourceSHA256: String,
                              sourceAuthority: SourceAuthority, profileID: String,
                              harness: ReconstructionSourceBehaviorHarness, parent: URL) throws -> Self {
        try Task.checkCancellation()
        _ = try ReconstructionSourceProfile.enabled(profileID)
        guard !sourceUTF8.isEmpty, sourceUTF8.count <= 65_536,
              String(data: sourceUTF8, encoding: .utf8) != nil,
              !sourceUTF8.contains(0),
              ReconstructionSourceRevisionAdmission.sourceSHA256(sourceUTF8) == expectedSourceSHA256 else {
            throw Failure.invalidFile
        }
        let parentPath = parent.path
        guard parent.isFileURL, MacScopeWorkRoot.contains(parentPath),
              parent.resolvingSymlinksInPath().standardizedFileURL.path == parentPath else {
            throw Failure.unsafeRoot
        }
        var parentStat = stat()
        guard lstat(parentPath, &parentStat) == 0, (parentStat.st_mode & S_IFMT) == S_IFDIR,
              parentStat.st_uid == getuid(), (parentStat.st_mode & 0o022) == 0 else {
            throw Failure.unsafeRoot
        }
        let root = parent.appendingPathComponent("source-" + UUID().uuidString.lowercased(), isDirectory: true)
        guard mkdir(root.path, 0o700) == 0 else { throw Failure.writeFailed }
        var rootStat = stat()
        guard lstat(root.path, &rootStat) == 0 else { throw Failure.unsafeRoot }
        var completed = false
        defer {
            var current = stat()
            if !completed, lstat(root.path, &current) == 0,
               (current.st_mode & S_IFMT) == S_IFDIR,
               current.st_dev == rootStat.st_dev, current.st_ino == rootStat.st_ino {
                try? FileManager.default.removeItem(at: root)
            }
        }
        try write(sourceUTF8, to: root.appendingPathComponent("candidate.c"))
        try write(harness.sourceUTF8, to: root.appendingPathComponent("harness.c"))
        let result = Self(profileID: profileID, root: root, sourceAuthority: sourceAuthority,
            source: try capture(root.appendingPathComponent("candidate.c"), maximum: 65_536),
            harness: try capture(root.appendingPathComponent("harness.c"), maximum: 65_536),
            rootDevice: rootStat.st_dev, rootInode: rootStat.st_ino)
        guard result.source.sha256 == expectedSourceSHA256,
              result.source.byteCount == sourceUTF8.count,
              result.harness.sha256 == ReconstructionSourceRevisionAdmission.sourceSHA256(harness.sourceUTF8),
              result.harness.byteCount == harness.sourceUTF8.count else { throw Failure.changedIdentity }
        try result.verifyInputs()
        completed = true
        return result
    }

    func verifyInputs() throws {
        try Task.checkCancellation()
        var info = stat()
        guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700,
              info.st_dev == rootDevice, info.st_ino == rootInode,
              root.resolvingSymlinksInPath().path == root.path else { throw Failure.unsafeRoot }
        guard try Self.capture(root.appendingPathComponent("candidate.c"), maximum: 65_536) == source,
              try Self.capture(root.appendingPathComponent("harness.c"), maximum: 65_536) == harness else {
            throw Failure.changedIdentity
        }
    }

    func captureInspection() throws -> FileIdentity {
        try captureInspectionBytes().identity
    }

    /// Captures identity and bytes in one bounded no-follow descriptor read for AST admission.
    func captureInspectionBytes() throws -> (identity: FileIdentity, bytes: Data) {
        try verifyInputs()
        let directory = root.appendingPathComponent("inspection", isDirectory: true)
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else { throw Failure.invalidFile }
        let captured = try Self.captureBytes(directory.appendingPathComponent("candidate.ast.json"), maximum: 1_048_576)
        try verifyInputs()
        return captured
    }

    func captureExecutable() throws -> FileIdentity {
        try verifyInputs()
        let directory = root.appendingPathComponent("output", isDirectory: true)
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else { throw Failure.invalidFile }
        let file = directory.appendingPathComponent("candidate")
        guard lstat(file.path, &info) == 0, (info.st_mode & S_IXUSR) != 0 else { throw Failure.invalidFile }
        return try Self.capture(file, maximum: 1_048_576)
    }

    func verifyExecutable(_ identity: FileIdentity) throws {
        guard try captureExecutable() == identity else { throw Failure.changedIdentity }
    }

    /// Resume recovery for a trusted original only: installs the job's durably admitted executable
    /// bytes as `output/candidate` (never compiled here) and returns its identity, which must equal
    /// the admitted SHA-256 and byte count exactly. The output directory must not preexist.
    func installRetainedExecutable(_ bytes: Data, expectedSHA256: String) throws -> FileIdentity {
        guard case .trustedOriginal = sourceAuthority, !bytes.isEmpty, bytes.count <= 1_048_576,
              ReconstructionSourceRevisionAdmission.sourceSHA256(bytes) == expectedSHA256 else {
            throw Failure.changedIdentity
        }
        try verifyInputs()
        let directory = root.appendingPathComponent("output", isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw Failure.writeFailed }
        try Self.write(bytes, to: directory.appendingPathComponent("candidate"), mode: 0o500)
        let identity = try captureExecutable()
        guard identity.sha256 == expectedSHA256, identity.byteCount == bytes.count else { throw Failure.changedIdentity }
        return identity
    }

    private static func write(_ data: Data, to url: URL, mode: mode_t = 0o400) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.writeFailed }
        defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw Failure.writeFailed }
                offset += n
            }
        }
        guard fsync(fd) == 0, fchmod(fd, mode) == 0 else { throw Failure.writeFailed }
    }

    private static func capture(_ url: URL, maximum: Int) throws -> FileIdentity {
        try captureBytes(url, maximum: maximum).identity
    }

    private static func captureBytes(_ url: URL, maximum: Int) throws -> (identity: FileIdentity, bytes: Data) {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.invalidFile }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == getuid(), before.st_nlink == 1,
              (before.st_mode & 0o022) == 0, before.st_size > 0,
              before.st_size <= maximum else { throw Failure.invalidFile }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            guard n >= 0 else { throw Failure.invalidFile }
            if n == 0 { break }
            guard bytes.count + n <= maximum else { throw Failure.invalidFile }
            bytes.append(contentsOf: buffer.prefix(n))
        }
        var after = stat(), path = stat()
        guard fstat(fd, &after) == 0, lstat(url.path, &path) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              after.st_dev == path.st_dev, after.st_ino == path.st_ino,
              (path.st_mode & S_IFMT) == S_IFREG, after.st_nlink == 1, path.st_nlink == 1,
              after.st_uid == getuid(), path.st_uid == getuid(),
              (after.st_mode & 0o022) == 0, (path.st_mode & 0o022) == 0,
              before.st_size == after.st_size, after.st_size == bytes.count,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.changedIdentity }
        return (.init(device: after.st_dev, inode: after.st_ino, byteCount: bytes.count,
                      sha256: ReconstructionSourceRevisionAdmission.sourceSHA256(bytes)), bytes)
    }
}
