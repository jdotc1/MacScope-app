import CryptoKit
import Darwin
import Foundation

struct ReconstructionArtifactClassification: Sendable {
    let kind: ReconstructionArtifactKind
    let diagnostic: ReconstructionDiagnostic?
}

enum ReconstructionArtifactClassifierError: Error {
    case invalidAttachment
    case unreadableAttachment
}

struct ReconstructionVerifiedContainerFact: Sendable {
    enum NodeKind: Equatable, Sendable {
        case regularFile
        case directory
        case symbolicLink
    }

    let relativePath: String
    let nodeKind: NodeKind
    let artifactKind: ReconstructionArtifactKind
    let executableMode: Bool
}

struct ReconstructionArtifactClassifier: Sendable {
    private static let maximumTextInspectionBytes: UInt64 = 1_048_576
    static let maximumVerifiedContainerFactDepth = 3
    private static let loadableKinds: Set<ReconstructionArtifactKind> = [
        .machOImage,
        .dynamicLibrary,
        .objectFile,
    ]

    /// Source-compatible fail-closed seam for callers that possess names but no structural proof.
    /// Bare relative paths can never authorize a bundle kind.
    func classifyContainer(
        originalName: String,
        childRelativePaths: [String]
    ) -> ReconstructionArtifactKind {
        .directory
    }

    /// Classifies only from descriptor-captured structural facts. A bundle suffix is a naming
    /// hint, never sufficient evidence on its own.
    func classifyContainer(
        originalName: String,
        verifiedFacts: [ReconstructionVerifiedContainerFact]
    ) -> ReconstructionArtifactKind {
        guard isSafePathComponent(originalName),
              verifiedFacts.allSatisfy({ isSafeRelativePath($0.relativePath) }),
              Set(verifiedFacts.map(\.relativePath)).count == verifiedFacts.count else {
            return .directory
        }
        switch (originalName as NSString).pathExtension.lowercased() {
        case "app":
            guard verifiedFacts.contains(where: {
                $0.relativePath == "Contents/Info.plist" && $0.nodeKind == .regularFile
            }),
                  verifiedFacts.contains(where: { fact in
                      let components = fact.relativePath.split(
                          separator: "/",
                          omittingEmptySubsequences: false
                      )
                      return components.count == 3
                          && components[0] == "Contents"
                          && components[1] == "MacOS"
                          && fact.nodeKind == .regularFile
                          && fact.executableMode
                          && Self.loadableKinds.contains(fact.artifactKind)
                  }) else {
                return .directory
            }
            return .applicationBundle

        case "framework":
            let binaryName = (originalName as NSString).deletingPathExtension
            guard isSafePathComponent(binaryName),
                  verifiedFacts.contains(where: { fact in
                let components = fact.relativePath.split(
                    separator: "/",
                    omittingEmptySubsequences: false
                )
                return components.count == 3
                    && components[0] == "Versions"
                    && components[2] == Substring(binaryName)
                    && fact.nodeKind == .regularFile
                    && Self.loadableKinds.contains(fact.artifactKind)
            }) else {
                return .directory
            }
            return .frameworkBundle

        default:
            return .directory
        }
    }

