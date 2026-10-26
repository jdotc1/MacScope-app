import Foundation

/// MacScope-owned action vocabulary. Ghostty implementation types stop at the host adapter.
enum MacScopeGhosttyAction: Equatable, Sendable {
    case render
    case wakeup
    case selectionChanged
    case pointerChanged(MacScopeGhosttyPointerStyle)
    case titleChanged(String)
    case workingDirectoryChanged(String)
    case bell
    case closeSurface
    case activateHyperlink(String, activation: MacScopeGhosttyActivation)
    case rendererHealth(MacScopeGhosttyRendererHealth)
    case osc52ClipboardControl
    case application(MacScopeGhosttyApplicationAction)
}

enum MacScopeGhosttyPointerStyle: Equatable, Sendable {
    case arrow
    case text
    case pointingHand
    case hidden
}

enum MacScopeGhosttyRendererHealth: Equatable, Sendable {
    case healthy
    case unhealthy
}

enum MacScopeGhosttyActivation: Equatable, Sendable {
    case directHuman
    case keyboardProtocol
    case terminalProgram
    case replay
}

/// Ghostty application-shell actions are represented exhaustively and uniformly denied.
enum MacScopeGhosttyApplicationAction: CaseIterable, Hashable, Sendable {
    case newWindow
    case closeWindow
    case newTab
    case closeTab
    case splitHorizontal
    case splitVertical
    case closeSplit
    case quitApplication
    case checkForUpdates
    case applyUpdate
    case reloadConfiguration
    case openConfiguration
    case showNotification
    case installShellIntegration
    case launchChildProcess
    case unsupportedNativeAction
}

struct MacScopeGhosttyActionRouter: Sendable {
    struct Limits: Equatable, Sendable {
        static let `default` = Limits(
            maximumTitleByteCount: 256,
            maximumWorkingDirectoryByteCount: 1_024,
            maximumHyperlinkByteCount: 2_048
        )

        let maximumTitleByteCount: Int
        let maximumWorkingDirectoryByteCount: Int
        let maximumHyperlinkByteCount: Int

        init(
            maximumTitleByteCount: Int,
            maximumWorkingDirectoryByteCount: Int,
            maximumHyperlinkByteCount: Int
        ) {
            self.maximumTitleByteCount = min(max(1, maximumTitleByteCount), 4_096)
            self.maximumWorkingDirectoryByteCount = min(
                max(1, maximumWorkingDirectoryByteCount),
                16_384
            )
            self.maximumHyperlinkByteCount = min(max(1, maximumHyperlinkByteCount), 16_384)
        }
    }

    enum Intent: Equatable, Sendable {
        case scheduleRender
        case wakeup
        case selectionChanged
        case pointerChanged(MacScopeGhosttyPointerStyle)
        case updateTitleMetadata(String)
        case updateWorkingDirectoryMetadata(String)
        case bell
        case requestClose
        case activateHyperlink(URL)
        case rendererHealth(MacScopeGhosttyRendererHealth)
    }

    enum Denial: Equatable, Sendable {
        case applicationAuthority
        case clipboardControlDisabled
        case indirectActivation
        case invalidActivation
    }

    enum Decision: Equatable, Sendable {
        case perform(Intent)
        case denied(Denial)
    }

    private let limits: Limits
    private let diagnostics: MacScopeGhosttySurfaceDiagnostics

    init(
        limits: Limits = .default,
        diagnostics: MacScopeGhosttySurfaceDiagnostics = MacScopeGhosttySurfaceDiagnostics()
    ) {
        self.limits = limits
        self.diagnostics = diagnostics
    }

    func route(_ action: MacScopeGhosttyAction) -> Decision {
        let category: MacScopeGhosttySurfaceDiagnostics.ActionCategory
        let decision: Decision

        switch action {
        case .render:
            category = .render
            decision = .perform(.scheduleRender)
        case .wakeup:
            category = .wakeup
            decision = .perform(.wakeup)
        case .selectionChanged:
            category = .selection
            decision = .perform(.selectionChanged)
        case let .pointerChanged(style):
            category = .pointer
            decision = .perform(.pointerChanged(style))
        case let .titleChanged(value):
            category = .titleMetadata
            decision = .perform(.updateTitleMetadata(Self.boundedMetadata(
                value,
                maximumUTF8ByteCount: limits.maximumTitleByteCount
            )))
        case let .workingDirectoryChanged(value):
            category = .workingDirectoryMetadata
            decision = .perform(.updateWorkingDirectoryMetadata(Self.boundedMetadata(
                value,
                maximumUTF8ByteCount: limits.maximumWorkingDirectoryByteCount
            )))
        case .bell:
            category = .bell
            decision = .perform(.bell)
        case .closeSurface:
            category = .close
            decision = .perform(.requestClose)
        case let .activateHyperlink(rawValue, activation):
            category = .hyperlink
            decision = routeHyperlink(rawValue, activation: activation)
        case let .rendererHealth(health):
            category = .render
            decision = .perform(.rendererHealth(health))
        case .osc52ClipboardControl:
            category = .clipboardControl
            decision = .denied(.clipboardControlDisabled)
        case let .application(applicationAction):
            category = .applicationLifecycle
            decision = routeApplicationAction(applicationAction)
        }

        record(decision, category: category)
        return decision
    }

    private func routeHyperlink(
        _ rawValue: String,
        activation: MacScopeGhosttyActivation
    ) -> Decision {
        guard activation == .directHuman else {
            return .denied(.indirectActivation)
        }
        guard rawValue.utf8.count <= limits.maximumHyperlinkByteCount,
              let components = URLComponents(string: rawValue),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.user == nil,
              components.password == nil,
              let host = components.host,
              !host.isEmpty,
              let url = components.url else {
            return .denied(.invalidActivation)
        }
        return .perform(.activateHyperlink(url))
    }

    private func routeApplicationAction(_ action: MacScopeGhosttyApplicationAction) -> Decision {
        switch action {
        case .newWindow,
             .closeWindow,
             .newTab,
             .closeTab,
             .splitHorizontal,
             .splitVertical,
             .closeSplit,
             .quitApplication,
             .checkForUpdates,
             .applyUpdate,
             .reloadConfiguration,
             .openConfiguration,
             .showNotification,
             .installShellIntegration,
             .launchChildProcess,
             .unsupportedNativeAction:
            .denied(.applicationAuthority)
        }
    }

    private func record(
        _ decision: Decision,
        category: MacScopeGhosttySurfaceDiagnostics.ActionCategory
    ) {
        switch decision {
        case .perform:
            diagnostics.record(.actionAccepted(category))
        case let .denied(reason):
            let diagnosticReason: MacScopeGhosttySurfaceDiagnostics.ActionRejection = switch reason {
            case .applicationAuthority: .applicationAuthority
            case .clipboardControlDisabled: .clipboardControlDisabled
            case .indirectActivation: .indirectActivation
            case .invalidActivation: .invalidActivation
            }
            diagnostics.record(.actionRejected(category, diagnosticReason))
        }
    }

    private static func boundedMetadata(
        _ value: String,
        maximumUTF8ByteCount: Int
    ) -> String {
        var result = ""
        result.reserveCapacity(min(value.count, maximumUTF8ByteCount))
        var acceptedByteCount = 0

        for scalar in value.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) {
                continue
            }
            let scalarByteCount = scalar.utf8.count
            guard scalarByteCount <= maximumUTF8ByteCount - acceptedByteCount else { break }
            result.unicodeScalars.append(scalar)
            acceptedByteCount += scalarByteCount
        }
        return result
    }
}
