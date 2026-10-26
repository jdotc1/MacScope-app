import Foundation
import XCTest
@testable import MacScope

@MainActor
final class MCPTypeReadBudgetTests: XCTestCase {
    private func makeStore(fieldCount: Int = 1) -> WorkspaceStore {
        var analysis = ImageAnalysis()
        analysis.swiftTypes = [SwiftTypeDescriptor(kind: .struct, name: "Point",
            fields: [SwiftField(name: "x", typeName: "Int")], descriptorAddress: 0x8000)]
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "types", path: "/types", kind: "Mach-O", architecture: "arm64")],
            analysisBySlot: [.primary: analysis],
            typeDefinitions: [TypeDefinition(kind: .struct, name: "UserPoint",
                fields: (0..<fieldCount).map { FieldDef(name: "v\($0)", type: "int") })])
        return WorkspaceStore(workspaceName: "type-read", snapshot: snapshot,
                              engine: AnalysisEngine(), autosaveScheduler: nil)
    }

    func testImageTypePreparationAllowsMainActorSentinelAndRevocation() async throws {
        try await checkPreparationAndRevocation(command: "list-image-types")
    }

    func testUserTypePreparationAllowsMainActorSentinelAndRevocation() async throws {
        try await checkPreparationAndRevocation(command: "list-types")
    }

    private func checkPreparationAndRevocation(command: String) async throws {
        let store = makeStore()
        let gate = TypePreparationGate()
        let executor = MCPAttachExecutor(store: store, api: {
            WorkspaceScriptingAPI(store: $0, snapshotReadCheckpoint: { gate.park() })
        })
        executor.setConsent(.allowed)
        let read = Task { try await executor.execute(command, .object([:])) }
        let parked = await gate.waitUntilParked()
        XCTAssertTrue(parked, "type preparation must reach the injected checkpoint")
        // This continuation is a MainActor sentinel; it must run while preparation is parked.
        executor.setConsent(.revoked)
        gate.release()
        XCTAssertFalse(gate.expired, "preparation blocked the MainActor sentinel")
        do {
            _ = try await read.value
            XCTFail("revoked type read released its result")
        } catch { }
        XCTAssertTrue(gate.sawCancellation, "Disconnect must cancel request-owned preparation")
    }

    func testTypeReadRefusesOversizedNestedFieldsBeforeMaterialization() async throws {
        let store = makeStore(fieldCount: 5_001)
        let executor = MCPAttachExecutor(store: store, api: { WorkspaceScriptingAPI(store: $0) })
        executor.setConsent(.allowed)
        do {
            _ = try await executor.execute("list-types", .object([:]))
            XCTFail("type result exceeded the finite nested-value budget")
        } catch { }
    }

    func testInBudgetTypeReadsMatchExistingReplyShapes() async throws {
        let store = makeStore()
        let api = WorkspaceScriptingAPI(store: store)
        let executor = MCPAttachExecutor(store: store, api: { WorkspaceScriptingAPI(store: $0) })
        executor.setConsent(.allowed)
        for command in ["list-types", "list-image-types"] {
            let expected = try api.execute(command, arguments: .object([:]))
            let actual = try await executor.execute(command, .object([:]))
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(try actual.jsonData(), try expected.jsonData())
        }
    }
}

/// Deadlines are failure bounds only; the test asserts checkpoint ordering, never elapsed work.
private final class TypePreparationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let parked = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private var checkpoints = 0
    private var cancelled = false
    private var didExpire = false

    var expired: Bool { lock.withLock { didExpire } }
    var sawCancellation: Bool { lock.withLock { cancelled } }

    func park() {
        let first = lock.withLock {
            checkpoints += 1
            // Park inside field preparation, after entry, preflight and definition checkpoints.
            return checkpoints == 4
        }
        guard first else { return }
        parked.signal()
        if resume.wait(timeout: .now() + 2) == .timedOut {
            lock.withLock { didExpire = true }
        }
        lock.withLock { cancelled = Task.isCancelled }
    }

    func waitUntilParked() async -> Bool {
        await Task.detached { [self] in blockUntilParked() }.value
    }

    private func blockUntilParked() -> Bool { parked.wait(timeout: .now() + 2) == .success }

    func release() { resume.signal() }
}
