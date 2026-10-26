import Darwin
import Foundation
import XCTest
@testable import MacScope

private final class REAHeldExecution: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Result<Data, REAWorkerFailure>) -> Void)?
    private var id: UUID?
    func start(_ id: UUID, _ completion: @escaping @Sendable (Result<Data, REAWorkerFailure>) -> Void) {
        lock.withLock { self.id = id; callback = completion }
    }
    func finish() {
        let saved = lock.withLock { (id, callback) }
        if let id = saved.0, let callback = saved.1 {
            callback(.success(REAInspectionWireCodec.failure(requestID: id, operation: .nativeApplication,
                implementationIdentity: "test", code: "testFailure", message: "test")))
        }
    }
}
final class REAWorkerServiceTests: XCTestCase {
    func testPhysicalFootprintIgnoresLifetimePeakAndRejectsIncompleteObservation() throws {
        var info = task_vm_info_data_t()
        info.phys_footprint = 64 * 1_024 * 1_024
        info.resident_size_peak = 4 * 1_024 * 1_024 * 1_024
        info.ledger_phys_footprint_peak = 4 * 1_024 * 1_024 * 1_024
        let count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        XCTAssertEqual(REAWorkerExecutionControl.physicalFootprint(info, status: KERN_SUCCESS, count: count),
                       64 * 1_024 * 1_024)
        XCTAssertNil(REAWorkerExecutionControl.physicalFootprint(info, status: KERN_FAILURE, count: count))
        XCTAssertNil(REAWorkerExecutionControl.physicalFootprint(info, status: KERN_SUCCESS, count: 0))
        info.phys_footprint = UInt64.max
        XCTAssertNil(REAWorkerExecutionControl.physicalFootprint(info, status: KERN_SUCCESS, count: count))
        XCTAssertGreaterThan(try XCTUnwrap(REAWorkerExecutionControl.readCurrentPhysicalFootprint()), 0)
    }

    func testCurrentMemoryCeilingIsNotLatchedAfterAnEarlierPeak() throws {
        final class Footprint: @unchecked Sendable {
            let lock = NSLock()
            var bytes: Int64 = 3_000_000_000
            func read() -> Int64? { lock.withLock { bytes } }
            func release() { lock.withLock { bytes = 64_000_000 } }
        }
        let footprint = Footprint()
        let control = REAWorkerExecutionControl(deadline: Date().addingTimeInterval(5),
            currentPhysicalFootprint: { footprint.read() })
        XCTAssertThrowsError(try control.check()) { XCTAssertEqual($0 as? REAWorkerFailure, .init("budgetExceeded")) }
        footprint.release()
        XCTAssertNoThrow(try control.check())
    }

    func testMemoryObservationFailureAndExcessiveLiveFootprintFailClosed() throws {
        for bytes: Int64? in [nil, -1, 2_147_483_649] {
            let control = REAWorkerExecutionControl(deadline: Date().addingTimeInterval(5),
                currentPhysicalFootprint: { bytes })
            XCTAssertThrowsError(try control.check()) { XCTAssertEqual($0 as? REAWorkerFailure, .init("budgetExceeded")) }
        }
        let boundary = REAWorkerExecutionControl(deadline: Date().addingTimeInterval(5),
            currentPhysicalFootprint: { 2_147_483_648 })
        XCTAssertNoThrow(try boundary.check())
    }

    private func request(_ id: UUID) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "requestID": id.uuidString,
            "operation": "nativeApplication", "input": [:]], options: [.sortedKeys])
    }
    private static func code(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any] else { return nil }
        return error["code"] as? String
    }
    func testTwoServicesCannotBypassAdmissionAndDuplicateCannotReplaceExecution() throws {
        let held = REAHeldExecution(), firstID = UUID()
        let first = REAWorkerService(executor: { _, id, _, completion in held.start(id, completion) }, implementationIdentity: "test")
        let second = REAWorkerService(executor: { _, _, _, completion in completion(.failure(.init("unexpected"))) }, implementationIdentity: "test")
        let completed = expectation(description: "original completes"), busy = expectation(description: "busy"), duplicate = expectation(description: "duplicate")
        first.handle(requestData: try request(firstID), requestID: firstID) { _ in completed.fulfill() }
        let secondID = UUID()
        second.handle(requestData: try request(secondID), requestID: secondID) { data in
            XCTAssertEqual(Self.code(data), "busy"); busy.fulfill()
        }
        first.handle(requestData: try request(firstID), requestID: firstID) { data in
            XCTAssertEqual(Self.code(data), "duplicateRequest"); duplicate.fulfill()
        }
        held.finish()
        wait(for: [completed, busy, duplicate], timeout: 2)
    }
    func testCancellationBeforeRegistrationAndDuringExecution() throws {
        let held = REAHeldExecution()
        let service = REAWorkerService(executor: { _, id, _, completion in held.start(id, completion) }, implementationIdentity: "test")
        let early = UUID(), earlyReply = expectation(description: "early cancellation")
        service.cancel(requestID: early)
        service.handle(requestData: try request(early), requestID: early) { data in
            XCTAssertEqual(Self.code(data), "cancelled"); earlyReply.fulfill()
        }
        let active = UUID(), activeReply = expectation(description: "active cancellation")
        service.handle(requestData: try request(active), requestID: active) { data in
            XCTAssertEqual(Self.code(data), "cancelled"); activeReply.fulfill()
        }
        service.cancel(requestID: active); held.finish()
        wait(for: [earlyReply, activeReply], timeout: 2)
    }
    func testDeadlineReplyDoesNotReleaseBlockedExecutorLease() throws {
        let held = REAHeldExecution()
        let service = REAWorkerService(executor: { _, id, _, completion in held.start(id, completion) }, implementationIdentity: "test", duration: 0.03)
        let id = UUID(), timedOut = expectation(description: "deadline")
        service.handle(requestData: try request(id), requestID: id) { data in
            XCTAssertEqual(Self.code(data), "timeout"); timedOut.fulfill()
        }
        wait(for: [timedOut], timeout: 2)
        let other = REAWorkerService(executor: { _, _, _, completion in completion(.failure(.init("unexpected"))) }, implementationIdentity: "test")
        let otherID = UUID(), rejected = expectation(description: "lease retained")
        other.handle(requestData: try request(otherID), requestID: otherID) { data in
            XCTAssertEqual(Self.code(data), "busy"); rejected.fulfill()
        }
        wait(for: [rejected], timeout: 2)
        held.finish() // Terminal cleanup, rather than caller timeout, releases admission.
        held.finish() // Duplicate terminal completion must be harmless.
    }
}
