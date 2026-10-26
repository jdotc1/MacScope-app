import Foundation
import MacScopePatternAdapter

// Worker-only: compiled in AnalysisWorkerXPCService.
// Never expose this class or the native module to the app/shared analysis target.
// The request/bytes/source are copied by the C adapter before init returns.
final class PatternNativeJob: PatternEvaluationJob, @unchecked Sendable {
    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var didRun = false
    private var cancelled = false

    init(request: PatternInterpretationRequest) throws {
        try request.validate()
        let sourceBytes = Array(request.source.utf8)
        let created: OpaquePointer? = request.bytes.withUnsafeBytes { bytes in
            sourceBytes.withUnsafeBufferPointer { source in
                request.requestID.uuidString.withCString { requestID in
                    request.key.imageIdentity.withCString { imageID in
                        request.key.patternIdentity.withCString { patternID in
                            request.key.byteSnapshotID.uuidString.withCString { byteSnapshotID in
                                var native = ms_pattern_request()
                                native.abi_version = 1
                                native.bytes = bytes.bindMemory(to: UInt8.self).baseAddress
                                native.byte_count = bytes.count
                                guard let sourceBase = source.baseAddress else { return nil }
                                native.source = UnsafeRawPointer(sourceBase).assumingMemoryBound(to: CChar.self)
                                native.source_count = source.count
                                native.request_id = requestID
                                native.image_identity = imageID
                                native.pattern_identity = patternID
                                native.byte_snapshot_id = byteSnapshotID
                                native.selection_image_offset = request.key.selectionImageOffset
                                native.maximum_nodes = UInt32(request.maximumNodes)
                                native.maximum_depth = UInt32(request.maximumDepth)
                                native.maximum_array_children = UInt32(request.maximumArrayChildren)
                                native.cooperative_timeout_ms = UInt32(request.cooperativeTimeoutMS)
                                return ms_pattern_job_create(&native)
                            }
                        }
                    }
                }
            }
        }
        guard let created else { throw PatternInterpretationError.nativeUnavailable }
        handle = created
    }

    func run() throws -> Data {
        lock.lock()
        guard !didRun, let active = handle else {
            lock.unlock()
            throw PatternInterpretationError.alreadyRun
        }
        didRun = true
        lock.unlock()

        // The method's strong self lifetime keeps the handle alive during run.
        // Cancellation takes the lock but never destroys or releases a lease.
        let document = ms_pattern_job_run(active)
        defer { ms_pattern_document_free(document) }
        guard let pointer = document.bytes, document.length > 0, document.length <= 4_194_304 else {
            finishHandle()
            throw PatternInterpretationError.nativeUnavailable
        }
        let copied = Data(bytes: pointer, count: document.length)
        finishHandle()
        return copied
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if let handle { ms_pattern_job_cancel(handle) }
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    private func finishHandle() {
        lock.lock()
        if let handle { ms_pattern_job_destroy(handle) }
        handle = nil
        lock.unlock()
    }

    deinit {
        // deinit cannot race this instance's run or cancel while they hold self.
        if let handle { ms_pattern_job_destroy(handle) }
    }
}

