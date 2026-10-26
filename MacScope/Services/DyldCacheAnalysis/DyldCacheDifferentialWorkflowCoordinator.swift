import Foundation

/// Native facts already established by MacScope's authoritative cache loader. The supplemental
/// provider may compare with these values, but it cannot replace the selected bytes, address map,
/// artifact identity, or workspace state.
struct DyldCacheNativeCatalogFacts: Equatable, Sendable {
    let sourceURL: URL
    let artifactIdentity: MachOSliceArtifactIdentity
    let imageIdentity: DyldCacheImageIdentity
    let images: [DyldCacheImageIdentity]
    let mappings: [DyldCacheComparableMapping]
}

struct DyldCacheDifferentialWorkflowBinding: Equatable, Sendable {
    let sourceIdentity: DyldCacheFileIdentity
    let subject: DyldCacheAnalysisSubjectIdentity
}

enum DyldCacheDifferentialWorkflowState: Equatable, Sendable {
    case agreement
    case supplementalOnly
    case nativeOnly
    case disagreement
    case partial
    case invalid
    case error
}

/// Stable app-owned error vocabulary. Provider implementation details, paths, and raw diagnostics
/// never cross this publication seam.
enum DyldCacheDifferentialWorkflowFailure: Equatable, Sendable {
    case generationExhausted
    case sourceUnavailable
    case sourceChanged
    case sourceIdentityMismatch
    case subjectIdentityMismatch
    case staleGeneration
    case providerUnavailable
    case providerRejectedInput
    case outputLimitExceeded
    case cancelled
    case timeout
    case workerCrashed
    case workerUnavailable
    case malformedReply
    case versionMismatch
    case unexpected
}

/// The only value published by the workflow. In particular, the raw MachOKit-backed provider
/// result is intentionally absent: callers receive exact request binding plus a MacScope-owned
/// comparison or a closed failure classification.
struct DyldCacheDifferentialWorkflowReport: Equatable, Sendable {
    let state: DyldCacheDifferentialWorkflowState
    let binding: DyldCacheDifferentialWorkflowBinding?
    let differential: DyldCacheCatalogDifferentialReport?
    let failure: DyldCacheDifferentialWorkflowFailure?

    fileprivate static func comparison(
        binding: DyldCacheDifferentialWorkflowBinding,
        differential: DyldCacheCatalogDifferentialReport
    ) -> Self {
        let state: DyldCacheDifferentialWorkflowState
        switch differential.state {
        case .agreement: state = .agreement
        case .supplementalOnly: state = .supplementalOnly
        case .nativeOnly: state = .nativeOnly
        case .disagreement: state = .disagreement
        case .uncomparable: state = .partial
        case .invalid: state = .invalid
        }
        return Self(
            state: state,
            binding: binding,
            differential: differential,
            failure: nil
        )
    }

    fileprivate static func error(
        binding: DyldCacheDifferentialWorkflowBinding?,
        failure: DyldCacheDifferentialWorkflowFailure
    ) -> Self {
        Self(state: .error, binding: binding, differential: nil, failure: failure)
    }
}

