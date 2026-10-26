import Foundation

enum MachOSliceArtifactValidationError: Error, Equatable, LocalizedError {
    case invalidSHA256
    case invalidByteCount
    case invalidSegmentName
    case invalidSegmentVirtualSpan(name: String)
    case invalidSegmentFileSpan(name: String)
    case segmentFileSpanOutsideSlice(name: String)

    var errorDescription: String? {
        switch self {
        case .invalidSHA256:
            "The selected-slice SHA-256 is not canonical lowercase hexadecimal."
        case .invalidByteCount:
            "The selected-slice byte count must be positive."
        case .invalidSegmentName:
            "A preferred Mach-O segment name is invalid."
        case .invalidSegmentVirtualSpan(let name):
            "Preferred Mach-O segment \(name) has an invalid virtual span."
        case .invalidSegmentFileSpan(let name):
            "Preferred Mach-O segment \(name) has an invalid file span."
        case .segmentFileSpanOutsideSlice(let name):
            "Preferred Mach-O segment \(name) extends outside the selected slice."
        }
    }
}

enum MachOSliceArchitectureVariant: String, Codable, Hashable, Sendable {
    case arm64
    case arm64e
    case x86_64
    case x86_64h
    case other

    private static let capabilityMask: UInt32 = 0xFF00_0000

    static func classify(rawCPUType: Int32, rawCPUSubtype: Int32) -> Self {
        let subtype = UInt32(bitPattern: rawCPUSubtype) & ~capabilityMask
        switch (rawCPUType, subtype) {
        case (MachOConstants.cpuTypeARM64, 0): return .arm64
        case (MachOConstants.cpuTypeARM64, 2): return .arm64e
        case (MachOConstants.cpuTypeX86_64, 3): return .x86_64
        case (MachOConstants.cpuTypeX86_64, 8): return .x86_64h
        default: return .other
        }
    }
}

struct MachOSliceArtifactIdentity: Codable, Hashable, Sendable {
    let uuid: UUID?
    let rawCPUType: Int32
    let rawCPUSubtype: Int32
    let architectureVariant: MachOSliceArchitectureVariant
    let selectedSliceSHA256: String
    let selectedSliceByteCount: UInt64

    private enum CodingKeys: String, CodingKey {
        case uuid, rawCPUType, rawCPUSubtype, architectureVariant
        case selectedSliceSHA256, selectedSliceByteCount
    }

    init(
        uuid: UUID?,
        rawCPUType: Int32,
        rawCPUSubtype: Int32,
        selectedSliceSHA256: String,
        selectedSliceByteCount: UInt64
    ) throws {
        guard selectedSliceByteCount > 0 else {
            throw MachOSliceArtifactValidationError.invalidByteCount
        }
        guard selectedSliceSHA256.utf8.count == 64,
              selectedSliceSHA256.unicodeScalars.allSatisfy({ scalar in
                  ("0"..."9").contains(Character(String(scalar)))
                      || ("a"..."f").contains(Character(String(scalar)))
              }) else {
            throw MachOSliceArtifactValidationError.invalidSHA256
        }
        self.uuid = uuid
        self.rawCPUType = rawCPUType
        self.rawCPUSubtype = rawCPUSubtype
        architectureVariant = .classify(
            rawCPUType: rawCPUType,
            rawCPUSubtype: rawCPUSubtype
        )
        self.selectedSliceSHA256 = selectedSliceSHA256
        self.selectedSliceByteCount = selectedSliceByteCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawCPUType = try container.decode(Int32.self, forKey: .rawCPUType)
        let rawCPUSubtype = try container.decode(Int32.self, forKey: .rawCPUSubtype)
        let encodedVariant = try container.decode(
            MachOSliceArchitectureVariant.self,
            forKey: .architectureVariant
        )
        try self.init(
            uuid: try container.decodeIfPresent(UUID.self, forKey: .uuid),
            rawCPUType: rawCPUType,
            rawCPUSubtype: rawCPUSubtype,
            selectedSliceSHA256: try container.decode(String.self, forKey: .selectedSliceSHA256),
            selectedSliceByteCount: try container.decode(UInt64.self, forKey: .selectedSliceByteCount)
        )
        guard architectureVariant == encodedVariant else {
            throw DecodingError.dataCorruptedError(
                forKey: .architectureVariant,
                in: container,
                debugDescription: "Architecture variant contradicts the raw Mach-O CPU evidence."
            )
        }
    }
}

struct MachOPreferredSegmentLayout: Codable, Hashable, Sendable {
    struct Record: Codable, Hashable, Sendable {
        let name: String
        let preferredVMStart: UInt64
        let preferredVMSize: UInt64
        let sliceRelativeFileOffset: UInt64
        let fileSize: UInt64
        let initialProtections: Int32

        init(
            name: String,
            preferredVMStart: UInt64,
            preferredVMSize: UInt64,
            sliceRelativeFileOffset: UInt64,
            fileSize: UInt64,
            initialProtections: Int32
        ) {
            self.name = name
            self.preferredVMStart = preferredVMStart
            self.preferredVMSize = preferredVMSize
            self.sliceRelativeFileOffset = sliceRelativeFileOffset
            self.fileSize = fileSize
            self.initialProtections = initialProtections
        }
    }

    let records: [Record]

    private enum CodingKeys: String, CodingKey {
        case records
    }

    init(records: [Record], selectedSliceByteCount: UInt64) throws {
        try Self.validate(records: records, selectedSliceByteCount: selectedSliceByteCount)
        self.records = records
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let records = try container.decode([Record].self, forKey: .records)
        try Self.validate(records: records, selectedSliceByteCount: nil)
        self.records = records
    }

    private static func validate(
        records: [Record],
        selectedSliceByteCount: UInt64?
    ) throws {
        for record in records {
            let nameBytes = record.name.utf8
            guard (1...16).contains(nameBytes.count),
                  !record.name.unicodeScalars.contains(where: {
                      $0.value == 0 || CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw MachOSliceArtifactValidationError.invalidSegmentName
            }
            // vmsize 0 is legal: an unmapped segment that still carries file bytes (Go's
            // __DWARF). Only a span that wraps the address space is malformed.
            guard !record.preferredVMStart.addingReportingOverflow(record.preferredVMSize).overflow else {
                throw MachOSliceArtifactValidationError.invalidSegmentVirtualSpan(name: record.name)
            }
            let fileEnd = record.sliceRelativeFileOffset.addingReportingOverflow(record.fileSize)
            guard !fileEnd.overflow else {
                throw MachOSliceArtifactValidationError.invalidSegmentFileSpan(name: record.name)
            }
            guard selectedSliceByteCount.map({ fileEnd.partialValue <= $0 }) ?? true else {
                throw MachOSliceArtifactValidationError.segmentFileSpanOutsideSlice(name: record.name)
            }
        }
    }
}

enum MachOSliceArtifactIntegrityState: Codable, Hashable, Sendable {
    case verified
    case unavailable
    case contradictoryEvidence(diagnostic: String)
}

struct MachOSliceArtifactReconstruction: Hashable, Sendable {
    let identity: MachOSliceArtifactIdentity
    let preferredSegmentLayout: MachOPreferredSegmentLayout
}
