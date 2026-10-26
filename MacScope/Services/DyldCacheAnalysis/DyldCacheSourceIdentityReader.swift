import CryptoKit
import Dispatch
import Foundation
import Darwin

struct DyldCacheSourceContentSeal: Equatable, Sendable {
    let identity: DyldCacheFileIdentity
    let sha256: String
}

/// One request-wide cooperative budget shared by source admission, provider projection, and
/// post-provider verification. The injectable monotonic clock is intentionally internal so the
/// timeout boundary can be tested without sleeping.
struct DyldCacheInspectionBudget {
    private let deadlineNanoseconds: UInt64
    private let cancellation: AnalysisCancellationToken
    private let nowNanoseconds: @Sendable () -> UInt64
    private(set) var indexedCheckpointCount = 0

    init(
        maximumDurationMilliseconds: Int,
        cancellation: AnalysisCancellationToken,
        nowNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) throws {
        guard maximumDurationMilliseconds > 0 else {
            throw DyldCacheAnalysisProviderError.timeout
        }
        let duration = UInt64(maximumDurationMilliseconds)
        let (nanoseconds, durationOverflow) = duration.multipliedReportingOverflow(by: 1_000_000)
        let now = nowNanoseconds()
        let (deadline, deadlineOverflow) = now.addingReportingOverflow(nanoseconds)
        guard !durationOverflow, !deadlineOverflow else {
            throw DyldCacheAnalysisProviderError.timeout
        }
        deadlineNanoseconds = deadline
        self.cancellation = cancellation
        self.nowNanoseconds = nowNanoseconds
    }

    mutating func check(index: Int? = nil) throws {
        if index != nil, indexedCheckpointCount < Int.max { indexedCheckpointCount += 1 }
        if let index, index & 0xff != 0 { return }
        try cancellation.check()
        guard nowNanoseconds() <= deadlineNanoseconds else {
            throw DyldCacheAnalysisProviderError.timeout
        }
    }
}

/// Opens untrusted cache files with `O_NOFOLLOW` and derives identity from the opened descriptor.
/// Metadata identity remains useful for pathname-reopen checks, while `sealedMappedData` also
/// hashes the exact descriptor-backed bytes so same-inode rewrites with restored metadata cannot
/// masquerade as an unchanged source.
enum DyldCacheSourceIdentityReader {
    private static let hashChunkBytes = 1024 * 1024

    static func identity(for url: URL) throws -> DyldCacheFileIdentity {
        let opened = try openIdentityBoundDescriptor(for: url)
        defer { _ = close(opened.descriptor) }
        return opened.identity
    }

    /// Maps the exact descriptor whose identity was checked. This closes the preflight reader's
    /// own pathname-replacement race; it does not make a later provider reopen race disappear.
    static func mappedData(
        for url: URL,
        expectedIdentity: DyldCacheFileIdentity,
        maximumBytes: UInt64
    ) throws -> Data {
        try sealedMappedData(
            for: url,
            expectedIdentity: expectedIdentity,
            maximumBytes: maximumBytes
        ).data
    }

    static func sealedMappedData(
        for url: URL,
        expectedIdentity: DyldCacheFileIdentity,
        maximumBytes: UInt64
    ) throws -> (data: Data, seal: DyldCacheSourceContentSeal) {
        var budget = try DyldCacheInspectionBudget(
            maximumDurationMilliseconds: DyldCacheAnalysisLimits.hardMaximum.maximumDurationMilliseconds,
            cancellation: .never
        )
        return try sealedMappedData(
            for: url,
            expectedIdentity: expectedIdentity,
            maximumBytes: maximumBytes,
            budget: &budget
        )
    }

