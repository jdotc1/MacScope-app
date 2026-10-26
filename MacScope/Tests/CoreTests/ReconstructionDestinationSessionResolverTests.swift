import Foundation
import XCTest
@testable import MacScope

final class ReconstructionDestinationSessionResolverTests: XCTestCase {
    private struct Session: Equatable, Sendable {
        let jobID: UUID
        let instanceID: UUID
    }

    private actor FactoryProbe {
        private(set) var calls: [UUID] = []
        var shouldFail = false

        func make(jobID: UUID) async throws -> Session {
            calls.append(jobID)
            try await Task.sleep(for: .milliseconds(20))
            if shouldFail {
                throw ProbeError.failed
            }
            return Session(jobID: jobID, instanceID: UUID())
        }

        func callCount() -> Int { calls.count }
        func setShouldFail(_ value: Bool) { shouldFail = value }
    }

    private actor NonCooperativeFactoryProbe {
        private(set) var calls: [UUID] = []
        private var released = false
        private var cancellationObserved = false
        private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

        func make(jobID: UUID) async -> Session {
            calls.append(jobID)
            while !released {
                if Task.isCancelled, !cancellationObserved {
                    cancellationObserved = true
                    cancellationWaiters.forEach { $0.resume() }
                    cancellationWaiters.removeAll()
                }
                await Task.yield()
            }
            return Session(jobID: jobID, instanceID: UUID())
        }

        func callCount() -> Int { calls.count }

        func waitUntilCancellationObserved() async {
            if cancellationObserved { return }
            await withCheckedContinuation { cancellationWaiters.append($0) }
        }

        func release() {
            released = true
        }
    }

    private actor RetirementProbe {
        private(set) var instanceIDs: [UUID] = []

        func retire(_ session: Session) {
            instanceIDs.append(session.instanceID)
        }
    }

    private actor RetirementGate {
        private(set) var instanceIDs: [UUID] = []
        private var released = false
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func retire(_ session: Session) async {
            instanceIDs.append(session.instanceID)
            startedWaiters.forEach { $0.resume() }
            startedWaiters.removeAll()
            if !released {
                await withCheckedContinuation { releaseWaiters.append($0) }
            }
        }

        func waitUntilStarted() async {
            if !instanceIDs.isEmpty { return }
            await withCheckedContinuation { startedWaiters.append($0) }
        }

        func release() {
            released = true
            releaseWaiters.forEach { $0.resume() }
            releaseWaiters.removeAll()
        }
    }

    private enum ProbeError: Error {
        case failed
    }

    func testEmptyDestinationCannotAcquireRuntimeAuthority() async throws {
        let probe = FactoryProbe()
        let resolver = ReconstructionDestinationSessionResolver<Session> { jobID in
            try await probe.make(jobID: jobID)
        }

        do {
            _ = try await resolver.resolve(forDurableJobID: nil)
            XCTFail("expected durable-job refusal")
        } catch {
            XCTAssertEqual(
                error as? ReconstructionDestinationSessionResolutionError,
                .durableJobRequired
            )
        }
        let callCount = await probe.callCount()
        let resolvedJobID = await resolver.resolvedDurableJobID()
        XCTAssertEqual(callCount, 0)
        XCTAssertNil(resolvedJobID)
    }

