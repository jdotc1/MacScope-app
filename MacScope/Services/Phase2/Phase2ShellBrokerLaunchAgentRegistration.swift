import Foundation
import OSLog
import ServiceManagement

protocol Phase2ShellBrokerLaunchAgentServicing: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
}

extension SMAppService: Phase2ShellBrokerLaunchAgentServicing {}

enum Phase2ShellBrokerEndpoint: Equatable, Sendable {
    case embeddedApplicationService
    case persistentLaunchAgent
}

enum Phase2ShellBrokerLaunchAgentState: Equatable, Sendable {
    case developmentFallback
    case enabled
    case notRegistered
    case requiresApproval
    case notFound
    case registrationFailed

    var endpoint: Phase2ShellBrokerEndpoint {
        self == .enabled ? .persistentLaunchAgent : .embeddedApplicationService
    }
}

/// Process-local endpoint selection for the ShellBroker.
///
/// Registration is deliberately limited to an app installed at the canonical
/// `/Applications/MacScope.app` path. Development products and test hosts keep using the embedded
/// XPC service, so a build never mutates the user's login-item state accidentally.
enum Phase2ShellBrokerLaunchAgentRegistration {
    static let plistName = "org.macscope.app.ShellBroker.agent.plist"
    static let machServiceName = "org.macscope.app.ShellBroker.agent"
    static let maximumDiagnosticBytes = 512

    private static let lock = NSLock()
    private static let preparationLock = NSLock()
    private static let logger = Logger(
        subsystem: "org.macscope.app",
        category: "ShellBrokerLaunchAgentRegistration"
    )
    private nonisolated(unsafe) static var selectedState: Phase2ShellBrokerLaunchAgentState =
        .developmentFallback
    private nonisolated(unsafe) static var selectedDiagnostic = "Development build uses embedded broker."

    static var endpoint: Phase2ShellBrokerEndpoint {
        lock.withLock { selectedState.endpoint }
    }

    static var state: Phase2ShellBrokerLaunchAgentState {
        lock.withLock { selectedState }
    }

    static var diagnostic: String {
        lock.withLock { selectedDiagnostic }
    }

    static func prepareForApplicationLaunch(
        bundleURL: URL = Bundle.main.bundleURL,
        service: (any Phase2ShellBrokerLaunchAgentServicing)? = nil
    ) {
        preparationLock.lock()
        defer { preparationLock.unlock() }
        guard isCanonicalInstalledApplication(bundleURL) else {
            setState(.developmentFallback, diagnostic: "Non-installed build uses embedded broker.")
            return
        }

        let agent: any Phase2ShellBrokerLaunchAgentServicing = service
            ?? SMAppService.agent(plistName: plistName)
        let initialStatus = agent.status
        if shouldAttemptRegistration(status: initialStatus) {
            do {
                try agent.register()
            } catch {
                setState(
                    .registrationFailed,
                    diagnostic: "Persistent ShellBroker LaunchAgent registration failed: \(error.localizedDescription)"
                )
                return
            }
            switch agent.status {
            case .enabled:
                setState(.enabled, diagnostic: "Persistent ShellBroker LaunchAgent registered and enabled.")
            case .requiresApproval:
                setState(
                    .requiresApproval,
                    diagnostic: "Persistent ShellBroker LaunchAgent registered and requires user approval."
                )
            case .notFound:
                setState(
                    .notFound,
                    diagnostic: "Persistent ShellBroker LaunchAgent remains unavailable after registration."
                )
            case .notRegistered:
                setState(
                    .notRegistered,
                    diagnostic: "Persistent ShellBroker LaunchAgent remains unregistered after registration."
                )
            @unknown default:
                setState(.registrationFailed, diagnostic: "Persistent ShellBroker LaunchAgent returned an unknown status.")
            }
            return
        }

        switch initialStatus {
        case .enabled:
            setState(.enabled, diagnostic: "Persistent ShellBroker LaunchAgent is enabled.")
        case .requiresApproval:
            setState(.requiresApproval, diagnostic: "Persistent ShellBroker LaunchAgent requires user approval.")
        case .notFound, .notRegistered:
            assertionFailure("Registration-eligible status bypassed registration policy.")
            setState(.registrationFailed, diagnostic: "Persistent ShellBroker LaunchAgent registration policy failed.")
        @unknown default:
            setState(.registrationFailed, diagnostic: "Persistent ShellBroker LaunchAgent returned an unknown status.")
        }
    }

    static func shouldAttemptRegistration(status: SMAppService.Status) -> Bool {
        status == .notFound || status == .notRegistered
    }

    static func isCanonicalInstalledApplication(_ bundleURL: URL) -> Bool {
        bundleURL.standardizedFileURL.path == "/Applications/MacScope.app"
    }

    private static func setState(
        _ state: Phase2ShellBrokerLaunchAgentState,
        diagnostic: String
    ) {
        let diagnostic = boundedDiagnostic(diagnostic)
        lock.withLock {
            selectedState = state
            selectedDiagnostic = diagnostic
        }
        logger.notice("ShellBroker LaunchAgent state: \(String(describing: state), privacy: .public)")
        logger.debug("ShellBroker LaunchAgent detail: \(diagnostic, privacy: .private(mask: .hash))")
    }

    private static func boundedDiagnostic(_ diagnostic: String) -> String {
        guard diagnostic.utf8.count > maximumDiagnosticBytes else { return diagnostic }
        let marker = "…"
        let contentBudget = maximumDiagnosticBytes - marker.utf8.count
        var bounded = ""
        var byteCount = 0
        for character in diagnostic {
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= contentBudget else { break }
            bounded.append(character)
            byteCount += characterBytes
        }
        return bounded + marker
    }
}
