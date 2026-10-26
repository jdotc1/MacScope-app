import CryptoKit
import Darwin
import Foundation

enum ReconstructionDetachedAnalysisError: Error, Equatable, Sendable {
    case invalidAttachment
    case contentDrift
    case analysisAuthorityMismatch
}

struct ReconstructionDetachedAnalysisSnapshot: Sendable {
    let artifact: ReconstructionArtifactCoordinate
    let image: ReconstructionImageBinding
    let workspace: WorkspaceSnapshot
    let analysisInputFingerprintSHA256: String
}

enum ReconstructionDetachedAnalysisSnapshotBuilder {
    private struct StableMetadata: Equatable {
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let size: UInt64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64

        init(_ value: stat) {
            device = UInt64(truncatingIfNeeded: value.st_dev)
            inode = UInt64(truncatingIfNeeded: value.st_ino)
            mode = UInt32(value.st_mode)
            size = UInt64(value.st_size)
            modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        }
    }

    private static let observedDescriptorMutationFlags = UInt32(
        NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_DELETE | NOTE_LINK | NOTE_REVOKE
            | NOTE_RENAME
    )
    private static let disallowedDescriptorMutationFlags = UInt32(
        NOTE_WRITE | NOTE_EXTEND | NOTE_DELETE | NOTE_LINK | NOTE_REVOKE
    )

    static func build(
        source: ReconstructionAttachmentSource,
        artifact: ReconstructionArtifactCoordinate,
        expectedImage: ReconstructionImageBinding?,
        provider: any AnalysisProviding,
        overrides: [UInt64: AddressOverride],
        cancellation: ReconstructionCancellation
    ) async throws -> ReconstructionDetachedAnalysisSnapshot {
        guard artifact.contentIdentity == source.contentIdentity else {
            throw ReconstructionDetachedAnalysisError.contentDrift
        }
        let analysisToken = AnalysisCancellationToken {
            cancellation.isCancelled || Task.isCancelled
        }
        let providerWorkspace = try await withPinnedVerifiedSource(
            source,
            cancellation: cancellation
        ) { pinnedURL, descriptor in
            if let pinnedProvider = provider as? any PinnedAnalysisInputProviding {
                let transferredDescriptor = Darwin.dup(descriptor)
                guard transferredDescriptor >= 0 else {
                    throw ReconstructionDetachedAnalysisError.invalidAttachment
                }
                let sourceHandle = FileHandle(fileDescriptor: transferredDescriptor, closeOnDealloc: true)
                return try await pinnedProvider.openPinnedBinary(
                    url: source.verifiedURL,
                    source: sourceHandle,
                    selection: .machOSlice(expectedImage?.selectedSliceIndex),
                    overrides: overrides,
                    cancellation: analysisToken
                )
            }
            return try await provider.openBinary(
                url: pinnedURL,
                requestedSliceIndex: expectedImage?.selectedSliceIndex,
                overrides: overrides,
                cancellation: analysisToken
            )
        }
        let workspace = try normalizeProviderWorkspace(
            providerWorkspace,
            to: source.verifiedURL
        )
        let bound = try ReconstructionStableImageAuthority.bind(
            freshWorkspace: workspace,
            artifact: artifact,
            expectedImage: expectedImage
        )
        return .init(
            artifact: artifact,
            image: bound.image,
            workspace: bound.workspace,
            analysisInputFingerprintSHA256: bound.analysisInputFingerprintSHA256
        )
    }

    /// Keeps the exact verified inode open while the provider materializes it. The provider sees a
    /// descriptor-backed path, so replacing and later restoring `verifiedURL` cannot redirect the
    /// analysis open between the two identity checks.
    private static func withPinnedVerifiedSource<Value: Sendable>(
        _ source: ReconstructionAttachmentSource,
        cancellation: ReconstructionCancellation,
        operation: @Sendable (URL, Int32) async throws -> Value
    ) async throws -> Value {
        try cancellation.check()
        let descriptor: Int32
        do {
            descriptor = try source.openVerifiedDescriptor()
        } catch {
            throw ReconstructionDetachedAnalysisError.invalidAttachment
        }
        guard descriptor >= 0 else {
            throw ReconstructionDetachedAnalysisError.invalidAttachment
        }
        defer { _ = Darwin.close(descriptor) }
        let mutationQueue = try makeDescriptorMutationQueue(descriptor)
        defer { _ = Darwin.close(mutationQueue) }

        let before = try verifiedDescriptorMetadata(
            descriptor,
            source: source,
            cancellation: cancellation
        )
        let pinnedURL = URL(fileURLWithPath: "/dev/fd/\(descriptor)")
        let value = try await operation(pinnedURL, descriptor)
        guard let operationMutationFlags = descriptorMutationFlags(mutationQueue) else {
            throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
        }
        let after = try verifiedDescriptorMetadata(
            descriptor,
            source: source,
            cancellation: cancellation
        )
        guard let verificationMutationFlags = descriptorMutationFlags(mutationQueue),
              (operationMutationFlags | verificationMutationFlags)
                & disallowedDescriptorMutationFlags == 0,
              before == after else {
            throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
        }
        return value
    }

