import Foundation

enum Phase2LocalModelDiscoveryOutcome: Equatable, Sendable {
    case success(Phase2LocalModelInventory)
    case authenticationRequired
    case unavailable
    case incompatible
    case cancelled
}

/// Provider-neutral app seam for observational model discovery. Implementations may neither select
/// nor load/unload a model, and cancellation is bound to the app-issued request identity.
protocol Phase2LocalModelDiscovering: Sendable {
    func discoverModels(
        endpoint: Phase2LocalProviderEndpoint,
        requestID: UUID
    ) async throws -> Phase2LocalModelDiscoveryOutcome

    func cancel(requestID: UUID) async
}
