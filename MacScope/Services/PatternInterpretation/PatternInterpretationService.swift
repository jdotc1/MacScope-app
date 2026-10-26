import Foundation

// The injectable job interface keeps every C/native
// symbol in AnalysisWorkerXPCService; this shared target never links libpl.
protocol PatternEvaluationJob: AnyObject, Sendable {
    func run() throws -> Data
    func cancel()
    var isCancelled: Bool { get }
}

enum PatternServiceFailure: String, Codable, Error, Sendable {
    case unavailable, busy, invalidRequest, cancelled, invalidNativeReply
}
struct PatternWorkerEnvelope: Codable, Sendable {
    var schemaVersion: Int = 1
    var requestID: UUID
    var nativeDocument: Data?
    var failure: PatternServiceFailure?

    static let maximumWireBytes = 6 * 1024 * 1024

    func encode() -> Data {
        // All stored values are Codable primitives; encoding failure remains
        // explicit through an empty (invalid) transport response, never success.
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    static func unwrap(_ data: Data, requestID: UUID) throws -> Data {
        guard data.count <= maximumWireBytes else { throw PatternInterpretationError.malformedReply }
        let reply = try JSONDecoder().decode(Self.self, from: data)
        guard reply.schemaVersion == 1, reply.requestID == requestID,
              (reply.nativeDocument != nil) != (reply.failure != nil)
        else { throw PatternInterpretationError.malformedReply }
        if let failure = reply.failure { throw failure }
        guard let document = reply.nativeDocument, document.count <= 4_194_304
        else { throw PatternInterpretationError.malformedReply }
        return document
    }
}

final class PatternInterpretationService: @unchecked Sendable {
    typealias JobFactory = @Sendable (PatternInterpretationRequest) throws -> any PatternEvaluationJob
    private let watchdog: (any PatternWorkerWatchdog)?
    private let makeJob: JobFactory?
    private let admission: PatternWorkerAdmission
    private let queue: DispatchQueue

    init(makeJob: JobFactory?,
         watchdog: (any PatternWorkerWatchdog)? = nil,
         admission: PatternWorkerAdmission = .shared,
         queue: DispatchQueue = .init(label: "org.macscope.app.pattern-interpretation", qos: .userInitiated)) {
        self.watchdog = watchdog
        self.makeJob = makeJob
        self.admission = admission
        self.queue = queue
    }

    static func unavailable() -> Self {
        Self(makeJob: nil)
    }

    func handle(requestData: Data, requestID: UUID, expectedNonce: UUID? = nil, reply: @escaping @Sendable (Data) -> Void) {
        // An unsupervised production lane never acquires a lease or constructs a job.
        guard let makeJob else {
            reply(PatternWorkerEnvelope(requestID: requestID, failure: .unavailable).encode())
            return
        }
        guard requestData.count <= 2 * 1024 * 1024 else {
            reply(PatternWorkerEnvelope(requestID: requestID, failure: .invalidRequest).encode())
            return
        }
        guard admission.tryAcquire(requestID: requestID) else {
            reply(PatternWorkerEnvelope(requestID: requestID, failure: .busy).encode())
            return
        }
        // A future worker-only native composition must inject the watchdog and supply the
        // authenticated startup nonce. Legacy test injection without a watchdog stays supported.
        if let watchdog {
            guard let expectedNonce,
                  let request = try? JSONDecoder().decode(PatternInterpretationRequest.self, from: requestData),
                  request.requestID == requestID, (try? request.validate()) != nil,
                  watchdog.arm(requestID: requestID, expectedNonce: expectedNonce,
                               timeoutMS: request.cooperativeTimeoutMS,
                               abort: { [admission] in admission.cancel(requestID: requestID) }) else {
                admission.releaseAfterNativeReturn(requestID: requestID) // No native job was created.
                reply(PatternWorkerEnvelope(requestID: requestID, failure: .unavailable).encode())
                return
            }
        }
        queue.async { [makeJob, admission, watchdog] in
            // A cooperative cancel or client timeout does not execute this defer.
            // A lease ends only when this actual synchronous native call returns.
            defer {
                watchdog?.nativeReturned(requestID: requestID)
                admission.releaseAfterNativeReturn(requestID: requestID)
            }
            do {
                let request: PatternInterpretationRequest
                do {
                    request = try JSONDecoder().decode(PatternInterpretationRequest.self, from: requestData)
                    try request.validate()
                    guard request.requestID == requestID else { throw PatternInterpretationError.invalidRequest }
                } catch {
                    throw PatternServiceFailure.invalidRequest
                }
                let job = try makeJob(request)
                admission.installCancellation(requestID: requestID) { job.cancel() }
                let native = try job.run()
                if job.isCancelled { throw PatternServiceFailure.cancelled }
                do {
                    // Validate before crossing XPC, then validate/freshness-check again
                    // in the app against its still-current captured selection.
                    _ = try ValidatedPatternInterpretation.decodeForWorker(native, for: request)
                } catch {
                    throw PatternServiceFailure.invalidNativeReply
                }
                reply(PatternWorkerEnvelope(requestID: requestID, nativeDocument: native).encode())
            } catch let failure as PatternServiceFailure {
                reply(PatternWorkerEnvelope(requestID: requestID, failure: failure).encode())
            } catch {
                reply(PatternWorkerEnvelope(requestID: requestID, failure: .unavailable).encode())
            }
        }
    }

    func cancel(requestID: UUID) {
        guard makeJob != nil else { return }
        admission.cancel(requestID: requestID)
    }
}

