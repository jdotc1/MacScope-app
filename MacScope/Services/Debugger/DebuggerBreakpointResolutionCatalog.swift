import Foundation

private func breakpointExactUTF8Equal(_ lhs: String, _ rhs: String) -> Bool {
    Data(lhs.utf8) == Data(rhs.utf8)
}

private func breakpointExactOptionalUTF8Equal(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none): true
    case let (.some(lhs), .some(rhs)): breakpointExactUTF8Equal(lhs, rhs)
    default: false
    }
}

private func breakpointHashOptionalUTF8(_ value: String?, into hasher: inout Hasher) {
    switch value {
    case .none: hasher.combine(0)
    case .some(let value): hasher.combine(1); hasher.combine(Data(value.utf8))
    }
}

struct DebuggerBreakpointResolutionCatalogRevision: RawRepresentable, Hashable, Sendable, Comparable {
    let rawValue: UInt64

    func incremented() -> Self? {
        let next = rawValue.addingReportingOverflow(1)
        return next.overflow ? nil : Self(rawValue: next.partialValue)
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct DebuggerBreakpointResolutionCatalogCoordinate: Hashable, Sendable {
    let workspaceID: UUID
    let revision: DebuggerBreakpointResolutionCatalogRevision
    let workspaceArtifactCatalogRevision: DebuggerWorkspaceArtifactCatalogRevision
}

enum DebuggerBreakpointStaticAddressKind: Hashable, Sendable {
    case decodedExecutableInstruction
    case data
}

struct DebuggerBreakpointStaticAddressEvidence: Hashable, Sendable {
    let preferredVA: UInt64
    let segmentName: String
    let kind: DebuggerBreakpointStaticAddressKind
}

extension DebuggerBreakpointStaticAddressEvidence {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.preferredVA == rhs.preferredVA
            && breakpointExactUTF8Equal(lhs.segmentName, rhs.segmentName)
            && lhs.kind == rhs.kind
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(preferredVA); hasher.combine(Data(segmentName.utf8)); hasher.combine(kind)
    }
}

struct DebuggerBreakpointResolutionSegment: Hashable, Sendable {
    let name: String
    let preferredStart: UInt64
    let byteCount: UInt64
    let isExecutable: Bool

    init?(name: String, preferredStart: UInt64, byteCount: UInt64, isExecutable: Bool) {
        guard !name.isEmpty,
              name.utf8.count <= 16,
              byteCount > 0,
              !preferredStart.addingReportingOverflow(byteCount - 1).overflow else {
            return nil
        }
        self.name = name
        self.preferredStart = preferredStart
        self.byteCount = byteCount
        self.isExecutable = isExecutable
    }

    func contains(_ address: UInt64) -> Bool {
        address >= preferredStart && address - preferredStart < byteCount
    }
}

extension DebuggerBreakpointResolutionSegment {
    static func == (lhs: Self, rhs: Self) -> Bool {
        breakpointExactUTF8Equal(lhs.name, rhs.name)
            && lhs.preferredStart == rhs.preferredStart
            && lhs.byteCount == rhs.byteCount
            && lhs.isExecutable == rhs.isExecutable
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(Data(name.utf8)); hasher.combine(preferredStart)
        hasher.combine(byteCount); hasher.combine(isExecutable)
    }
}

struct DebuggerBreakpointFunctionEvidence: Hashable, Sendable {
    let entryPreferredVA: UInt64
    let rawLinkageName: String?
}

extension DebuggerBreakpointFunctionEvidence {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entryPreferredVA == rhs.entryPreferredVA
            && breakpointExactOptionalUTF8Equal(lhs.rawLinkageName, rhs.rawLinkageName)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(entryPreferredVA)
        breakpointHashOptionalUTF8(rawLinkageName, into: &hasher)
    }
}

struct DebuggerBreakpointRawSymbolEvidence: Hashable, Sendable {
    let exactRawLinkageName: String
    let kind: String?
    let libraryName: String?
    let preferredVA: UInt64
}

extension DebuggerBreakpointRawSymbolEvidence {
    static func == (lhs: Self, rhs: Self) -> Bool {
        breakpointExactUTF8Equal(lhs.exactRawLinkageName, rhs.exactRawLinkageName)
            && breakpointExactOptionalUTF8Equal(lhs.kind, rhs.kind)
            && breakpointExactOptionalUTF8Equal(lhs.libraryName, rhs.libraryName)
            && lhs.preferredVA == rhs.preferredVA
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(Data(exactRawLinkageName.utf8))
        breakpointHashOptionalUTF8(kind, into: &hasher)
        breakpointHashOptionalUTF8(libraryName, into: &hasher)
        hasher.combine(preferredVA)
    }
}