    static func sealedMappedData(
        for url: URL,
        expectedIdentity: DyldCacheFileIdentity,
        maximumBytes: UInt64,
        budget: inout DyldCacheInspectionBudget
    ) throws -> (data: Data, seal: DyldCacheSourceContentSeal) {
        try budget.check()
        let opened = try openIdentityBoundDescriptor(for: url)
        defer { _ = close(opened.descriptor) }
        guard opened.identity == expectedIdentity else {
            throw DyldCacheAnalysisProviderError.sourceIdentityMismatch
        }
        guard opened.identity.byteCount <= maximumBytes,
              opened.identity.byteCount <= UInt64(Int.max) else {
            throw DyldCacheAnalysisProviderError.outputLimitExceeded
        }
        let byteCount = Int(opened.identity.byteCount)
        let pointer = mmap(nil, byteCount, PROT_READ, MAP_PRIVATE, opened.descriptor, 0)
        guard pointer != MAP_FAILED, let pointer else {
            throw DyldCacheAnalysisProviderError.providerRejectedInput
        }
        let data = Data(
            bytesNoCopy: pointer,
            count: byteCount,
            deallocator: .custom { bytes, count in
                _ = munmap(bytes, count)
            }
        )
        let sha256 = try sha256Hex(data, budget: &budget)

        // `mmap(MAP_PRIVATE)` binds this read to the admitted descriptor, but it is not an
        // immutable snapshot of a file another process may still write. A second descriptor
        // identity check catches ordinary size/time drift during hashing. Same-size concurrent
        // writes with deliberately restored metadata can still yield a mixed read; callers
        // therefore bracket third-party consumption with independent before/after content seals.
        var metadataAfterHash = stat()
        guard fstat(opened.descriptor, &metadataAfterHash) == 0,
              identity(from: metadataAfterHash) == opened.identity else {
            throw DyldCacheAnalysisProviderError.sourceChangedDuringInspection
        }
        try budget.check()
        return (
            data,
            DyldCacheSourceContentSeal(identity: opened.identity, sha256: sha256)
        )
    }

    static func sha256Hex(
        _ data: Data,
        budget: inout DyldCacheInspectionBudget
    ) throws -> String {
        var hasher = SHA256()
        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            var chunkIndex = 0
            while offset < rawBuffer.count {
                try budget.check(index: chunkIndex << 8)
                let end = min(rawBuffer.count, offset + hashChunkBytes)
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: rawBuffer[offset..<end]))
                offset = end
                chunkIndex += 1
            }
        }
        try budget.check()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func safeSiblingURL(mainURL: URL, suffix: String) throws -> URL {
        let mainURL = mainURL.standardizedFileURL
        guard !suffix.isEmpty,
              suffix != ".",
              suffix != "..",
              suffix.first == ".",
              suffix.utf8.count <= 96,
              !suffix.contains("/"),
              !suffix.contains("\\"),
              !suffix.utf8.contains(0),
              suffix.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 45, 46, 48...57, 65...90, 95, 97...122: true
                  default: false
                  }
              }) else {
            throw DyldCacheAnalysisProviderError.unsafeSubcacheSuffix
        }

        let sibling = URL(fileURLWithPath: mainURL.path + suffix).standardizedFileURL
        guard sibling.deletingLastPathComponent().standardizedFileURL
                == mainURL.deletingLastPathComponent().standardizedFileURL,
              sibling.lastPathComponent == mainURL.lastPathComponent + suffix else {
            throw DyldCacheAnalysisProviderError.unsafeSubcacheSuffix
        }
        return sibling
    }

    private static func openIdentityBoundDescriptor(
        for url: URL
    ) throws -> (descriptor: Int32, identity: DyldCacheFileIdentity) {
        let url = url.standardizedFileURL
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              !url.path.utf8.contains(0) else {
            throw DyldCacheAnalysisProviderError.providerRejectedInput
        }

        var pathMetadata = stat()
        guard url.path.withCString({ lstat($0, &pathMetadata) }) == 0 else {
            throw DyldCacheAnalysisProviderError.providerRejectedInput
        }
        guard (pathMetadata.st_mode & S_IFMT) == S_IFREG else {
            throw DyldCacheAnalysisProviderError.sourceIsNotRegularFile
        }

        let descriptor = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw DyldCacheAnalysisProviderError.sourceIsNotRegularFile
        }

        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              (openedMetadata.st_mode & S_IFMT) == S_IFREG,
              openedMetadata.st_dev == pathMetadata.st_dev,
              openedMetadata.st_ino == pathMetadata.st_ino,
              openedMetadata.st_size == pathMetadata.st_size,
              openedMetadata.st_size > 0,
              openedMetadata.st_mtimespec.tv_sec == pathMetadata.st_mtimespec.tv_sec,
              openedMetadata.st_mtimespec.tv_nsec == pathMetadata.st_mtimespec.tv_nsec else {
            _ = close(descriptor)
            throw DyldCacheAnalysisProviderError.sourceChangedDuringInspection
        }

        let identity = identity(from: openedMetadata)
        return (descriptor, identity)
    }

    private static func identity(from metadata: stat) -> DyldCacheFileIdentity {
        DyldCacheFileIdentity(
            deviceID: UInt64(truncatingIfNeeded: metadata.st_dev),
            fileID: UInt64(truncatingIfNeeded: metadata.st_ino),
            byteCount: UInt64(metadata.st_size),
            modificationTimeSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationTimeNanoseconds: Int64(metadata.st_mtimespec.tv_nsec)
        )
    }
}
