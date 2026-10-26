import XCTest
@testable import MacScope

final class DebuggerLogicalBreakpointPresentationTests: XCTestCase {
    func testRowsAreDeterministicAndQualifyAuthoredAddressesWithExactImage() throws {
        let second = try makeSpecification(id: logicalB, address: 0x1020)
        let first = try makeSpecification(id: logicalA, address: 0x1010)
        let projection = DebuggerLogicalBreakpointPresentation.project(
            catalog: try makeCatalog([second, first]),
            coordinate: try catalogCoordinate,
            reducerSnapshot: nil,
            imageIdentities: [try imageIdentity]
        )

        XCTAssertEqual(projection.rows.map(\.id), [logicalA, logicalB])
        XCTAssertEqual(projection.rows.map(\.locatorTitle), ["0x0000000000001010", "0x0000000000001020"])
        XCTAssertEqual(projection.rows.map(\.scopeTitle), ["Fixture.framework", "Fixture.framework"])
        XCTAssertEqual(projection.rows.map(\.state), [.savedOffline, .savedOffline])
        XCTAssertTrue(projection.rows[0].accessibilityLabel.contains("Fixture.framework"))
        XCTAssertTrue(projection.rows[0].accessibilityLabel.contains("0x0000000000001010"))
        XCTAssertTrue(projection.rows[0].accessibilityLabel.contains("Saved, offline"))
    }

    func testDurableDisabledStateWinsWithoutRuntimeAuthority() throws {
        let specification = try makeSpecification(id: logicalA, address: 0x1010, enabled: false)
        let projection = project([specification], reducerSnapshot: nil)

        let row = try XCTUnwrap(projection.rows.first)
        XCTAssertEqual(row.state, .disabled)
        XCTAssertEqual(row.state.status.title, "Disabled")
        XCTAssertEqual(row.state.status.symbol, .disabled)
        XCTAssertEqual(row.sessionHitCount, 0)
        XCTAssertTrue(row.locations.isEmpty)
    }

    func testPendingReasonsDistinguishAwaitingFirstStopInventoryAndOrdinaryPending() throws {
        let specification = try makeSpecification(id: logicalA, address: 0x1010)
        let revision = specification.revision

        let beforeFirstStop = snapshot(
            currentStop: nil,
            resolutions: [.init(
                logicalID: logicalA,
                specificationRevision: revision,
                state: .pending(.awaitingRuntimeInventory)
            )]
        )
        XCTAssertEqual(
            project([specification], reducerSnapshot: beforeFirstStop).rows.first?.state,
            .awaiting(.firstStop)
        )

        let awaitingInventory = snapshot(
            currentStop: stop,
            resolutions: [.init(
                logicalID: logicalA,
                specificationRevision: revision,
                state: .pending(.awaitingRuntimeInventory)
            )]
        )
        XCTAssertEqual(
            project([specification], reducerSnapshot: awaitingInventory).rows.first?.state,
            .awaiting(.runtimeInventory)
        )

        let pending = snapshot(
            currentStop: stop,
            resolutions: [.init(
                logicalID: logicalA,
                specificationRevision: revision,
                state: .pending(.moduleUnloaded)
            )]
        )
        let pendingState = try XCTUnwrap(project([specification], reducerSnapshot: pending).rows.first?.state)
        XCTAssertEqual(pendingState, .pending(.moduleUnloaded))
        XCTAssertEqual(pendingState.diagnostic?.code, "breakpoint.pending.module-unloaded")
    }

    func testApplyingStateDoesNotClaimLocationsBeforeReceipt() throws {
        let specification = try makeSpecification(id: logicalA, address: 0x1010)
        let resolution = DebuggerLogicalBreakpointResolution(
            logicalID: logicalA,
            specificationRevision: specification.revision,
            state: .pending(.newerCatalogAwaitingConvergence)
        )
        let reducer = snapshot(
            currentStop: stop,
            resolutions: [resolution],
            backendState: .applying(.init(rawValue: transactionID))
        )

        let row = try XCTUnwrap(project([specification], reducerSnapshot: reducer).rows.first)
        XCTAssertEqual(row.state, .applying)
        XCTAssertEqual(row.locationCount, 0)
        XCTAssertTrue(row.locations.isEmpty)
    }

