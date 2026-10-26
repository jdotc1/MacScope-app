import Combine
import Foundation

#if canImport(GhosttyKit) && MACSCOPE_FULL_GHOSTTY_SURFACE
import GhosttyKit
#endif

/// One application-process Ghostty initialization authority.
///
/// Production code obtains only `productionShared`. SwiftUI surface updates must never construct
/// another production runtime. Test instances use an injected initializer to prove lifecycle
/// semantics without linking GhosttyKit.
@MainActor
final class MacScopeGhosttyRuntime: ObservableObject {
    enum Unavailability: Equatable, Sendable {
        case notCompiled
        case recoveryOverride
        case initializerUnavailable
    }

    enum Failure: Equatable, Sendable {
        case initialization
        case health
    }

    enum State: Equatable, Sendable {
        case notStarted
        case unavailable(Unavailability)
        case ready
        case failed(Failure)
    }

    /// Monotonic process authority kept separate from `@Published`'s will-set observation.
    /// `initializing` closes synchronous MainActor reentry without exposing a transient product
    /// selection to callers or observers.
    private enum Authority: Equatable {
        case notStarted
        case initializing
        case unavailable(Unavailability)
        case ready
        case failed(Failure)

        var observableState: State {
            switch self {
            case .notStarted, .initializing:
                .notStarted
            case let .unavailable(reason):
                .unavailable(reason)
            case .ready:
                .ready
            case let .failed(reason):
                .failed(reason)
            }
        }
    }

    typealias Initializer = @MainActor @Sendable (
        _ configuration: MacScopeGhosttyConfiguration
    ) throws -> AnyObject

    static let productionShared = MacScopeGhosttyRuntime(
        feature: .production,
        configuration: .terminalOnlyDefault,
        initializer: productionInitializer
    )

    let feature: MacScopeGhosttySurfaceFeature
    let configuration: MacScopeGhosttyConfiguration
    @Published private(set) var state: State

    private let initializer: Initializer?
    private var authority: Authority
    private var isPublishingState = false
    private var pendingPublishedState: State?
    /// Retains any successfully initialized linked runtime for the process-runtime lifetime. A
    /// health latch must not release shared native state while surface retirement is still in
    /// flight.
    private var lifetime: AnyObject?

    init(
        feature: MacScopeGhosttySurfaceFeature,
        configuration: MacScopeGhosttyConfiguration = .terminalOnlyDefault,
        initializer: Initializer? = nil
    ) {
        self.feature = feature
        self.configuration = configuration
        self.initializer = initializer

        switch feature.startupSelection {
        case .fullSurface:
            state = .notStarted
            authority = .notStarted
        case .legacyGrid(.compileTimeUnavailable):
            state = .unavailable(.notCompiled)
            authority = .unavailable(.notCompiled)
        case .legacyGrid(.recoveryOverride):
            state = .unavailable(.recoveryOverride)
            authority = .unavailable(.recoveryOverride)
        }
    }

    /// Initializes the linked runtime at most once. Failure is latched for the process lifetime;
    /// callers should immediately present the independently pinned legacy grid.
    @discardableResult
    func prepare() -> State {
        guard authority == .notStarted else { return authority.observableState }
        guard let initializer else {
            transition(to: .unavailable(.initializerUnavailable))
            return authority.observableState
        }

        // Latch the attempt before invoking foreign initialization. The synchronous initializer
        // may reenter this actor, but no reentrant caller may begin another attempt.
        authority = .initializing
        do {
            let initializedLifetime = try initializer(configuration)
            // Retain a successfully created native lifetime even if initialization reentrantly
            // reported a terminal failure. Surface teardown may still reference shared state.
            lifetime = initializedLifetime
            if authority == .initializing {
                transition(to: .ready)
            }
        } catch {
            if authority == .initializing {
                transition(to: .failed(.initialization))
            }
        }
        return authority.observableState
    }

    /// Converts a renderer/runtime health failure into a stable fallback decision. It never
    /// touches ShellBroker session authority and never retries Ghostty inside this process.
    @discardableResult
    func recordHealthFailure() -> State {
        switch authority {
        case .ready:
            transition(to: .failed(.health))
        case .failed, .unavailable:
            break
        case .notStarted, .initializing:
            // A pre-start health report is an initialization failure, not evidence of readiness.
            transition(to: .failed(.initialization))
        }
        return authority.observableState
    }

    var isFullSurfaceUsable: Bool {
        authority == .ready
    }

    var fallbackReason: MacScopeGhosttySurfaceFallbackReason? {
        switch authority.observableState {
        case .notStarted, .ready:
            nil
        case .unavailable(.notCompiled):
            .compileTimeUnavailable
        case .unavailable(.recoveryOverride):
            .recoveryOverride
        case .unavailable(.initializerUnavailable):
            .runtimeInitializerUnavailable
        case .failed(.initialization):
            .runtimeInitializationFailure
        case .failed(.health):
            .runtimeHealthFailure
        }
    }

    private func transition(to newAuthority: Authority) {
        authority = newAuthority
        publish(newAuthority.observableState)
    }

    /// `Published` emits from `willSet`. Queueing a reentrant transition prevents an observer from
    /// recursively publishing against stale storage or letting an outer setter overwrite a
    /// terminal latch. The authority is already monotonic; this method only drains its observable
    /// mirror in deterministic order.
    private func publish(_ newState: State) {
        if isPublishingState {
            pendingPublishedState = newState
            return
        }
        guard state != newState else { return }

        isPublishingState = true
        defer {
            pendingPublishedState = nil
            isPublishingState = false
        }

        var nextState: State? = newState
        while let candidate = nextState {
            pendingPublishedState = nil
            if state != candidate {
                state = candidate
            }
            nextState = pendingPublishedState
        }
    }

    private static var productionInitializer: Initializer? {
        #if canImport(GhosttyKit) && MACSCOPE_FULL_GHOSTTY_SURFACE
        return { _ in
            // Pass only argv[0]. Ghostty receives a valid executable identity but cannot parse
            // MacScope launch arguments as Ghostty application actions.
            guard ghostty_init(1, CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
                throw MacScopeGhosttyRuntimeInitializationError.linkedRuntimeRejectedInitialization
            }
            return MacScopeGhosttyLinkedRuntimeLifetime()
        }
        #else
        return nil
        #endif
    }
}

private enum MacScopeGhosttyRuntimeInitializationError: Error {
    case linkedRuntimeRejectedInitialization
}

private final class MacScopeGhosttyLinkedRuntimeLifetime: NSObject {}
