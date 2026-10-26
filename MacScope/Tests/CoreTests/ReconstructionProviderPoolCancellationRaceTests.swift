import Foundation
import XCTest

@testable import MacScope

final class ReconstructionProviderPoolCancellationRaceTests: XCTestCase {
    func testReleaseSkipsCancelledWaiterBeforeRemovalSettles() async throws {
        let factory = ReleaseRaceProviderFactory()
        let leaseGate = ReleaseRaceAsyncGate()
        let removalGate = ReleaseRaceAsyncGate()
        let cancelledOperation = ReleaseRaceCounter()
        let secondOperation = ReleaseRaceCounter()
        let pool = try ReconstructionAnalysisProviderPool(
            factory: factory,
            budget: .init(
                maximumActiveAnalyses: 1,
                estimatedResidentBytesPerAnalysis: 1,
                reservedHostBytes: 0
            ),
            processorCount: 1,
            physicalMemory: 8,
            hooks: .init(beforeWaiterCancellationRemoval: { _ in
                await removalGate.wait()
            })
        )

        let active = Task {
            try await pool.withProvider { _ in
                await leaseGate.wait()
                return "active"
            }
        }
        await waitUntilReleaseRace { await leaseGate.waiterCount == 1 }

        let cancelled = Task {
            try await pool.withProvider { _ in
                await cancelledOperation.increment()
                return "cancelled"
            }
        }
        await waitUntilReleaseRace {
            await pool.snapshot().queuedWaiterCount == 1
        }

        let second = Task {
            try await pool.withProvider { _ in
                await secondOperation.increment()
                return "second"
            }
        }
        await waitUntilReleaseRace {
            await pool.snapshot().queuedWaiterCount == 2
        }

        cancelled.cancel()
        await waitUntilReleaseRace { await removalGate.waiterCount == 1 }
        await leaseGate.open()

        let activeValue = try await active.value
        let secondValue = try await second.value
        XCTAssertEqual(activeValue, "active")
        XCTAssertEqual(secondValue, "second")

        do {
            _ = try await cancelled.value
            XCTFail("A cancelled first waiter must not consume the released provider.")
        } catch is CancellationError {
            // Expected.
        }

        let cancelledOperationCount = await cancelledOperation.value
        let secondOperationCount = await secondOperation.value
        XCTAssertEqual(cancelledOperationCount, 0)
        XCTAssertEqual(secondOperationCount, 1)
        XCTAssertEqual(factory.makeProviderCount, 1)

        await removalGate.open()
        await waitUntilReleaseRace {
            await pool.snapshot().queuedWaiterCount == 0
        }
    }
}

private final class ReleaseRaceProviderFactory:
    ReconstructionAnalysisProviderFactory,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedMakeProviderCount = 0

    var makeProviderCount: Int {
        lock.withLock { storedMakeProviderCount }
    }

    func makeProvider() -> any AnalysisProviding {
        lock.withLock { storedMakeProviderCount += 1 }
        return ReleaseRaceUnusedAnalysisProvider()
    }
}

private struct ReleaseRaceUnusedAnalysisProvider: AnalysisProviding {
    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        fatalError("release-race tests do not execute provider analysis")
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        fatalError("release-race tests do not execute provider analysis")
    }
}

private actor ReleaseRaceAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiterCount: Int {
        waiters.count
    }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private actor ReleaseRaceCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private func waitUntilReleaseRace(
    _ predicate: @Sendable @escaping () async -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<200_000 {
        if await predicate() { return }
        await Task.yield()
    }
    XCTFail("release-race condition did not settle", file: file, line: line)
}
