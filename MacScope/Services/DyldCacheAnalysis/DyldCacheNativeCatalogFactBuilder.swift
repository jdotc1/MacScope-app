import Foundation

final class DyldCacheSupplementalCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var token: AnalysisCancellationToken {
        AnalysisCancellationToken { [weak self] in self?.isCancelled ?? true }
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Builds the native side of the dyld-cache differential from MacScope's authoritative parser.
/// The selected image is derived from the admitted cache header, never from `BinaryImage.path`
/// (which is presentation text for a projected image). The projected thin-Mach-O identity is then
/// reverified against the exact admitted cache bytes before any supplemental request is issued.
protocol DyldCacheNativeCatalogFactBuilding: Sendable {
    func build(
        sourceURL: URL,
        artifactIdentity: MachOSliceArtifactIdentity,
        cancellation: AnalysisCancellationToken
    ) throws -> DyldCacheNativeCatalogFacts
}

struct DyldCacheNativeCatalogFactBuilder: DyldCacheNativeCatalogFactBuilding {
    private let parser: DyldSharedCacheParser

    init(parser: DyldSharedCacheParser = DyldSharedCacheParser()) {
        self.parser = parser
    }

    func build(
        sourceURL: URL,
        artifactIdentity: MachOSliceArtifactIdentity,
        cancellation: AnalysisCancellationToken = .never
    ) throws -> DyldCacheNativeCatalogFacts {
        try cancellation.check()
        let sourceURL = sourceURL.standardizedFileURL
        let sourceIdentity = try DyldCacheSourceIdentityReader.identity(for: sourceURL)
        let preflight = try DyldCacheSourcePreflight.inspect(
            mainURL: sourceURL,
            expectedMainIdentity: sourceIdentity,
            // This is the authoritative MacScope side of the differential. Vendor-specific
            // read-surface admission belongs to the supplemental worker and must not prevent
            // native facts from being constructed for a cache MacScope already loaded.
            requestedCategories: [],
            parser: parser
        )
        try cancellation.check()

        guard let selectedImage = preflight.header.images.first(where: { !$0.path.isEmpty })
            ?? preflight.header.images.first else {
            throw DyldCacheAnalysisProviderError.providerRejectedInput
        }
        let imageIdentity = DyldCacheImageIdentity(
            path: selectedImage.path,
            loadAddress: selectedImage.address
        )
        let validationSubject = DyldCacheAnalysisSubjectIdentity(
            artifactIdentity: artifactIdentity,
            imageIdentity: imageIdentity,
            analysisGeneration: 1
        )
        _ = try validationSubject.validated()
        try preflight.validateSelectedArtifact(validationSubject, parser: parser)
        try cancellation.check()

        return DyldCacheNativeCatalogFacts(
            sourceURL: sourceURL,
            artifactIdentity: artifactIdentity,
            imageIdentity: imageIdentity,
            images: try preflight.header.images.map {
                try DyldCacheImageIdentity(path: $0.path, loadAddress: $0.address).validated()
            },
            mappings: preflight.header.mappings.map {
                DyldCacheComparableMapping(
                    address: $0.address,
                    size: $0.size,
                    fileOffset: $0.fileOffset,
                    sourceFileIndex: 0,
                    maximumProtection: $0.maxProtection,
                    initialProtection: $0.initialProtection,
                    flags: 0
                )
            }
        )
    }
}