/// App-side callable workflow for the supplemental MachOKit lane.
///
/// Actor isolation makes generation allocation and late-result rejection one operation. A newer
/// inspection supersedes an older in-flight inspection; even a provider reply that correctly
/// echoes the older request is rejected before comparison or publication.
actor DyldCacheDifferentialWorkflowCoordinator {
    typealias SourceIdentityReader = @Sendable (URL) throws -> DyldCacheFileIdentity

    private let provider: any DyldCacheAnalysisProviding
    private let comparator: DyldCacheCatalogDifferentialComparator
    private let readSourceIdentity: SourceIdentityReader
    private var latestGeneration: UInt64

    init(
        provider: any DyldCacheAnalysisProviding,
        comparator: DyldCacheCatalogDifferentialComparator = .init(),
        initialGeneration: UInt64 = 0,
        readSourceIdentity: @escaping SourceIdentityReader =
            DyldCacheSourceIdentityReader.identity(for:)
    ) {
        self.provider = provider
        self.comparator = comparator
        self.latestGeneration = initialGeneration
        self.readSourceIdentity = readSourceIdentity
    }

    func inspect(
        native: DyldCacheNativeCatalogFacts,
        categories: [DyldCacheAnalysisCategory] = [.catalog, .mappings],
        limits: DyldCacheAnalysisLimits = .default,
        cancellation: AnalysisCancellationToken = .never
    ) async -> DyldCacheDifferentialWorkflowReport {
        let increment = latestGeneration.addingReportingOverflow(1)
        guard !increment.overflow, increment.partialValue > 0 else {
            return .error(binding: nil, failure: .generationExhausted)
        }
        let generation = increment.partialValue
        latestGeneration = generation

        let sourceIdentity: DyldCacheFileIdentity
        do {
            sourceIdentity = try readSourceIdentity(native.sourceURL.standardizedFileURL)
        } catch {
            return .error(binding: nil, failure: Self.classify(error))
        }

        let subject = DyldCacheAnalysisSubjectIdentity(
            artifactIdentity: native.artifactIdentity,
            imageIdentity: native.imageIdentity,
            analysisGeneration: generation
        )
        do {
            _ = try subject.validated()
        } catch {
            return .error(binding: nil, failure: .subjectIdentityMismatch)
        }
        let binding = DyldCacheDifferentialWorkflowBinding(
            sourceIdentity: sourceIdentity,
            subject: subject
        )

        let result: DyldCacheAnalysisResult
        do {
            result = try await provider.inspectCache(
                at: native.sourceURL.standardizedFileURL,
                expectedSourceIdentity: sourceIdentity,
                subject: subject,
                categories: categories,
                limits: limits,
                cancellation: cancellation
            )
        } catch {
            return .error(binding: binding, failure: Self.classify(error))
        }

        // The provider contract validates these fields too. Rechecking at the publication seam is
        // intentional: an injected/headless provider cannot bypass app-owned authority, and actor
        // reentrancy cannot allow an older successful request to publish after a newer one starts.
        let recapturedSourceIdentity: DyldCacheFileIdentity
        do {
            recapturedSourceIdentity = try readSourceIdentity(native.sourceURL.standardizedFileURL)
        } catch {
            return .error(binding: binding, failure: Self.classify(error))
        }
        guard recapturedSourceIdentity == sourceIdentity else {
            return .error(binding: binding, failure: .sourceChanged)
        }
        guard generation == latestGeneration else {
            return .error(binding: binding, failure: .staleGeneration)
        }
        guard result.subject.analysisGeneration == generation else {
            return .error(binding: binding, failure: .staleGeneration)
        }
        guard result.subject.artifactIdentity == subject.artifactIdentity,
              result.subject.imageIdentity == subject.imageIdentity else {
            return .error(binding: binding, failure: .subjectIdentityMismatch)
        }
        guard result.sourceIdentity == sourceIdentity else {
            return .error(binding: binding, failure: .sourceIdentityMismatch)
        }
        guard result.version == DyldCacheAnalysisResult.schemaVersion,
              result.provider == .machOKit0522 else {
            return .error(binding: binding, failure: .providerRejectedInput)
        }

        return .comparison(
            binding: binding,
            differential: comparator.compare(
                nativeImages: native.images,
                nativeMappings: native.mappings,
                provider: result
            )
        )
    }

    private nonisolated static func classify(
        _ error: Error
    ) -> DyldCacheDifferentialWorkflowFailure {
        if error is AnalysisCancelled || error is CancellationError { return .cancelled }
        if let error = error as? DyldCacheAnalysisProviderError {
            switch error {
            case .sourceIsNotRegularFile: return .sourceUnavailable
            case .sourceIdentityMismatch: return .sourceIdentityMismatch
            case .subjectIdentityMismatch: return .subjectIdentityMismatch
            case .staleGeneration: return .staleGeneration
            case .unsafeSubcacheSuffix, .providerRejectedInput: return .providerRejectedInput
            case .sourceChangedDuringInspection: return .sourceChanged
            case .providerUnavailable: return .providerUnavailable
            case .outputLimitExceeded: return .outputLimitExceeded
            case .cancelled: return .cancelled
            case .timeout: return .timeout
            }
        }
        if let error = error as? AnalysisWorkerError {
            switch error {
            case .workerCrashed: return .workerCrashed
            case .workerUnavailable: return .workerUnavailable
            case .malformedReply: return .malformedReply
            case .versionMismatch: return .versionMismatch
            }
        }
        if let error = error as? RemoteDyldCacheAnalysisFailure {
            switch error.code {
            case .cancelled: return .cancelled
            case .timeout: return .timeout
            case .sourceIdentityMismatch: return .sourceIdentityMismatch
            case .subjectIdentityMismatch: return .subjectIdentityMismatch
            case .staleGeneration: return .staleGeneration
            case .sourceChanged: return .sourceChanged
            case .providerUnavailable: return .providerUnavailable
            case .outputLimitExceeded: return .outputLimitExceeded
            case .malformedRequest, .invalidRequest, .providerRejectedInput:
                return .providerRejectedInput
            case .unexpectedFailure: return .unexpected
            }
        }
        return .unexpected
    }
}
