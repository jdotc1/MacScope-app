import Foundation

/// What the Debug sidebar shows about this window's debugger session. The editor's
/// `DebuggerPanelViewModel` owns the session; it publishes this summary into the store whenever
/// the session changes, so the sidebar never shows a hard-coded state.
struct DebuggerSidebarSummary: Equatable {
    var sessionTitle: String
    var sessionImage: String
    var consoleDetail: String

    static let notStarted = DebuggerSidebarSummary(sessionTitle: "No debugger session", sessionImage: "pause.circle",
                                                   consoleDetail: "Idle")

    init(sessionTitle: String, sessionImage: String, consoleDetail: String) {
        self.sessionTitle = sessionTitle
        self.sessionImage = sessionImage
        self.consoleDetail = consoleDetail
    }

    init(_ session: DebuggerSessionSnapshot) {
        let pid: Int32?
        switch session.processState {
        case .running(let processID, _), .paused(let processID, _), .detaching(let processID): pid = processID
        case .batchStopped(let processID, _): pid = processID
        default: pid = nil
        }
        sessionImage = session.processState.systemImage
        if case .notAttached = session.processState {
            // Nothing attached: say so plainly; "ready" on the console row read as a live session.
            sessionTitle = "No debugger session"
            switch session.backendState {
            case .unavailable: consoleDetail = "LLDB unavailable"
            case .failed: consoleDetail = "LLDB failed; see the Debug panel"
            default: consoleDetail = "Idle"
            }
            return
        }
        sessionTitle = session.processState.displayTitle + (pid.map { " · pid \($0)" } ?? "")
        switch session.backendState {
        case .disconnected: consoleDetail = "No debugger session"
        case .unavailable: consoleDetail = "LLDB unavailable"
        case .discovered: consoleDetail = "LLDB found, not connected"
        case .ready(let adapter): consoleDetail = "\(adapter) ready"
        case .launching: consoleDetail = "Launching"
        case .connected(let processID, let adapter): consoleDetail = "\(adapter) · pid \(processID)"
        case .disconnecting: consoleDetail = "Disconnecting"
        case .failed: consoleDetail = "LLDB failed; see the Debug panel"
        }
    }
}

extension WorkspaceStore {
    /// Debug rows: the live session state, the saved breakpoints, and the LLDB backend state.
    var debugSidebarItems: [SidebarItem] {
        let summary = debuggerSidebarSummary
        return [
            SidebarItem(id: "debug:session", title: "Session", detail: summary.sessionTitle, systemImage: summary.sessionImage),
            SidebarItem(
                id: "debug:breakpoints",
                title: "Breakpoints",
                detail: "\(logicalBreakpointCount) saved · \(enabledLogicalBreakpointCount) enabled",
                systemImage: "lumen.breakpoint"
            ),
            SidebarItem(id: "debug:console", title: "Console", detail: summary.consoleDetail, systemImage: "terminal"),
        ]
    }

    /// Extensions: plugins are not loaded by this build (no plugin registry runs in the app), so
    /// one row says so instead of describing an SDK and host that aren't active.
    var extensionsSidebarItems: [SidebarItem] {
        [SidebarItem(id: "extensions:none", title: "No plugins loaded",
                     detail: "Plugin loading isn't active in this build", systemImage: "puzzlepiece.extension")]
    }
}
