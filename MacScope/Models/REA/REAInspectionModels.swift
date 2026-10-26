import Foundation

/// The only entry points exposed by the app-owned, pinned REA resource.
enum REAInspectionOperation: String, Codable, CaseIterable, Sendable {
    case nativeApplication
    case uiResources
    case processComparison
}

struct REAInspectionHeader: Equatable, Sendable {
    let requestID: UUID
    let operation: REAInspectionOperation
}

enum REAInspectionLimits {
    static let maximumRequestBytes = 16 * 1_024 * 1_024
    static let maximumResponseBytes = 8 * 1_024 * 1_024
    static let maximumDepth = 96
    static let maximumValues = 500_000
    static let maximumDurationSeconds: TimeInterval = 30
    static let maximumDecodedResourceBytes = 32 * 1_024 * 1_024
}
