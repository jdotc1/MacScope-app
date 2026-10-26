import Foundation

#if NATIVE_DECOMPILER_PROJECTION_GATE_FOCUSED_MAIN

struct ImageSlot: Hashable, Sendable {
    static let primary = ImageSlot(rawValue: 0)
    let rawValue: Int
}

struct NativeDecompilerSnapshotProjection: Equatable, Sendable {
    let label: String
}

@main
private enum NativeDecompilerProjectionGateFocusedMain {
    static func main() async throws {
        let harness = FocusedProjectionGateHarness()
        let gate = NativeDecompilerProjectionGate()
        let key = focusedProjectionKey()
        let first = Task {
            try await gate.project(owner: UUID(), key: key, queuedWeight: 1) {
                try await harness.runBlocking(label: "stale-authored-input")
                return .init(label: "stale-authored-input")
            }
        }
        try await focusedWait { await harness.started == ["stale-authored-input"] }
        let second = Task {
            try await gate.project(owner: UUID(), key: key, queuedWeight: 1) {
                await harness.markStarted(label: "current-authored-input")
                return .init(label: "current-authored-input")
            }
        }
        try await focusedWait {
            let snapshot = await gate.snapshot()
            return snapshot.waiterCount == 2 || snapshot.queuedEntryCount == 1
        }
        await harness.release()

        let firstProjection = try await first.value
        let secondProjection = try await second.value
        guard firstProjection.label == "stale-authored-input",
              secondProjection.label == "current-authored-input",
              await harness.started == ["stale-authored-input", "current-authored-input"]
        else {
            fputs("FAIL: incomplete projection authority coalesced distinct authored inputs\n", stderr)
            exit(1)
        }
        print("PASS: distinct authored projections cannot substitute through gate coalescing")
    }
}

