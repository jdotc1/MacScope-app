import Foundation

enum WorkspaceBottomDeck: String, CaseIterable, Identifiable {
    case debugger
    case shell

    var id: String { rawValue }
    var title: String { self == .debugger ? "Debugger" : "Shell" }
    var systemImage: String { self == .debugger ? "ladybug" : "terminal" }
}

/// Window UI state only. It carries no debugger, PTY, or persisted workspace authority.
struct WorkspaceBottomPanelPresentation: Equatable {
    var isPresented = true
    var selectedDeck: WorkspaceBottomDeck = .debugger
    var debuggerTab: DebuggerDeckTab = .console
    private(set) var debuggerUserHeight: CGFloat?
    private(set) var shellUserHeight: CGFloat?

    mutating func show(_ deck: WorkspaceBottomDeck) {
        selectedDeck = deck
        isPresented = true
    }

    mutating func routeSidebarSelection(_ identifier: String?) {
        switch identifier {
        case "debug:breakpoints":
            debuggerTab = .breakpoints
        case "debug:session", "debug:console":
            debuggerTab = .console
        default:
            return
        }
        show(.debugger)
    }

    func preferredHeight(debuggerExpanded: Bool) -> CGFloat {
        switch selectedDeck {
        case .debugger: debuggerUserHeight ?? (debuggerExpanded ? 148 : 48)
        case .shell: shellUserHeight ?? 148
        }
    }

    subscript(isPresentedIn geometry: DSBottomPanelGeometry) -> Bool {
        get { isPresented && geometry.canPresent }
        set { isPresented = newValue }
    }

    /// The getter clamps for this window size without erasing the user's larger preference.
    /// Only a divider gesture writes a new preference; compact/live defaults stay automatic
    /// until that first user adjustment, independently for each deck.
    subscript(heightIn geometry: DSBottomPanelGeometry, debuggerExpanded expanded: Bool) -> CGFloat {
        get { geometry.clampedPanelHeight(preferredHeight(debuggerExpanded: expanded)) }
        set {
            let height = geometry.clampedPanelHeight(newValue)
            switch selectedDeck {
            case .debugger: debuggerUserHeight = height
            case .shell: shellUserHeight = height
            }
        }
    }
}

enum DebuggerDeckTab: String, CaseIterable, Identifiable {
    case console
    case threads
    case frames
    case breakpoints
    case registers
    case variables
    case memory
    case problems

    var id: String { rawValue }

    var title: String {
        switch self {
        case .console: "Console"
        case .threads: "Threads"
        case .frames: "Frames"
        case .breakpoints: "Breakpoints"
        case .registers: "Registers"
        case .variables: "Variables"
        case .memory: "Memory"
        case .problems: "Problems"
        }
    }

    var systemImage: String {
        switch self {
        case .console: "terminal"
        case .threads: "point.3.connected.trianglepath.dotted"
        case .frames: "square.stack.3d.down.right"
        case .breakpoints: "lumen.breakpoint"
        case .registers: "cpu"
        case .variables: "curlybraces.square"
        case .memory: "memorychip"
        case .problems: "exclamationmark.triangle"
        }
    }
}
