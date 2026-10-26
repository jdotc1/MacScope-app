import Foundation

/// The seam between the workspace layer and WHOEVER performs binary analysis.
///
/// `WorkspaceStore` (and the headless launchers) talk to this protocol, not to
/// `AnalysisEngine` directly, so the analysis implementation can move out of process (an XPC
/// worker, WS-3 Stage 3) without touching the store: crash isolation becomes a swap of the
/// injected provider, never a rewrite of the callers. `AnalysisEngine` is the in-process
/// implementation and remains the only one the golden/reference oracles run against.
///
/// Contract notes for implementors (binding for the XPC provider):
/// - `analyze` is the SYNCHRONOUS core. The scripting/headless path calls it inline for
///   deterministic mutate-then-query; an out-of-process implementation may bridge by blocking
///   on its async transport, but must preserve synchronous completion semantics.
/// - `openBinary` is the interactive entry. It must observe BOTH cooperative signals: the
///   explicit `cancellation` token AND `Task.isCancelled` of the calling task (the store
///   cancels its retained import/reanalysis tasks; that must halt remote work too).
/// - Cancellation surfaces as `AnalysisCancelled`; callers treat it as benign. Any transport
///   failure must map to a thrown error, never a hung call.
/// - The returned snapshot must satisfy the same invariants as a fresh in-process analysis
///   (exact selected-slice payload, bounded hex window, primary-slot-qualified overrides).
protocol AnalysisProviding: Sendable {
    /// Synchronous analysis of the binary at `url`, honoring the user's fat-slice pick and
    /// the authoring overrides that re-drive analysis (mark-as-code/data/procedure).
    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot

    /// Format-neutral production overload. A default implementation keeps existing Mach-O-only
    /// test doubles source-compatible; archive selection is rejected unless a production provider
    /// explicitly carries it across its boundary.
    func analyze(
        url: URL,
        selection: BinaryLoadSelection,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot

    /// Async analysis for the interactive paths (initial import, background re-analysis).
    /// Must fold the calling task's cancellation into the cooperative token.
    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot

    func openBinary(
        url: URL,
        selection: BinaryLoadSelection,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot

    /// WS-5: reconstruct an image's byte-derived products from its persisted slice `imageBytes`
    /// WITHOUT re-decoding, preserving the persisted analysis. The bytes come from a package the
    /// user opened and the format loaders parse them, so they are hostile input: since MS-18 the
    /// out-of-process provider runs rehydrate in the analysis worker (`XPCAnalysisProvider+Rehydrate`).
    /// Only the in-process engine, and test doubles that inherit the default below, load in-process.
    func rehydrate(
        imageBytes: Data,
        requestedSliceIndex: Int?,
        preserving persisted: ImageAnalysis,
        cancellation: AnalysisCancellationToken
    ) throws -> ImageAnalysis

    /// Image-local authoring must accompany reload's table reads. The old overload
    /// remains source-compatible for providers and callers with no authoring inputs.
    func rehydrate(
        imageBytes: Data,
        requestedSliceIndex: Int?,
        preserving persisted: ImageAnalysis,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> ImageAnalysis

    /// Saved COFF coordinate policy is explicit; nil is reserved for fresh/default callers.
    func rehydrate(imageBytes: Data, requestedSliceIndex: Int?, preserving persisted: ImageAnalysis,
                   overrides: [UInt64: AddressOverride], coffSectionLayoutVersion: Int?,
                   cancellation: AnalysisCancellationToken) throws -> ImageAnalysis

}

/// Worker-only capability for the slim reopen protocol. It accepts captured loader inputs,
/// never persisted analysis products. An injected provider must opt in explicitly; the worker
/// must not substitute a fresh AnalysisEngine when its provider lacks this capability.
protocol RehydrationLoaderProductsProviding: AnalysisProviding {
    func rehydrateLoaderProducts(
        imageBytes: Data,
        requestedSliceIndex: Int?,
        requestID: UUID,
        cancellation: AnalysisCancellationToken
    ) throws -> RehydrationLoaderProducts

    func rehydrateLoaderProducts(imageBytes: Data, requestedSliceIndex: Int?, requestID: UUID,
                                 coffSectionLayoutVersion: Int?,
                                 cancellation: AnalysisCancellationToken) throws -> RehydrationLoaderProducts

}

/// Optional capability for providers that can preserve an already-open source across a process
/// boundary. Callers must keep the handle alive until the operation completes.
protocol PinnedAnalysisInputProviding: AnalysisProviding {
    func openPinnedBinary(
        url: URL,
        source: FileHandle,
        selection: BinaryLoadSelection,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot
}

extension AnalysisProviding {
    func analyze(
        url: URL,
        selection: BinaryLoadSelection,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        guard selection.elfArchiveMember == nil else {
            throw BinaryLoadSelectionError.archiveSelectionUnsupported
        }
        guard selection.coffSectionLayoutVersion == nil else { throw BinaryLoadSelectionError.coffSectionLayoutUnsupported }
        guard selection.dyldCacheImagePath == nil else {
            throw BinaryLoadSelectionError.dyldCacheImageSelectionUnsupported
        }
        return try analyze(
            url: url,
            requestedSliceIndex: selection.requestedMachOSliceIndex,
            overrides: overrides,
            cancellation: cancellation
        )
    }

    func openBinary(
        url: URL,
        selection: BinaryLoadSelection,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        guard selection.elfArchiveMember == nil else {
            throw BinaryLoadSelectionError.archiveSelectionUnsupported
        }
        guard selection.coffSectionLayoutVersion == nil else { throw BinaryLoadSelectionError.coffSectionLayoutUnsupported }
        guard selection.dyldCacheImagePath == nil else {
            throw BinaryLoadSelectionError.dyldCacheImageSelectionUnsupported
        }
        return try await openBinary(
            url: url,
            requestedSliceIndex: selection.requestedMachOSliceIndex,
            overrides: overrides,
            cancellation: cancellation
        )
    }

    func rehydrate(imageBytes: Data, requestedSliceIndex: Int?, preserving persisted: ImageAnalysis,
                   overrides: [UInt64: AddressOverride], coffSectionLayoutVersion: Int?,
                   cancellation: AnalysisCancellationToken) throws -> ImageAnalysis {
        guard coffSectionLayoutVersion == nil else { throw BinaryLoadSelectionError.coffSectionLayoutUnsupported }
        return try rehydrate(imageBytes: imageBytes, requestedSliceIndex: requestedSliceIndex,
            preserving: persisted, overrides: overrides, cancellation: cancellation)
    }

    func rehydrate(
        imageBytes: Data,
        requestedSliceIndex: Int?,
        preserving persisted: ImageAnalysis,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> ImageAnalysis {
        // Keep existing injected providers' reload behavior for an unpatched image.
        guard overrides.values.contains(where: { !($0.patch?.isEmpty ?? true) }) else {
            return try rehydrate(imageBytes: imageBytes, requestedSliceIndex: requestedSliceIndex,
                                 preserving: persisted, cancellation: cancellation)
        }
        return try AnalysisEngine().rehydrate(
            imageBytes: imageBytes, requestedSliceIndex: requestedSliceIndex,
            preserving: persisted, overrides: overrides, cancellation: cancellation
        )
    }

    /// Default for in-process providers and test doubles: run the loaders through a local engine.
    /// `AnalysisEngine`'s own concrete method overrides this for the in-process engine, and
    /// `XPCAnalysisProvider` overrides it to run in the analysis worker (MS-18).
    func rehydrate(
        imageBytes: Data,
        requestedSliceIndex: Int?,
        preserving persisted: ImageAnalysis,
        cancellation: AnalysisCancellationToken
    ) throws -> ImageAnalysis {
        try AnalysisEngine().rehydrate(
            imageBytes: imageBytes, requestedSliceIndex: requestedSliceIndex,
            preserving: persisted, cancellation: cancellation
        )
    }
}

/// `AnalysisEngine` is the in-process provider; its existing methods already match the
/// protocol requirements exactly (the engine's default arguments are a convenience of the
/// concrete type and do not participate in conformance).
extension AnalysisEngine: RehydrationLoaderProductsProviding {}


extension RehydrationLoaderProductsProviding {
    func rehydrateLoaderProducts(imageBytes: Data, requestedSliceIndex: Int?, requestID: UUID,
                                 coffSectionLayoutVersion: Int?,
                                 cancellation: AnalysisCancellationToken) throws -> RehydrationLoaderProducts {
        guard coffSectionLayoutVersion == nil else { throw BinaryLoadSelectionError.coffSectionLayoutUnsupported }
        return try rehydrateLoaderProducts(imageBytes: imageBytes, requestedSliceIndex: requestedSliceIndex,
            requestID: requestID, cancellation: cancellation)
    }
}
