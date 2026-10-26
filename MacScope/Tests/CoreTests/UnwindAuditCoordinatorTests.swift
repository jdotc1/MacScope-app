import Foundation
import XCTest
@testable import MacScope

private actor SuspendedUnwindAudit {
    private var continuation: CheckedContinuation<UnwindAuditReport, any Error>?
    private var started: CheckedContinuation<Void, Never>?

    func run() async throws -> UnwindAuditReport {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ report: UnwindAuditReport) {
        continuation?.resume(returning: report)
        continuation = nil
    }
}

@MainActor
final class UnwindAuditCoordinatorTests: XCTestCase {
    private func input() throws -> (LoadedBinary, UnwindAuditResultKey) {
        let identity = try MachOSliceArtifactIdentity(uuid: nil, rawCPUType: 0x0100000c,
            rawCPUSubtype: 0, selectedSliceSHA256: String(repeating: "a", count: 64), selectedSliceByteCount: 64)
        let key = UnwindAuditResultKey(imageID: UUID(), slot: .primary, generation: UUID(),
            identity: identity, modelID: UnwindAuditResultKey.currentModelID, configuration: .init())
        let binary = LoadedBinary(name: "authored", path: "", isBundle: false, cpuType: 0x0100000c,
            cpuSubtype: 0, fileTypeName: "Mach-O", architectureDisplayName: "arm64", metadata: .empty,
            artifactIdentity: identity, artifactIntegrityState: .verified, bytes: Data(repeating: 0, count: 64),
            sliceOffset: 0, sections: [], executableTextSection: nil, entryPointAddress: nil,
            symbols: [], imports: [], indirectSymbols: [], exports: [], stringLiterals: [],
            functionStarts: [], objcSelectors: [:])
        return (binary, key)
    }

    func testMatchingCompletionPublishes() async throws {
        let (binary, key) = try input()
        let report = UnwindAuditReport(identity: key.identity, findings: [])
        let coordinator = UnwindAuditCoordinator(runner: { _, _ in report })
        let task = try XCTUnwrap(coordinator.start(binary: binary, key: key))
        await task.value
        XCTAssertEqual(coordinator.state.phase, .completed)
        XCTAssertEqual(coordinator.state.report, report)
    }

    func testCancellationRejectsUncooperativeLateCompletion() async throws {
        let (binary, key) = try input()
        let runner = SuspendedUnwindAudit()
        let coordinator = UnwindAuditCoordinator(runner: { _, _ in try await runner.run() })
        let task = try XCTUnwrap(coordinator.start(binary: binary, key: key))
        await runner.waitUntilStarted()
        coordinator.cancel()
        XCTAssertEqual(coordinator.state.phase, .cancelled)
        await runner.finish(.init(identity: key.identity, findings: []))
        await task.value
        XCTAssertNil(coordinator.state.report)
        XCTAssertEqual(coordinator.state.phase, .cancelled)
        XCTAssertEqual(coordinator.state.discardedPublicationCount, 1)
    }

    func testImageChangeRejectsLateCompletion() async throws {
        let (binary, key) = try input()
        let runner = SuspendedUnwindAudit()
        let coordinator = UnwindAuditCoordinator(runner: { _, _ in try await runner.run() })
        let task = try XCTUnwrap(coordinator.start(binary: binary, key: key))
        await runner.waitUntilStarted()
        coordinator.activate(nil)
        await runner.finish(.init(identity: key.identity, findings: []))
        await task.value
        XCTAssertNil(coordinator.state.report)
        XCTAssertEqual(coordinator.state.phase, .idle)
        XCTAssertEqual(coordinator.state.discardedPublicationCount, 1)
    }

    func testUnverifiedInputNeverRuns() throws {
        var (binary, key) = try input()
        binary.artifactIntegrityState = .unavailable
        let coordinator = UnwindAuditCoordinator(runner: { _, _ in
            XCTFail("Unverified input entered runner")
            throw CancellationError()
        })
        XCTAssertNil(coordinator.start(binary: binary, key: key))
        guard case .failed = coordinator.state.phase else { return XCTFail("Expected refusal") }
        XCTAssertNil(coordinator.state.report)
    }
}
