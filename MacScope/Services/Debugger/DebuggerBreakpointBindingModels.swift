import CryptoKit
import Foundation

struct DebuggerBreakpointDigest: Hashable, Sendable {
    let bytes: Data

    init?(_ bytes: Data) {
        guard bytes.count == 32 else { return nil }
        self.bytes = bytes
    }
}

/// Deterministic identity for one exact static site of one immutable logical-breakpoint revision.
/// Runtime/load-instance identity is deliberately absent.
struct DebuggerLogicalBreakpointSiteID: Hashable, Sendable {
    let logicalID: DebuggerLogicalBreakpointID
    let specificationRevision: DebuggerLogicalBreakpointRevision
    let imageAddress: ImageAddress
    let staticOrdinal: UInt32
}

enum DebuggerLogicalBreakpointSiteProvenance: Hashable, Sendable {
    case preferredAddress
    case imageOffset(segmentName: String, segmentPreferredStart: UInt64, offset: UInt64)
    case function(entryPreferredVA: UInt64, rawLinkageName: String?)
    case symbol(
        exactRawLinkageName: String,
        kind: String?,
        libraryName: String?,
        staticOrdinal: UInt32
    )
    case source(
        file: DebuggerCanonicalSourceFileIdentity,
        line: UInt32,
        column: UInt32?,
        staticOrdinal: UInt32
    )
}

extension DebuggerLogicalBreakpointSiteProvenance {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.preferredAddress, .preferredAddress):
            true
        case let (.imageOffset(ln, ls, lo), .imageOffset(rn, rs, ro)):
            Data(ln.utf8) == Data(rn.utf8) && ls == rs && lo == ro
        case let (.function(la, ln), .function(ra, rn)):
            la == ra && exactOptionalUTF8Equal(ln, rn)
        case let (.symbol(ln, lk, ll, lo), .symbol(rn, rk, rl, ro)):
            Data(ln.utf8) == Data(rn.utf8)
                && exactOptionalUTF8Equal(lk, rk)
                && exactOptionalUTF8Equal(ll, rl)
                && lo == ro
        case let (.source(lf, ll, lc, lo), .source(rf, rl, rc, ro)):
            lf == rf && ll == rl && lc == rc && lo == ro
        default:
            false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .preferredAddress:
            hasher.combine(0)
        case .imageOffset(let name, let start, let offset):
            hasher.combine(1); hasher.combine(Data(name.utf8)); hasher.combine(start); hasher.combine(offset)
        case .function(let address, let name):
            hasher.combine(2); hasher.combine(address); hashOptionalUTF8(name, into: &hasher)
        case .symbol(let name, let kind, let library, let ordinal):
            hasher.combine(3); hasher.combine(Data(name.utf8))
            hashOptionalUTF8(kind, into: &hasher); hashOptionalUTF8(library, into: &hasher)
            hasher.combine(ordinal)
        case .source(let file, let line, let column, let ordinal):
            hasher.combine(4); hasher.combine(file); hasher.combine(line)
            hasher.combine(column); hasher.combine(ordinal)
        }
    }

    private static func exactOptionalUTF8Equal(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): true
        case let (.some(lhs), .some(rhs)): Data(lhs.utf8) == Data(rhs.utf8)
        default: false
        }
    }

    private func hashOptionalUTF8(_ value: String?, into hasher: inout Hasher) {
        switch value {
        case .none: hasher.combine(0)
        case .some(let value): hasher.combine(1); hasher.combine(Data(value.utf8))
        }
    }
}

struct DebuggerResolvedLogicalBreakpointSite: Hashable, Sendable {
    let logicalID: DebuggerLogicalBreakpointID
    let specificationRevision: DebuggerLogicalBreakpointRevision
    let siteID: DebuggerLogicalBreakpointSiteID
    let owner: DebuggerWorkspaceImageOwnerSeal
    let coordinate: DebuggerWorkspaceArtifactCoordinate
    let imageAddress: ImageAddress
    let provenance: DebuggerLogicalBreakpointSiteProvenance

    init?(
        logicalID: DebuggerLogicalBreakpointID,
        specificationRevision: DebuggerLogicalBreakpointRevision,
        siteID: DebuggerLogicalBreakpointSiteID,
        owner: DebuggerWorkspaceImageOwnerSeal,
        coordinate: DebuggerWorkspaceArtifactCoordinate,
        imageAddress: ImageAddress,
        provenance: DebuggerLogicalBreakpointSiteProvenance
    ) {
        guard siteID.logicalID == logicalID,
              siteID.specificationRevision == specificationRevision,
              siteID.imageAddress == imageAddress,
              owner.slot == coordinate.slot,
              owner.binaryID == coordinate.binaryID,
              owner.artifactIdentity.map({ $0 == coordinate.artifactIdentity }) ?? true else {
            return nil
        }
        self.logicalID = logicalID
        self.specificationRevision = specificationRevision
        self.siteID = siteID
        self.owner = owner
        self.coordinate = coordinate
        self.imageAddress = imageAddress
        self.provenance = provenance
    }
}

struct DebuggerTransientBreakpointBindingID: Hashable, Sendable {
    let logicalID: DebuggerLogicalBreakpointID
    let siteID: DebuggerLogicalBreakpointSiteID
    let moduleInstanceID: DebuggerRuntimeModuleInstanceID

    init?(
        logicalID: DebuggerLogicalBreakpointID,
        siteID: DebuggerLogicalBreakpointSiteID,
        moduleInstanceID: DebuggerRuntimeModuleInstanceID
    ) {
        guard logicalID == siteID.logicalID,
              moduleInstanceID.processID > 0,
              moduleInstanceID.inventoryRevision.rawValue > 0 else {
            return nil
        }
        self.logicalID = logicalID
        self.siteID = siteID
        self.moduleInstanceID = moduleInstanceID
    }
}