    func testBoundRowsExposeOnlyTheirDeterministicallyOrderedLocationsAndSessionHits() throws {
        let first = try makeSpecification(id: logicalA, address: 0x1010)
        let second = try makeSpecification(id: logicalB, address: 0x1020)
        let firstHigh = try runtimeFixture(specification: first, runtimeAddress: 0x9018, ordinal: 1, backendID: 12)
        let secondLocation = try runtimeFixture(specification: second, runtimeAddress: 0x9020, ordinal: 0, backendID: 21)
        let firstLow = try runtimeFixture(specification: first, runtimeAddress: 0x9010, ordinal: 0, backendID: 11)
        let firstResolution = DebuggerLogicalBreakpointResolution(
            logicalID: logicalA,
            specificationRevision: first.revision,
            state: .resolvedMultiple(
                sites: [firstLow.site, firstHigh.site],
                bindings: [firstLow.binding, firstHigh.binding]
            )
        )
        let reducer = snapshot(
            currentStop: stop,
            resolutions: [firstResolution, secondLocation.resolution],
            backendState: .bound([firstHigh.location, secondLocation.location, firstLow.location]),
            ownedLocations: [secondLocation.location, firstHigh.location, firstLow.location],
            observedHitCounts: [logicalA: 7, logicalB: 3]
        )

        let rows = project([second, first], reducerSnapshot: reducer).rows
        XCTAssertEqual(rows.map(\.id), [logicalA, logicalB])
        XCTAssertEqual(rows[0].state, .bound(locationCount: 2))
        XCTAssertEqual(rows[0].sessionHitCount, 7)
        XCTAssertEqual(rows[0].locations.map(\.runtimeAddress), [0x9010, 0x9018])
        XCTAssertEqual(rows[0].locations.map(\.imageName), ["Fixture.framework", "Fixture.framework"])
        XCTAssertFalse(rows[0].locations[0].accessibilityLabel.contains("11"), "Backend IDs are not presentation data")
        XCTAssertEqual(rows[1].state, .bound(locationCount: 1))
        XCTAssertEqual(rows[1].sessionHitCount, 3)
    }

    func testArmedAndFailureStatesUseSemanticRedactedDiagnostics() throws {
        let sensitiveSymbol = "_private_user_token_do_not_echo"
        let specification = try makeSymbolSpecification(id: logicalA, symbol: sensitiveSymbol)
        let runtime = try runtimeFixture(specification: specification, runtimeAddress: 0x9010, ordinal: 0, backendID: 11)
        let armed = snapshot(
            currentStop: nil,
            resolutions: [.init(
                logicalID: logicalA,
                specificationRevision: specification.revision,
                state: .pending(.awaitingRuntimeInventory)
            )],
            backendState: .armedUnobserved([runtime.location]),
            ownedLocations: [runtime.location]
        )
        XCTAssertEqual(
            project([specification], reducerSnapshot: armed).rows.first?.state,
            .armed(locationCount: 1)
        )

        let failed = snapshot(
            currentStop: stop,
            resolutions: [runtime.resolution],
            backendState: .failClosed(.postWriteUncertainty),
            ownedLocations: [runtime.location]
        )
        let state = try XCTUnwrap(project([specification], reducerSnapshot: failed).rows.first?.state)
        XCTAssertEqual(state, .failure(.backend(.postWriteUncertainty)))
        let diagnostic = try XCTUnwrap(state.diagnostic)
        XCTAssertEqual(diagnostic.code, "breakpoint.failure.backend.post-write-uncertainty")
        XCTAssertFalse(diagnostic.title.contains(sensitiveSymbol))
        XCTAssertFalse(diagnostic.detail.contains(sensitiveSymbol))
        XCTAssertFalse(diagnostic.detail.contains("0x0000000000009010"))
        XCTAssertFalse(diagnostic.detail.contains("11"))
    }

    func testStaleReducerCoordinateContributesNoRuntimeFacts() throws {
        let specification = try makeSpecification(id: logicalA, address: 0x1010)
        let runtime = try runtimeFixture(specification: specification, runtimeAddress: 0x9010, ordinal: 0, backendID: 11)
        let staleCoordinate = try DebuggerLogicalBreakpointCatalogCoordinate(
            workspaceID: workspaceID,
            catalogID: catalogID,
            revision: 2
        )
        let stale = snapshot(
            desiredCatalogCoordinate: staleCoordinate,
            currentStop: stop,
            resolutions: [runtime.resolution],
            backendState: .bound([runtime.location]),
            ownedLocations: [runtime.location],
            observedHitCounts: [logicalA: 99]
        )

        let row = try XCTUnwrap(project([specification], reducerSnapshot: stale).rows.first)
        XCTAssertEqual(row.state, .savedOffline)
        XCTAssertEqual(row.sessionHitCount, 0)
        XCTAssertTrue(row.locations.isEmpty)
    }

