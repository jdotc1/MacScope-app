import Foundation

enum DebuggerLogicalBreakpointReconcileRequestError: Error, Equatable, Sendable {
    case catalogUnavailable
    case logicalCatalogCoordinateMismatch
    case specificationCoverageMismatch
    case noncanonicalObservation
}

/// Complete immutable authority handed to one logical-breakpoint reconciliation boundary.
///
/// This value deliberately has no `Codable` conformance, rendered plan, wire payload, or backend
/// command field. The durable authored catalog and its canonical pure resolution observation remain
/// paired until a later reducer-owned boundary derives and admits an exact-stop backend plan.
struct DebuggerLogicalBreakpointReconcileRequest: Hashable, Sendable {
    let catalog: DebuggerLogicalBreakpointCatalog
    let observation: DebuggerBreakpointResolutionObservation

    init(
        catalogAvailability: DebuggerLogicalBreakpointCatalogAvailability,
        catalog: DebuggerLogicalBreakpointCatalog,
        observation: DebuggerBreakpointResolutionObservation
    ) throws {
        guard catalogAvailability == .available else {
            throw DebuggerLogicalBreakpointReconcileRequestError.catalogUnavailable
        }
        guard observation.logicalCatalogCoordinate.catalogID == catalog.catalogID,
              observation.logicalCatalogCoordinate.revision == catalog.revision else {
            throw DebuggerLogicalBreakpointReconcileRequestError
                .logicalCatalogCoordinateMismatch
        }

        let catalogCoverage = Set(catalog.specifications.map {
            DebuggerLogicalBreakpointResolutionExpectation(
                logicalID: $0.id,
                specificationRevision: $0.revision
            )
        })
        let observedCoverage = Set(observation.expectedSpecifications)
        guard catalogCoverage.count == catalog.specifications.count,
              observedCoverage.count == observation.expectedSpecifications.count,
              catalogCoverage == observedCoverage else {
            throw DebuggerLogicalBreakpointReconcileRequestError
                .specificationCoverageMismatch
        }

        guard let rebuilt = DebuggerBreakpointResolutionObservation.make(
            logicalCatalogCoordinate: observation.logicalCatalogCoordinate,
            resolutionCatalogCoordinate: observation.resolutionCatalogCoordinate,
            mappingKey: observation.mappingKey,
            expectedSpecifications: observation.expectedSpecifications,
            results: observation.results
        ), rebuilt == observation else {
            throw DebuggerLogicalBreakpointReconcileRequestError.noncanonicalObservation
        }

        self.catalog = catalog
        self.observation = observation
    }
}
