import Foundation

struct DebuggerWorkspaceArtifactCatalogRevision: Hashable, Sendable, Comparable {
    let rawValue: UInt64

    func incremented() -> Self? {
        let (next, overflowed) = rawValue.addingReportingOverflow(1)
        return overflowed ? nil : Self(rawValue: next)
    }

    static func < (
        lhs: DebuggerWorkspaceArtifactCatalogRevision,
        rhs: DebuggerWorkspaceArtifactCatalogRevision
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct DebuggerWorkspaceArtifactOwnerRevision: Hashable, Sendable, Comparable {
    let rawValue: UInt64

    func incremented() -> Self? {
        let (next, overflowed) = rawValue.addingReportingOverflow(1)
        return overflowed ? nil : Self(rawValue: next)
    }

    static func < (
        lhs: DebuggerWorkspaceArtifactOwnerRevision,
        rhs: DebuggerWorkspaceArtifactOwnerRevision
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct DebuggerWorkspaceArtifactCoordinate: Hashable, Sendable {
    let binaryID: UUID
    let slot: ImageSlot
    let artifactIdentity: MachOSliceArtifactIdentity
    let ownerRevision: DebuggerWorkspaceArtifactOwnerRevision
}

struct DebuggerWorkspaceArtifactCatalogEntry: Hashable, Sendable {
    let binaryID: UUID
    let slot: ImageSlot
    let ownerRevision: DebuggerWorkspaceArtifactOwnerRevision
    let artifactIdentity: MachOSliceArtifactIdentity?
    let preferredSegmentLayout: MachOPreferredSegmentLayout?
    let artifactIntegrityState: MachOSliceArtifactIntegrityState
    let sourcePathHint: String?
    let executablePathHint: String?

    init(
        binaryID: UUID,
        slot: ImageSlot,
        ownerRevision: DebuggerWorkspaceArtifactOwnerRevision,
        artifactIdentity: MachOSliceArtifactIdentity?,
        preferredSegmentLayout: MachOPreferredSegmentLayout?,
        artifactIntegrityState: MachOSliceArtifactIntegrityState,
        sourcePathHint: String?,
        executablePathHint: String?
    ) {
        self.binaryID = binaryID
        self.slot = slot
        self.ownerRevision = ownerRevision
        self.artifactIdentity = artifactIdentity
        self.preferredSegmentLayout = preferredSegmentLayout
        self.artifactIntegrityState = artifactIntegrityState
        self.sourcePathHint = Self.normalizedPathHint(sourcePathHint)
        self.executablePathHint = Self.normalizedPathHint(executablePathHint)
    }

    private static func normalizedPathHint(_ path: String?) -> String? {
        guard let path,
              path.hasPrefix("/"),
              path.utf8.count <= 4_096,
              path.unicodeScalars.allSatisfy({ scalar in
                  scalar.properties.generalCategory != .control
              }) else {
            return nil
        }
        return (path as NSString).standardizingPath
    }
}

struct DebuggerWorkspaceArtifactCatalog: Hashable, Sendable {
    let revision: DebuggerWorkspaceArtifactCatalogRevision
    let artifacts: [DebuggerWorkspaceArtifactCatalogEntry]

    init(
        revision: DebuggerWorkspaceArtifactCatalogRevision,
        artifacts: [DebuggerWorkspaceArtifactCatalogEntry]
    ) {
        self.revision = revision
        self.artifacts = artifacts.sorted(by: Self.entryPrecedes)
    }

    private static func entryPrecedes(
        _ lhs: DebuggerWorkspaceArtifactCatalogEntry,
        _ rhs: DebuggerWorkspaceArtifactCatalogEntry
    ) -> Bool {
        if lhs.slot != rhs.slot { return lhs.slot < rhs.slot }
        return lhs.binaryID.uuidString < rhs.binaryID.uuidString
    }
}

/// One inventory-qualified range whose static span was proven to be wholly contained in exactly
/// one same-name preferred Mach-O segment by `DebuggerWorkspaceArtifactCorrelator`.
struct DebuggerRuntimeMappedRange: Hashable, Sendable {
    let moduleInstanceID: DebuggerRuntimeModuleInstanceID
    let sourceSectionOrdinal: UInt32
    let segmentName: String
    let staticStart: UInt64
    let runtimeStart: UInt64
    let byteCount: UInt64
    let permissions: UInt8

    init?(
        moduleInstanceID: DebuggerRuntimeModuleInstanceID,
        sourceSectionOrdinal: UInt32,
        segmentName: String,
        staticStart: UInt64,
        runtimeStart: UInt64,
        byteCount: UInt64,
        permissions: UInt8
    ) {
        guard !segmentName.isEmpty,
              segmentName.utf8.count <= 16,
              permissions <= 7,
              byteCount > 0,
              !Self.lastByte(start: staticStart, byteCount: byteCount).overflow,
              !Self.lastByte(start: runtimeStart, byteCount: byteCount).overflow else {
            return nil
        }
        self.moduleInstanceID = moduleInstanceID
        self.sourceSectionOrdinal = sourceSectionOrdinal
        self.segmentName = segmentName
        self.staticStart = staticStart
        self.runtimeStart = runtimeStart
        self.byteCount = byteCount
        self.permissions = permissions
    }

    private static func lastByte(
        start: UInt64,
        byteCount: UInt64
    ) -> (partialValue: UInt64, overflow: Bool) {
        let displacement = byteCount - 1
        return start.addingReportingOverflow(displacement)
    }
}

struct DebuggerRuntimeMappingProjectionKey: Hashable, Sendable {
    let stopCoordinate: DebuggerStopCoordinate
    let observedPID: Int32
    let authorityRevision: DebuggerRuntimeModuleAuthorityRevision
    let inventoryRevision: DebuggerRuntimeModuleInventoryRevision
    let workspaceCatalogRevision: DebuggerWorkspaceArtifactCatalogRevision
}

struct DebuggerCorrelatedRuntimeModule: Hashable, Sendable {
    let instanceID: DebuggerRuntimeModuleInstanceID
    let coordinate: DebuggerWorkspaceArtifactCoordinate
    let mappedRanges: [DebuggerRuntimeMappedRange]
}

struct DebuggerRuntimeMappingProjection: Hashable, Sendable {
    let key: DebuggerRuntimeMappingProjectionKey
    let modules: [DebuggerCorrelatedRuntimeModule]
}

enum DebuggerWorkspaceArtifactUnresolvedReason: Hashable, Sendable {
    case missingRuntimeUUID
    case unsupportedRuntimeArchitecture
    case noMappedRanges
    case noCompatibleWorkspaceArtifact
}

enum DebuggerWorkspaceArtifactCorrelation: Hashable, Sendable {
    case matched(
        coordinate: DebuggerWorkspaceArtifactCoordinate,
        mappedRanges: [DebuggerRuntimeMappedRange]
    )
    case unresolved(reason: DebuggerWorkspaceArtifactUnresolvedReason)
    case ambiguous(candidateIDs: [UUID])
}

struct DebuggerWorkspaceArtifactCorrelator: Sendable {
    func correlation(
        for module: DebuggerRuntimeModuleInstance,
        catalog: DebuggerWorkspaceArtifactCatalog
    ) -> DebuggerWorkspaceArtifactCorrelation {
        guard let runtimeUUID = module.observation.uuid,
              runtimeUUID != Self.zeroUUID else {
            return .unresolved(reason: .missingRuntimeUUID)
        }
        guard let runtimeVariant = Self.supportedArchitectureVariant(
            for: module.observation.normalizedArchitectureTriple
        ) else {
            return .unresolved(reason: .unsupportedRuntimeArchitecture)
        }
        guard !module.observation.mappedRanges.isEmpty else {
            return .unresolved(reason: .noMappedRanges)
        }

        let candidates = catalog.artifacts.compactMap { entry -> Candidate? in
            guard entry.artifactIntegrityState == .verified,
                  let identity = entry.artifactIdentity,
                  let layout = entry.preferredSegmentLayout,
                  identity.uuid == runtimeUUID,
                  identity.rawCPUType == MachOConstants.cpuTypeARM64,
                  identity.architectureVariant == runtimeVariant,
                  let mappedRanges = validatedRanges(
                      module: module,
                      layout: layout
                  ) else {
                return nil
            }
            return Candidate(
                coordinate: .init(
                    binaryID: entry.binaryID,
                    slot: entry.slot,
                    artifactIdentity: identity,
                    ownerRevision: entry.ownerRevision
                ),
                mappedRanges: mappedRanges
            )
        }

        switch candidates.count {
        case 0:
            return .unresolved(reason: .noCompatibleWorkspaceArtifact)
        case 1:
            return .matched(
                coordinate: candidates[0].coordinate,
                mappedRanges: candidates[0].mappedRanges
            )
        default:
            return .ambiguous(candidateIDs: candidates.map(\.coordinate.binaryID))
        }
    }

    func correlate(
        inventory: DebuggerRuntimeModuleInventory,
        authorityRevision: DebuggerRuntimeModuleAuthorityRevision,
        catalog: DebuggerWorkspaceArtifactCatalog
    ) -> DebuggerRuntimeMappingProjection {
        let key = DebuggerRuntimeMappingProjectionKey(
            stopCoordinate: inventory.stop,
            observedPID: inventory.processID,
            authorityRevision: authorityRevision,
            inventoryRevision: inventory.revision,
            workspaceCatalogRevision: catalog.revision
        )
        let modules = inventory.modules.compactMap { module -> DebuggerCorrelatedRuntimeModule? in
            guard module.id.processID == inventory.processID,
                  module.id.stop == inventory.stop,
                  module.id.inventoryRevision == inventory.revision,
                  module.observation.processID == inventory.processID,
                  module.observation.observedStopID == inventory.observedStopID else {
                return nil
            }
            guard case let .matched(coordinate, mappedRanges) = correlation(
                for: module,
                catalog: catalog
            ) else {
                return nil
            }
            return DebuggerCorrelatedRuntimeModule(
                instanceID: module.id,
                coordinate: coordinate,
                mappedRanges: mappedRanges
            )
        }
        return DebuggerRuntimeMappingProjection(key: key, modules: modules)
    }

    private func validatedRanges(
        module: DebuggerRuntimeModuleInstance,
        layout: MachOPreferredSegmentLayout
    ) -> [DebuggerRuntimeMappedRange]? {
        var accepted: [DebuggerRuntimeMappedRange] = []
        accepted.reserveCapacity(module.observation.mappedRanges.count)
        for observed in module.observation.mappedRanges {
            let containingSegments = layout.records.filter { segment in
                segment.name == observed.sectionName
                    && Self.contains(
                        start: observed.staticStart,
                        byteCount: observed.byteCount,
                        in: segment
                    )
            }
            guard containingSegments.count == 1,
                  let mapped = DebuggerRuntimeMappedRange(
                      moduleInstanceID: module.id,
                      sourceSectionOrdinal: observed.sectionOrdinal,
                      segmentName: observed.sectionName,
                      staticStart: observed.staticStart,
                      runtimeStart: observed.runtimeStart,
                      byteCount: observed.byteCount,
                      permissions: observed.permissions
                  ) else {
                return nil
            }
            accepted.append(mapped)
        }
        return accepted
    }

    private static func contains(
        start: UInt64,
        byteCount: UInt64,
        in segment: MachOPreferredSegmentLayout.Record
    ) -> Bool {
        guard start >= segment.preferredVMStart else { return false }
        let offset = start - segment.preferredVMStart
        guard offset < segment.preferredVMSize else { return false }
        return byteCount <= segment.preferredVMSize - offset
    }

    private static func supportedArchitectureVariant(
        for normalizedTriple: String
    ) -> MachOSliceArchitectureVariant? {
        let components = normalizedTriple.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty }),
              components[1] == "apple",
              isSupportedMacOSComponent(components[2]) else {
            return nil
        }
        switch components[0] {
        case "arm64": return .arm64
        case "arm64e": return .arm64e
        default: return nil
        }
    }

    private static func isSupportedMacOSComponent(_ component: Substring) -> Bool {
        let prefix = "macosx"
        guard component.hasPrefix(prefix) else { return false }
        let version = component.dropFirst(prefix.count)
        if version.isEmpty { return true }
        let numericComponents = version.split(separator: ".", omittingEmptySubsequences: false)
        return !numericComponents.isEmpty && numericComponents.allSatisfy { part in
            !part.isEmpty && part.utf8.allSatisfy { (0x30...0x39).contains($0) }
        }
    }

    private struct Candidate {
        let coordinate: DebuggerWorkspaceArtifactCoordinate
        let mappedRanges: [DebuggerRuntimeMappedRange]
    }

    private static let zeroUUID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!
}
