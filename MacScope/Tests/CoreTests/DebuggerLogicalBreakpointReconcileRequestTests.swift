import XCTest
@testable import MacScope

final class DebuggerLogicalBreakpointReconcileRequestTests: XCTestCase {
    func testAvailableCompleteCatalogAndCanonicalObservationFormHashableSendableEnvelope() throws {
        let first = try specification(id: logicalA, revision: 2, address: 0x1010)
        let second = try specification(id: logicalB, revision: 1, address: 0x1020)
        let catalog = try makeCatalog(revision: 2, specifications: [second, first])
        let observation = try makeObservation(
            catalogID: catalog.catalogID,
            catalogRevision: catalog.revision,
            specifications: [second, first]
        )

        let request = try DebuggerLogicalBreakpointReconcileRequest(
            catalogAvailability: .available,
            catalog: catalog,
            observation: observation
        )
        let duplicate = try DebuggerLogicalBreakpointReconcileRequest(
            catalogAvailability: .available,
            catalog: catalog,
            observation: observation
        )

        XCTAssertEqual(request.catalog, catalog)
        XCTAssertEqual(request.observation, observation)
        XCTAssertEqual(Set([request, duplicate]).count, 1)
        requireSendable(request)
        XCTAssertEqual(
            Set(Mirror(reflecting: request).children.compactMap(\.label)),
            ["catalog", "observation"]
        )
    }

    func testUnavailableCatalogIsRejectedEvenWhenCompleteSetIsEmpty() throws {
        let catalog = DebuggerLogicalBreakpointCatalog.freshPristine(catalogID: catalogID)
        let observation = try makeObservation(
            catalogID: catalog.catalogID,
            catalogRevision: catalog.revision,
            specifications: []
        )

        XCTAssertThrowsError(try DebuggerLogicalBreakpointReconcileRequest(
            catalogAvailability: .unavailable,
            catalog: catalog,
            observation: observation
        )) {
            XCTAssertEqual(
                $0 as? DebuggerLogicalBreakpointReconcileRequestError,
                .catalogUnavailable
            )
        }

        XCTAssertNoThrow(try DebuggerLogicalBreakpointReconcileRequest(
            catalogAvailability: .available,
            catalog: catalog,
            observation: observation
        ))
    }

    func testCatalogIDAndRevisionMustExactlyMatchObservationCoordinate() throws {
        let item = try specification(id: logicalA, revision: 1, address: 0x1010)
        let observation = try makeObservation(
            catalogID: catalogID,
            catalogRevision: 1,
            specifications: [item]
        )
        let foreignIDCatalog = try makeCatalog(
            catalogID: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            revision: 1,
            specifications: [item]
        )
        let newerCatalog = try makeCatalog(revision: 2, specifications: [item])

        for catalog in [foreignIDCatalog, newerCatalog] {
            XCTAssertThrowsError(try DebuggerLogicalBreakpointReconcileRequest(
                catalogAvailability: .available,
                catalog: catalog,
                observation: observation
            )) {
                XCTAssertEqual(
                    $0 as? DebuggerLogicalBreakpointReconcileRequestError,
                    .logicalCatalogCoordinateMismatch
                )
            }
        }
    }

    func testCoverageRequiresEveryExactLogicalIDAndSpecificationRevision() throws {
        let firstV1 = try specification(id: logicalA, revision: 1, address: 0x1010)
        let second = try specification(id: logicalB, revision: 1, address: 0x1020)
        let twoItemCatalog = try makeCatalog(revision: 1, specifications: [firstV1, second])
        let partialObservation = try makeObservation(
            catalogID: catalogID,
            catalogRevision: 1,
            specifications: [firstV1]
        )
        XCTAssertThrowsError(try DebuggerLogicalBreakpointReconcileRequest(
            catalogAvailability: .available,
            catalog: twoItemCatalog,
            observation: partialObservation
        )) {
            XCTAssertEqual(
                $0 as? DebuggerLogicalBreakpointReconcileRequestError,
                .specificationCoverageMismatch
            )
        }

        let firstV2 = try specification(id: logicalA, revision: 2, address: 0x1010)
        let revisedCatalog = try makeCatalog(revision: 2, specifications: [firstV2])
        let staleSpecificationObservation = try makeObservation(
            catalogID: catalogID,
            catalogRevision: 2,
            specifications: [firstV1]
        )
        XCTAssertThrowsError(try DebuggerLogicalBreakpointReconcileRequest(
            catalogAvailability: .available,
            catalog: revisedCatalog,
            observation: staleSpecificationObservation
        )) {
            XCTAssertEqual(
                $0 as? DebuggerLogicalBreakpointReconcileRequestError,
                .specificationCoverageMismatch
            )
        }
    }

