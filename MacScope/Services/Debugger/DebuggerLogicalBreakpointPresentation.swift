import Foundation

/// Exact display identity supplied by the workspace shell. Presentation lookup uses the complete
/// immutable owner seal so a same-slot replacement or same-VA sibling can never inherit a label.
struct DebuggerLogicalBreakpointImagePresentationIdentity: Hashable, Sendable {
    let owner: DebuggerWorkspaceImageOwnerSeal
    let displayName: String

    init(owner: DebuggerWorkspaceImageOwnerSeal, displayName: String) {
        self.owner = owner
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum DebuggerLogicalBreakpointPresentationSymbol: Hashable, Sendable {
    case none
    case saved
    case disabled
    case awaiting
    case pending
    case applying
    case bound
    case multiple
    case armed
    case failure
}

enum DebuggerLogicalBreakpointPresentationTone: Hashable, Sendable {
    case secondary
    case disabled
    case informational
    case warning
    case success
    case error
}

struct DebuggerLogicalBreakpointPresentationStatus: Hashable, Sendable {
    let title: String
    let detail: String
    let symbol: DebuggerLogicalBreakpointPresentationSymbol
    let tone: DebuggerLogicalBreakpointPresentationTone
}

struct DebuggerLogicalBreakpointPresentationDiagnostic: Hashable, Sendable {
    let code: String
    let title: String
    let detail: String
    let tone: DebuggerLogicalBreakpointPresentationTone
}

enum DebuggerLogicalBreakpointAwaitingPresentation: Hashable, Sendable {
    case firstStop
    case runtimeInventory
    case backendConvergence
}

enum DebuggerLogicalBreakpointPresentationFailure: Hashable, Sendable {
    case resolution(DebuggerLogicalBreakpointInvalidReason)
    case backend(DebuggerBreakpointBackendFailureReason)
    case inconsistentProjection
}

enum DebuggerLogicalBreakpointPresentationState: Hashable, Sendable {
    case savedOffline
    case disabled
    case awaiting(DebuggerLogicalBreakpointAwaitingPresentation)
    case pending(DebuggerLogicalBreakpointPendingReason)
    case applying
    case bound(locationCount: Int)
    case armed(locationCount: Int)
    case failure(DebuggerLogicalBreakpointPresentationFailure)

    var status: DebuggerLogicalBreakpointPresentationStatus {
        switch self {
        case .savedOffline:
            return .init(
                title: "Saved, offline",
                detail: "Saved in the workspace. No current runtime binding is claimed.",
                symbol: .saved,
                tone: .secondary
            )
        case .disabled:
            return .init(
                title: "Disabled",
                detail: "Saved in the workspace and intentionally disabled.",
                symbol: .disabled,
                tone: .disabled
            )
        case .awaiting(let reason):
            switch reason {
            case .firstStop:
                return .init(
                    title: "Awaiting first stop",
                    detail: "Saved and waiting for the first proven stopped-process state.",
                    symbol: .awaiting,
                    tone: .informational
                )
            case .runtimeInventory:
                return .init(
                    title: "Awaiting runtime inventory",
                    detail: "Saved and waiting for current module and location evidence.",
                    symbol: .awaiting,
                    tone: .informational
                )
            case .backendConvergence:
                return .init(
                    title: "Awaiting convergence",
                    detail: "Saved and waiting for the current backend transaction boundary.",
                    symbol: .awaiting,
                    tone: .informational
                )
            }
        case .pending(let reason):
            return .init(
                title: "Pending",
                detail: reason.presentationDetail,
                symbol: .pending,
                tone: .warning
            )
        case .applying:
            return .init(
                title: "Applying",
                detail: "The current logical specification is being applied.",
                symbol: .applying,
                tone: .informational
            )
        case .bound(let count):
            return .init(
                title: count > 1 ? "Bound, multiple locations" : "Bound",
                detail: count == 1
                    ? "One current runtime location is proven bound."
                    : "\(count) current runtime locations are proven bound.",
                symbol: count > 1 ? .multiple : .bound,
                tone: .success
            )
        case .armed(let count):
            return .init(
                title: "Armed, awaiting verification",
                detail: count == 1
                    ? "One prior binding remains armed while current runtime evidence is refreshed."
                    : "\(count) prior bindings remain armed while current runtime evidence is refreshed.",
                symbol: .armed,
                tone: .warning
            )
        case .failure(let failure):
            return .init(
                title: "Binding failed",
                detail: failure.presentationDetail,
                symbol: .failure,
                tone: .error
            )
        }
    }

    var diagnostic: DebuggerLogicalBreakpointPresentationDiagnostic? {
        switch self {
        case .pending(let reason):
            return .init(
                code: "breakpoint.pending.\(reason.presentationCode)",
                title: "Breakpoint pending",
                detail: reason.presentationDetail,
                tone: .warning
            )
        case .failure(let failure):
            return .init(
                code: failure.presentationCode,
                title: "Breakpoint binding failed",
                detail: failure.presentationDetail,
                tone: .error
            )
        default:
            return nil
        }
    }
}

struct DebuggerLogicalBreakpointRuntimeLocationPresentation: Hashable, Sendable {
    let imageName: String
    let preferredAddress: UInt64
    let runtimeAddress: UInt64
    let accessibilityLabel: String
}

struct DebuggerLogicalBreakpointRowPresentation: Identifiable, Hashable, Sendable {
    let id: DebuggerLogicalBreakpointID
    let specificationRevision: DebuggerLogicalBreakpointRevision
    let isEnabled: Bool
    let locatorTitle: String
    let scopeTitle: String
    let state: DebuggerLogicalBreakpointPresentationState
    let locationCount: Int
    let sessionHitCount: UInt64
    let locations: [DebuggerLogicalBreakpointRuntimeLocationPresentation]
    let accessibilityLabel: String
}

enum DebuggerLogicalBreakpointGutterAction: Hashable, Sendable {
    case set
    case remove(DebuggerLogicalBreakpointID)
    case manage(count: Int)

    var title: String {
        switch self {
        case .set: "Set breakpoint"
        case .remove: "Remove breakpoint"
        case .manage: "Manage breakpoints"
        }
    }
}

struct DebuggerLogicalBreakpointGutterPresentation: Hashable, Sendable {
    let action: DebuggerLogicalBreakpointGutterAction
    let symbol: DebuggerLogicalBreakpointPresentationSymbol
    let stateDescription: String
    let logicalBreakpointCount: Int
    let locationCount: Int
    let accessibilityLabel: String
}

struct DebuggerLogicalBreakpointPresentationSnapshot: Sendable {
    let rows: [DebuggerLogicalBreakpointRowPresentation]

    private let specificationsByID: [DebuggerLogicalBreakpointID: DebuggerLogicalBreakpointSpecification]
    private let imageNamesByOwner: [DebuggerWorkspaceImageOwnerSeal: String]

    fileprivate init(
        rows: [DebuggerLogicalBreakpointRowPresentation],
        specificationsByID: [
            DebuggerLogicalBreakpointID: DebuggerLogicalBreakpointSpecification
        ],
        imageNamesByOwner: [DebuggerWorkspaceImageOwnerSeal: String]
    ) {
        self.rows = rows
        self.specificationsByID = specificationsByID
        self.imageNamesByOwner = imageNamesByOwner
    }

    func gutter(
        at address: ImageAddress,
        owner: DebuggerWorkspaceImageOwnerSeal
    ) -> DebuggerLogicalBreakpointGutterPresentation {
        let matches = rows.filter { row in
            guard let specification = specificationsByID[row.id],
                  case .preferredAddress(let candidateOwner, let preferredVA) = specification.target
            else { return false }
            return candidateOwner == owner
                && address.slot == owner.slot
                && preferredVA == address.address
        }
        let action: DebuggerLogicalBreakpointGutterAction
        switch matches.count {
        case 0: action = .set
        case 1: action = .remove(matches[0].id)
        default: action = .manage(count: matches.count)
        }

        let aggregateState = Self.aggregateState(matches.map(\.state))
        let stateDescription = aggregateState?.status.title ?? "No saved breakpoint"
        let symbol = aggregateState?.status.symbol ?? .none
        let locationCount = matches.reduce(0) { $0 + $1.locationCount }
        let imageName = imageNamesByOwner[owner] ?? Self.fallbackImageName(for: owner)
        let locationNoun = locationCount == 1 ? "location" : "locations"
        let accessibilityLabel = [
            action.title,
            imageName,
            Self.hex(address.address),
            stateDescription,
            "\(locationCount) \(locationNoun)",
        ].joined(separator: ", ")

        return DebuggerLogicalBreakpointGutterPresentation(
            action: action,
            symbol: symbol,
            stateDescription: stateDescription,
            logicalBreakpointCount: matches.count,
            locationCount: locationCount,
            accessibilityLabel: accessibilityLabel
        )
    }

    private static func aggregateState(
        _ states: [DebuggerLogicalBreakpointPresentationState]
    ) -> DebuggerLogicalBreakpointPresentationState? {
        guard !states.isEmpty else { return nil }
        if let failure = states.first(where: { if case .failure = $0 { true } else { false } }) {
            return failure
        }
        if states.contains(.applying) { return .applying }
        if let pending = states.first(where: {
            switch $0 {
            case .pending, .awaiting: true
            default: false
            }
        }) {
            return pending
        }
        let armedCount = states.reduce(0) { partial, state in
            if case .armed(let count) = state { partial + count } else { partial }
        }
        if armedCount > 0 { return .armed(locationCount: armedCount) }
        let boundCount = states.reduce(0) { partial, state in
            if case .bound(let count) = state { partial + count } else { partial }
        }
        if boundCount > 0 { return .bound(locationCount: boundCount) }
        if states.allSatisfy({ $0 == .disabled }) { return .disabled }
        return .savedOffline
    }

    fileprivate static func fallbackImageName(for owner: DebuggerWorkspaceImageOwnerSeal) -> String {
        let shortID = owner.binaryID.uuidString.prefix(8)
        return "Image \(owner.slot.rawValue), binary \(shortID)"
    }

    fileprivate static func hex(_ value: UInt64) -> String {
        String(format: "0x%016llx", value)
    }
}

enum DebuggerLogicalBreakpointPresentation {
    static func project(
        catalog: DebuggerLogicalBreakpointCatalog,
        coordinate: DebuggerLogicalBreakpointCatalogCoordinate,
        reducerSnapshot: DebuggerBreakpointBindingReducerSnapshot?,
        imageIdentities: [DebuggerLogicalBreakpointImagePresentationIdentity]
    ) -> DebuggerLogicalBreakpointPresentationSnapshot {
        let imageNames = Dictionary(
            imageIdentities
                .filter { !$0.displayName.isEmpty }
                .map { ($0.owner, $0.displayName) },
            uniquingKeysWith: { min($0, $1) }
        )
        let specificationsByID = Dictionary(
            uniqueKeysWithValues: catalog.specifications.map { ($0.id, $0) }
        )
        guard coordinate.catalogID == catalog.catalogID,
              coordinate.revision == catalog.revision else {
            return DebuggerLogicalBreakpointPresentationSnapshot(
                rows: [],
                specificationsByID: specificationsByID,
                imageNamesByOwner: imageNames
            )
        }

        let acceptedSnapshot: DebuggerBreakpointBindingReducerSnapshot?
        if reducerSnapshot?.desiredCatalogCoordinate == coordinate {
            acceptedSnapshot = reducerSnapshot
        } else {
            acceptedSnapshot = nil
        }

        let rows = catalog.specifications
            .sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
            .map { specification in
                row(
                    specification: specification,
                    snapshot: acceptedSnapshot,
                    imageNames: imageNames
                )
            }
        return DebuggerLogicalBreakpointPresentationSnapshot(
            rows: rows,
            specificationsByID: specificationsByID,
            imageNamesByOwner: imageNames
        )
    }

    private static func row(
        specification: DebuggerLogicalBreakpointSpecification,
        snapshot: DebuggerBreakpointBindingReducerSnapshot?,
        imageNames: [DebuggerWorkspaceImageOwnerSeal: String]
    ) -> DebuggerLogicalBreakpointRowPresentation {
        let owner = specification.target.presentationOwner
        let imageName = imageNames[owner]
            ?? DebuggerLogicalBreakpointPresentationSnapshot.fallbackImageName(for: owner)
        let locatorTitle = specification.target.presentationLocator
        let matchingResolution = snapshot?.resolutions.first {
            $0.logicalID == specification.id
                && $0.specificationRevision == specification.revision
        }
        let desiredBindingIDs = matchingResolution.map(Self.desiredBindingIDs) ?? []
        let matchingOwnedLocations = (snapshot?.ownedLocations ?? [])
            .filter {
                guard $0.bindingID.logicalID == specification.id,
                      $0.bindingID.siteID.specificationRevision == specification.revision else {
                    return false
                }
                if let snapshot, case .bound = snapshot.backendState {
                    return desiredBindingIDs.contains($0.bindingID)
                }
                return true
            }
            .sorted(by: locationPrecedes)
        let locations = matchingOwnedLocations.map { location in
            let preferredAddress = location.bindingID.siteID.imageAddress.address
            return DebuggerLogicalBreakpointRuntimeLocationPresentation(
                imageName: imageName,
                preferredAddress: preferredAddress,
                runtimeAddress: location.runtimeAddress,
                accessibilityLabel: [
                    imageName,
                    "preferred \(DebuggerLogicalBreakpointPresentationSnapshot.hex(preferredAddress))",
                    "runtime \(DebuggerLogicalBreakpointPresentationSnapshot.hex(location.runtimeAddress))",
                ].joined(separator: ", ")
            )
        }
        let state = presentationState(
            specification: specification,
            matchingResolution: matchingResolution,
            matchingLocationCount: locations.count,
            snapshot: snapshot
        )
        let acceptedLocations = state.exposesRuntimeLocations ? locations : []
        let hitCount = matchingResolution == nil
            || snapshot?.isTerminal == true
            || snapshot?.isInvalidated == true
            ? 0
            : (snapshot?.observedHitCounts[specification.id] ?? 0)
        let locationNoun = acceptedLocations.count == 1 ? "location" : "locations"
        let hitNoun = hitCount == 1 ? "session hit" : "session hits"
        let accessibilityLabel = [
            locatorTitle,
            imageName,
            state.status.title,
            "\(acceptedLocations.count) \(locationNoun)",
            "\(hitCount) \(hitNoun)",
        ].joined(separator: ", ")

        return DebuggerLogicalBreakpointRowPresentation(
            id: specification.id,
            specificationRevision: specification.revision,
            isEnabled: specification.enabled,
            locatorTitle: locatorTitle,
            scopeTitle: imageName,
            state: state,
            locationCount: acceptedLocations.count,
            sessionHitCount: hitCount,
            locations: acceptedLocations,
            accessibilityLabel: accessibilityLabel
        )
    }

    private static func presentationState(
        specification: DebuggerLogicalBreakpointSpecification,
        matchingResolution: DebuggerLogicalBreakpointResolution?,
        matchingLocationCount: Int,
        snapshot: DebuggerBreakpointBindingReducerSnapshot?
    ) -> DebuggerLogicalBreakpointPresentationState {
        guard specification.enabled else { return .disabled }
        guard let snapshot else { return .savedOffline }
        guard let matchingResolution else { return .awaiting(.backendConvergence) }

        if case .failClosed(let reason) = snapshot.backendState {
            return .failure(.backend(reason))
        }
        if case .invalid(let reason) = matchingResolution.state {
            return .failure(.resolution(reason))
        }
        if case .disabled = matchingResolution.state {
            return .failure(.inconsistentProjection)
        }
        if case .applying = snapshot.backendState {
            return .applying
        }
        if case .armedUnobserved = snapshot.backendState, matchingLocationCount > 0 {
            return .armed(locationCount: matchingLocationCount)
        }

        switch matchingResolution.state {
        case .disabled:
            return .failure(.inconsistentProjection)
        case .pending(.noSession):
            return .savedOffline
        case .pending(.awaitingRuntimeInventory):
            return snapshot.currentStop == nil
                ? .awaiting(.firstStop)
                : .awaiting(.runtimeInventory)
        case .pending(.hitAwaitingInventory):
            return .awaiting(.runtimeInventory)
        case .pending(.newerCatalogAwaitingConvergence):
            return .awaiting(.backendConvergence)
        case .pending(let reason):
            return .pending(reason)
        case .resolved, .resolvedMultiple:
            if case .bound = snapshot.backendState, matchingLocationCount > 0 {
                return .bound(locationCount: matchingLocationCount)
            }
            return .awaiting(.backendConvergence)
        case .invalid(let reason):
            return .failure(.resolution(reason))
        }
    }

    private static func locationPrecedes(
        _ lhs: DebuggerOwnedBackendBreakpointLocation,
        _ rhs: DebuggerOwnedBackendBreakpointLocation
    ) -> Bool {
        if lhs.runtimeAddress != rhs.runtimeAddress {
            return lhs.runtimeAddress < rhs.runtimeAddress
        }
        let leftSite = lhs.bindingID.siteID
        let rightSite = rhs.bindingID.siteID
        if leftSite.imageAddress != rightSite.imageAddress {
            if leftSite.imageAddress.slot != rightSite.imageAddress.slot {
                return leftSite.imageAddress.slot < rightSite.imageAddress.slot
            }
            return leftSite.imageAddress.address < rightSite.imageAddress.address
        }
        if leftSite.staticOrdinal != rightSite.staticOrdinal {
            return leftSite.staticOrdinal < rightSite.staticOrdinal
        }
        return lhs.bindingID.moduleInstanceID.ordinal < rhs.bindingID.moduleInstanceID.ordinal
    }

    private static func desiredBindingIDs(
        _ resolution: DebuggerLogicalBreakpointResolution
    ) -> Set<DebuggerTransientBreakpointBindingID> {
        switch resolution.state {
        case .resolved(_, let binding):
            [binding.id]
        case .resolvedMultiple(_, let bindings):
            Set(bindings.map(\.id))
        case .disabled, .pending, .invalid:
            []
        }
    }
}

private extension DebuggerLogicalBreakpointPresentationState {
    var exposesRuntimeLocations: Bool {
        switch self {
        case .bound, .armed, .failure:
            true
        default:
            false
        }
    }
}

private extension DebuggerLogicalBreakpointTarget {
    var presentationOwner: DebuggerWorkspaceImageOwnerSeal {
        switch self {
        case .preferredAddress(let owner, _),
             .imageOffset(let owner, _, _, _),
             .function(let owner, _, _),
             .symbol(let owner, _, _, _, _),
             .source(let owner, _, _, _, _):
            owner
        }
    }

    var presentationLocator: String {
        switch self {
        case .preferredAddress(_, let preferredVA):
            return DebuggerLogicalBreakpointPresentationSnapshot.hex(preferredVA)
        case .imageOffset(_, let segmentName, _, let offset):
            return "\(segmentName) + \(DebuggerLogicalBreakpointPresentationSnapshot.hex(offset))"
        case .function(_, let entryPreferredVA, let rawLinkageNameHint):
            return rawLinkageNameHint
                ?? "Function at \(DebuggerLogicalBreakpointPresentationSnapshot.hex(entryPreferredVA))"
        case .symbol(_, let exactRawLinkageName, _, let libraryName, _):
            return libraryName.map { "\(exactRawLinkageName) in \($0)" } ?? exactRawLinkageName
        case .source(_, let file, let line, let columnPolicy, _):
            let column: String
            switch columnPolicy {
            case .any: column = ""
            case .exact(let value): column = ":\(value)"
            }
            return "\(file.tablePath.presentationPath):\(line)\(column)"
        }
    }
}

private extension DebuggerCanonicalSourceTablePath {
    var presentationPath: String {
        let value: String
        switch self {
        case .absoluteUTF8(let path), .compilationDirectoryRelativeUTF8(let path):
            value = path
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: true)
        if value.hasPrefix("/Users/"), components.count >= 2 {
            let suffix = components.dropFirst(2).joined(separator: "/")
            return suffix.isEmpty ? "<home>" : "<home>/\(suffix)"
        }
        if value.hasPrefix("/home/"), components.count >= 2 {
            let suffix = components.dropFirst(2).joined(separator: "/")
            return suffix.isEmpty ? "<home>" : "<home>/\(suffix)"
        }
        return value
    }
}

private extension DebuggerLogicalBreakpointPendingReason {
    var presentationCode: String {
        switch self {
        case .noSession: "no-session"
        case .awaitingRuntimeInventory: "awaiting-runtime-inventory"
        case .ownerUnavailable: "owner-unavailable"
        case .ownerAmbiguous: "owner-ambiguous"
        case .ownerSealMismatch: "owner-seal-mismatch"
        case .artifactCatalogStale: "artifact-catalog-stale"
        case .resolutionCatalogStale: "resolution-catalog-stale"
        case .staticAddressUnavailable: "static-address-unavailable"
        case .staticAddressNotExecutable: "static-address-not-executable"
        case .segmentUnavailable: "segment-unavailable"
        case .addressOverflow: "address-overflow"
        case .functionUnavailable: "function-unavailable"
        case .functionCorroborationMismatch: "function-corroboration-mismatch"
        case .rawSymbolAuthorityUnavailable: "raw-symbol-authority-unavailable"
        case .symbolUnavailable: "symbol-unavailable"
        case .sourceAuthorityUnavailable: "source-authority-unavailable"
        case .sourceUnavailable: "source-unavailable"
        case .accidentalAmbiguity: "accidental-ambiguity"
        case .moduleUnloaded: "module-unloaded"
        case .runtimeProjectionStale: "runtime-projection-stale"
        case .runtimeAddressNotExecutable: "runtime-address-not-executable"
        case .runtimeAddressCollision: "runtime-address-collision"
        case .capacityExceeded: "capacity-exceeded"
        case .newerCatalogAwaitingConvergence: "newer-catalog-awaiting-convergence"
        case .hitAwaitingInventory: "hit-awaiting-inventory"
        }
    }

    var presentationDetail: String {
        switch self {
        case .noSession:
            "Saved in the workspace. No debug session is active."
        case .awaitingRuntimeInventory, .hitAwaitingInventory:
            "Waiting for complete current runtime inventory."
        case .ownerUnavailable:
            "The authored image owner is not currently available."
        case .ownerAmbiguous:
            "The authored image owner is not uniquely proven."
        case .ownerSealMismatch:
            "The current image does not match the authored owner identity."
        case .artifactCatalogStale, .resolutionCatalogStale, .runtimeProjectionStale:
            "Waiting for current analysis and runtime authority."
        case .staticAddressUnavailable:
            "The authored static address is not currently available."
        case .staticAddressNotExecutable:
            "The authored static address is not proven executable."
        case .segmentUnavailable:
            "The authored segment is not currently available."
        case .addressOverflow:
            "The resolved address cannot be represented safely."
        case .functionUnavailable:
            "The authored function is not currently available."
        case .functionCorroborationMismatch:
            "Current function evidence does not corroborate the authored locator."
        case .rawSymbolAuthorityUnavailable:
            "Exact raw-symbol authority is not currently available."
        case .symbolUnavailable:
            "The authored symbol has no current exact match."
        case .sourceAuthorityUnavailable:
            "Exact source-line authority is not currently available."
        case .sourceUnavailable:
            "The authored source location has no current exact match."
        case .accidentalAmbiguity:
            "The authored locator resolves ambiguously and will not guess."
        case .moduleUnloaded:
            "The matching runtime module is currently unloaded."
        case .runtimeAddressNotExecutable:
            "The runtime address is not proven executable."
        case .runtimeAddressCollision:
            "Current runtime evidence maps distinct locations to one address."
        case .capacityExceeded:
            "The result exceeds the safe logical-breakpoint capacity."
        case .newerCatalogAwaitingConvergence:
            "A newer saved catalog is waiting for backend convergence."
        }
    }
}

private extension DebuggerLogicalBreakpointPresentationFailure {
    var presentationCode: String {
        switch self {
        case .resolution(let reason):
            "breakpoint.failure.resolution.\(reason.presentationCode)"
        case .backend(let reason):
            "breakpoint.failure.backend.\(reason.presentationCode)"
        case .inconsistentProjection:
            "breakpoint.failure.presentation.inconsistent-projection"
        }
    }

    var presentationDetail: String {
        switch self {
        case .resolution:
            "Current resolver evidence is contradictory or structurally invalid."
        case .backend(.postWriteUncertainty):
            "A backend write may have occurred without a complete verified receipt."
        case .backend:
            "The backend could not prove an exact, owned breakpoint result."
        case .inconsistentProjection:
            "The runtime projection conflicts with the current durable specification."
        }
    }
}

private extension DebuggerLogicalBreakpointInvalidReason {
    var presentationCode: String {
        switch self {
        case .invalidResolutionCatalog: "invalid-resolution-catalog"
        case .invalidRuntimeProjection: "invalid-runtime-projection"
        case .contradictoryStaticEvidence: "contradictory-static-evidence"
        case .duplicateStaticSiteIdentity: "duplicate-static-site-identity"
        }
    }
}

private extension DebuggerBreakpointBackendFailureReason {
    var presentationCode: String {
        switch self {
        case .incompleteReceipt: "incomplete-receipt"
        case .contradictoryReceipt: "contradictory-receipt"
        case .postWriteUncertainty: "post-write-uncertainty"
        case .ownershipMismatch: "ownership-mismatch"
        case .inventoryIncomplete: "inventory-incomplete"
        case .callbackFault: "callback-fault"
        case .revisionOverflow: "revision-overflow"
        case .sessionInvalidated: "session-invalidated"
        }
    }
}
