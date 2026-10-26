import Darwin
import Foundation

struct REAWorkerFailure: Error, Equatable, Sendable {
    let code: String
    init(_ code: String) { self.code = code }
}

/// Thread-safe control only. JavaScript objects never cross this boundary.
final class REAWorkerExecutionControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var checkpoints = 0
    let deadline: Date
    let maximumCheckpoints: Int
    let maximumResidentBytes: Int64
    private let currentPhysicalFootprint: @Sendable () -> Int64?
    init(deadline: Date, maximumCheckpoints: Int = 500_000, maximumResidentBytes: Int64 = 2_147_483_648,
         currentPhysicalFootprint: @escaping @Sendable () -> Int64? = {
             REAWorkerExecutionControl.readCurrentPhysicalFootprint()
         }) {
        self.deadline = deadline; self.maximumCheckpoints = maximumCheckpoints
        self.maximumResidentBytes = maximumResidentBytes
        self.currentPhysicalFootprint = currentPhysicalFootprint
    }
    static func readCurrentPhysicalFootprint() -> Int64? {
        var info = task_vm_info_data_t()
        let capacity = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return physicalFootprint(info, status: status, count: count)
    }

    /// TASK_VM_INFO revisions can differ; require the returned words to include phys_footprint.
    static func physicalFootprint(_ info: task_vm_info_data_t, status: kern_return_t,
                                  count: mach_msg_type_number_t) -> Int64? {
        guard status == KERN_SUCCESS,
              let offset = MemoryLayout<task_vm_info_data_t>.offset(of: \.phys_footprint),
              Int(count) * MemoryLayout<integer_t>.size >= offset + MemoryLayout<mach_vm_size_t>.size
        else { return nil }
        return Int64(exactly: info.phys_footprint)
    }

    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        try lock.withLock {
            if cancelled { throw REAWorkerFailure("cancelled") }
            if Date() >= deadline { throw REAWorkerFailure("timeout") }
            // This long-lived worker also performs binary/dyld analysis. Charge its current
            // physical footprint, including other live work, rather than its lifetime peak.
            // Failed observations deny execution; they never erase live memory from the budget.
            guard let bytes = currentPhysicalFootprint(), bytes >= 0,
                  bytes <= maximumResidentBytes else { throw REAWorkerFailure("budgetExceeded") }
            checkpoints += 1
            if checkpoints > maximumCheckpoints { throw REAWorkerFailure("budgetExceeded") }
        }
    }
}

/// Process-wide admission is acquired before enqueueing. A deadline can settle the caller,
/// but only the executor's terminal callback releases the lease.
final class REAWorkerService: @unchecked Sendable {
    typealias Executor = @Sendable (Data, UUID, REAWorkerExecutionControl,
        @escaping @Sendable (Result<Data, REAWorkerFailure>) -> Void) -> Void
    private final class Admission: @unchecked Sendable {
        static let shared = Admission()
        let lock = NSLock()
        var owner: UUID?
        func acquire(_ id: UUID) -> Bool { lock.withLock {
            guard owner == nil else { return false }; owner = id; return true
        } }
        func release(_ id: UUID) { lock.withLock { if owner == id { owner = nil } } }
    }
    private final class Reply: @unchecked Sendable {
        let lock = NSLock()
        var sent = false
        let completion: @Sendable (Data) -> Void
        init(_ completion: @escaping @Sendable (Data) -> Void) { self.completion = completion }
        func send(_ data: Data) {
            let first = lock.withLock { if sent { return false }; sent = true; return true }
            if first { completion(data) }
        }
    }
    private let lock = NSLock()
    private var active: [UUID: REAWorkerExecutionControl] = [:]
    private var seen: Set<UUID> = []
    private var preCancelled: Set<UUID> = []
    private var cancellationOverflow = false
    private let executor: Executor?
    private let implementationIdentity: String
    private let duration: TimeInterval
    private let executionControlFactory: @Sendable (Date) -> REAWorkerExecutionControl

    init(executor: Executor?, implementationIdentity: String, duration: TimeInterval = 30,
         executionControlFactory: @escaping @Sendable (Date) -> REAWorkerExecutionControl = {
             REAWorkerExecutionControl(deadline: $0)
         }) {
        self.executor = executor; self.implementationIdentity = implementationIdentity
        self.duration = min(max(duration, 0.01), 120)
        self.executionControlFactory = executionControlFactory
    }
    static func unavailable() -> REAWorkerService {
        .init(executor: nil, implementationIdentity: "unavailable")
    }
    func cancel(requestID: UUID) {
        lock.withLock {
            if let control = active[requestID] { control.cancel() }
            else if !seen.contains(requestID) {
                if preCancelled.count < 4_096 { preCancelled.insert(requestID) }
                else { cancellationOverflow = true }
            }
        }
    }
    func handle(requestData: Data, requestID: UUID, completion: @escaping @Sendable (Data) -> Void) {
        let reply = Reply(completion)
        var operation: REAInspectionOperation?
        func fail(_ code: String) { reply.send(failure(requestID, operation, code)) }
        do { operation = try REAInspectionWireCodec.validateRequest(requestData, requestID: requestID).operation }
        catch { fail("malformedRequest"); return }
        let control = executionControlFactory(Date().addingTimeInterval(duration))
        let registration: String? = lock.withLock {
            guard !cancellationOverflow else { return "unavailable" }
            guard !seen.contains(requestID), seen.count < 65_536 else { return "duplicateRequest" }
            seen.insert(requestID)
            if preCancelled.remove(requestID) != nil { return "cancelled" }
            active[requestID] = control
            return nil
        }
        if let registration { fail(registration); return }
        guard let executor else { lock.withLock { active.removeValue(forKey: requestID) }; fail("unavailable"); return }
        let leaseID = UUID()
        guard Admission.shared.acquire(leaseID) else {
            lock.withLock { active.removeValue(forKey: requestID) }; fail("busy"); return
        }
        guard let selectedOperation = operation else {
            lock.withLock { active.removeValue(forKey: requestID) }; Admission.shared.release(leaseID); fail("invalidRequest"); return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + duration) { [self, reply, control] in
            do { try control.check() } catch {
                reply.send(failure(requestID, selectedOperation, (error as? REAWorkerFailure)?.code ?? "timeout"))
            }
        }
        executor(requestData, requestID, control) { [self, reply, control] result in
            // Duplicate executor completion cannot release another request's admission.
            let owned = lock.withLock { active.removeValue(forKey: requestID) != nil }
            guard owned else { return }
            let response: Data
            do {
                try control.check()
                let data = try result.get()
                try REAInspectionWireCodec.validateResponse(data, requestID: requestID,
                    operation: selectedOperation, implementationIdentity: implementationIdentity)
                response = data
            } catch { response = failure(requestID, selectedOperation, (error as? REAWorkerFailure)?.code ?? "invalidResponse") }
            Admission.shared.release(leaseID)
            reply.send(response)
        }
    }
    private func failure(_ id: UUID, _ operation: REAInspectionOperation?, _ code: String) -> Data {
        REAInspectionWireCodec.failure(requestID: id, operation: operation,
            implementationIdentity: implementationIdentity, code: String(code.prefix(64)),
            message: "REA inspection did not complete.")
    }
}