    func testGutterProjectionUsesExactOwnerQualifiedActionStateAndLocationCount() throws {
        let specification = try makeSpecification(id: logicalA, address: 0x1010)
        let runtime = try runtimeFixture(specification: specification, runtimeAddress: 0x9010, ordinal: 0, backendID: 11)
        let reducer = snapshot(
            currentStop: stop,
            resolutions: [runtime.resolution],
            backendState: .bound([runtime.location]),
            ownedLocations: [runtime.location]
        )
        let projection = project([specification], reducerSnapshot: reducer)

        let gutter = projection.gutter(
            at: ImageAddress.primary(0x1010),
            owner: try owner
        )
        XCTAssertEqual(gutter.action, .remove(logicalA))
        XCTAssertEqual(gutter.symbol, .bound)
        XCTAssertEqual(gutter.locationCount, 1)
        XCTAssertEqual(
            gutter.accessibilityLabel,
            "Remove breakpoint, Fixture.framework, 0x0000000000001010, Bound, 1 location"
        )

        let empty = projection.gutter(
            at: ImageAddress.primary(0x1090),
            owner: try owner
        )
        XCTAssertEqual(empty.action, .set)
        XCTAssertEqual(empty.symbol, .none)
        XCTAssertEqual(
            empty.accessibilityLabel,
            "Set breakpoint, Fixture.framework, 0x0000000000001090, No saved breakpoint, 0 locations"
        )
    }

    // MARK: - Fixtures

    private struct RuntimeFixture {
        let site: DebuggerResolvedLogicalBreakpointSite
        let binding: DebuggerDesiredBreakpointBinding
        let resolution: DebuggerLogicalBreakpointResolution
        let location: DebuggerOwnedBackendBreakpointLocation
    }

    private let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let catalogID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let binaryID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let transactionID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let epoch = DebuggerSessionEpoch(
        rawValue: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
    )
    private let logicalA = DebuggerLogicalBreakpointID(
        rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    )
    private let logicalB = DebuggerLogicalBreakpointID(
        rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    )

    private var artifactIdentity: MachOSliceArtifactIdentity {
        get throws {
            try MachOSliceArtifactIdentity(
                uuid: binaryID,
                rawCPUType: MachOConstants.cpuTypeARM64,
                rawCPUSubtype: 0,
                selectedSliceSHA256: String(repeating: "a", count: 64),
                selectedSliceByteCount: 0x10_000
            )
        }
    }

    private var owner: DebuggerWorkspaceImageOwnerSeal {
        get throws {
            DebuggerWorkspaceImageOwnerSeal(
                slot: .primary,
                binaryID: binaryID,
                artifactIdentity: try artifactIdentity
            )
        }
    }

    private var imageIdentity: DebuggerLogicalBreakpointImagePresentationIdentity {
        get throws {
            DebuggerLogicalBreakpointImagePresentationIdentity(
                owner: try owner,
                displayName: "Fixture.framework"
            )
        }
    }

    private var catalogCoordinate: DebuggerLogicalBreakpointCatalogCoordinate {
        get throws {
            try DebuggerLogicalBreakpointCatalogCoordinate(
                workspaceID: workspaceID,
                catalogID: catalogID,
                revision: 1
            )
        }
    }

    private var stop: DebuggerStopCoordinate {
        DebuggerStopCoordinate(
            session: DebuggerSessionCoordinate(
                epoch: epoch,
                lifecycleRevision: .init(rawValue: 2)
            ),
            stopRevision: .init(rawValue: 3)
        )
    }

    private func makeSpecification(
        id: DebuggerLogicalBreakpointID,
        address: UInt64,
        enabled: Bool = true
    ) throws -> DebuggerLogicalBreakpointSpecification {
        try DebuggerLogicalBreakpointSpecification(
            id: id,
            revision: .init(validating: 1),
            enabled: enabled,
            target: .preferredAddress(owner: try owner, preferredVA: address),
            condition: nil,
            hitPolicy: .always,
            actions: [],
            disposition: .stop
        )
    }

    private func makeSymbolSpecification(
        id: DebuggerLogicalBreakpointID,
        symbol: String
    ) throws -> DebuggerLogicalBreakpointSpecification {
        try DebuggerLogicalBreakpointSpecification(
            id: id,
            revision: .init(validating: 1),
            enabled: true,
            target: .symbol(
                owner: try owner,
                exactRawLinkageName: symbol,
                kind: nil,
                libraryName: nil,
                cardinality: .exactlyOne
            ),
            condition: nil,
            hitPolicy: .always,
            actions: [],
            disposition: .stop
        )
    }

    private func makeCatalog(
        _ specifications: [DebuggerLogicalBreakpointSpecification]
    ) throws -> DebuggerLogicalBreakpointCatalog {
        try DebuggerLogicalBreakpointCatalog(
            catalogID: catalogID,
            revision: 1,
            specifications: specifications
        )
    }

    private func project(
        _ specifications: [DebuggerLogicalBreakpointSpecification],
        reducerSnapshot: DebuggerBreakpointBindingReducerSnapshot?
    ) -> DebuggerLogicalBreakpointPresentationSnapshot {
        try! DebuggerLogicalBreakpointPresentation.project(
            catalog: makeCatalog(specifications),
            coordinate: catalogCoordinate,
            reducerSnapshot: reducerSnapshot,
            imageIdentities: [imageIdentity]
        )
    }

