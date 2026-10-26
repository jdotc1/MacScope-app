import Foundation

struct ELFProgramHeaderMetadataFacts: Hashable, Sendable {
    let buildID: String?
    let platformName: String?
    let minimumOSVersion: String?
    let hasConflictingBuildIDs: Bool
    let hasConflictingABITags: Bool
}

struct ELFProgramHeaderBinaryProjection {
    struct StringScanLimits: Hashable, Sendable {
        let maximumTotalScannedBytes: UInt64
        let maximumStringCount: Int
        let maximumTotalStringBytes: UInt64
        let maximumStringBytes: Int

        static let production = StringScanLimits(
            maximumTotalScannedBytes: 64 * 1_024 * 1_024,
            maximumStringCount: 1_000_000,
            maximumTotalStringBytes: 32 * 1_024 * 1_024,
            maximumStringBytes: 1 * 1_024 * 1_024
        )
    }

    static func makeLoadedBinary(
        catalog: ELFProgramHeaderCatalog,
        bytes: Data,
        name: String,
        path: String
    ) throws -> LoadedBinary {
        guard catalog.objectType == 2 || catalog.objectType == 3 else {
            throw ELFProgramHeaderError.unsupported("sectionless ELF requires ET_EXEC or ET_DYN")
        }
        let loads = catalog.records.filter { $0.isLoadable && $0.memorySize > 0 }
        guard !loads.isEmpty else {
            throw ELFProgramHeaderError.unsupported("sectionless ELF has no PT_LOAD segments")
        }
        let sections = loads.map { record in
            BinarySection(
                name: "PT_LOAD[\(record.index)]",
                address: record.virtualAddress,
                size: record.memorySize,
                fileOffset: record.fileOffset,
                isExecutable: record.isExecutable && record.fileSize > 0,
                isZeroFill: record.fileSize == 0,
                fileSize: record.fileSize
            )
        }
        let executable = sections.first { $0.isExecutable }
        let entryPoint = validatedEntryPoint(catalog: catalog)
        let facts = metadataFacts(catalog: catalog)
        var metadata = BinaryMetadataSummary.empty
        metadata.elfGNUBuildID = facts.buildID
        metadata.platformName = facts.platformName
        metadata.minimumOSVersion = facts.minimumOSVersion

        let (cpuType, architectureName) = architecture(machine: catalog.machine)
        let fileTypeName = catalog.objectType == 2 ? "ELF executable" : "ELF shared object"
        return LoadedBinary(
            name: name,
            path: path,
            isBundle: false,
            cpuType: cpuType,
            fileTypeName: fileTypeName,
            architectureDisplayName: architectureName,
            metadata: metadata,
            bytes: bytes,
            sliceOffset: 0,
            sections: sections,
            executableTextSection: executable,
            entryPointAddress: entryPoint,
            symbols: [],
            imports: [],
            indirectSymbols: [],
            exports: [],
            stringLiterals: try stringLiterals(catalog: catalog, bytes: bytes),
            functionStarts: entryPoint.map { [$0] } ?? [],
            objcSelectors: [:],
            relocations: []
        )
    }

    static func validatedEntryPoint(catalog: ELFProgramHeaderCatalog) -> UInt64? {
        guard catalog.entryPoint != 0 else { return nil }
        return catalog.records.contains { record in
            guard record.isLoadable, record.isExecutable, record.fileSize > 0,
                  catalog.entryPoint >= record.virtualAddress else { return false }
            let relative = catalog.entryPoint - record.virtualAddress
            return relative < record.fileSize
        } ? catalog.entryPoint : nil
    }

    static func metadataFacts(catalog: ELFProgramHeaderCatalog) -> ELFProgramHeaderMetadataFacts {
        let buildIDs = Set(catalog.notes.compactMap { note -> String? in
            guard note.name == "GNU", note.type == 3, !note.descriptor.isEmpty else { return nil }
            return note.descriptor.map { String(format: "%02x", $0) }.joined()
        })
        let abiTags = Set(catalog.notes.compactMap { note -> [UInt32]? in
            guard note.name == "GNU", note.type == 1, note.descriptor.count == 16 else { return nil }
            let reader = ELFProjectionEndianReader(bytes: note.descriptor, bigEndian: catalog.isBigEndian)
            guard let os = try? reader.u32(0), let major = try? reader.u32(4),
                  let minor = try? reader.u32(8), let patch = try? reader.u32(12) else { return nil }
            return [os, major, minor, patch]
        })
        let abi = abiTags.count == 1 ? abiTags.first : nil
        let platform: String?
        switch abi?.first {
        case 0: platform = "Linux"
        case 1: platform = "GNU Hurd"
        case 2: platform = "Solaris"
        case 3: platform = "FreeBSD"
        case 4: platform = "NetBSD"
        case 5: platform = "Syllable"
        case 6: platform = "NaCl"
        default: platform = nil
        }
        let version = abi.map { "\($0[1]).\($0[2]).\($0[3])" }
        return ELFProgramHeaderMetadataFacts(
            buildID: buildIDs.count == 1 ? buildIDs.first : nil,
            platformName: platform,
            minimumOSVersion: version,
            hasConflictingBuildIDs: buildIDs.count > 1,
            hasConflictingABITags: abiTags.count > 1
        )
    }