/// One exact desired physical location. The backend transaction layer may serialize this value,
/// but it is never part of workspace persistence.
struct DebuggerDesiredBreakpointBinding: Hashable, Sendable {
    let id: DebuggerTransientBreakpointBindingID
    let site: DebuggerResolvedLogicalBreakpointSite
    let mappingKey: DebuggerRuntimeMappingProjectionKey
    let runtimeAddress: UInt64
    let policyActionDigest: DebuggerBreakpointDigest
    let issuanceDigest: DebuggerBreakpointDigest

    init?(
        id: DebuggerTransientBreakpointBindingID,
        site: DebuggerResolvedLogicalBreakpointSite,
        mappingKey: DebuggerRuntimeMappingProjectionKey,
        runtimeAddress: UInt64,
        policyActionDigest: DebuggerBreakpointDigest,
        issuanceDigest: DebuggerBreakpointDigest
    ) {
        guard id.logicalID == site.logicalID,
              id.siteID == site.siteID,
              id.moduleInstanceID.processID == mappingKey.observedPID,
              id.moduleInstanceID.stop == mappingKey.stopCoordinate,
              id.moduleInstanceID.inventoryRevision == mappingKey.inventoryRevision else {
            return nil
        }
        self.id = id
        self.site = site
        self.mappingKey = mappingKey
        self.runtimeAddress = runtimeAddress
        self.policyActionDigest = policyActionDigest
        self.issuanceDigest = issuanceDigest
    }
}

struct DebuggerBreakpointBindingTransactionID: RawRepresentable, Hashable, Sendable {
    let rawValue: UUID
}

struct DebuggerBreakpointBindingAuthorityRevision: RawRepresentable, Hashable, Sendable, Comparable {
    let rawValue: UInt64

    static let initial = Self(rawValue: 0)

