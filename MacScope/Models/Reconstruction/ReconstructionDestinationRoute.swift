import Foundation

/// Restorable, value-only identity for one native Reconstruction destination.
/// Runtime and persistence capabilities are deliberately absent from the route.
struct ReconstructionDestinationRoute: Hashable, Codable, Sendable {
    let workspaceID: UUID
    let durableJobID: UUID?

    init(workspaceID: UUID, durableJobID: UUID? = nil) {
        self.workspaceID = workspaceID
        self.durableJobID = durableJobID
    }

    var isEmptyWorkspaceDestination: Bool {
        durableJobID == nil
    }
}
