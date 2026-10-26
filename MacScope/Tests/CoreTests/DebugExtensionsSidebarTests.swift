import Foundation
import LumenUI
import SwiftUI
import XCTest
@testable import MacScope

/// The Debug sidebar reflects the window's debugger session; Extensions no longer describes a
/// plugin SDK and host that this build doesn't run.
@MainActor
final class DebugExtensionsSidebarTests: XCTestCase {
    private func session(_ process: DebuggerProcessState, _ backend: DebuggerBackendSessionState) -> DebuggerSessionSnapshot {
        var snapshot = DebuggerSessionSnapshot.empty
        snapshot.processState = process
        snapshot.backendState = backend
        return snapshot
    }

    func testSummaryFollowsTheSession() {
        XCTAssertEqual(DebuggerSidebarSummary.notStarted.sessionTitle, "No debugger session")
        XCTAssertEqual(DebuggerSidebarSummary.notStarted.consoleDetail, "Idle")
        let running = DebuggerSidebarSummary(session(.running(processID: 4242, executableName: "ls"),
                                                     .connected(processID: 4242, adapterName: "LLDB")))
        XCTAssertEqual(running.sessionTitle, "Running · pid 4242")
        XCTAssertEqual(running.consoleDetail, "LLDB · pid 4242")
        let paused = DebuggerSidebarSummary(session(.paused(processID: 7, reason: .breakpoint(address: 0x1000)), .connected(processID: 7, adapterName: "LLDB")))
        XCTAssertEqual(paused.sessionTitle, "Paused · pid 7")
        let idle = DebuggerSidebarSummary(session(.notAttached, .ready(adapterName: "LLDB")))
        XCTAssertEqual(idle.sessionTitle, "No debugger session", "nothing attached, even with LLDB ready")
        XCTAssertEqual(idle.consoleDetail, "Idle", "no \"ready\" that reads like a live session")
    }

    func testStoreRowsUseTheSummaryAndExtensionsAreHonest() throws {
        let code = Data([0xc0, 0x03, 0x5f, 0xd6])
        let url = try TinyMachO.make(code: code).write()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try MCPLauncher.makeStore(binaryURL: url)
        store.debuggerSidebarSummary = DebuggerSidebarSummary(session(.running(processID: 9, executableName: "x"),
                                                                      .connected(processID: 9, adapterName: "LLDB")))
        let debug = store.debugSidebarItems
        XCTAssertEqual(debug.first { $0.id == "debug:session" }?.detail, "Running · pid 9")
        XCTAssertEqual(debug.first { $0.id == "debug:console" }?.detail, "LLDB · pid 9")
        XCTAssertFalse(debug.contains { $0.detail == "LLDB bridge pending" })
        XCTAssertEqual(store.extensionsSidebarItems.map(\.title), ["No plugins loaded"])
    }

    func testRenderSidebarRowsForReview() throws {
        let running = DebuggerSidebarSummary(session(.paused(processID: 4242, reason: .breakpoint(address: 0x1000)),
                                                     .connected(processID: 4242, adapterName: "LLDB")))
        let rows: [(String, String, String)] = [
            ("Session", running.sessionTitle, running.sessionImage),
            ("Breakpoints", "3 saved · 2 enabled", "lumen.breakpoint"),
            ("Console", running.consoleDetail, "terminal"),
        ]
        try UIReviewShots.write("sidebar-debug-extensions", size: CGSize(width: 320, height: 300)) {
            VStack(alignment: .leading, spacing: 1) {
                Text("DEBUG").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 4)
                ForEach(rows, id: \.0) { row in
                    LumenListRow(row.0, detail: row.1, systemImage: row.2, context: .sidebar)
                }
                Text("EXTENSIONS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.vertical, 4)
                LumenListRow("No plugins loaded", detail: "Plugin loading isn't active in this build",
                             systemImage: "puzzlepiece.extension", context: .sidebar)
            }
            .padding(Lumen.Space.s4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .lumenSidebarBackground()
        }
    }

    func testRenderIdleDebugSidebarForReview() throws {
        let idle = DebuggerSidebarSummary.notStarted
        try UIReviewShots.write("live-fix-3-debug-sidebar-idle", size: CGSize(width: 320, height: 210)) {
            VStack(alignment: .leading, spacing: 1) {
                Text("DEBUG").font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 4)
                LumenListRow("Session", detail: idle.sessionTitle, systemImage: idle.sessionImage, context: .sidebar)
                LumenListRow("Breakpoints", detail: "0 saved · 0 enabled", systemImage: "lumen.breakpoint", context: .sidebar)
                LumenListRow("Console", detail: idle.consoleDetail, systemImage: "terminal", context: .sidebar)
            }
            .padding(Lumen.Space.s4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .lumenSidebarBackground()
        }
    }
}