    func incremented() -> Self? {
        let next = rawValue.addingReportingOverflow(1)
        return next.overflow ? nil : Self(rawValue: next.partialValue)
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct DebuggerBreakpointBackendInventoryRevision: RawRepresentable, Hashable, Sendable, Comparable {
    let rawValue: UInt64

    static let initial = Self(rawValue: 0)

    func incremented() -> Self? {
        let next = rawValue.addingReportingOverflow(1)
        return next.overflow ? nil : Self(rawValue: next.partialValue)
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum DebuggerLogicalBreakpointPendingReason: Hashable, Sendable {
    case noSession
    case awaitingRuntimeInventory
    case ownerUnavailable
    case ownerAmbiguous
    case ownerSealMismatch
    case artifactCatalogStale
    case resolutionCatalogStale
    case staticAddressUnavailable
    case staticAddressNotExecutable
    case segmentUnavailable
    case addressOverflow
    case functionUnavailable
    case functionCorroborationMismatch
    case rawSymbolAuthorityUnavailable
    case symbolUnavailable
    case sourceAuthorityUnavailable
    case sourceUnavailable
    case accidentalAmbiguity
    case moduleUnloaded
    case runtimeProjectionStale
    case runtimeAddressNotExecutable
    case runtimeAddressCollision
    case capacityExceeded
    case newerCatalogAwaitingConvergence
    case hitAwaitingInventory
}

enum DebuggerLogicalBreakpointInvalidReason: Hashable, Sendable {
    case invalidResolutionCatalog
    case invalidRuntimeProjection
    case contradictoryStaticEvidence
    case duplicateStaticSiteIdentity
}

enum DebuggerLogicalBreakpointResolutionState: Hashable, Sendable {
    case disabled
    case pending(DebuggerLogicalBreakpointPendingReason)
    case resolved(site: DebuggerResolvedLogicalBreakpointSite, binding: DebuggerDesiredBreakpointBinding)
    case resolvedMultiple(sites: [DebuggerResolvedLogicalBreakpointSite], bindings: [DebuggerDesiredBreakpointBinding])
    case invalid(DebuggerLogicalBreakpointInvalidReason)
}

struct DebuggerLogicalBreakpointResolution: Hashable, Sendable {
    let logicalID: DebuggerLogicalBreakpointID
    let specificationRevision: DebuggerLogicalBreakpointRevision
    let state: DebuggerLogicalBreakpointResolutionState
}

struct DebuggerLogicalBreakpointResolutionExpectation: Hashable, Sendable {
    let logicalID: DebuggerLogicalBreakpointID
    let specificationRevision: DebuggerLogicalBreakpointRevision
}

/// One complete, digest-qualified resolution observation. `expectedSpecifications` distinguishes a
/// genuinely empty catalog from a partial/empty result that could otherwise authorize deletion.
struct DebuggerBreakpointResolutionObservation: Hashable, Sendable {
    let logicalCatalogCoordinate: DebuggerLogicalBreakpointCatalogCoordinate
    let resolutionCatalogCoordinate: DebuggerBreakpointResolutionCatalogCoordinate
    let mappingKey: DebuggerRuntimeMappingProjectionKey
    let expectedSpecifications: [DebuggerLogicalBreakpointResolutionExpectation]
    let results: [DebuggerLogicalBreakpointResolution]
    let canonicalDigest: DebuggerBreakpointDigest

    static func make(
        logicalCatalogCoordinate: DebuggerLogicalBreakpointCatalogCoordinate,
        resolutionCatalogCoordinate: DebuggerBreakpointResolutionCatalogCoordinate,
        mappingKey: DebuggerRuntimeMappingProjectionKey,
        expectedSpecifications: [DebuggerLogicalBreakpointResolutionExpectation],
        results: [DebuggerLogicalBreakpointResolution]
    ) -> Self? {
        let canonicalResults = results.map(Self.canonicalized)
        guard let digest = Self.digest(
            logicalCatalogCoordinate: logicalCatalogCoordinate,
            resolutionCatalogCoordinate: resolutionCatalogCoordinate,
            mappingKey: mappingKey,
            expectedSpecifications: expectedSpecifications,
            results: canonicalResults
        ) else {
            return nil
        }
        return Self(
            logicalCatalogCoordinate: logicalCatalogCoordinate,
            resolutionCatalogCoordinate: resolutionCatalogCoordinate,
            mappingKey: mappingKey,
            expectedSpecifications: expectedSpecifications,
            results: canonicalResults,
            canonicalDigest: digest
        )
    }

    private init?(
        logicalCatalogCoordinate: DebuggerLogicalBreakpointCatalogCoordinate,
        resolutionCatalogCoordinate: DebuggerBreakpointResolutionCatalogCoordinate,
        mappingKey: DebuggerRuntimeMappingProjectionKey,
        expectedSpecifications: [DebuggerLogicalBreakpointResolutionExpectation],
        results: [DebuggerLogicalBreakpointResolution],
        canonicalDigest: DebuggerBreakpointDigest
    ) {
        let expected = expectedSpecifications.sorted {
            Self.uuidBytes($0.logicalID.rawValue).lexicographicallyPrecedes(
                Self.uuidBytes($1.logicalID.rawValue)
            )
        }
        let orderedResults = results.sorted {
            Self.uuidBytes($0.logicalID.rawValue).lexicographicallyPrecedes(
                Self.uuidBytes($1.logicalID.rawValue)
            )
        }
        guard logicalCatalogCoordinate.workspaceID == resolutionCatalogCoordinate.workspaceID,
              resolutionCatalogCoordinate.workspaceArtifactCatalogRevision
                == mappingKey.workspaceCatalogRevision,
              resolutionCatalogCoordinate.revision.rawValue > 0,
              mappingKey.observedPID > 0,
              mappingKey.authorityRevision.rawValue > 0,
              mappingKey.inventoryRevision.rawValue > 0,
              mappingKey.workspaceCatalogRevision.rawValue > 0,
              mappingKey.stopCoordinate.session.lifecycleRevision.rawValue > 0,
              mappingKey.stopCoordinate.stopRevision.rawValue > 0,
              expected.count <= 4_096,
              expected.count == orderedResults.count,
              Set(expected.map(\.logicalID)).count == expected.count,
              Set(orderedResults.map(\.logicalID)).count == orderedResults.count,
              zip(expected, orderedResults).allSatisfy({ expectation, result in
                  expectation.logicalID == result.logicalID
                      && expectation.specificationRevision == result.specificationRevision
              }),
              orderedResults.allSatisfy(Self.isStructurallyValid),
              orderedResults.flatMap(Self.bindings).allSatisfy({ binding in
                  binding.mappingKey == mappingKey
              }) else {
            return nil
        }
        self.logicalCatalogCoordinate = logicalCatalogCoordinate
        self.resolutionCatalogCoordinate = resolutionCatalogCoordinate
        self.mappingKey = mappingKey
        self.expectedSpecifications = expected
        self.results = orderedResults
        self.canonicalDigest = canonicalDigest
    }

    private static func bindings(
        _ result: DebuggerLogicalBreakpointResolution
    ) -> [DebuggerDesiredBreakpointBinding] {
        switch result.state {
        case .resolved(_, let binding): return [binding]
        case .resolvedMultiple(_, let bindings): return bindings
        default: return []
        }
    }

    private static func isStructurallyValid(
        _ result: DebuggerLogicalBreakpointResolution
    ) -> Bool {
        func matches(_ site: DebuggerResolvedLogicalBreakpointSite) -> Bool {
            site.logicalID == result.logicalID
                && site.specificationRevision == result.specificationRevision
                && site.siteID.logicalID == result.logicalID
                && site.siteID.specificationRevision == result.specificationRevision
        }
        func matches(_ binding: DebuggerDesiredBreakpointBinding) -> Bool {
            binding.id.logicalID == result.logicalID
                && binding.id.siteID.specificationRevision == result.specificationRevision
                && matches(binding.site)
        }
        switch result.state {
        case .resolved(let site, let binding):
            return matches(site) && matches(binding) && binding.site == site
        case .resolvedMultiple(let sites, let bindings):
            return !sites.isEmpty
                && !bindings.isEmpty
                && sites.count <= 256
                && bindings.count <= 4_096
                && Set(sites).count == sites.count
                && Set(bindings).count == bindings.count
                && sites.allSatisfy(matches)
                && bindings.allSatisfy(matches)
                && Set(bindings.map(\.site)).isSubset(of: Set(sites))
        default:
            return true
        }
    }

    private static func uuidBytes(_ value: UUID) -> [UInt8] {
        withUnsafeBytes(of: value.uuid) { Array($0) }
    }

    private static func canonicalized(
        _ result: DebuggerLogicalBreakpointResolution
    ) -> DebuggerLogicalBreakpointResolution {
        guard case .resolvedMultiple(let sites, let bindings) = result.state else {
            return result
        }
        return DebuggerLogicalBreakpointResolution(
            logicalID: result.logicalID,
            specificationRevision: result.specificationRevision,
            state: .resolvedMultiple(
                sites: sites.sorted {
                    canonicalData(siteObject($0)).lexicographicallyPrecedes(
                        canonicalData(siteObject($1))
                    )
                },
                bindings: bindings.sorted {
                    canonicalData(bindingObject($0)).lexicographicallyPrecedes(
                        canonicalData(bindingObject($1))
                    )
                }
            )
        )
    }

    private static func digest(
        logicalCatalogCoordinate: DebuggerLogicalBreakpointCatalogCoordinate,
        resolutionCatalogCoordinate: DebuggerBreakpointResolutionCatalogCoordinate,
        mappingKey: DebuggerRuntimeMappingProjectionKey,
        expectedSpecifications: [DebuggerLogicalBreakpointResolutionExpectation],
        results: [DebuggerLogicalBreakpointResolution]
    ) -> DebuggerBreakpointDigest? {
        let expected = expectedSpecifications.sorted {
            uuidBytes($0.logicalID.rawValue).lexicographicallyPrecedes(
                uuidBytes($1.logicalID.rawValue)
            )
        }
        let orderedResults = results.sorted {
            uuidBytes($0.logicalID.rawValue).lexicographicallyPrecedes(
                uuidBytes($1.logicalID.rawValue)
            )
        }
        let object: [String: Any] = [
            "schema": "1",
            "logicalCatalog": [
                uuidHex(logicalCatalogCoordinate.workspaceID),
                uuidHex(logicalCatalogCoordinate.catalogID),
                String(logicalCatalogCoordinate.revision),
            ],
            "resolutionCatalog": [
                uuidHex(resolutionCatalogCoordinate.workspaceID),
                String(resolutionCatalogCoordinate.revision.rawValue),
                String(resolutionCatalogCoordinate.workspaceArtifactCatalogRevision.rawValue),
            ],
            "mapping": mappingObject(mappingKey),
            "expected": expected.map {
                [uuidHex($0.logicalID.rawValue), String($0.specificationRevision.rawValue)]
            },
            "results": orderedResults.map(resolutionObject),
        ]
        let bytes = canonicalData(object)
        guard !bytes.isEmpty else { return nil }
        return DebuggerBreakpointDigest(Data(SHA256.hash(data: bytes)))
    }

    private static func resolutionObject(
        _ result: DebuggerLogicalBreakpointResolution
    ) -> [String: Any] {
        var object: [String: Any] = [
            "id": uuidHex(result.logicalID.rawValue),
            "revision": String(result.specificationRevision.rawValue),
        ]
        switch result.state {
        case .disabled:
            object["state"] = "disabled"
        case .pending(let reason):
            object["state"] = ["pending", pendingCode(reason)]
        case .invalid(let reason):
            object["state"] = ["invalid", invalidCode(reason)]
        case .resolved(let site, let binding):
            object["state"] = ["resolved", siteObject(site), bindingObject(binding)]
        case .resolvedMultiple(let sites, let bindings):
            object["state"] = [
                "resolvedMultiple",
                sites.map(siteObject),
                bindings.map(bindingObject),
            ]
        }
        return object
    }

    private static func siteObject(_ site: DebuggerResolvedLogicalBreakpointSite) -> [String: Any] {
        [
            "logicalID": uuidHex(site.logicalID.rawValue),
            "revision": String(site.specificationRevision.rawValue),
            "slot": String(site.imageAddress.slot.rawValue),
            "address": String(site.imageAddress.address),
            "ordinal": String(site.siteID.staticOrdinal),
            "ownerSlot": String(site.owner.slot.rawValue),
            "ownerBinary": uuidHex(site.owner.binaryID),
            "ownerArtifact": artifactObject(site.owner.artifactIdentity),
            "coordinateBinary": uuidHex(site.coordinate.binaryID),
            "coordinateSlot": String(site.coordinate.slot.rawValue),
            "coordinateArtifact": artifactObject(site.coordinate.artifactIdentity),
            "ownerRevision": String(site.coordinate.ownerRevision.rawValue),
            "provenance": provenanceObject(site.provenance),
        ]
    }

    private static func bindingObject(_ binding: DebuggerDesiredBreakpointBinding) -> [String: Any] {
        [
            "site": siteObject(binding.site),
            "processID": String(binding.id.moduleInstanceID.processID),
            "sessionEpoch": uuidHex(binding.id.moduleInstanceID.stop.session.epoch.rawValue),
            "lifecycle": String(binding.id.moduleInstanceID.stop.session.lifecycleRevision.rawValue),
            "stop": String(binding.id.moduleInstanceID.stop.stopRevision.rawValue),
            "inventory": String(binding.id.moduleInstanceID.inventoryRevision.rawValue),
            "moduleOrdinal": String(binding.id.moduleInstanceID.ordinal),
            "runtimeAddress": String(binding.runtimeAddress),
            "mapping": mappingObject(binding.mappingKey),
            "policyDigest": hex(binding.policyActionDigest.bytes),
            "issuanceDigest": hex(binding.issuanceDigest.bytes),
        ]
    }

    private static func mappingObject(_ key: DebuggerRuntimeMappingProjectionKey) -> [String] {
        [
            uuidHex(key.stopCoordinate.session.epoch.rawValue),
            String(key.stopCoordinate.session.lifecycleRevision.rawValue),
            String(key.stopCoordinate.stopRevision.rawValue),
            String(key.observedPID),
            String(key.authorityRevision.rawValue),
            String(key.inventoryRevision.rawValue),
            String(key.workspaceCatalogRevision.rawValue),
        ]
    }

    private static func artifactObject(_ artifact: MachOSliceArtifactIdentity?) -> Any {
        guard let artifact else { return NSNull() }
        return [
            "uuid": artifact.uuid.map(uuidHex) ?? "nil",
            "cpu": String(artifact.rawCPUType),
            "subtype": String(artifact.rawCPUSubtype),
            "sha256": artifact.selectedSliceSHA256,
            "bytes": String(artifact.selectedSliceByteCount),
        ]
    }

    private static func provenanceObject(
        _ provenance: DebuggerLogicalBreakpointSiteProvenance
    ) -> [Any] {
        switch provenance {
        case .preferredAddress:
            return ["preferredAddress"]
        case .imageOffset(let name, let start, let offset):
            return ["imageOffset", name, String(start), String(offset)]
        case .function(let address, let name):
            return ["function", String(address), name.map { ["some", $0] } ?? ["nil"]]
        case .symbol(let name, let kind, let library, let ordinal):
            return [
                "symbol", name,
                kind.map { ["some", $0] } ?? ["nil"],
                library.map { ["some", $0] } ?? ["nil"],
                String(ordinal),
            ]
        case .source(let file, let line, let column, let ordinal):
            return [
                "source", sourceFileObject(file), String(line),
                column.map { ["some", String($0)] } ?? ["nil"], String(ordinal),
            ]
        }
    }

    private static func sourceFileObject(_ file: DebuggerCanonicalSourceFileIdentity) -> [Any] {
        let path: [String]
        switch file.tablePath {
        case .absoluteUTF8(let value): path = ["absolute", value]
        case .compilationDirectoryRelativeUTF8(let value): path = ["relative", value]
        }
        return [
            uuidHex(file.debugArtifactUUID), file.debugArtifactMachOSHA256,
            String(file.debugArtifactMachOByteCount), String(file.lineProgramUnitOffset),
            String(file.fileTableIndex), path,
        ]
    }

    private static func pendingCode(_ reason: DebuggerLogicalBreakpointPendingReason) -> String {
        switch reason {
        case .noSession: "noSession"
        case .awaitingRuntimeInventory: "awaitingRuntimeInventory"
        case .ownerUnavailable: "ownerUnavailable"
        case .ownerAmbiguous: "ownerAmbiguous"
        case .ownerSealMismatch: "ownerSealMismatch"
        case .artifactCatalogStale: "artifactCatalogStale"
        case .resolutionCatalogStale: "resolutionCatalogStale"
        case .staticAddressUnavailable: "staticAddressUnavailable"
        case .staticAddressNotExecutable: "staticAddressNotExecutable"
        case .segmentUnavailable: "segmentUnavailable"
        case .addressOverflow: "addressOverflow"
        case .functionUnavailable: "functionUnavailable"
        case .functionCorroborationMismatch: "functionCorroborationMismatch"
        case .rawSymbolAuthorityUnavailable: "rawSymbolAuthorityUnavailable"
        case .symbolUnavailable: "symbolUnavailable"
        case .sourceAuthorityUnavailable: "sourceAuthorityUnavailable"
        case .sourceUnavailable: "sourceUnavailable"
        case .accidentalAmbiguity: "accidentalAmbiguity"
        case .moduleUnloaded: "moduleUnloaded"
        case .runtimeProjectionStale: "runtimeProjectionStale"
        case .runtimeAddressNotExecutable: "runtimeAddressNotExecutable"
        case .runtimeAddressCollision: "runtimeAddressCollision"
        case .capacityExceeded: "capacityExceeded"
        case .newerCatalogAwaitingConvergence: "newerCatalogAwaitingConvergence"
        case .hitAwaitingInventory: "hitAwaitingInventory"
        }
    }

    private static func invalidCode(_ reason: DebuggerLogicalBreakpointInvalidReason) -> String {
        switch reason {
        case .invalidResolutionCatalog: "invalidResolutionCatalog"
        case .invalidRuntimeProjection: "invalidRuntimeProjection"
        case .contradictoryStaticEvidence: "contradictoryStaticEvidence"
        case .duplicateStaticSiteIdentity: "duplicateStaticSiteIdentity"
        }
    }

    private static func canonicalData(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    private static func uuidHex(_ uuid: UUID) -> String {
        withUnsafeBytes(of: uuid.uuid) { hex(Data($0)) }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

enum DebuggerBreakpointBackendFailureReason: Hashable, Sendable {
    case incompleteReceipt
    case contradictoryReceipt
    case postWriteUncertainty
    case ownershipMismatch
    case inventoryIncomplete
    case callbackFault
    case revisionOverflow
    case sessionInvalidated
}

struct DebuggerOwnedBackendBreakpointLocation: Hashable, Sendable {
    let bindingID: DebuggerTransientBreakpointBindingID
    let backendBreakpointID: UInt64
    let backendLocationID: UInt64
    let runtimeAddress: UInt64
    let ownershipTagDigest: DebuggerBreakpointDigest
    let policyActionDigest: DebuggerBreakpointDigest
    let issuanceDigest: DebuggerBreakpointDigest

    init?(
        bindingID: DebuggerTransientBreakpointBindingID,
        backendBreakpointID: UInt64,
        backendLocationID: UInt64,
        runtimeAddress: UInt64,
        ownershipTagDigest: DebuggerBreakpointDigest,
        policyActionDigest: DebuggerBreakpointDigest,
        issuanceDigest: DebuggerBreakpointDigest
    ) {
        guard backendBreakpointID > 0,
              backendLocationID > 0 else {
            return nil
        }
        self.bindingID = bindingID
        self.backendBreakpointID = backendBreakpointID
        self.backendLocationID = backendLocationID
        self.runtimeAddress = runtimeAddress
        self.ownershipTagDigest = ownershipTagDigest
        self.policyActionDigest = policyActionDigest
        self.issuanceDigest = issuanceDigest
    }
}

struct DebuggerBreakpointBindingPlan: Hashable, Sendable {
    let transactionID: DebuggerBreakpointBindingTransactionID
    let sessionEpoch: DebuggerSessionEpoch
    let adapterGeneration: UInt64
    let stopCoordinate: DebuggerStopCoordinate
    let observedPID: Int32
    let observedStopID: UInt32
    let logicalCatalogCoordinate: DebuggerLogicalBreakpointCatalogCoordinate
    let resolutionCatalogCoordinate: DebuggerBreakpointResolutionCatalogCoordinate
    let resolutionObservationDigest: DebuggerBreakpointDigest
    let mappingKey: DebuggerRuntimeMappingProjectionKey
    let bindings: [DebuggerDesiredBreakpointBinding]
    let ownershipTagDigest: DebuggerBreakpointDigest
    let canonicalPlanDigest: DebuggerBreakpointDigest

    init?(
        transactionID: DebuggerBreakpointBindingTransactionID,
        sessionEpoch: DebuggerSessionEpoch,
        adapterGeneration: UInt64,
        stopCoordinate: DebuggerStopCoordinate,
        observedPID: Int32,
        observedStopID: UInt32,
        logicalCatalogCoordinate: DebuggerLogicalBreakpointCatalogCoordinate,
        resolutionCatalogCoordinate: DebuggerBreakpointResolutionCatalogCoordinate,
        resolutionObservationDigest: DebuggerBreakpointDigest,
        mappingKey: DebuggerRuntimeMappingProjectionKey,
        bindings: [DebuggerDesiredBreakpointBinding],
        ownershipTagDigest: DebuggerBreakpointDigest,
        canonicalPlanDigest: DebuggerBreakpointDigest
    ) {
        let ordered = bindings.sorted(by: Self.bindingPrecedes)
        guard adapterGeneration > 0,
              observedPID > 0,
              observedStopID > 0,
              sessionEpoch == stopCoordinate.session.epoch,
              stopCoordinate.session.lifecycleRevision.rawValue > 0,
              stopCoordinate.stopRevision.rawValue > 0,
              stopCoordinate == mappingKey.stopCoordinate,
              observedPID == mappingKey.observedPID,
              mappingKey.authorityRevision.rawValue > 0,
              mappingKey.inventoryRevision.rawValue > 0,
              mappingKey.workspaceCatalogRevision.rawValue > 0,
              resolutionCatalogCoordinate.revision.rawValue > 0,
              ordered.count <= 4_096,
              Set(ordered.map(\.id)).count == ordered.count,
              ordered.allSatisfy({ $0.mappingKey == mappingKey }),
              resolutionCatalogCoordinate.workspaceID == logicalCatalogCoordinate.workspaceID,
              resolutionCatalogCoordinate.workspaceArtifactCatalogRevision
                == mappingKey.workspaceCatalogRevision,
              !Self.hasRuntimeAddressCollision(ordered) else {
            return nil
        }
        self.transactionID = transactionID
        self.sessionEpoch = sessionEpoch
        self.adapterGeneration = adapterGeneration
        self.stopCoordinate = stopCoordinate
        self.observedPID = observedPID
        self.observedStopID = observedStopID
        self.logicalCatalogCoordinate = logicalCatalogCoordinate
        self.resolutionCatalogCoordinate = resolutionCatalogCoordinate
        self.resolutionObservationDigest = resolutionObservationDigest
        self.mappingKey = mappingKey
        self.bindings = ordered
        self.ownershipTagDigest = ownershipTagDigest
        self.canonicalPlanDigest = canonicalPlanDigest
    }

    private static func bindingPrecedes(
        _ lhs: DebuggerDesiredBreakpointBinding,
        _ rhs: DebuggerDesiredBreakpointBinding
    ) -> Bool {
        if lhs.runtimeAddress != rhs.runtimeAddress { return lhs.runtimeAddress < rhs.runtimeAddress }
        let left = withUnsafeBytes(of: lhs.id.logicalID.rawValue.uuid) { Array($0) }
        let right = withUnsafeBytes(of: rhs.id.logicalID.rawValue.uuid) { Array($0) }
        if left != right { return left.lexicographicallyPrecedes(right) }
        if lhs.id.siteID.staticOrdinal != rhs.id.siteID.staticOrdinal {
            return lhs.id.siteID.staticOrdinal < rhs.id.siteID.staticOrdinal
        }
        return lhs.id.moduleInstanceID.ordinal < rhs.id.moduleInstanceID.ordinal
    }

    private static func hasRuntimeAddressCollision(
        _ bindings: [DebuggerDesiredBreakpointBinding]
    ) -> Bool {
        Dictionary(grouping: bindings, by: \.runtimeAddress).values.contains {
            Set($0.map(\.id)).count > 1
        }
    }
}

struct DebuggerBreakpointBindingReceipt: Hashable, Sendable {
    let transactionID: DebuggerBreakpointBindingTransactionID
    let sessionEpoch: DebuggerSessionEpoch
    let adapterGeneration: UInt64
    let stopCoordinate: DebuggerStopCoordinate
    let observedPID: Int32
    let observedStopID: UInt32
    let canonicalPlanDigest: DebuggerBreakpointDigest
    let didWriteBackend: Bool
    let completeOwnedInventory: [DebuggerOwnedBackendBreakpointLocation]

    init?(
        transactionID: DebuggerBreakpointBindingTransactionID,
        sessionEpoch: DebuggerSessionEpoch,
        adapterGeneration: UInt64,
        stopCoordinate: DebuggerStopCoordinate,
        observedPID: Int32,
        observedStopID: UInt32,
        canonicalPlanDigest: DebuggerBreakpointDigest,
        didWriteBackend: Bool,
        completeOwnedInventory: [DebuggerOwnedBackendBreakpointLocation]
    ) {
        let ordered = completeOwnedInventory.sorted(by: Self.locationPrecedes)
        guard adapterGeneration > 0,
              observedPID > 0,
              observedStopID > 0,
              sessionEpoch == stopCoordinate.session.epoch,
              stopCoordinate.session.lifecycleRevision.rawValue > 0,
              stopCoordinate.stopRevision.rawValue > 0,
              ordered.count <= 4_096,
              Set(ordered.map(\.bindingID)).count == ordered.count,
              Set(ordered.map(\.backendBreakpointID)).count == ordered.count else {
            return nil
        }
        self.transactionID = transactionID
        self.sessionEpoch = sessionEpoch
        self.adapterGeneration = adapterGeneration
        self.stopCoordinate = stopCoordinate
        self.observedPID = observedPID
        self.observedStopID = observedStopID
        self.canonicalPlanDigest = canonicalPlanDigest
        self.didWriteBackend = didWriteBackend
        self.completeOwnedInventory = ordered
    }

    private static func locationPrecedes(
        _ lhs: DebuggerOwnedBackendBreakpointLocation,
        _ rhs: DebuggerOwnedBackendBreakpointLocation
    ) -> Bool {
        if lhs.backendBreakpointID != rhs.backendBreakpointID {
            return lhs.backendBreakpointID < rhs.backendBreakpointID
        }
        return lhs.backendLocationID < rhs.backendLocationID
    }
}

struct DebuggerBreakpointOwnedInventoryObservation: Hashable, Sendable {
    let sessionEpoch: DebuggerSessionEpoch
    let adapterGeneration: UInt64
    let stopCoordinate: DebuggerStopCoordinate
    let observedPID: Int32
    let observedStopID: UInt32
    let isComplete: Bool
    let locations: [DebuggerOwnedBackendBreakpointLocation]

    init?(
        sessionEpoch: DebuggerSessionEpoch,
        adapterGeneration: UInt64,
        stopCoordinate: DebuggerStopCoordinate,
        observedPID: Int32,
        observedStopID: UInt32,
        isComplete: Bool,
        locations: [DebuggerOwnedBackendBreakpointLocation]
    ) {
        let ordered = locations.sorted {
            if $0.backendBreakpointID != $1.backendBreakpointID {
                return $0.backendBreakpointID < $1.backendBreakpointID
            }
            return $0.backendLocationID < $1.backendLocationID
        }
        guard adapterGeneration > 0,
              observedPID > 0,
              observedStopID > 0,
              sessionEpoch == stopCoordinate.session.epoch,
              stopCoordinate.session.lifecycleRevision.rawValue > 0,
              stopCoordinate.stopRevision.rawValue > 0,
              ordered.count <= 4_096,
              Set(ordered.map(\.bindingID)).count == ordered.count,
              Set(ordered.map(\.backendBreakpointID)).count == ordered.count else {
            return nil
        }
        self.sessionEpoch = sessionEpoch
        self.adapterGeneration = adapterGeneration
        self.stopCoordinate = stopCoordinate
        self.observedPID = observedPID
        self.observedStopID = observedStopID
        self.isComplete = isComplete
        self.locations = ordered
    }
}

enum DebuggerBreakpointCallbackActionOutput: Hashable, Sendable {
    static let maximumLogTextUTF8Bytes = 4_096
    static let maximumExpressionLabelUTF8Bytes = 256
    static let maximumExpressionValueUTF8Bytes = 4_096

    case log(text: String)
    case targetExpression(label: String, value: String)

    static func makeLog(text: String) -> Self? {
        guard isBoundedText(
            text,
            maximumUTF8Bytes: maximumLogTextUTF8Bytes,
            permitsEmpty: true
        ) else { return nil }
        return .log(text: text)
    }

    static func makeTargetExpression(label: String, value: String) -> Self? {
        guard isBoundedText(label, maximumUTF8Bytes: maximumExpressionLabelUTF8Bytes),
              isBoundedText(
                value,
                maximumUTF8Bytes: maximumExpressionValueUTF8Bytes,
                permitsEmpty: true
              ) else {
            return nil
        }
        return .targetExpression(label: label, value: value)
    }

    fileprivate var isValid: Bool {
        switch self {
        case .log(let text):
            Self.isBoundedText(
                text,
                maximumUTF8Bytes: Self.maximumLogTextUTF8Bytes,
                permitsEmpty: true
            )
        case .targetExpression(let label, let value):
            Self.isBoundedText(
                label,
                maximumUTF8Bytes: Self.maximumExpressionLabelUTF8Bytes
            ) && Self.isBoundedText(
                value,
                maximumUTF8Bytes: Self.maximumExpressionValueUTF8Bytes,
                permitsEmpty: true
            )
        }
    }

    private static func isBoundedText(
        _ text: String,
        maximumUTF8Bytes: Int,
        permitsEmpty: Bool = false
    ) -> Bool {
        let count = text.utf8.count
        return (permitsEmpty || count > 0) && count <= maximumUTF8Bytes
    }
}

enum DebuggerBreakpointCallbackOutcome: Hashable, Sendable {
    case ignored
    case conditionFalse
    case stopped
    case continued
    case fault(code: String)
}

struct DebuggerBreakpointCallbackRecord: Hashable, Sendable {
    static let maximumActionOutputCount = 16

    let sessionEpoch: DebuggerSessionEpoch
    let adapterGeneration: UInt64
    let processID: Int32
    let sequence: UInt64
    let logicalID: DebuggerLogicalBreakpointID
    let specificationRevision: DebuggerLogicalBreakpointRevision
    let bindingID: DebuggerTransientBreakpointBindingID
    let backendBreakpointID: UInt64
    let backendLocationID: UInt64
    let issuanceDigest: DebuggerBreakpointDigest
    let observedLogicalHitCount: UInt64
    let outcome: DebuggerBreakpointCallbackOutcome
    let actionOutputs: [DebuggerBreakpointCallbackActionOutput]
    /// Cumulative helper-ring loss reported by a semantic fault record. Ordinary callback records
    /// omit the value because no new drop fact was observed.
    let reportedDropCount: UInt64?

    init?(
        sessionEpoch: DebuggerSessionEpoch,
        adapterGeneration: UInt64,
        processID: Int32,
        sequence: UInt64,
        logicalID: DebuggerLogicalBreakpointID,
        specificationRevision: DebuggerLogicalBreakpointRevision,
        bindingID: DebuggerTransientBreakpointBindingID,
        backendBreakpointID: UInt64,
        backendLocationID: UInt64,
        issuanceDigest: DebuggerBreakpointDigest,
        observedLogicalHitCount: UInt64,
        outcome: DebuggerBreakpointCallbackOutcome
    ) {
        self.init(
            sessionEpoch: sessionEpoch,
            adapterGeneration: adapterGeneration,
            processID: processID,
            sequence: sequence,
            logicalID: logicalID,
            specificationRevision: specificationRevision,
            bindingID: bindingID,
            backendBreakpointID: backendBreakpointID,
            backendLocationID: backendLocationID,
            issuanceDigest: issuanceDigest,
            observedLogicalHitCount: observedLogicalHitCount,
            outcome: outcome,
            actionOutputs: [],
            reportedDropCount: nil
        )
    }

    init?(
        sessionEpoch: DebuggerSessionEpoch,
        adapterGeneration: UInt64,
        processID: Int32,
        sequence: UInt64,
        logicalID: DebuggerLogicalBreakpointID,
        specificationRevision: DebuggerLogicalBreakpointRevision,
        bindingID: DebuggerTransientBreakpointBindingID,
        backendBreakpointID: UInt64,
        backendLocationID: UInt64,
        issuanceDigest: DebuggerBreakpointDigest,
        observedLogicalHitCount: UInt64,
        outcome: DebuggerBreakpointCallbackOutcome,
        actionOutputs: [DebuggerBreakpointCallbackActionOutput],
        reportedDropCount: UInt64?
    ) {
        guard adapterGeneration > 0,
              processID > 0,
              sequence > 0,
              backendBreakpointID > 0,
              backendLocationID > 0,
              observedLogicalHitCount > 0 || Self.isFault(outcome),
              logicalID == bindingID.logicalID,
              specificationRevision == bindingID.siteID.specificationRevision,
              Self.isValid(outcome),
              actionOutputs.count <= Self.maximumActionOutputCount,
              actionOutputs.allSatisfy(\.isValid),
              Self.outputsAreValid(actionOutputs, for: outcome),
              Self.dropCountIsValid(reportedDropCount, for: outcome) else {
            return nil
        }
        self.sessionEpoch = sessionEpoch
        self.adapterGeneration = adapterGeneration
        self.processID = processID
        self.sequence = sequence
        self.logicalID = logicalID
        self.specificationRevision = specificationRevision
        self.bindingID = bindingID
        self.backendBreakpointID = backendBreakpointID
        self.backendLocationID = backendLocationID
        self.issuanceDigest = issuanceDigest
        self.observedLogicalHitCount = observedLogicalHitCount
        self.outcome = outcome
        self.actionOutputs = actionOutputs
        self.reportedDropCount = reportedDropCount
    }

    private static func isFault(_ outcome: DebuggerBreakpointCallbackOutcome) -> Bool {
        if case .fault = outcome { return true }
        return false
    }

    private static func isValid(_ outcome: DebuggerBreakpointCallbackOutcome) -> Bool {
        guard case .fault(let code) = outcome else { return true }
        let bytes = Array(code.utf8)
        return (1...64).contains(bytes.count) && bytes.allSatisfy {
            (0x61...0x7A).contains($0)
                || (0x30...0x39).contains($0)
                || $0 == 0x2D
        }
    }

    private static func outputsAreValid(
        _ outputs: [DebuggerBreakpointCallbackActionOutput],
        for outcome: DebuggerBreakpointCallbackOutcome
    ) -> Bool {
        switch outcome {
        case .stopped, .continued:
            true
        case .ignored, .conditionFalse, .fault:
            outputs.isEmpty
        }
    }

    private static func dropCountIsValid(
        _ dropCount: UInt64?,
        for outcome: DebuggerBreakpointCallbackOutcome
    ) -> Bool {
        switch outcome {
        case .fault:
            true
        case .ignored, .conditionFalse, .stopped, .continued:
            dropCount == nil
        }
    }
}

/// One canonical helper-ring page. The page cursor is a generation-local callback sequence, not a
/// transport request/event sequence. Construction is all-or-nothing and preserves empty final
/// acknowledgements without manufacturing records.
struct DebuggerBreakpointCallbackBatch: Hashable, Sendable {
    static let maximumRecordCount = 1_024

    let sessionEpoch: DebuggerSessionEpoch
    let adapterGeneration: UInt64
    let processID: Int32
    let afterSequence: UInt64
    let nextSequence: UInt64
    let isFinal: Bool
    let records: [DebuggerBreakpointCallbackRecord]

    init?(
        sessionEpoch: DebuggerSessionEpoch,
        adapterGeneration: UInt64,
        processID: Int32,
        afterSequence: UInt64,
        nextSequence: UInt64,
        isFinal: Bool,
        records: [DebuggerBreakpointCallbackRecord]
    ) {
        guard adapterGeneration > 0,
              processID > 0,
              records.count <= Self.maximumRecordCount,
              nextSequence >= afterSequence,
              records.allSatisfy({
                  $0.sessionEpoch == sessionEpoch
                      && $0.adapterGeneration == adapterGeneration
                      && $0.processID == processID
              }),
              Self.hasExactContiguousSequence(
                records,
                afterSequence: afterSequence,
                nextSequence: nextSequence
              ) else {
            return nil
        }
        self.sessionEpoch = sessionEpoch
        self.adapterGeneration = adapterGeneration
        self.processID = processID
        self.afterSequence = afterSequence
        self.nextSequence = nextSequence
        self.isFinal = isFinal
        self.records = records
    }

    private static func hasExactContiguousSequence(
        _ records: [DebuggerBreakpointCallbackRecord],
        afterSequence: UInt64,
        nextSequence: UInt64
    ) -> Bool {
        guard !records.isEmpty else { return nextSequence == afterSequence }
        var prior = afterSequence
        for record in records {
            let next = prior.addingReportingOverflow(1)
            guard !next.overflow, record.sequence == next.partialValue else { return false }
            prior = record.sequence
        }
        return prior == nextSequence
    }
}