    private func snapshot(
        desiredCatalogCoordinate: DebuggerLogicalBreakpointCatalogCoordinate? = nil,
        currentStop: DebuggerStopCoordinate?,
        resolutions: [DebuggerLogicalBreakpointResolution],
        backendState: DebuggerBreakpointBackendState = .unbound,
        ownedLocations: [DebuggerOwnedBackendBreakpointLocation] = [],
        observedHitCounts: [DebuggerLogicalBreakpointID: UInt64] = [:]
    ) -> DebuggerBreakpointBindingReducerSnapshot {
        DebuggerBreakpointBindingReducerSnapshot(
            sessionEpoch: epoch,
            authorityRevision: .init(rawValue: 1),
            backendInventoryRevision: .init(rawValue: 1),
            desiredCatalogCoordinate: desiredCatalogCoordinate ?? (try! catalogCoordinate),
            resolutionObservation: nil,
            currentStop: currentStop,
            lifecycleHighWater: currentStop?.session.lifecycleRevision ?? .initial,
            stopHighWater: currentStop?.stopRevision ?? .initial,
            adapterGeneration: currentStop == nil ? nil : 1,
            observedPID: currentStop == nil ? nil : 77,
            observedStopID: currentStop == nil ? nil : 3,
            resolutions: resolutions,
            backendState: backendState,
            ownedLocations: ownedLocations,
            pendingPlan: nil,
            observedHitCounts: observedHitCounts,
            lastCallbackSequence: 0,
            isTerminal: false,
            isInvalidated: false
        )
    }

    private func runtimeFixture(
        specification: DebuggerLogicalBreakpointSpecification,
        runtimeAddress: UInt64,
        ordinal: UInt32,
        backendID: UInt64
    ) throws -> RuntimeFixture {
        let preferredAddress: UInt64
        switch specification.target {
        case .preferredAddress(_, let value): preferredAddress = value
        default: preferredAddress = 0x1010
        }
        let imageAddress = ImageAddress.primary(preferredAddress)
        let siteID = DebuggerLogicalBreakpointSiteID(
            logicalID: specification.id,
            specificationRevision: specification.revision,
            imageAddress: imageAddress,
            staticOrdinal: ordinal
        )
        let coordinate = DebuggerWorkspaceArtifactCoordinate(
            binaryID: binaryID,
            slot: .primary,
            artifactIdentity: try artifactIdentity,
            ownerRevision: .init(rawValue: 1)
        )
        let site = try XCTUnwrap(DebuggerResolvedLogicalBreakpointSite(
            logicalID: specification.id,
            specificationRevision: specification.revision,
            siteID: siteID,
            owner: try owner,
            coordinate: coordinate,
            imageAddress: imageAddress,
            provenance: .preferredAddress
        ))
        let mappingKey = DebuggerRuntimeMappingProjectionKey(
            stopCoordinate: stop,
            observedPID: 77,
            authorityRevision: .init(rawValue: 1),
            inventoryRevision: .init(rawValue: 1),
            workspaceCatalogRevision: .init(rawValue: 1)
        )
        let moduleID = DebuggerRuntimeModuleInstanceID(
            processID: 77,
            stop: stop,
            inventoryRevision: mappingKey.inventoryRevision,
            ordinal: ordinal
        )
        let bindingID = try XCTUnwrap(DebuggerTransientBreakpointBindingID(
            logicalID: specification.id,
            siteID: siteID,
            moduleInstanceID: moduleID
        ))
        let policyDigest = try XCTUnwrap(DebuggerBreakpointDigest(Data(repeating: 9, count: 32)))
        let issuanceDigest = try XCTUnwrap(DebuggerBreakpointDigest(Data(repeating: 8, count: 32)))
        let ownershipDigest = try XCTUnwrap(DebuggerBreakpointDigest(Data(repeating: 7, count: 32)))
        let binding = try XCTUnwrap(DebuggerDesiredBreakpointBinding(
            id: bindingID,
            site: site,
            mappingKey: mappingKey,
            runtimeAddress: runtimeAddress,
            policyActionDigest: policyDigest,
            issuanceDigest: issuanceDigest
        ))
        let location = try XCTUnwrap(DebuggerOwnedBackendBreakpointLocation(
            bindingID: bindingID,
            backendBreakpointID: backendID,
            backendLocationID: backendID + 100,
            runtimeAddress: runtimeAddress,
            ownershipTagDigest: ownershipDigest,
            policyActionDigest: policyDigest,
            issuanceDigest: issuanceDigest
        ))
        return RuntimeFixture(
            site: site,
            binding: binding,
            resolution: .init(
                logicalID: specification.id,
                specificationRevision: specification.revision,
                state: .resolved(site: site, binding: binding)
            ),
            location: location
        )
    }
}