    func testConcurrentResolutionCoalescesOneFactoryCall() async throws {
        let probe = FactoryProbe()
        let resolver = ReconstructionDestinationSessionResolver<Session> { jobID in
            try await probe.make(jobID: jobID)
        }
        let jobID = UUID()

        let sessions = try await withThrowingTaskGroup(of: Session.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try await resolver.resolve(forDurableJobID: jobID)
                }
            }
            var values: [Session] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        let callCount = await probe.callCount()
        let resolvedJobID = await resolver.resolvedDurableJobID()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(Set(sessions.map(\.instanceID)).count, 1)
        XCTAssertTrue(sessions.allSatisfy { $0.jobID == jobID })
        XCTAssertEqual(resolvedJobID, jobID)
    }

    func testWindowCannotSilentlyRebindToSiblingJob() async throws {
        let probe = FactoryProbe()
        let resolver = ReconstructionDestinationSessionResolver<Session> { jobID in
            try await probe.make(jobID: jobID)
        }
        let first = UUID()
        let second = UUID()
        _ = try await resolver.resolve(forDurableJobID: first)

        do {
            _ = try await resolver.resolve(forDurableJobID: second)
            XCTFail("expected identity mismatch")
        } catch {
            XCTAssertEqual(
                error as? ReconstructionDestinationSessionResolutionError,
                .jobIdentityMismatch(expected: first, actual: second)
            )
        }
        let callCount = await probe.callCount()
        let resolvedJobID = await resolver.resolvedDurableJobID()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(resolvedJobID, first)
    }

    func testFailedConstructionDoesNotPoisonRetry() async throws {
        let probe = FactoryProbe()
        await probe.setShouldFail(true)
        let resolver = ReconstructionDestinationSessionResolver<Session> { jobID in
            try await probe.make(jobID: jobID)
        }
        let jobID = UUID()

        do {
            _ = try await resolver.resolve(forDurableJobID: jobID)
            XCTFail("expected factory failure")
        } catch is ProbeError {
            // Expected.
        }
        let failedResolution = await resolver.resolvedDurableJobID()
        XCTAssertNil(failedResolution)

        await probe.setShouldFail(false)
        let session = try await resolver.resolve(forDurableJobID: jobID)
        let callCount = await probe.callCount()
        XCTAssertEqual(session.jobID, jobID)
        XCTAssertEqual(callCount, 2)
    }

    func testResetFencesLateConstructionAndAllowsNewJob() async throws {
        let probe = FactoryProbe()
        let resolver = ReconstructionDestinationSessionResolver<Session> { jobID in
            try await probe.make(jobID: jobID)
        }
        let first = UUID()
        let second = UUID()
        let inFlight = Task {
            try await resolver.resolve(forDurableJobID: first)
        }

        var constructionStarted = false
        for _ in 0..<1_000 {
            if await probe.callCount() == 1 {
                constructionStarted = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(constructionStarted, "factory did not begin")

        await resolver.reset()
        do {
            _ = try await inFlight.value
            XCTFail("expected reset to fence the old construction")
        } catch {
            XCTAssertTrue(
                error is CancellationError
                    || error as? ReconstructionDestinationSessionResolutionError
                        == .staleResolution
            )
        }

        let replacement = try await resolver.resolve(forDurableJobID: second)
        let resolvedJobID = await resolver.resolvedDurableJobID()
        XCTAssertEqual(replacement.jobID, second)
        XCTAssertEqual(resolvedJobID, second)
    }

    func testResetRetiresLateNonCooperativeFactoryResultExactlyOnce() async throws {
        let factory = NonCooperativeFactoryProbe()
        let retirement = RetirementProbe()
        let resolver = ReconstructionDestinationSessionResolver<Session>(
            factory: { jobID in await factory.make(jobID: jobID) },
            retire: { session in await retirement.retire(session) }
        )
        let first = UUID()
        let inFlight = Task { () -> ReconstructionDestinationSessionResolutionError? in
            do {
                _ = try await resolver.resolve(forDurableJobID: first)
                return nil
            } catch {
                return error as? ReconstructionDestinationSessionResolutionError
            }
        }

        var constructionStarted = false
        for _ in 0..<1_000 {
            if await factory.callCount() == 1 {
                constructionStarted = true
                break
            }
            await Task.yield()
        }
        XCTAssertTrue(constructionStarted, "factory did not begin")

        let reset = Task { await resolver.reset() }
        await factory.waitUntilCancellationObserved()
        await factory.release()
        await reset.value
        let error = await inFlight.value

        let retiredInstanceIDs = await retirement.instanceIDs
        let resolvedJobID = await resolver.resolvedDurableJobID()
        XCTAssertEqual(retiredInstanceIDs.count, 1)
        XCTAssertEqual(error, .staleResolution)
        XCTAssertNil(resolvedJobID)
    }

    func testReplacementActivationWaitsForPriorRetirementBarrier() async throws {
        let factory = FactoryProbe()
        let retirement = RetirementGate()
        let resolver = ReconstructionDestinationSessionResolver<Session>(
            factory: { jobID in try await factory.make(jobID: jobID) },
            retire: { session in await retirement.retire(session) }
        )
        let first = UUID()
        let second = UUID()
        _ = try await resolver.resolve(forDurableJobID: first)

        let reset = Task { await resolver.reset() }
        await retirement.waitUntilStarted()
        let replacement = Task {
            try await resolver.resolve(forDurableJobID: second)
        }
        for _ in 0..<100 { await Task.yield() }
        let callsWhileRetiring = await factory.callCount()
        XCTAssertEqual(callsWhileRetiring, 1)

        await retirement.release()
        await reset.value
        let replacementSession = try await replacement.value
        let finalCallCount = await factory.callCount()
        XCTAssertEqual(replacementSession.jobID, second)
        XCTAssertEqual(finalCallCount, 2)
    }

    func testTerminalRetirementIsIdempotentAndBlocksFutureResolution() async throws {
        let factory = FactoryProbe()
        let retirement = RetirementProbe()
        let resolver = ReconstructionDestinationSessionResolver<Session>(
            factory: { jobID in try await factory.make(jobID: jobID) },
            retire: { session in await retirement.retire(session) }
        )
        let jobID = UUID()
        _ = try await resolver.resolve(forDurableJobID: jobID)

        await resolver.retire()
        await resolver.retire()
        await resolver.reset()

        let retirementCount = await retirement.instanceIDs.count
        XCTAssertEqual(retirementCount, 1)
        do {
            _ = try await resolver.resolve(forDurableJobID: jobID)
            XCTFail("expected terminal resolver refusal")
        } catch {
            XCTAssertEqual(
                error as? ReconstructionDestinationSessionResolutionError,
                .retired
            )
        }
        let finalCallCount = await factory.callCount()
        XCTAssertEqual(finalCallCount, 1)
    }
}
