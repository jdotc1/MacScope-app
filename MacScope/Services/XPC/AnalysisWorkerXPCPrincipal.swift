import Darwin
import Foundation

/// The object exported by each accepted analysis-worker XPC connection.
///
/// The default initializer is the production composition root: it constructs the existing pure
/// worker handler with the real analysis engine and payload codec. Tests inject that same handler
/// with controlled dependencies and call this principal directly, without a live XPC process.
final class AnalysisWorkerXPCPrincipal: NSObject, AnalysisWorkerXPCProtocol {
    private let service: AnalysisWorkerService
    private let reaService: REAWorkerService
    private let processControl: (any AnalysisWorkerProcessControlling)?
    private let patternService: PatternInterpretationService
    private let dyldCacheService: DyldCacheAnalysisWorkerService
    private let workerQueue: DispatchQueue
    private let dyldCacheQueue: DispatchQueue
    private let dyldCacheAdmission: DyldCacheInspectionAdmission

    override convenience init() {
        self.init(
            service: AnalysisWorkerService(engine: AnalysisEngine(), codec: PayloadWireCodec()),
            dyldCacheService: .unavailable()
        )
    }

    init(
        service: AnalysisWorkerService,
        dyldCacheService: DyldCacheAnalysisWorkerService = .unavailable(),
        reaService: REAWorkerService = .unavailable(),
        patternService: PatternInterpretationService = .unavailable(),
        workerQueue: DispatchQueue = DispatchQueue(
            label: "org.macscope.app.AnalysisWorker.requests",
            qos: .userInitiated,
            attributes: .concurrent
        ),
        dyldCacheQueue: DispatchQueue = DispatchQueue(
            label: "org.macscope.app.AnalysisWorker.dyld-cache",
            qos: .userInitiated
        ),
        dyldCacheAdmission: DyldCacheInspectionAdmission = .shared,
        processControl: (any AnalysisWorkerProcessControlling)? = nil
    ) {
        self.processControl = processControl
        self.reaService = reaService
        self.patternService = patternService
        self.service = service
        self.dyldCacheService = dyldCacheService
        self.workerQueue = workerQueue
        self.dyldCacheQueue = dyldCacheQueue
        self.dyldCacheAdmission = dyldCacheAdmission
        super.init()
    }

    func workerControlChallenge(challenge: UUID, with reply: @escaping (Data) -> Void) {
        replyControl(challenge: challenge, accepted: processControl != nil, reply: reply)
    }

    func workerControlTerminate(expectedNonce: UUID, challenge: UUID,
                                with reply: @escaping (Data) -> Void) {
        let accepted = processControl?.requestTermination(expectedNonce: expectedNonce) ?? false
        replyControl(challenge: challenge, accepted: accepted, reply: reply)
    }

    private func replyControl(challenge: UUID, accepted: Bool, reply: (Data) -> Void) {
        guard let processControl else { reply(Data()); return }
        let response = AnalysisWorkerControlReply(schemaVersion: 1, challenge: challenge,
            identity: processControl.identity, accepted: accepted)
        reply((try? JSONEncoder().encode(response)) ?? Data())
    }

    func interpretPattern(requestData: Data, requestID: UUID, with reply: @escaping (Data) -> Void) {
        let sender = AnalysisWorkerXPCReplySender(reply)
        patternService.handle(requestData: requestData, requestID: requestID) { data in sender.send(data) }
    }

    func cancelPatternInterpretation(requestID: UUID) { patternService.cancel(requestID: requestID) }

    func inspectREA(requestData: Data, requestID: UUID, with reply: @escaping (Data) -> Void) {
        let sender = AnalysisWorkerXPCReplySender(reply)
        reaService.handle(requestData: requestData, requestID: requestID) { data in sender.send(data) }
    }

    func cancelREAInspection(requestID: UUID) { reaService.cancel(requestID: requestID) }

    func inspectDyldCache(
        requestData: Data,
        requestID: UUID,
        with reply: @escaping (Data) -> Void
    ) {
        let replySender = AnalysisWorkerXPCReplySender(reply)
        // The XPC listener exports one principal per connection. A per-principal serial queue is
        // therefore insufficient: independent connections could otherwise start independent
        // synchronous MachOKit calls. Acquire the process-wide, non-queuing lease before enqueueing
        // any work so at most one call can run or wait across the complete worker service.
        guard dyldCacheAdmission.tryAcquire() else {
            replySender.send(DyldCacheAnalysisWireCodec().encodeReply(.failure(
                DyldCacheAnalysisWorkerServiceError.providerUnavailable
            )))
            return
        }
        dyldCacheQueue.async { [dyldCacheService, dyldCacheAdmission] in
            defer { dyldCacheAdmission.release() }
            replySender.send(
                dyldCacheService.handle(requestData: requestData, requestID: requestID)
            )
        }
    }

