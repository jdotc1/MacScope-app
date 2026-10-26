import Foundation

/// App-owned asynchronous seam for supplemental dyld-cache metadata inspection.
///
/// `LoadedBinary` remains authoritative for selected bytes and address translation. A provider
/// result is accepted only when it returns the caller's exact source, artifact/slice, image, and
/// analysis-generation identity.
protocol DyldCacheAnalysisProviding: Sendable {
    func inspectCache(
        at url: URL,
        expectedSourceIdentity: DyldCacheFileIdentity,
        subject: DyldCacheAnalysisSubjectIdentity,
        categories: [DyldCacheAnalysisCategory],
        limits: DyldCacheAnalysisLimits,
        cancellation: AnalysisCancellationToken
    ) async throws -> DyldCacheAnalysisResult
}

/// Synchronous worker-side seam. Third-party pointer-bearing models and mapped storage must remain
/// behind this boundary; only MacScope-owned value records may be returned.
protocol DyldCacheAnalysisWorkerProviding: Sendable {
    func inspectCache(
        request: DyldCacheAnalysisRequest,
        cancellation: AnalysisCancellationToken
    ) throws -> DyldCacheAnalysisResult
}

struct DyldCacheAnalysisRequest: Equatable, Sendable {
    let url: URL
    let expectedSourceIdentity: DyldCacheFileIdentity
    let subject: DyldCacheAnalysisSubjectIdentity
    let categories: [DyldCacheAnalysisCategory]
    let limits: DyldCacheAnalysisLimits
    let requestID: UUID

    func validated() throws -> Self {
        guard url.isFileURL,
              url.path.hasPrefix("/"),
              !url.path.utf8.contains(0) else {
            throw DyldCacheAnalysisModelError.invalidPath
        }
        _ = try expectedSourceIdentity.validated()
        _ = try subject.validated()
        _ = try limits.validated()
        guard !categories.isEmpty else {
            throw DyldCacheAnalysisModelError.emptyCategorySelection
        }

        var observed: Set<DyldCacheAnalysisCategory> = []
        for category in categories where !observed.insert(category).inserted {
            throw DyldCacheAnalysisModelError.duplicateCategory(category)
        }
        let canonical = DyldCacheAnalysisCategory.allCases.filter(observed.contains)
        return Self(
            url: url.standardizedFileURL,
            expectedSourceIdentity: expectedSourceIdentity,
            subject: subject,
            categories: canonical,
            limits: limits,
            requestID: requestID
        )
    }

    /// Refuses late or cross-request replies before supplemental facts reach app-owned state.
    func validate(result: DyldCacheAnalysisResult) throws -> DyldCacheAnalysisResult {
        guard result.version == DyldCacheAnalysisResult.schemaVersion,
              result.requestID == requestID,
              result.provider == .machOKit0522 else {
            throw DyldCacheAnalysisProviderError.providerRejectedInput
        }
        guard result.subject.analysisGeneration == subject.analysisGeneration else {
            throw DyldCacheAnalysisProviderError.staleGeneration
        }
        guard result.subject.artifactIdentity == subject.artifactIdentity,
              result.subject.imageIdentity == subject.imageIdentity else {
            throw DyldCacheAnalysisProviderError.subjectIdentityMismatch
        }
        guard result.sourceIdentity == expectedSourceIdentity else {
            throw DyldCacheAnalysisProviderError.sourceIdentityMismatch
        }
        return try result.validated(requestedCategories: categories, limits: limits)
    }
}

struct UnavailableDyldCacheAnalysisWorkerProvider: DyldCacheAnalysisWorkerProviding {
    func inspectCache(
        request: DyldCacheAnalysisRequest,
        cancellation: AnalysisCancellationToken
    ) throws -> DyldCacheAnalysisResult {
        _ = try request.validated()
        try cancellation.check()
        throw DyldCacheAnalysisProviderError.providerUnavailable
    }
}
