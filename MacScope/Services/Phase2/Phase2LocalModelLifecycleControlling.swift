import Foundation

/// App-owned seam for one explicit local-provider lifecycle transaction.
protocol Phase2LocalModelLifecycleControlling: Sendable {
    func perform(
        command: Phase2LocalModelLifecycleCommand,
        endpoint: Phase2LocalProviderEndpoint,
        acceptedInventory: Phase2LocalModelInventory
    ) async throws -> Phase2LocalModelLifecycleOutcome

    func cancel(effectID: UUID) async
}
