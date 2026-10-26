import Foundation

/// Objective-C-visible wire contract exported by the bundled analysis-worker service.
///
/// Both directions deliberately use Foundation value types that `NSXPCInterface` can carry.
/// `requestData` and the reply are the existing `PayloadWireCodec` envelopes; the XPC layer does
/// not decode or reinterpret them.
@objc protocol AnalysisWorkerXPCProtocol {
    /// Foundations only: optional for legacy peers; no native activation is implied.
    @objc optional func workerControlChallenge(challenge: UUID, with reply: @escaping (Data) -> Void)
    @objc optional func workerControlTerminate(expectedNonce: UUID, challenge: UUID,
                                               with reply: @escaping (Data) -> Void)

    /// New bounded read-only pattern interpretation lane.
    func interpretPattern(requestData: Data, requestID: UUID, with reply: @escaping (Data) -> Void)
    func cancelPatternInterpretation(requestID: UUID)

    /// Starts one analysis request and returns exactly one encoded worker reply.
    func analyze(
        requestData: Data,
        requestID: UUID,
        with reply: @escaping (Data) -> Void
    )

    /// Analyzes the exact already-open source descriptor transferred by the caller. The worker
    /// must use this handle and must not reopen `requestData`'s path.
    func analyzePinned(
        requestData: Data,
        requestID: UUID,
        source: FileHandle,
        with reply: @escaping (Data) -> Void
    )

    /// MS-18: re-runs the format loaders over persisted package attachment bytes in the worker.
    /// `requestData` is an `AnalysisRehydrateWireCodec` envelope; `cancel(requestID:)` applies.
    func rehydrate(
        requestData: Data,
        requestID: UUID,
        with reply: @escaping (Data) -> Void
    )

    /// PERF-C: `rehydrate` with the image bytes on `imageSource`, a sealed read-only descriptor
    /// (`AnalysisSealedByteDescriptor`), instead of base64 inside the JSON envelope.
    func rehydratePinned(
        requestData: Data,
        requestID: UUID,
        imageSource: FileHandle,
        with reply: @escaping (Data) -> Void
    )

    /// Starts one supplemental dyld-cache inspection and returns exactly one encoded reply.
    /// This selector is intentionally distinct from `analyze` so its cancellation registry and
    /// typed reply schema cannot be confused with the primary analysis protocol.
    func inspectDyldCache(
        requestData: Data,
        requestID: UUID,
        with reply: @escaping (Data) -> Void
    )

    /// Inspects captured data through the verified worker-only REA resource.
    func inspectREA(requestData: Data, requestID: UUID, with reply: @escaping (Data) -> Void)

    /// Cooperative cancellation does not establish worker termination or release its lease.
    func cancelREAInspection(requestID: UUID)

    /// Requests cooperative cancellation of the analysis identified by `requestID`.
    func cancel(requestID: UUID)

    /// HOP-3: the latest phase the analysis `requestID` reached, as an encoded
    /// `AnalysisProgressReply` (phase nil when unknown or finished). Answered immediately; it
    /// never waits behind an analysis.
    @objc optional func progress(requestID: UUID, with reply: @escaping (Data) -> Void)

    /// Requests cooperative cancellation of the dyld-cache inspection identified by `requestID`.
    func cancelDyldCacheInspection(requestID: UUID)
}
