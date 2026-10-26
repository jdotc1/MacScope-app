import Foundation

/// Declarative, read-only assessment of Mach-O library loading. No candidate outside the
/// caller's bundle is probed; `notChecked` is an evidence state, not an absence claim.
struct LoadPathRiskReport: Codable, Sendable {
    var bundleRoot: String?
    var images: [Image]
    var assumptions: [String]

    struct Image: Codable, Sendable {
        var path: String
        var role: Role
        var platform: String
        var resolution: [Resolution]
        var findings: [Finding]
        var entitlementState: String? = nil
        var privilege: Privilege? = nil
        var priority: Priority? = nil
    }

    struct Privilege: Codable, Sendable {
        enum Kind: String, Codable, Sendable { case root, user, unknown }
        var kind: Kind
        var sources: [String]
        var reason: String
    }

    struct Priority: Codable, Sendable {
        enum Level: String, Codable, Sendable { case high, review, informational }
        var level: Level
        var reason: String
    }

    /// Optional caller-supplied evidence. The analyzer never probes outside the bundle.
    /// A non-root writer and an existing candidate must be established independently.
    struct CandidateAccessEvidence: Sendable {
        var path: String
        var writerUserID: UInt32
        var exists: Bool
        var source: String
    }

    enum Role: String, Codable, Sendable {
        case mainExecutable, framework, plugIn, helper, library
    }

    struct Command: Codable, Sendable, Hashable {
        var index: Int
        var name: String
        var rawString: String
    }

    struct Resolution: Codable, Sendable {
        var dependency: Command
        var candidate: String
        var searchOrder: Int
        var rpath: Command?
        var location: Location
        var existence: Existence
        var note: String?
        /// Set only for a present in-bundle candidate. A matching CPU type does not establish dyld loadability.
        var architectureAssessment: ArchitectureAssessment? = nil
    }

    enum ArchitectureAssessment: String, Codable, Sendable {
        case matchingCPUType = "matching-cpu-type"
        case differentCPUType = "different-cpu-type"
        case unassessed
    }

    enum Location: String, Codable, Sendable {
        case bundle, sealedSystem, elsewhere, unresolved
    }

    enum Existence: String, Codable, Sendable {
        case present, absent, notChecked
    }

    struct Finding: Codable, Sendable {
        var ruleID: String
        var severity: Severity
        var confidence: Confidence
        var confidenceReason: String
        var reason: String
        var mitigation: String?
        var commands: [Command]
    }

    enum Severity: String, Codable, Sendable {
        case high, medium, low, informational
    }

    enum Confidence: String, Codable, Sendable {
        case definite
        case needsReview = "needs-review"
        case needsPhaseB = "needs-phase-B"
    }
}

/// Rules are data rather than switch-local prose, so consumers can display the full
/// condition and weakening criteria alongside any finding.
struct LoadPathRiskRule: Sendable {
    let id: String
    let condition: String
    let severity: LoadPathRiskReport.Severity
    let reason: String
    let weakenedBy: String
}

enum LoadPathRiskCatalog {
    static let rules: [LoadPathRiskRule] = [
        .init(id: "L1", condition: "Weak library has no in-bundle candidate and is not a sealed-system path", severity: .medium, reason: "An absent weak dependency can later be supplied by a different party.", weakenedBy: "A known sealed-system library, a bundled file, or enforced library validation."),
        .init(id: "L2", condition: "An unsealed outside @rpath candidate precedes a present bundled candidate", severity: .high, reason: "The earlier runpath can select a different copy first.", weakenedBy: "Enforced library validation or a path known to be unavailable or unwritable."),
        .init(id: "L3", condition: "Dependency or LC_RPATH is relative to the working directory or empty", severity: .medium, reason: "Its interpretation depends on process launch context.", weakenedBy: "A fixed launch directory and validated path ownership."),
        .init(id: "L4", condition: "Dependency or LC_RPATH names an absolute path outside sealed system and bundle", severity: .medium, reason: "The declared location may be controlled outside the bundle.", weakenedBy: "Enforced library validation or independently established filesystem ownership."),
        .init(id: "L5", condition: "LC_DYLD_ENVIRONMENT declares a dyld variable", severity: .medium, reason: "A dyld setting can affect library selection when the loader honors it.", weakenedBy: "Restricted execution or hardened runtime without a true allow-dyld-environment-variables entitlement."),
        .init(id: "L6", condition: "Re-export or upward dependency resolves outside the bundle", severity: .medium, reason: "The exported library graph crosses the bundle trust boundary.", weakenedBy: "Enforced library validation or a sealed-system destination."),
        .init(id: "L7", condition: "Bundled library LC_ID_DYLIB differs from its found path", severity: .informational, reason: "The install name can explain a different copy selected by dyld.", weakenedBy: "An intentional relocation with independently verified loader resolution.")
    ]
}
