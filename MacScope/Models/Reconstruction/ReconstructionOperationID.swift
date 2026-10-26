import Foundation

/// Stable reconstruction operation vocabulary.
///
/// Declaration order is the retrieval priority. Persisted evidence and gap rows continue to store
/// `rawValue`; this type is deliberately not coupled to any Assistant or worker registry.
enum ReconstructionOperationID: String, Codable, CaseIterable, Hashable, Sendable {
    case corpusSummary = "reconstruction.corpus.summary"
    case corpusArtifactsPage = "reconstruction.corpus.artifacts.page"
    case corpusArtifactDescribe = "reconstruction.corpus.artifact.describe"
    case corpusRelationsPage = "reconstruction.corpus.relations.page"
    case corpusSearch = "reconstruction.corpus.search"
    case imagesPage = "reconstruction.images.page"
    case functionsPage = "reconstruction.functions.page"
    case functionReview = "reconstruction.function.review"
    case decompilerNative = "reconstruction.decompiler.native"
    case decompilerMacScope = "reconstruction.decompiler.macscope"
    case decompilerCompare = "reconstruction.decompiler.compare"
    case evidenceQuery = "reconstruction.evidence.query"
    case evidenceGet = "reconstruction.evidence.get"
    case gapsPage = "reconstruction.gaps.page"
    case checkpointStatus = "reconstruction.checkpoint.status"
    case analysisMacScopeRefresh = "reconstruction.analysis.macscope.refresh"

    case sourceRevision = "reconstruction.source.revision"
    case sourceOracle = "reconstruction.source.oracle"
    case sourceEvaluate = "reconstruction.source.evaluate"

    /// Persisted source authority is never an ordinary worker read-tool handle.
    var isDurableSourceOperation: Bool {
        self == .sourceRevision || self == .sourceOracle || self == .sourceEvaluate
    }

    var priority: Int {
        switch self {
        case .corpusSummary: 0
        case .corpusArtifactsPage: 1
        case .corpusArtifactDescribe: 2
        case .corpusRelationsPage: 3
        case .corpusSearch: 4
        case .imagesPage: 5
        case .functionsPage: 6
        case .functionReview: 7
        case .decompilerNative: 8
        case .decompilerMacScope: 9
        case .decompilerCompare: 10
        case .evidenceQuery: 11
        case .evidenceGet: 12
        case .gapsPage: 13
        case .checkpointStatus: 14
        case .analysisMacScopeRefresh: 15
        case .sourceRevision: 16
        case .sourceOracle: 17
        case .sourceEvaluate: 18
        }
    }
}