    func analyze(
        requestData: Data,
        requestID: UUID,
        with reply: @escaping (Data) -> Void
    ) {
        // XPC reply blocks are safe to invoke asynchronously, but Foundation's Objective-C
        // signature cannot express Swift's `@Sendable`. The wrapper makes that runtime contract
        // explicit while keeping the queue closure Swift-6-sendable.
        let replySender = AnalysisWorkerXPCReplySender(reply)
        workerQueue.async { [service] in
            replySender.send(service.handle(requestData: requestData, requestID: requestID))
        }
    }

    func analyzePinned(
        requestData: Data,
        requestID: UUID,
        source: FileHandle,
        with reply: @escaping (Data) -> Void
    ) {
        let replySender = AnalysisWorkerXPCReplySender(reply)
        workerQueue.async { [service] in
            // `source` is the XPC-transferred descriptor. Keep the FileHandle captured through
            // analysis so its descriptor remains open; never resolve the caller's path string.
            let descriptor = source.fileDescriptor
            var state = stat()
            let flags = Darwin.fcntl(descriptor, F_GETFL)
            guard descriptor >= 0,
                  Darwin.fstat(descriptor, &state) == 0,
                  (state.st_mode & S_IFMT) == S_IFREG,
                  flags >= 0,
                  flags & O_ACCMODE != O_WRONLY else {
                replySender.send(service.handle(requestData: Data(), requestID: requestID))
                return
            }
            let reply = withExtendedLifetime(source) {
                service.handle(
                    requestData: requestData,
                    requestID: requestID,
                    pinnedURL: URL(fileURLWithPath: "/dev/fd/\(descriptor)"),
                    pinnedSource: source
                )
            }
            replySender.send(reply)
        }
    }

    func rehydrate(
        requestData: Data,
        requestID: UUID,
        with reply: @escaping (Data) -> Void
    ) {
        let replySender = AnalysisWorkerXPCReplySender(reply)
        workerQueue.async { [service] in
            replySender.send(service.handleRehydrate(requestData: requestData, requestID: requestID))
        }
    }

    func rehydratePinned(
        requestData: Data,
        requestID: UUID,
        imageSource: FileHandle,
        with reply: @escaping (Data) -> Void
    ) {
        let replySender = AnalysisWorkerXPCReplySender(reply)
        workerQueue.async { [service] in
            // Keep the transferred FileHandle alive until its bytes are read and the reply is built.
            let reply = withExtendedLifetime(imageSource) {
                service.handleRehydrate(requestData: requestData, requestID: requestID, imageSource: imageSource)
            }
            replySender.send(reply)
        }
    }

    func cancel(requestID: UUID) {
        // Cancellation stays synchronous and lock-protected inside AnalysisWorkerService, so it
        // can trip a token while the matching analysis occupies the worker queue.
        service.cancel(requestID: requestID)
    }

    func progress(requestID: UUID, with reply: @escaping (Data) -> Void) {
        // Inline under the registry's lock, like `cancel`: never queued behind the analysis it
        // reports on, and no engine access.
        reply(service.progressReply(requestID: requestID))
    }

    func cancelDyldCacheInspection(requestID: UUID) {
        dyldCacheService.cancel(requestID: requestID)
    }
}

/// One bounded admission slot shared by every XPC connection in this service process.
///
/// The worker's cooperative soft deadline is the request limit, capped at exactly 120,000 ms by
/// `DyldCacheAnalysisLimits.hardMaximum`. MachOKit construction is synchronous, so a vendor call
/// that never returns cannot be forcibly interrupted inside this architecture. In that case this
/// lease deliberately remains held until the call returns or the XPC process exits; every later
/// connection receives `providerUnavailable` immediately instead of starting parallel work or
/// accumulating an unbounded queue. Process termination remains the hard-retirement boundary.
final class DyldCacheInspectionAdmission: @unchecked Sendable {
    static let shared = DyldCacheInspectionAdmission()
    static let maximumCooperativeDurationMilliseconds =
        DyldCacheAnalysisLimits.hardMaximum.maximumDurationMilliseconds

    private let lock = NSLock()
    private var isOccupied = false

    func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isOccupied else { return false }
        isOccupied = true
        return true
    }

    func release() {
        lock.lock()
        isOccupied = false
        lock.unlock()
    }
}

private final class AnalysisWorkerXPCReplySender: @unchecked Sendable {
    private let reply: (Data) -> Void

    init(_ reply: @escaping (Data) -> Void) {
        self.reply = reply
    }

    func send(_ data: Data) {
        reply(data)
    }
}