struct DebuggerBreakpointSourceEvidence: Hashable, Sendable {
    let file: DebuggerCanonicalSourceFileIdentity
    let line: UInt32
    let column: UInt32
    let preferredVA: UInt64
    let isEndSequence: Bool
}

/// Immutable, owner-qualified evidence used by the pure logical-breakpoint resolver. Display names,
/// focus, current-machine source remaps, and runtime/load-instance state are deliberately absent.
struct DebuggerBreakpointResolutionOwnerIndex: Hashable, Sendable {
    let coordinate: DebuggerWorkspaceArtifactCoordinate
    let revision: UInt64
    let segments: [DebuggerBreakpointResolutionSegment]
    let staticAddresses: [DebuggerBreakpointStaticAddressEvidence]
    let functions: [DebuggerBreakpointFunctionEvidence]
    let hasCanonicalRawSymbolAuthority: Bool
    let rawSymbols: [DebuggerBreakpointRawSymbolEvidence]
    let hasExactSourceAuthority: Bool
    let sourceRows: [DebuggerBreakpointSourceEvidence]

    init(
        coordinate: DebuggerWorkspaceArtifactCoordinate,
        revision: UInt64,
        segments: [DebuggerBreakpointResolutionSegment],
        staticAddresses: [DebuggerBreakpointStaticAddressEvidence],
        functions: [DebuggerBreakpointFunctionEvidence],
        hasCanonicalRawSymbolAuthority: Bool,
        rawSymbols: [DebuggerBreakpointRawSymbolEvidence],
        hasExactSourceAuthority: Bool,
        sourceRows: [DebuggerBreakpointSourceEvidence]
    ) {
        self.coordinate = coordinate
        self.revision = revision
        self.segments = segments.sorted(by: Self.segmentPrecedes)
        self.staticAddresses = staticAddresses.sorted(by: Self.addressPrecedes)
        self.functions = functions.sorted(by: Self.functionPrecedes)
        self.hasCanonicalRawSymbolAuthority = hasCanonicalRawSymbolAuthority
        self.rawSymbols = rawSymbols.sorted(by: Self.symbolPrecedes)
        self.hasExactSourceAuthority = hasExactSourceAuthority
        self.sourceRows = sourceRows.sorted(by: Self.sourcePrecedes)
    }

    private static func segmentPrecedes(
        _ lhs: DebuggerBreakpointResolutionSegment,
        _ rhs: DebuggerBreakpointResolutionSegment
    ) -> Bool {
        if lhs.preferredStart != rhs.preferredStart { return lhs.preferredStart < rhs.preferredStart }
        if !breakpointExactUTF8Equal(lhs.name, rhs.name) {
            return utf8Precedes(lhs.name, rhs.name)
        }
        if lhs.byteCount != rhs.byteCount { return lhs.byteCount < rhs.byteCount }
        return lhs.isExecutable && !rhs.isExecutable
    }

    private static func addressPrecedes(
        _ lhs: DebuggerBreakpointStaticAddressEvidence,
        _ rhs: DebuggerBreakpointStaticAddressEvidence
    ) -> Bool {
        if lhs.preferredVA != rhs.preferredVA { return lhs.preferredVA < rhs.preferredVA }
        if !breakpointExactUTF8Equal(lhs.segmentName, rhs.segmentName) {
            return utf8Precedes(lhs.segmentName, rhs.segmentName)
        }
        return kindRank(lhs.kind) < kindRank(rhs.kind)
    }

    private static func functionPrecedes(
        _ lhs: DebuggerBreakpointFunctionEvidence,
        _ rhs: DebuggerBreakpointFunctionEvidence
    ) -> Bool {
        if lhs.entryPreferredVA != rhs.entryPreferredVA {
            return lhs.entryPreferredVA < rhs.entryPreferredVA
        }
        let left = optionalUTF8Bytes(lhs.rawLinkageName)
        let right = optionalUTF8Bytes(rhs.rawLinkageName)
        return left != right && left.lexicographicallyPrecedes(right)
    }

    private static func symbolPrecedes(
        _ lhs: DebuggerBreakpointRawSymbolEvidence,
        _ rhs: DebuggerBreakpointRawSymbolEvidence
    ) -> Bool {
        let leftName = Data(lhs.exactRawLinkageName.utf8)
        let rightName = Data(rhs.exactRawLinkageName.utf8)
        if leftName != rightName {
            return leftName.lexicographicallyPrecedes(rightName)
        }
        if lhs.preferredVA != rhs.preferredVA { return lhs.preferredVA < rhs.preferredVA }
        if optionalUTF8Bytes(lhs.kind) != optionalUTF8Bytes(rhs.kind) {
            return optionalUTF8Precedes(lhs.kind, rhs.kind)
        }
        return optionalUTF8Precedes(lhs.libraryName, rhs.libraryName)
    }