    func classify(
        source: ReconstructionAttachmentSource,
        originalName: String,
        cancellation: ReconstructionCancellation? = nil
    ) throws -> ReconstructionArtifactClassification {
        try cancellation?.check()
        let descriptor = source.verifiedURL.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) } ?? -1
        }
        guard descriptor >= 0 else {
            throw ReconstructionArtifactClassifierError.unreadableAttachment
        }
        defer { _ = Darwin.close(descriptor) }

        var beforeMetadata = stat()
        var beforePathMetadata = stat()
        let beforePathStatus = source.verifiedURL.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &beforePathMetadata) } ?? -1
        }
        guard Darwin.fstat(descriptor, &beforeMetadata) == 0,
              beforePathStatus == 0,
              (beforeMetadata.st_mode & S_IFMT) == S_IFREG,
              beforeMetadata.st_size >= 0,
              StableMetadata(beforePathMetadata) == StableMetadata(beforeMetadata),
              UInt64(beforeMetadata.st_size) == source.contentIdentity.byteCount else {
            throw ReconstructionArtifactClassifierError.invalidAttachment
        }
        let before = StableMetadata(beforeMetadata)

        let inspectionLimit = min(
            source.contentIdentity.byteCount,
            Self.maximumTextInspectionBytes
        )
        var inspected = Data()
        inspected.reserveCapacity(Int(inspectionLimit))
        var hasher = SHA256()
        var byteCount: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try cancellation?.check()
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count > 0 {
                let count = Int(count)
                let chunk = Data(buffer.prefix(count))
                byteCount += UInt64(count)
                guard byteCount <= source.contentIdentity.byteCount else {
                    throw ReconstructionArtifactClassifierError.invalidAttachment
                }
                hasher.update(data: chunk)
                if UInt64(inspected.count) < inspectionLimit {
                    let remaining = Int(inspectionLimit - UInt64(inspected.count))
                    inspected.append(contentsOf: chunk.prefix(remaining))
                }
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            throw ReconstructionArtifactClassifierError.unreadableAttachment
        }

        try cancellation?.check()
        var afterMetadata = stat()
        guard Darwin.fstat(descriptor, &afterMetadata) == 0,
              StableMetadata(afterMetadata) == before,
              byteCount == source.contentIdentity.byteCount else {
            throw ReconstructionArtifactClassifierError.invalidAttachment
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == source.contentIdentity.digest else {
            throw ReconstructionArtifactClassifierError.invalidAttachment
        }

        let verifiedMachOKind = try machOKind(
            descriptor: descriptor,
            verifiedPrefix: inspected,
            verifiedByteCount: byteCount,
            cancellation: cancellation
        )
        try cancellation?.check()
        var finalMetadata = stat()
        var finalPathMetadata = stat()
        let finalPathStatus = source.verifiedURL.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.lstat($0, &finalPathMetadata) } ?? -1
        }
        guard Darwin.fstat(descriptor, &finalMetadata) == 0,
              finalPathStatus == 0,
              StableMetadata(finalMetadata) == before,
              StableMetadata(finalPathMetadata) == before else {
            throw ReconstructionArtifactClassifierError.invalidAttachment
        }
        if let kind = verifiedMachOKind {
            return ReconstructionArtifactClassification(kind: kind, diagnostic: nil)
        }

        return classifyVerifiedRegularFile(
            originalName: originalName,
            verifiedPrefix: inspected,
            verifiedByteCount: source.contentIdentity.byteCount,
            completeSample: UInt64(inspected.count) == source.contentIdentity.byteCount
        )
    }

    /// Classifies only descriptor-verified facts. File names refine complete, verified text but
    /// never independently authorize a binary kind. Container builders can use this same pure seam
    /// after acquiring their own descriptor-bound prefix and byte-count evidence.
    func classifyVerifiedRegularFile(
        originalName: String,
        verifiedPrefix: Data,
        verifiedByteCount: UInt64,
        completeSample: Bool
    ) -> ReconstructionArtifactClassification {
        if let kind = machOKind(
            verifiedPrefix,
            verifiedByteCount: verifiedByteCount
        ) {
            return ReconstructionArtifactClassification(kind: kind, diagnostic: nil)
        }
        if verifiedPrefix.starts(with: Data("!<arch>\n".utf8)) {
            return ReconstructionArtifactClassification(kind: .staticLibrary, diagnostic: nil)
        }
        if verifiedPrefix.starts(with: [0x50, 0x4b, 0x03, 0x04])
            || verifiedPrefix.starts(with: [0x50, 0x4b, 0x05, 0x06])
            || verifiedPrefix.starts(with: [0x1f, 0x8b]) {
            return ReconstructionArtifactClassification(kind: .archive, diagnostic: nil)
        }
        if isRecognizedResource(verifiedPrefix) {
            return ReconstructionArtifactClassification(kind: .resource, diagnostic: nil)
        }

        let suffix = (originalName as NSString).pathExtension.lowercased()
        if completeSample,
           verifiedByteCount <= Self.maximumTextInspectionBytes,
           UInt64(verifiedPrefix.count) == verifiedByteCount,
           let text = verifiedText(verifiedPrefix) {
            if ["c", "cc", "cpp", "cxx", "m", "mm", "swift"].contains(suffix) {
                return ReconstructionArtifactClassification(kind: .source, diagnostic: nil)
            }
            if ["h", "hh", "hpp", "hxx"].contains(suffix) {
                return ReconstructionArtifactClassification(kind: .header, diagnostic: nil)
            }
            if suffix == "swiftinterface" {
                return ReconstructionArtifactClassification(kind: .moduleInterface, diagnostic: nil)
            }
            if ["log", "trace"].contains(suffix) {
                return ReconstructionArtifactClassification(kind: .log, diagnostic: nil)
            }
            if ["crash", "diag", "diagnostic"].contains(suffix) {
                return ReconstructionArtifactClassification(kind: .diagnostic, diagnostic: nil)
            }
            if ["json", "plist", "yaml", "yml", "xcconfig", "pbxproj"].contains(suffix),
               !text.isEmpty {
                return ReconstructionArtifactClassification(kind: .buildManifest, diagnostic: nil)
            }
            if ["txt", "md", "html", "css", "strings"].contains(suffix) {
                return ReconstructionArtifactClassification(kind: .resource, diagnostic: nil)
            }
        }

        return ReconstructionArtifactClassification(
            kind: .opaque,
            diagnostic: .sanitizing(
                "Unrecognized verified bytes for \(originalName); retained as opaque."
            )
        )
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

    private enum ByteOrder: Equatable {
        case littleEndian
        case bigEndian

        var isLittleEndian: Bool { self == .littleEndian }
    }

    private struct ThinFormat {
        let headerByteCount: Int
        let byteOrder: ByteOrder
    }

    private struct FatFormat {
        let byteOrder: ByteOrder
        let is64Bit: Bool

        var entryByteCount: Int { is64Bit ? 32 : 20 }
    }

    private struct FatSlice {
        let cpuType: UInt32
        let cpuSubtype: UInt32
        let offset: UInt64
        let byteCount: UInt64
    }

    private func machOKind(
        _ data: Data,
        verifiedByteCount: UInt64
    ) -> ReconstructionArtifactKind? {
        guard data.count >= 4,
              UInt64(data.count) <= verifiedByteCount else {
            return nil
        }
        let magic = Array(data.prefix(4))
        if let thinFormat = thinFormat(for: magic) {
            return validatedThinFileType(
                data,
                verifiedByteCount: verifiedByteCount,
                headerByteCount: thinFormat.headerByteCount,
                byteOrder: thinFormat.byteOrder
            ).map { artifactKind(forMachOFileType: $0) }
        }
        guard let fatFormat = fatFormat(for: magic),
              let slices = validatedFatSlices(
                  tableBytes: data,
                  verifiedByteCount: verifiedByteCount,
                  format: fatFormat
              ),
              let selected = selectedFatSlice(from: slices),
              let fileType = validatedFatSliceFileType(
                  selected,
                  in: data
              ) else {
            return nil
        }
        return artifactKind(forMachOFileType: fileType)
    }

    private func machOKind(
        descriptor: Int32,
        verifiedPrefix: Data,
        verifiedByteCount: UInt64,
        cancellation: ReconstructionCancellation?
    ) throws -> ReconstructionArtifactKind? {
        guard verifiedPrefix.count >= 4 else { return nil }
        let magic = Array(verifiedPrefix.prefix(4))
        guard let format = fatFormat(for: magic) else {
            return machOKind(verifiedPrefix, verifiedByteCount: verifiedByteCount)
        }
        guard verifiedPrefix.count >= 8 else { return nil }
        let architectureCount = uint32(
            verifiedPrefix,
            at: 4,
            littleEndian: format.byteOrder.isLittleEndian
        )
        guard (1...64).contains(architectureCount) else { return nil }
        let tableByteCount = 8 + Int(architectureCount) * format.entryByteCount
        try cancellation?.check()
        guard let tableBytes = try readExactly(
            descriptor: descriptor,
            offset: 0,
            byteCount: tableByteCount,
            cancellation: cancellation
        ),
              let slices = validatedFatSlices(
                  tableBytes: tableBytes,
                  verifiedByteCount: verifiedByteCount,
                  format: format
              ),
              let selected = selectedFatSlice(from: slices) else {
            return nil
        }
        guard let header = try readExactly(
            descriptor: descriptor,
            offset: selected.offset,
            byteCount: 32,
            cancellation: cancellation
        ),
              let thinFormat = thinFormat(for: Array(header.prefix(4))),
              header.count >= thinFormat.headerByteCount else {
            return nil
        }
        let commandBytes = uint32(
            header,
            at: 20,
            littleEndian: thinFormat.byteOrder.isLittleEndian
        )
        let probeByteCount = UInt64(thinFormat.headerByteCount) + UInt64(commandBytes)
        guard probeByteCount <= selected.byteCount,
              probeByteCount <= Self.maximumTextInspectionBytes,
              probeByteCount <= UInt64(Int.max),
              let probe = try readExactly(
                  descriptor: descriptor,
                  offset: selected.offset,
                  byteCount: Int(probeByteCount),
                  cancellation: cancellation
              ),
              uint32(probe, at: 4, littleEndian: thinFormat.byteOrder.isLittleEndian)
                == selected.cpuType,
              uint32(probe, at: 8, littleEndian: thinFormat.byteOrder.isLittleEndian)
                == selected.cpuSubtype,
              let fileType = validatedThinFileType(
                  probe,
                  verifiedByteCount: selected.byteCount,
                  headerByteCount: thinFormat.headerByteCount,
                  byteOrder: thinFormat.byteOrder
              ) else {
            return nil
        }
        return artifactKind(forMachOFileType: fileType)
    }

    private func validatedThinFileType(
        _ data: Data,
        verifiedByteCount: UInt64,
        headerByteCount: Int,
        byteOrder: ByteOrder
    ) -> UInt32? {
        guard data.count >= headerByteCount,
              verifiedByteCount >= UInt64(headerByteCount) else {
            return nil
        }
        let cpuType = uint32(data, at: 4, littleEndian: byteOrder.isLittleEndian)
        guard isSupportedCPUType(cpuType) else { return nil }
        let fileType = uint32(data, at: 12, littleEndian: byteOrder.isLittleEndian)
        guard isSupportedMachOFileType(fileType) else { return nil }
        let commandCount = uint32(data, at: 16, littleEndian: byteOrder.isLittleEndian)
        let commandBytes = uint32(data, at: 20, littleEndian: byteOrder.isLittleEndian)
        guard commandCount <= 65_535,
              (commandCount == 0) == (commandBytes == 0) else {
            return nil
        }
        let minimumCommandBytes = UInt64(commandCount) * 8
        guard UInt64(commandBytes) >= minimumCommandBytes else { return nil }
        let commandEnd = UInt64(headerByteCount) + UInt64(commandBytes)
        guard commandEnd <= verifiedByteCount,
              commandEnd <= UInt64(data.count) else {
            return nil
        }

        var offset = headerByteCount
        for _ in 0..<commandCount {
            guard offset <= Int(commandEnd) - 8 else { return nil }
            let commandSize = uint32(
                data,
                at: offset + 4,
                littleEndian: byteOrder.isLittleEndian
            )
            guard commandSize >= 8,
                  commandSize % 4 == 0,
                  UInt64(offset) + UInt64(commandSize) <= commandEnd else {
                return nil
            }
            offset += Int(commandSize)
        }
        guard UInt64(offset) == commandEnd else { return nil }
        return fileType
    }

    private func validatedFatSlices(
        tableBytes: Data,
        verifiedByteCount: UInt64,
        format: FatFormat
    ) -> [FatSlice]? {
        guard tableBytes.count >= 8 else { return nil }
        let architectureCount = uint32(
            tableBytes,
            at: 4,
            littleEndian: format.byteOrder.isLittleEndian
        )
        guard (1...64).contains(architectureCount) else { return nil }
        let tableEnd = 8 + Int(architectureCount) * format.entryByteCount
        guard tableEnd <= tableBytes.count,
              UInt64(tableEnd) <= verifiedByteCount else {
            return nil
        }

        var slices: [FatSlice] = []
        slices.reserveCapacity(Int(architectureCount))
        for index in 0..<Int(architectureCount) {
            let entryOffset = 8 + index * format.entryByteCount
            let cpuType = uint32(
                tableBytes,
                at: entryOffset,
                littleEndian: format.byteOrder.isLittleEndian
            )
            let cpuSubtype = uint32(
                tableBytes,
                at: entryOffset + 4,
                littleEndian: format.byteOrder.isLittleEndian
            )
            let sliceOffset = format.is64Bit
                ? uint64(
                    tableBytes,
                    at: entryOffset + 8,
                    littleEndian: format.byteOrder.isLittleEndian
                )
                : UInt64(uint32(
                    tableBytes,
                    at: entryOffset + 8,
                    littleEndian: format.byteOrder.isLittleEndian
                ))
            let sliceByteCount = format.is64Bit
                ? uint64(
                    tableBytes,
                    at: entryOffset + 16,
                    littleEndian: format.byteOrder.isLittleEndian
                )
                : UInt64(uint32(
                    tableBytes,
                    at: entryOffset + 12,
                    littleEndian: format.byteOrder.isLittleEndian
                ))
            let alignmentOffset = format.is64Bit ? entryOffset + 24 : entryOffset + 16
            let alignment = uint32(
                tableBytes,
                at: alignmentOffset,
                littleEndian: format.byteOrder.isLittleEndian
            )
            if format.is64Bit {
                let reserved = uint32(
                    tableBytes,
                    at: entryOffset + 28,
                    littleEndian: format.byteOrder.isLittleEndian
                )
                guard reserved == 0 else { return nil }
            }
            let sliceEnd = sliceOffset.addingReportingOverflow(sliceByteCount)
            guard isSupportedCPUType(cpuType),
                  sliceByteCount >= 28,
                  alignment <= 30,
                  !sliceEnd.overflow,
                  sliceEnd.partialValue <= verifiedByteCount,
                  sliceOffset >= UInt64(tableEnd) else {
                return nil
            }
            if alignment != 0 {
                let alignmentBytes = UInt64(1) << alignment
                guard sliceOffset % alignmentBytes == 0 else { return nil }
            }
            slices.append(FatSlice(
                cpuType: cpuType,
                cpuSubtype: cpuSubtype,
                offset: sliceOffset,
                byteCount: sliceByteCount
            ))
        }
        let sortedRanges = slices.sorted { $0.offset < $1.offset }
        for index in 1..<sortedRanges.count {
            let previousEnd = sortedRanges[index - 1].offset
                .addingReportingOverflow(sortedRanges[index - 1].byteCount)
            guard !previousEnd.overflow,
                  previousEnd.partialValue <= sortedRanges[index].offset else {
                return nil
            }
        }
        return slices
    }

    private func selectedFatSlice(from slices: [FatSlice]) -> FatSlice? {
        for preferredCPUType: UInt32 in [0x0100_000c, 0x0100_0007] {
            let candidates = slices.filter { $0.cpuType == preferredCPUType }
            if candidates.count == 1 { return candidates[0] }
            if candidates.count > 1 { return nil }
        }
        return slices.count == 1 ? slices[0] : nil
    }

    private func validatedFatSliceFileType(
        _ selected: FatSlice,
        in data: Data
    ) -> UInt32? {
        guard selected.offset <= UInt64(Int.max),
              selected.byteCount <= UInt64(Int.max),
              selected.offset <= UInt64(data.count),
              selected.byteCount <= UInt64(data.count) - selected.offset else {
            return nil
        }
        let start = Int(selected.offset)
        guard data.count - start >= 4,
              let format = thinFormat(for: Array(data[start..<(start + 4)])),
              data.count - start >= format.headerByteCount else {
            return nil
        }
        let commandBytes = uint32(
            data,
            at: start + 20,
            littleEndian: format.byteOrder.isLittleEndian
        )
        let probeByteCount = UInt64(format.headerByteCount) + UInt64(commandBytes)
        guard probeByteCount <= selected.byteCount,
              probeByteCount <= Self.maximumTextInspectionBytes,
              probeByteCount <= UInt64(data.count - start) else {
            return nil
        }
        let end = start + Int(probeByteCount)
        let probe = Data(data[start..<end])
        guard uint32(probe, at: 4, littleEndian: format.byteOrder.isLittleEndian)
                == selected.cpuType,
              uint32(probe, at: 8, littleEndian: format.byteOrder.isLittleEndian)
                == selected.cpuSubtype else {
            return nil
        }
        return validatedThinFileType(
            probe,
            verifiedByteCount: selected.byteCount,
            headerByteCount: format.headerByteCount,
            byteOrder: format.byteOrder
        )
    }

    private func thinFormat(for magic: [UInt8]) -> ThinFormat? {
        switch magic {
        case [0xce, 0xfa, 0xed, 0xfe]:
            ThinFormat(headerByteCount: 28, byteOrder: .littleEndian)
        case [0xfe, 0xed, 0xfa, 0xce]:
            ThinFormat(headerByteCount: 28, byteOrder: .bigEndian)
        case [0xcf, 0xfa, 0xed, 0xfe]:
            ThinFormat(headerByteCount: 32, byteOrder: .littleEndian)
        case [0xfe, 0xed, 0xfa, 0xcf]:
            ThinFormat(headerByteCount: 32, byteOrder: .bigEndian)
        default:
            nil
        }
    }

    private func fatFormat(for magic: [UInt8]) -> FatFormat? {
        switch magic {
        case [0xca, 0xfe, 0xba, 0xbe]:
            FatFormat(byteOrder: .bigEndian, is64Bit: false)
        case [0xbe, 0xba, 0xfe, 0xca]:
            FatFormat(byteOrder: .littleEndian, is64Bit: false)
        case [0xca, 0xfe, 0xba, 0xbf]:
            FatFormat(byteOrder: .bigEndian, is64Bit: true)
        case [0xbf, 0xba, 0xfe, 0xca]:
            FatFormat(byteOrder: .littleEndian, is64Bit: true)
        default:
            nil
        }
    }

    private func artifactKind(forMachOFileType fileType: UInt32) -> ReconstructionArtifactKind {
        switch fileType {
        case 0x1:
            .objectFile
        case 0x6:
            .dynamicLibrary
        case 0xa:
            .debugCompanion
        default:
            .machOImage
        }
    }

    private func readExactly(
        descriptor: Int32,
        offset: UInt64,
        byteCount: Int,
        cancellation: ReconstructionCancellation?
    ) throws -> Data? {
        guard byteCount >= 0,
              offset <= UInt64(Int64.max),
              UInt64(byteCount) <= UInt64(Int64.max) - offset else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        var totalRead = 0
        while totalRead < byteCount {
            try cancellation?.check()
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.pread(
                    descriptor,
                    buffer.baseAddress?.advanced(by: totalRead),
                    byteCount - totalRead,
                    off_t(offset) + off_t(totalRead)
                )
            }
            if count > 0 {
                totalRead += Int(count)
                continue
            }
            if count == 0 { return nil }
            if errno == EINTR { continue }
            throw ReconstructionArtifactClassifierError.unreadableAttachment
        }
        return Data(bytes)
    }

    private func isSupportedCPUType(_ value: UInt32) -> Bool {
        [
            7,
            12,
            18,
            0x0100_0007,
            0x0100_000c,
            0x0100_0012,
        ].contains(value)
    }

    private func isSupportedMachOFileType(_ value: UInt32) -> Bool {
        (1...12).contains(value)
    }

    private func uint32(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt32 {
        let bytes = [UInt8](data[offset..<(offset + 4)])
        if littleEndian {
            return UInt32(bytes[0])
                | (UInt32(bytes[1]) << 8)
                | (UInt32(bytes[2]) << 16)
                | (UInt32(bytes[3]) << 24)
        }
        return (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
    }

    private func uint64(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt64 {
        let lowerOffset = littleEndian ? offset : offset + 4
        let upperOffset = littleEndian ? offset + 4 : offset
        let lower = UInt64(uint32(data, at: lowerOffset, littleEndian: littleEndian))
        let upper = UInt64(uint32(data, at: upperOffset, littleEndian: littleEndian))
        return lower | (upper << 32)
    }

    private func isRecognizedResource(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
            || data.starts(with: [0xff, 0xd8, 0xff])
            || data.starts(with: Data("GIF87a".utf8))
            || data.starts(with: Data("GIF89a".utf8))
            || data.starts(with: Data("%PDF-".utf8))
    }

    private func verifiedText(_ data: Data) -> String? {
        guard !data.contains(0),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let prohibited = text.unicodeScalars.filter {
            ($0.value < 0x20 && $0.value != 0x09 && $0.value != 0x0a && $0.value != 0x0d)
                || $0.value == 0x7f
        }
        guard prohibited.count <= max(1, text.unicodeScalars.count / 100) else {
            return nil
        }
        return text
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              path == path.precomposedStringWithCanonicalMapping else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && components.allSatisfy { isSafePathComponent(String($0)) }
    }

    private func isSafePathComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.contains("/")
            && component == component.precomposedStringWithCanonicalMapping
            && !component.unicodeScalars.contains(where: {
                $0.value == 0 || $0.value < 0x20 || $0.value == 0x7f
            })
    }
}
