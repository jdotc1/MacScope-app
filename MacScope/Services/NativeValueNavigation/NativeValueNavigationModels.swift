// App-only, transient projections of existing validated NativeDecompilerWire records.
// No persistence, native-engine changes, secondary IR, or inferred memory aliases.
import Foundation

enum NativeValueNavigationDirection: String, CaseIterable, Sendable {
    case definitions
    case uses

    var title: String { self == .definitions ? "Definitions" : "Uses" }
}

/// Explicit cost limits. A limit produces an unavailable/partial presentation, never
/// a claim that an omitted relationship does not exist. Values are initial policy,
/// not measured M1 Max performance guarantees.
struct NativeValueNavigationLimits: Equatable, Sendable {
    var maximumIndexRecords = 300_000
    var maximumIndexReferences = 600_000
    var maximumOperations = 40_000
    var maximumValues = 80_000
    var maximumTokenReferences = 256
    var maximumContextOperations = 256
    var maximumCandidateScan = 8_192
    var maximumCandidates = 64
    var maximumVisitedValues = 512
    var maximumRows = 1_024
    var maximumDepth = 32
    var maximumSourceRanges = 32

    func validate() throws {
        let positive = [
            maximumIndexRecords, maximumIndexReferences, maximumOperations,
            maximumValues, maximumTokenReferences, maximumContextOperations,
            maximumCandidateScan, maximumCandidates, maximumVisitedValues,
            maximumRows, maximumSourceRanges
        ]
        guard positive.allSatisfy({ $0 > 0 && $0 <= 1_000_000 }),
              maximumDepth >= 0, maximumDepth <= 4_096 else {
            throw NativeValueNavigationFailure.invalidLimits
        }
    }
}

enum NativeValueNavigationFailure: Error, Equatable, Sendable {
    case invalidLimits
    case noStructuredValues
    case indexLimit(String)
    case duplicateRecord(String, String)
    case missingReference(String, String)
    case invalidBinding(String)
    case invalidSourceRange(String)
    case unknownToken
    case unknownValue
    case invalidSelection
}

enum NativeValueNavigationLimit: String, CaseIterable, Hashable, Sendable {
    case candidateCount
    case candidateScan
    case contextOperations
    case tokenReferences
    case visitedValues
    case rows
    case depth
    case sourceRanges

    var explanation: String {
        switch self {
        case .candidateCount: "More candidate values exist than this chooser displays."
        case .candidateScan: "The candidate scan reached its work limit."
        case .contextOperations: "The token references more operation contexts than this query admits."
        case .tokenReferences: "The token references more entities than this query admits."
        case .visitedValues: "The query reached its value limit."
        case .rows: "The query reached its relationship limit."
        case .depth: "The query reached its dependency-depth limit."
        case .sourceRanges: "Some source ranges are omitted from the presentation."
        }
    }
}

enum NativeValueNavigationSite: Hashable, Sendable {
    case operation(String)
    case phi(String)

    var recordID: String {
        switch self {
        case let .operation(id), let .phi(id): id
        }
    }
}

struct NativeValueNavigationCandidate: Equatable, Sendable, Identifiable {
    var id: String { ssaValueID }
    let ssaValueID: String
    let varnodeID: String
    let kind: NativeDecompilerWireSSAValueKind
    let registerName: String?
    let variableNames: [String]
    /// Labels refer to exact structured operation incidences, not parsed token text.
    let contexts: [String]
}

struct NativeValueNavigationCandidates: Equatable, Sendable {
    let tokenID: String
    let candidates: [NativeValueNavigationCandidate]
    let limitsReached: Set<NativeValueNavigationLimit>
    /// With no operation incidence, storage links cannot select a particular SSA version.
    let usesStorageAssociationOnly: Bool
    let explanation: String

    var requiresChoice: Bool {
        candidates.count != 1 || usesStorageAssociationOnly || !limitsReached.isEmpty
    }
}

enum NativeValueNavigationRelationship: String, Sendable {
    case definition
    case input
    case use
    case phiIncoming
}

/// Query-local row IDs are deterministic for the same immutable index/query/limits.
/// They are never usable without the containing report and publication identity.
struct NativeValueNavigationRow: Equatable, Sendable, Identifiable {
    let id: Int
    let site: NativeValueNavigationSite
    let siteLabel: String
    let valueID: String
    let relatedValueID: String?
    let relationship: NativeValueNavigationRelationship
    let depth: Int
    let operandIndex: Int?
    let predecessorBlockID: String?
    let incomingEdgeID: String?
    let sourceRanges: [NativeDecompilerWireSourceRange]
}

enum NativeValueNavigationBoundaryKind: String, Sendable {
    case functionEntry
    case constant
    case annotation
    case call
    case memory
    case authentication
    case opaqueOperation
    case terminalUse
    case noRecordedUse
}

struct NativeValueNavigationBoundary: Equatable, Sendable, Identifiable {
    let id: Int
    let valueID: String
    let site: NativeValueNavigationSite?
    let kind: NativeValueNavigationBoundaryKind
    let explanation: String

    var isUnknownBeyondBoundary: Bool {
        switch kind {
        case .call, .memory, .authentication, .opaqueOperation, .annotation: true
        case .functionEntry, .constant, .terminalUse, .noRecordedUse: false
        }
    }
}

struct NativeValueNavigationReport: Equatable, Sendable {
    let requestID: UUID
    let requestSHA256: String
    let imageID: String
    let functionID: String
    let seedValueID: String
    let direction: NativeValueNavigationDirection
    let rows: [NativeValueNavigationRow]
    let boundaries: [NativeValueNavigationBoundary]
    let visitedValueIDs: [String]
    let limitsReached: Set<NativeValueNavigationLimit>

    var hasUnknownBoundary: Bool { boundaries.contains { $0.isUnknownBeyondBoundary } }
    var isBudgetLimited: Bool { !limitsReached.isEmpty }
}

struct NativeValueNavigationUse: Equatable, Sendable {
    let site: NativeValueNavigationSite
    let inputIndex: Int
    let outputValueID: String?
    let predecessorBlockID: String?
    let incomingEdgeID: String?
}

/// Counts before admitting work; avoids overflow and checks cancellation during
/// index construction. This is an index cost guard, not a replacement wire validator.
struct NativeValueNavigationBuildBudget {
    let limits: NativeValueNavigationLimits
    var records = 0
    var references = 0
    let isCancelled: @Sendable () -> Bool

    mutating func addRecords(_ count: Int) throws {
        try checkCancellation()
        guard count >= 0, count <= limits.maximumIndexRecords - records else {
            throw NativeValueNavigationFailure.indexLimit("records")
        }
        records += count
    }

    mutating func addReferences(_ count: Int = 1) throws {
        try checkCancellation()
        guard count >= 0, count <= limits.maximumIndexReferences - references else {
            throw NativeValueNavigationFailure.indexLimit("references")
        }
        references += count
    }

    func checkCancellation() throws {
        if isCancelled() { throw CancellationError() }
    }
}
