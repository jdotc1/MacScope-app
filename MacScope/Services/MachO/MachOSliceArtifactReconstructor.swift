import CryptoKit
import Foundation

struct MachOSliceArtifactReconstructor: Sendable {
    private static let maximumLoadCommandCount = 4_096

    /// Reconstructs authoritative runtime-mapping evidence, except for the one valid Mach-O
    /// topology that cannot express a preferred named-segment layout: an MH_OBJECT containing
    /// exactly one anonymous parsed segment. Every other reconstruction failure remains fatal.
    static func reconstructOrMarkUnavailableForAnonymousObject(
        selectedSliceBytes: Data
    ) throws -> MachOSliceArtifactReconstruction? {
        let machO = try MachOParser().parse(
            selectedSliceBytes,
            options: MachOParseOptions(requestedSliceIndex: nil)
        )
        return try reconstructOrMarkUnavailableForAnonymousObject(
            machO: machO,
            selectedSliceBytes: selectedSliceBytes
        )
    }

    static func reconstructOrMarkUnavailableForAnonymousObject(
        machO: MachOFile,
        selectedSliceBytes: Data
    ) throws -> MachOSliceArtifactReconstruction? {
        do {
            return try reconstruct(machO: machO, selectedSliceBytes: selectedSliceBytes)
        } catch MachOSliceArtifactValidationError.invalidSegmentName {
            guard try isExactlyOneAnonymousObjectSegment(
                machO: machO,
                selectedSliceBytes: selectedSliceBytes
            ) else {
                throw MachOSliceArtifactValidationError.invalidSegmentName
            }
            return nil
        }
    }

    private static func isExactlyOneAnonymousObjectSegment(
        machO: MachOFile,
        selectedSliceBytes: Data
    ) throws -> Bool {
        guard machO.header.fileType == MachOConstants.fileTypeObject,
              machO.segments.count == 1,
              machO.segments[0].name.isEmpty,
              readUInt32LE(in: selectedSliceBytes, at: 0) == MachOConstants.machMagic64 else {
            return false
        }
        let segmentCommands = machO.loadCommands.filter {
            $0.command == MachOConstants.loadCommandSegment64
        }
        guard segmentCommands.count == 1 else {
            return false
        }
        let exactSegmentNames = try strictSegmentNames(
            in: selectedSliceBytes,
            allowingAnonymousSegmentName: true
        )
        return exactSegmentNames == [""]
    }

    static func reconstruct(
        selectedSliceBytes: Data
    ) throws -> MachOSliceArtifactReconstruction {
        let machO = try MachOParser().parse(
            selectedSliceBytes,
            options: MachOParseOptions(requestedSliceIndex: nil)
        )
        return try reconstruct(machO: machO, selectedSliceBytes: selectedSliceBytes)
    }

    static func reconstruct(
        machO: MachOFile,
        selectedSliceBytes: Data
    ) throws -> MachOSliceArtifactReconstruction {
        let exactSegmentNames = try strictSegmentNames(in: selectedSliceBytes)
        guard exactSegmentNames.count == machO.segments.count else {
            throw MachOSliceArtifactValidationError.invalidSegmentName
        }
        let hash = SHA256.hash(data: selectedSliceBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let identity = try MachOSliceArtifactIdentity(
            uuid: machO.uuid.flatMap { UUID(uuidString: $0.stringValue) },
            rawCPUType: machO.header.cpuType,
            rawCPUSubtype: machO.header.cpuSubtype,
            selectedSliceSHA256: hash,
            selectedSliceByteCount: UInt64(selectedSliceBytes.count)
        )
        let records = zip(machO.segments, exactSegmentNames).map { segment, exactName in
            MachOPreferredSegmentLayout.Record(
                name: exactName,
                preferredVMStart: segment.vmAddress,
                preferredVMSize: segment.vmSize,
                sliceRelativeFileOffset: segment.fileOffset,
                fileSize: segment.fileSize,
                initialProtections: segment.initialProtection
            )
        }
        let layout = try MachOPreferredSegmentLayout(
            records: records,
            selectedSliceByteCount: UInt64(selectedSliceBytes.count)
        )
        return MachOSliceArtifactReconstruction(
            identity: identity,
            preferredSegmentLayout: layout
        )
    }

    /// The general parser historically presents fixed C strings with lossy UTF-8 replacement.
    /// Artifact evidence cannot do that: re-read only LC_SEGMENT_64 names from the exact selected
    /// slice and fail closed before publishing a preferred layout.
    private static func strictSegmentNames(
        in bytes: Data,
        allowingAnonymousSegmentName: Bool = false
    ) throws -> [String] {
        guard bytes.count >= 32,
              readUInt32LE(in: bytes, at: 0) == MachOConstants.machMagic64,
              let commandCount = readUInt32LE(in: bytes, at: 16),
              let commandsSize = readUInt32LE(in: bytes, at: 20),
              commandCount <= UInt32(maximumLoadCommandCount),
              Int(commandsSize) <= bytes.count - 32 else {
            throw MachOSliceArtifactValidationError.invalidSegmentName
        }

        var names: [String] = []
        var cursor = 32
        let commandsEnd = 32 + Int(commandsSize)
        for _ in 0..<Int(commandCount) {
            guard cursor <= commandsEnd - 8,
                  let command = readUInt32LE(in: bytes, at: cursor),
                  let commandSize = readUInt32LE(in: bytes, at: cursor + 4),
                  commandSize >= 8,
                  Int(commandSize) <= commandsEnd - cursor else {
                throw MachOSliceArtifactValidationError.invalidSegmentName
            }
            if command == MachOConstants.loadCommandSegment64 {
                guard commandSize >= 72, cursor <= bytes.count - 24 else {
                    throw MachOSliceArtifactValidationError.invalidSegmentName
                }
                let fixedBytes = bytes.subdata(in: (cursor + 8)..<(cursor + 24))
                let nameBytes = fixedBytes.prefix { $0 != 0 }
                if nameBytes.isEmpty {
                    guard allowingAnonymousSegmentName,
                          fixedBytes.allSatisfy({ $0 == 0 }) else {
                        throw MachOSliceArtifactValidationError.invalidSegmentName
                    }
                    names.append("")
                } else if let name = String(data: Data(nameBytes), encoding: .utf8),
                          name.utf8.elementsEqual(nameBytes) {
                    names.append(name)
                } else {
                    throw MachOSliceArtifactValidationError.invalidSegmentName
                }
            }
            cursor += Int(commandSize)
        }
        guard cursor == commandsEnd else {
            throw MachOSliceArtifactValidationError.invalidSegmentName
        }
        return names
    }

    private static func readUInt32LE(in data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return data[offset..<(offset + 4)].enumerated().reduce(into: UInt32(0)) { value, pair in
            value |= UInt32(pair.element) << UInt32(pair.offset * 8)
        }
    }
}
