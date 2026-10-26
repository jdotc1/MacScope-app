import Foundation
import XCTest
@testable import MacScope

/// DP23 regression source authored before restoring the removed watchpoint APIs.
/// Baseline failure is missing-API compilation, not an observed behavioral failure.
@MainActor
final class DebuggerWatchpointRestorationTests: XCTestCase {
    func testPanelDispatchesAllWatchpointOperationsThroughTypedClient() async {
        let client = DP23WatchpointClient(snapshot: Self.pausedSnapshot)
        let model = DebuggerPanelViewModel(client: client)
        let id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let operations: [DebuggerWatchpointRequest] = [
            .upsert(id: id, address: 0x1000, size: 8, access: .readWrite, isEnabled: true),
            .setEnabled(id: id, isEnabled: false),
            .refresh,
            .remove(id: id),
        ]
        XCTAssertTrue(model.canEditWatchpoints)
        for operation in operations { await model.updateWatchpoints(operation) }
        XCTAssertEqual(client.requests, operations)
        XCTAssertEqual(model.session.watchpoints, client.publishedWatchpoints)
        XCTAssertEqual(model.session.watchpointError, "synthetic capacity refusal")
        XCTAssertEqual(model.lastError, "synthetic capacity refusal")
    }

    func testRunningAndRetiredPanelDoNotDispatchWatchpointMutation() async {
        var running = Self.pausedSnapshot
        running.processState = .running(processID: 222, executableName: "fixture")
        let runningClient = DP23WatchpointClient(snapshot: running)
        let runningModel = DebuggerPanelViewModel(client: runningClient)
        XCTAssertFalse(runningModel.canEditWatchpoints)
        await runningModel.updateWatchpoints(.refresh)
        XCTAssertTrue(runningClient.requests.isEmpty)

        let retiredClient = DP23WatchpointClient(snapshot: Self.pausedSnapshot)
        let retiredModel = DebuggerPanelViewModel(client: retiredClient)
        await retiredModel.beginWorkspaceRetirement().value
        XCTAssertFalse(retiredModel.canEditWatchpoints)
        await retiredModel.updateWatchpoints(.refresh)
        XCTAssertTrue(retiredClient.requests.isEmpty)
    }

    func testEditorAndDeckRetainTypedWatchpointRoute() throws {
        let point = DebuggerWatchpoint(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            address: 0x2000, size: 2, access: .read, isEnabled: false, backendID: 7)
        var draft = WatchpointEditorDraft(watchpoint: point)
        XCTAssertEqual(draft.request, .upsert(id: point.id, address: 0x2000,
            size: 2, access: .read, isEnabled: false))
        draft.addressText = "0x2001"
        XCTAssertNil(draft.request)
        var requests: [DebuggerWatchpointRequest] = []
        let deck = WatchpointsDeckView(watchpoints: [point], canEdit: true,
            error: nil, onRequest: { requests.append($0) })
        deck.onRequest(.remove(id: point.id))
        XCTAssertEqual(requests, [.remove(id: point.id)])
    }

    func testTypedOperationIsStoppedMutationAndTransportRecordRoundTrips() throws {
        XCTAssertEqual(DebuggerOperation.updateWatchpoints.classification, .stoppedStateMutating)
        XCTAssertTrue(DebuggerOperation.updateWatchpoints.requiresStopCoordinate)
        let point = DebuggerWatchpoint(id: UUID(), address: 0x3000, size: 4,
            access: .write, isEnabled: true, backendID: 1)
        let update = DebuggerWatchpointUpdate(watchpoints: [point], error: nil)
        let record = LLDBWatchpointProgram.marker + String(decoding: try JSONEncoder().encode(update), as: UTF8.self)
        XCTAssertEqual(try LLDBWatchpointProgram.decode(transcript: record), update)
        XCTAssertThrowsError(try LLDBWatchpointProgram.decode(transcript: record + "\n" + record))
    }

    private static var pausedSnapshot: DebuggerSessionSnapshot {
        DebuggerSessionSnapshot(
            processState: .paused(processID: 222, reason: .breakpoint(address: 0x1000)),
            breakpoints: [], frames: [], registers: [], memoryRegions: [],
            statusMessage: "Synthetic stopped session",
            backendState: .connected(processID: 222, adapterName: "DP23 recording client"))
    }
}

@MainActor
private final class DP23WatchpointClient: DebuggerClient {
    let snapshot: DebuggerSessionSnapshot
    var requests: [DebuggerWatchpointRequest] = []
    let publishedWatchpoints = [DebuggerWatchpoint(
        id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
        address: 0x4000, size: 8, access: .write, isEnabled: true, backendID: 3)]
    let capabilities = DebuggerCapabilityReport(backendName: "DP23 recording client",
        isBackendAvailable: true, canLaunch: true, canAttach: false,
        canControlExecution: true, limitations: [], entitlementNotes: [])
    init(snapshot: DebuggerSessionSnapshot) { self.snapshot = snapshot }
    func makeInitialSnapshot() -> DebuggerSessionSnapshot { snapshot }
    func launch(_ configuration: DebuggerLaunchConfiguration) async throws -> DebuggerSessionSnapshot { snapshot }
    func continueExecution(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func stepOver(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func pause(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func terminate(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func replaceBreakpoints(_ breakpoints: [DebuggerBreakpoint], from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func refreshSnapshot(from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot { snapshot }
    func updateWatchpoints(_ request: DebuggerWatchpointRequest, from snapshot: DebuggerSessionSnapshot) async throws -> DebuggerSessionSnapshot {
        requests.append(request)
        var result = snapshot
        result.watchpoints = publishedWatchpoints
        result.watchpointError = "synthetic capacity refusal"
        return result
    }
}