private actor FocusedProjectionGateHarness {
    private(set) var started: [String] = []
    private var isReleased = false

    func runBlocking(label: String) async throws {
        started.append(label)
        while !isReleased {
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func markStarted(label: String) {
        started.append(label)
    }

    func release() {
        isReleased = true
    }
}

private func focusedProjectionKey() -> NativeDecompilerProjectionKey {
    NativeDecompilerProjectionKey(
        imageSlot: .primary,
        ownerBinaryID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
        analysisInputFingerprintSHA256: String(repeating: "a", count: 64),
        functionID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    )
}

private func focusedWait(
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !(await condition()) {
        guard clock.now < deadline else { throw ProjectionGateTestError.timedOut }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private enum ProjectionGateTestError: Error {
    case timedOut
}

#else

import XCTest
@testable import MacScope

@MainActor
final class NativeDecompilerProjectionGateTests: XCTestCase {
    func testProjectionGateSerializesWorkBeforeNativeAdmission() async throws {
        let harness = ProjectionGateHarness()
        let gate = NativeDecompilerProjectionGate()
        let first = Task {
            try await gate.project(owner: UUID(), key: projectionKey("first"), queuedWeight: 4) {
                try await harness.run(label: "first")
                return makeProjection(label: "first")
            }
        }
        try await waitForProjectionGate { await harness.started == ["first"] }
        let second = Task {
            try await gate.project(owner: UUID(), key: projectionKey("second"), queuedWeight: 4) {
                try await harness.run(label: "second")
                return makeProjection(label: "second")
            }
        }
        try await waitForProjectionGate { await gate.snapshot().queuedEntryCount == 1 }
        let startsBeforeRelease = await harness.started
        XCTAssertEqual(startsBeforeRelease, ["first"])

        await harness.release("first")
        _ = try await first.value
        try await waitForProjectionGate { await harness.started == ["first", "second"] }
        await harness.release("second")
        _ = try await second.value
    }

    func testProjectionQueueWeightOverflowIsRejectedBeforeOperationStarts() async throws {
        let harness = ProjectionGateHarness()
        let gate = NativeDecompilerProjectionGate(configuration: .init(
            maximumQueuedEntries: 2,
            maximumQueuedWeight: 3
        ))
        let active = Task {
            try await gate.project(owner: UUID(), key: projectionKey("active"), queuedWeight: 100) {
                try await harness.run(label: "active")
                return makeProjection(label: "active")
            }
        }
        try await waitForProjectionGate { await harness.started == ["active"] }

        do {
            _ = try await gate.project(owner: UUID(), key: projectionKey("rejected"), queuedWeight: 4) {
                await harness.markUnexpectedStart()
                return makeProjection(label: "rejected")
            }
            XCTFail("projection above the queued-weight bound must fail closed")
        } catch let error as FairSingleLaneSchedulerError {
            XCTAssertEqual(error, .queuedWeightLimitReached(limit: 3))
        }
        let unexpectedStart = await harness.unexpectedStart
        XCTAssertFalse(unexpectedStart)
        await harness.release("active")
        _ = try await active.value
    }

    func testProjectionGateShutdownCancelsAndDrainsActiveProjection() async throws {
        let harness = ProjectionGateHarness()
        let gate = NativeDecompilerProjectionGate()
        let active = Task {
            try await gate.project(owner: UUID(), key: projectionKey("active"), queuedWeight: 1) {
                try await harness.run(label: "active")
                return makeProjection(label: "active")
            }
        }
        try await waitForProjectionGate { await harness.started == ["active"] }

        await gate.shutdown()
        _ = try? await active.value
        let cancellations = await harness.cancellations
        XCTAssertEqual(cancellations, 1)
        let snapshot = await gate.snapshot()
        XCTAssertTrue(snapshot.isShutDown)
        XCTAssertFalse(snapshot.hasActiveEntry)
        XCTAssertEqual(snapshot.waiterCount, 0)
    }

    func testIncompleteProjectionAuthorityDoesNotCoalesceDistinctAuthoredInputs() async throws {
        let harness = ProjectionGateHarness()
        let gate = NativeDecompilerProjectionGate()
        let key = projectionKey("shared")
        let first = Task {
            try await gate.project(owner: UUID(), key: key, queuedWeight: 4) {
                try await harness.run(label: "shared")
                return makeProjection(label: "shared")
            }
        }
        try await waitForProjectionGate { await harness.started == ["shared"] }
        let second = Task {
            try await gate.project(owner: UUID(), key: key, queuedWeight: 4) {
                try await harness.run(label: "replacement")
                return makeProjection(label: "replacement")
            }
        }
        try await waitForProjectionGate {
            let snapshot = await gate.snapshot()
            return snapshot.waiterCount == 2 || snapshot.queuedEntryCount == 1
        }

        await harness.release("shared")
        let firstProjection = try await first.value
        try await waitForProjectionGate { await harness.started == ["shared", "replacement"] }
        await harness.release("replacement")
        let secondProjection = try await second.value

        XCTAssertNotEqual(firstProjection, secondProjection)
        let started = await harness.started
        XCTAssertEqual(started, ["shared", "replacement"])
    }
}

private actor ProjectionGateHarness {
    private(set) var started: [String] = []
    private(set) var cancellations = 0
    private(set) var unexpectedStart = false
    private var released: Set<String> = []

    func run(label: String) async throws {
        started.append(label)
        do {
            while !released.contains(label) {
                try await Task.sleep(for: .milliseconds(1))
            }
        } catch is CancellationError {
            cancellations += 1
            throw CancellationError()
        }
    }

    func release(_ label: String) {
        released.insert(label)
    }

    func markUnexpectedStart() {
        unexpectedStart = true
    }
}

private func makeProjection(label: String) -> NativeDecompilerSnapshotProjection {
    let bytes = Data([0xc0, 0x03, 0x5f, 0xd6])
    return NativeDecompilerSnapshotProjection(
        coordinate: .init(
            imageSlot: .primary,
            ownerBinaryID: UUID(),
            analysisInputFingerprintSHA256: String(repeating: "a", count: 64)
        ),
        target: try! NativeDecompilerSealedTargetProfile.normalizedTarget(
            rawCPUType: 0x0100_000c,
            rawCPUSubtype: 0,
            selectedSliceSHA256: String(repeating: "b", count: 64),
            selectedSliceByteCount: UInt64(bytes.count)
        ),
        image: .init(
            imageID: "image:\(label)",
            uuid: UUID(),
            preferredLoadAddress: .init(0x1000)
        ),
        function: .init(
            functionID: "function:\(label)",
            name: label,
            entryAddress: .init(0x1000),
            endAddressExclusive: .init(0x1004)
        ),
        memoryRegions: [
            .init(
                name: "__text",
                startAddress: .init(0x1000),
                permissions: .readExecute,
                rawBytes: bytes,
                effectiveBytes: bytes,
                appliedPatchIDs: []
            ),
        ],
        symbols: [],
        authoredInputs: .empty
    )
}

private func waitForProjectionGate(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else { throw ProjectionGateTestError.timedOut }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private enum ProjectionGateTestError: Error {
    case timedOut
}

private func projectionKey(_ label: String) -> NativeDecompilerProjectionKey {
    NativeDecompilerProjectionKey(
        imageSlot: .primary,
        ownerBinaryID: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
        analysisInputFingerprintSHA256: String(repeating: label.first ?? "a", count: 64),
        functionID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    )
}

#endif
