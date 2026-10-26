import Foundation
import Darwin

enum ELFArchiveLoadError: LocalizedError, Equatable {
    case unreadable
    case noELFMembers
    case selectionRequired([ELFArchiveMemberSummary])
    case multiplyLinkedSource
    case sourceChangedDuringRead
    case containerIdentityMismatch
    case memberIdentityMismatch
    case parse(ELFArchiveParseError)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "The Unix archive could not be read."
        case .noELFMembers:
            return "The Unix archive contains no ELF object members."
        case .selectionRequired(let members):
            let names = members.prefix(12).map {
                "[\($0.index), header \($0.archiveHeaderIndex)] \($0.name)"
            }.joined(separator: ", ")
            let suffix = members.count > 12 ? ", …" : ""
            return "The Unix archive contains multiple ELF members; choose one before loading: \(names)\(suffix)"
        case .multiplyLinkedSource:
            return "The Unix archive has multiple filesystem links and cannot establish one stable path authority."
        case .sourceChangedDuringRead:
            return "The Unix archive changed while MacScope was taking its bounded input snapshot."
        case .containerIdentityMismatch:
            return "The Unix archive bytes changed after member selection. Choose a member again."
        case .memberIdentityMismatch:
            return "The selected Unix archive member changed or moved. Choose a member again."
        case .parse(let error):
            return error.localizedDescription
        }
    }
}

/// Container loader for ELF object archives. It auto-opens only the sole ELF member. Multiple
/// candidates require an explicit stable ordinary-member index; the loader never guesses.
struct ELFArchiveBinaryLoader: BinaryLoader {
    let selection: ELFArchiveMemberSelection?
    let limits: ELFArchiveParserLimits
    private let snapshotReadObserver: (@Sendable (Int) -> Void)?

    init(
        selection: ELFArchiveMemberSelection? = nil,
        limits: ELFArchiveParserLimits = .product,
        snapshotReadObserver: (@Sendable (Int) -> Void)? = nil
    ) {
        self.selection = selection
        self.limits = limits
        self.snapshotReadObserver = snapshotReadObserver
    }

    func catalog(at url: URL) throws -> [ELFArchiveMemberSummary] {
        let bytes = try readArchive(at: url, cancellation: .never)
        let catalog = try parse(bytes)
        return catalog.elfMembers.map { Self.summary($0, container: catalog.containerIdentity) }
    }

    func load(at url: URL) throws -> LoadedBinary {
        try load(at: url, cancellation: .never)
    }

    func load(at url: URL, cancellation: AnalysisCancellationToken) throws -> LoadedBinary {
        try cancellation.check()
        let bytes = try readArchive(at: url, cancellation: cancellation)
        let catalog = try parse(bytes, cancellation: cancellation)
        let elfMembers = catalog.elfMembers
        guard !elfMembers.isEmpty else { throw ELFArchiveLoadError.noELFMembers }

        let selected: ELFArchiveMember
        if let selection {
            guard selection.isWellFormed else {
                throw BinaryLoadSelectionError.invalidArchiveSelection
            }
            guard catalog.containerIdentity == selection.container else {
                throw ELFArchiveLoadError.containerIdentityMismatch
            }
            guard let member = elfMembers.first(where: { $0.index == selection.member.index }),
                  member.identity == selection.member else {
                throw ELFArchiveLoadError.memberIdentityMismatch
            }
            selected = member
        } else if elfMembers.count == 1 {
            selected = elfMembers[0]
        } else {
            throw ELFArchiveLoadError.selectionRequired(
                elfMembers.map { Self.summary($0, container: catalog.containerIdentity) }
            )
        }

        try cancellation.check()
        let memberBytes = Data(bytes[selected.payloadRange])
        try cancellation.check()
        var loaded = try ELFBinaryLoader.parse(
            bytes: memberBytes,
            name: selected.name,
            // The archive remains the only filesystem path authority. The selected member name is
            // presentation only until the separate durable coordinate tranche lands.
            path: url.path
        )
        try cancellation.check()
        loaded.resolvedExecutablePath = url.path
        loaded.loadSelection = BinaryLoadSelection(
            elfArchiveMember: ELFArchiveMemberSelection(
                container: catalog.containerIdentity,
                member: selected.identity
            )
        )
        return loaded
    }

    /// Takes one owned snapshot from one no-follow descriptor. Parsing, container/member hashing,
    /// selection validation, and selected bytes all consume this copy; none can observe later path
    /// replacement or mutate underneath a mapped `Data` view.
    private func readArchive(
        at url: URL,
        cancellation: AnalysisCancellationToken
    ) throws -> Data {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw ELFArchiveLoadError.unreadable }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size >= 0 else {
            throw ELFArchiveLoadError.unreadable
        }
        // The outer archive path is the only filesystem authority retained by the loaded image.
        // A multiply-linked inode gives another path mutation authority over the same bytes even
        // after this no-follow descriptor has been opened, so reject it before consuming input.
        guard before.st_nlink == 1 else {
            throw ELFArchiveLoadError.multiplyLinkedSource
        }
        guard UInt64(before.st_size) <= UInt64(limits.maximumArchiveBytes) else {
            throw ELFArchiveLoadError.parse(.boundExceeded("archive byte count"))
        }

        var snapshot = Data()
        snapshot.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try cancellation.check()
            let count = buffer.withUnsafeMutableBytes { storage in
                Darwin.read(descriptor, storage.baseAddress, storage.count)
            }
            if count > 0 {
                let newCount = snapshot.count.addingReportingOverflow(Int(count))
                guard !newCount.overflow,
                      newCount.partialValue <= limits.maximumArchiveBytes else {
                    throw ELFArchiveLoadError.parse(.boundExceeded("archive byte count"))
                }
                snapshot.append(contentsOf: buffer.prefix(Int(count)))
                snapshotReadObserver?(snapshot.count)
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            throw ELFArchiveLoadError.unreadable
        }

        try cancellation.check()
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0 else {
            throw ELFArchiveLoadError.unreadable
        }
        guard ArchiveSnapshotMetadata(before) == ArchiveSnapshotMetadata(after),
              snapshot.count == Int(after.st_size) else {
            throw ELFArchiveLoadError.sourceChangedDuringRead
        }
        return snapshot
    }

    private func parse(
        _ bytes: Data,
        cancellation: AnalysisCancellationToken = .never
    ) throws -> ELFArchiveCatalog {
        do {
            return try ELFArchiveParser.parse(
                bytes,
                limits: limits,
                shouldCancel: { cancellation.isCancelled }
            )
        } catch let error as ELFArchiveParseError {
            if error == .cancelled { throw AnalysisCancelled() }
            throw ELFArchiveLoadError.parse(error)
        }
    }

    private static func summary(
        _ member: ELFArchiveMember,
        container: ELFArchiveContainerIdentity
    ) -> ELFArchiveMemberSummary {
        ELFArchiveMemberSummary(
            containerIdentity: container,
            identity: member.identity
        )
    }
}

private struct ArchiveSnapshotMetadata: Equatable {
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