    /// A pathname rename changes ctime even though the already-open inode and its bytes remain
    /// authoritative. Vnode events distinguish that harmless case from an in-place write/restore,
    /// attribute change, unlink, hard-link change, or revocation without reopening by pathname.
    private static func makeDescriptorMutationQueue(_ descriptor: Int32) throws -> Int32 {
        let queue = Darwin.kqueue()
        guard queue >= 0 else {
            throw ReconstructionDetachedAnalysisError.invalidAttachment
        }
        var change = kevent64_s(
            ident: UInt64(descriptor),
            filter: Int16(EVFILT_VNODE),
            flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
            fflags: observedDescriptorMutationFlags,
            data: 0,
            udata: 0,
            ext: (0, 0)
        )
        var timeout = timespec(tv_sec: 0, tv_nsec: 0)
        guard Darwin.kevent64(queue, &change, 1, nil, 0, 0, &timeout) == 0 else {
            _ = Darwin.close(queue)
            throw ReconstructionDetachedAnalysisError.invalidAttachment
        }
        return queue
    }

    /// Drains every pending event so a harmless rename or attribute-only event cannot hide a
    /// later write. Attribute-only activity is not independently disqualifying: mapped reads may
    /// advance access metadata, while the stable-stat and content-digest checks below still reject
    /// persistent changes and the vnode flags reject transient byte or lifetime mutations.
    private static func descriptorMutationFlags(_ queue: Int32) -> UInt32? {
        var observedFlags: UInt32 = 0
        while true {
            var event = kevent64_s()
            var timeout = timespec(tv_sec: 0, tv_nsec: 0)
            let count = Darwin.kevent64(queue, nil, 0, &event, 1, 0, &timeout)
            if count == 0 { return observedFlags }
            if count == 1 {
                guard event.flags & UInt16(EV_ERROR) == 0 else { return nil }
                observedFlags |= event.fflags
                continue
            }
            if errno == EINTR { continue }
            return nil
        }
    }

    private static func verifiedDescriptorMetadata(
        _ descriptor: Int32,
        source: ReconstructionAttachmentSource,
        cancellation: ReconstructionCancellation
    ) throws -> StableMetadata {
        try cancellation.check()
        var descriptorState = stat()
        guard Darwin.fstat(descriptor, &descriptorState) == 0,
              (descriptorState.st_mode & S_IFMT) == S_IFREG,
              descriptorState.st_nlink == 1,
              descriptorState.st_size >= 0,
              UInt64(descriptorState.st_size) == source.contentIdentity.byteCount else {
            throw ReconstructionDetachedAnalysisError.invalidAttachment
        }
        if !source.hasDescriptorAuthority {
            var pathState = stat()
            guard source.verifiedURL.withUnsafeFileSystemRepresentation({ path in
                path.map { Darwin.lstat($0, &pathState) } ?? -1
            }) == 0,
            (pathState.st_mode & S_IFMT) == S_IFREG,
            pathState.st_nlink == 1,
            StableMetadata(pathState) == StableMetadata(descriptorState) else {
                throw ReconstructionDetachedAnalysisError.invalidAttachment
            }
        }

        var hasher = SHA256()
        var offset: off_t = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try cancellation.check()
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.pread(descriptor, bytes.baseAddress, bytes.count, offset)
            }
            if count > 0 {
                hasher.update(data: Data(buffer.prefix(count)))
                offset += off_t(count)
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            throw ReconstructionDetachedAnalysisError.invalidAttachment
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        var finalDescriptorState = stat()
        guard digest == source.contentIdentity.digest,
              UInt64(offset) == source.contentIdentity.byteCount,
              Darwin.fstat(descriptor, &finalDescriptorState) == 0,
              StableMetadata(finalDescriptorState) == StableMetadata(descriptorState) else {
            throw ReconstructionDetachedAnalysisError.contentDrift
        }
        return StableMetadata(descriptorState)
    }

    /// `/dev/fd/<n>` is deliberately ephemeral. Rebind the provider's otherwise validated one-
    /// image workspace to the durable source URL before its fingerprint can cross a checkpoint.
    private static func normalizeProviderWorkspace(
        _ workspace: WorkspaceSnapshot,
        to sourceURL: URL
    ) throws -> WorkspaceSnapshot {
        guard workspace.binaries.count == 1,
              let binaryIndex = workspace.binaries.indices.first,
              var analysis = workspace.analysis(in: workspace.binaries[binaryIndex].slot) else {
            throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
        }
        var normalized = workspace
        var binary = normalized.binaries[binaryIndex]
        binary.name = sourceURL.lastPathComponent
        binary.path = sourceURL.path
        binary.originalPathBookmark = nil
        if binary.resolvedExecutablePath != nil {
            binary.resolvedExecutablePath = sourceURL.path
        }
        normalized.binaries[binaryIndex] = binary
        do {
            analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(
                binary: binary,
                analysis: analysis
            )
        } catch {
            throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
        }
        normalized.replaceAnalysis(analysis, in: binary.slot)
        guard (try? normalized.validateInvariants()) != nil else {
            throw ReconstructionDetachedAnalysisError.analysisAuthorityMismatch
        }
        return normalized
    }
}
