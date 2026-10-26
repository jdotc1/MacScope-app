import Foundation
import CryptoKit
import Darwin

public enum AppKitAdmissionError: String, Error, Sendable {
    case invalidIdentity, invalidPath, inaccessible, notRegular, volumeBoundary
    case resourceLimit, byteLimit, changedDuringRead, unsupportedFormat, duplicatePath
}

/// Worker-owned immutable bytes. Only this admission boundary constructs leases.
/// Open each path component relative to a held directory FD with O_NOFOLLOW.
/// Caller supplies an explicit bounded resource list, never a recursive donor scan.
public struct AppKitResourceLease: Sendable {
    public let resource: AppKitResourceIdentity
    public let bytes: Data
}

public struct AppKitResourceAdmission: Sendable {
    public init() {}

    public func read(bundleRoot: URL, bundleID: String, bundleGeneration: String,
                     relativePaths: [String]) throws -> [AppKitResourceLease] {
        guard !bundleID.isEmpty, !bundleGeneration.isEmpty else {
            throw AppKitAdmissionError.invalidIdentity
        }
        guard relativePaths.count <= 256 else { throw AppKitAdmissionError.resourceLimit }
        var canonical = Set<String>()
        for path in relativePaths {
            let identity = AppKitResourceIdentity(bundleID: bundleID,
                bundleGeneration: bundleGeneration, relativePath: path,
                contentSHA256: String(repeating: "0", count: 64))
            guard identity.hasValidIdentity else { throw AppKitAdmissionError.invalidPath }
            let key = path.precomposedStringWithCanonicalMapping.lowercased()
            guard canonical.insert(key).inserted else { throw AppKitAdmissionError.duplicatePath }
        }
        // Root must already be the owner's resolved selected bundle. Refuse a
        // symlink in its final component; ancestors are the host's selection seam.
        let root = open(bundleRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw AppKitAdmissionError.inaccessible }
        defer { close(root) }
        var rootStat = stat()
        guard fstat(root, &rootStat) == 0 else { throw AppKitAdmissionError.inaccessible }
        var total = 0
        var result: [AppKitResourceLease] = []
        for path in relativePaths.sorted() {
            let bytes = try read(root: root, device: rootStat.st_dev, path: path,
                                 remaining: 64 * 1024 * 1024 - total)
            total += bytes.count
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            result.append(.init(resource: .init(bundleID: bundleID,
                bundleGeneration: bundleGeneration, relativePath: path,
                contentSHA256: digest), bytes: bytes))
        }
        return result
    }

    private func read(root: Int32, device: dev_t, path: String, remaining: Int) throws -> Data {
        var fd = dup(root)
        guard fd >= 0 else { throw AppKitAdmissionError.inaccessible }
        defer { close(fd) }
        let parts = path.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK |
                (index == parts.count - 1 ? 0 : O_DIRECTORY)
            let next = openat(fd, part, flags)
            guard next >= 0 else { throw AppKitAdmissionError.inaccessible }
            close(fd)
            fd = next
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw AppKitAdmissionError.inaccessible }
            guard info.st_dev == device else { throw AppKitAdmissionError.volumeBoundary }
        }
        var before = stat()
        guard fstat(fd, &before) == 0 else { throw AppKitAdmissionError.inaccessible }
        guard (before.st_mode & S_IFMT) == S_IFREG else { throw AppKitAdmissionError.notRegular }
        let cap = min(8 * 1024 * 1024, remaining)
        guard before.st_size >= 0, before.st_size <= cap else { throw AppKitAdmissionError.byteLimit }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, min(buffer.count, cap - output.count + 1))
            if count == -1 && errno == EINTR { continue }
            guard count >= 0 else { throw AppKitAdmissionError.inaccessible }
            if count == 0 { break }
            guard count <= cap - output.count else { throw AppKitAdmissionError.byteLimit }
            output.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0,
              before.st_size == after.st_size, output.count == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw AppKitAdmissionError.changedDuringRead
        }
        guard output.starts(with: Data("NIBArchive".utf8)) ||
                output.starts(with: Data("bplist00".utf8)) else {
            throw AppKitAdmissionError.unsupportedFormat
        }
        return output
    }
}