    private let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let catalogID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let binaryID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let logicalA = DebuggerLogicalBreakpointID(
        rawValue: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    )
    private let logicalB = DebuggerLogicalBreakpointID(
        rawValue: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    )

    private func specification(
        id: DebuggerLogicalBreakpointID,
        revision: UInt64,
        address: UInt64
    ) throws -> DebuggerLogicalBreakpointSpecification {
        try DebuggerLogicalBreakpointSpecification(
            id: id,
            revision: DebuggerLogicalBreakpointRevision(validating: revision),
            enabled: true,
            target: .preferredAddress(
                owner: DebuggerWorkspaceImageOwnerSeal(
                    slot: .primary,
                    binaryID: binaryID,
                    artifactIdentity: nil
                ),
                preferredVA: address
            ),
            condition: nil,
            hitPolicy: .always,
            actions: [],
            disposition: .stop
        )
    }

    private func makeCatalog(
        catalogID: UUID? = nil,
        revision: UInt64,
        specifications: [DebuggerLogicalBreakpointSpecification]
    ) throws -> DebuggerLogicalBreakpointCatalog {
        try DebuggerLogicalBreakpointCatalog(
            catalogID: catalogID ?? self.catalogID,
            revision: revision,
            specifications: specifications
        )
    }

    private func makeObservation(
        catalogID: UUID,
        catalogRevision: UInt64,
        specifications: [DebuggerLogicalBreakpointSpecification]
    ) throws -> DebuggerBreakpointResolutionObservation {
        let mappingKey = DebuggerRuntimeMappingProjectionKey(
            stopCoordinate: DebuggerStopCoordinate(
                session: DebuggerSessionCoordinate(
                    epoch: .init(
                        rawValue: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
                    ),
                    lifecycleRevision: .init(rawValue: 2)
                ),
                stopRevision: .init(rawValue: 3)
            ),
            observedPID: 42,
            authorityRevision: .init(rawValue: 4),
            inventoryRevision: .init(rawValue: 5),
            workspaceCatalogRevision: .init(rawValue: 6)
        )
        let resolutionCoordinate = DebuggerBreakpointResolutionCatalogCoordinate(
            workspaceID: workspaceID,
            revision: .init(rawValue: 7),
            workspaceArtifactCatalogRevision: mappingKey.workspaceCatalogRevision
        )
        let expectations = specifications.reversed().map {
            DebuggerLogicalBreakpointResolutionExpectation(
                logicalID: $0.id,
                specificationRevision: $0.revision
            )
        }
        let results = specifications.reversed().map {
            DebuggerLogicalBreakpointResolution(
                logicalID: $0.id,
                specificationRevision: $0.revision,
                state: .pending(.moduleUnloaded)
            )
        }
        return try XCTUnwrap(DebuggerBreakpointResolutionObservation.make(
            logicalCatalogCoordinate: try DebuggerLogicalBreakpointCatalogCoordinate(
                workspaceID: workspaceID,
                catalogID: catalogID,
                revision: catalogRevision
            ),
            resolutionCatalogCoordinate: resolutionCoordinate,
            mappingKey: mappingKey,
            expectedSpecifications: expectations,
            results: results
        ))
    }

    private func requireSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}