    private static func sourcePrecedes(
        _ lhs: DebuggerBreakpointSourceEvidence,
        _ rhs: DebuggerBreakpointSourceEvidence
    ) -> Bool {
        let leftFile = sourceFileBytes(lhs.file)
        let rightFile = sourceFileBytes(rhs.file)
        if leftFile != rightFile { return leftFile.lexicographicallyPrecedes(rightFile) }
        if lhs.line != rhs.line { return lhs.line < rhs.line }
        if lhs.column != rhs.column { return lhs.column < rhs.column }
        if lhs.preferredVA != rhs.preferredVA { return lhs.preferredVA < rhs.preferredVA }
        return !lhs.isEndSequence && rhs.isEndSequence
    }

    private static func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        Data(lhs.utf8).lexicographicallyPrecedes(Data(rhs.utf8))
    }

    private static func optionalUTF8Bytes(_ value: String?) -> Data {
        guard let value else { return Data([0]) }
        var bytes = Data([1])
        bytes.append(contentsOf: value.utf8)
        return bytes
    }

    private static func optionalUTF8Precedes(_ lhs: String?, _ rhs: String?) -> Bool {
        optionalUTF8Bytes(lhs).lexicographicallyPrecedes(optionalUTF8Bytes(rhs))
    }

    private static func kindRank(_ kind: DebuggerBreakpointStaticAddressKind) -> UInt8 {
        switch kind {
        case .decodedExecutableInstruction: 0
        case .data: 1
        }
    }

    private static func sourceFileBytes(_ file: DebuggerCanonicalSourceFileIdentity) -> Data {
        var value = Data()
        func append(_ data: Data) {
            var count = UInt64(data.count).bigEndian
            value.append(Data(bytes: &count, count: MemoryLayout<UInt64>.size))
            value.append(data)
        }
        withUnsafeBytes(of: file.debugArtifactUUID.uuid) { append(Data($0)) }
        append(Data(file.debugArtifactMachOSHA256.utf8))
        withUnsafeBytes(of: file.debugArtifactMachOByteCount.bigEndian) { append(Data($0)) }
        withUnsafeBytes(of: file.lineProgramUnitOffset.bigEndian) { append(Data($0)) }
        withUnsafeBytes(of: file.fileTableIndex.bigEndian) { append(Data($0)) }
        switch file.tablePath {
        case .absoluteUTF8(let path): append(Data([0])); append(Data(path.utf8))
        case .compilationDirectoryRelativeUTF8(let path):
            append(Data([1])); append(Data(path.utf8))
        }
        return value
    }
}

struct DebuggerBreakpointResolutionCatalog: Hashable, Sendable {
    let coordinate: DebuggerBreakpointResolutionCatalogCoordinate
    let owners: [DebuggerBreakpointResolutionOwnerIndex]

    init(
        coordinate: DebuggerBreakpointResolutionCatalogCoordinate,
        owners: [DebuggerBreakpointResolutionOwnerIndex]
    ) {
        self.coordinate = coordinate
        self.owners = owners.sorted(by: Self.ownerPrecedes)
    }

    var isStructurallyValid: Bool {
        guard coordinate.revision.rawValue > 0,
              coordinate.workspaceArtifactCatalogRevision.rawValue > 0,
              owners.count <= 4_096 else {
            return false
        }
        var coordinates = Set<DebuggerWorkspaceArtifactCoordinate>()
        for owner in owners {
            guard owner.revision > 0,
                  owner.coordinate.slot.rawValue >= 0,
                  coordinates.insert(owner.coordinate).inserted,
                  owner.segments.count <= 128,
                  owner.staticAddresses.count <= 1_000_000,
                  owner.functions.count <= 1_000_000,
                  owner.rawSymbols.count <= 1_000_000,
                  owner.sourceRows.count <= 1_000_000,
                  owner.segments.allSatisfy({ segment in
                      !segment.name.isEmpty && segment.byteCount > 0
                  }) else {
                return false
            }
        }
        return true
    }

    private static func ownerPrecedes(
        _ lhs: DebuggerBreakpointResolutionOwnerIndex,
        _ rhs: DebuggerBreakpointResolutionOwnerIndex
    ) -> Bool {
        if lhs.coordinate.slot != rhs.coordinate.slot {
            return lhs.coordinate.slot < rhs.coordinate.slot
        }
        if lhs.coordinate.binaryID != rhs.coordinate.binaryID {
            let left = withUnsafeBytes(of: lhs.coordinate.binaryID.uuid) { Array($0) }
            let right = withUnsafeBytes(of: rhs.coordinate.binaryID.uuid) { Array($0) }
            return left.lexicographicallyPrecedes(right)
        }
        return lhs.coordinate.ownerRevision < rhs.coordinate.ownerRevision
    }
}