    static func stringLiterals(
        catalog: ELFProgramHeaderCatalog,
        bytes: Data,
        limits: StringScanLimits = .production
    ) throws -> [StringLiteralSummary] {
        var totalScanned: UInt64 = 0
        var totalOutput: UInt64 = 0
        var output: [StringLiteralSummary] = []
        for record in catalog.records where record.isLoadable && record.isReadable
            && !record.isWritable && !record.isExecutable && record.fileSize > 0 {
            let (nextScanned, scanOverflow) = totalScanned.addingReportingOverflow(record.fileSize)
            guard !scanOverflow, nextScanned <= limits.maximumTotalScannedBytes else {
                throw ELFProgramHeaderError.malformed("aggregate PT_LOAD string scan exceeds bound")
            }
            totalScanned = nextScanned
            guard record.fileOffset <= UInt64(bytes.count),
                  record.fileSize <= UInt64(bytes.count) - record.fileOffset,
                  let lower = Int(exactly: record.fileOffset),
                  let count = Int(exactly: record.fileSize) else {
                throw ELFProgramHeaderError.truncated("PT_LOAD string bytes")
            }
            let upper = lower + count
            // MS-25b: `lower..<upper` is file-relative; `bytes` may be a slice above index zero.
            let base = bytes.startIndex
            var runStart: Int?
            var runLength = 0
            var runTooLong = false
            for offset in lower..<upper {
                let byte = bytes[base + offset]
                if byte >= 0x20 && byte <= 0x7e {
                    if runStart == nil { runStart = offset }
                    runLength += 1
                    if runLength > limits.maximumStringBytes { runTooLong = true }
                } else if byte == 0, let start = runStart {
                    if runLength > 0, !runTooLong {
                        guard output.count < limits.maximumStringCount else {
                            throw ELFProgramHeaderError.malformed("string literal count exceeds bound")
                        }
                        let byteCost = UInt64(runLength + 1)
                        let (nextOutput, outputOverflow) = totalOutput.addingReportingOverflow(byteCost)
                        guard !outputOverflow, nextOutput <= limits.maximumTotalStringBytes else {
                            throw ELFProgramHeaderError.malformed("aggregate string literal bytes exceed bound")
                        }
                        totalOutput = nextOutput
                        let value = String(decoding: bytes[(base + start)..<(base + offset)], as: UTF8.self)
                        let relative = UInt64(start - lower)
                        let (address, addressOverflow) = record.virtualAddress.addingReportingOverflow(relative)
                        guard !addressOverflow else {
                            throw ELFProgramHeaderError.malformed("string literal address overflow")
                        }
                        output.append(StringLiteralSummary(
                            id: UUID(), value: value, address: address,
                            sourceSection: "PT_LOAD[\(record.index)]", byteLength: runLength + 1
                        ))
                    }
                    runStart = nil
                    runLength = 0
                    runTooLong = false
                } else {
                    runStart = nil
                    runLength = 0
                    runTooLong = false
                }
            }
        }
        return output
    }

    private static func architecture(machine: UInt16) -> (Int32, String) {
        switch machine {
        case 62: (MachOConstants.cpuTypeX86_64, "x86_64")
        case 183: (MachOConstants.cpuTypeARM64, "arm64")
        case 3: (0, "i386")
        case 40: (0, "arm")
        case 20: (0, "ppc")
        case 21: (0, "ppc64")
        case 8: (0, "mips")
        case 2: (0, "sparc")
        default: (0, "elf-machine-\(machine)")
        }
    }
}

private struct ELFProjectionEndianReader {
    let bytes: Data
    let bigEndian: Bool

    func u32(_ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= bytes.count, 4 <= bytes.count - offset else {
            throw ELFProgramHeaderError.truncated("GNU ABI note")
        }
        let start = bytes.startIndex
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(bytes[start + offset + index]) << UInt32(index * 8) }
        return bigEndian ? value.byteSwapped : value
    }
}
