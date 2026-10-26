import CoreFoundation
import Foundation

enum MacScopeGhosttySurfaceCompileAvailability: Equatable, Sendable {
    case available
    case unavailable
}

enum MacScopeGhosttyRecoveryOverride: Equatable, Sendable {
    case absent
    case explicitlyAllowed
    case disabled
    case invalid
}

enum MacScopeGhosttySurfaceFallbackReason: Equatable, Sendable {
    case compileTimeUnavailable
    case recoveryOverride
    case runtimeInitializerUnavailable
    case runtimeInitializationFailure
    case runtimeHealthFailure
}

enum MacScopeGhosttySurfaceStartupFallbackReason: Equatable, Sendable {
    case compileTimeUnavailable
    case recoveryOverride
}

enum MacScopeGhosttySurfaceStartupSelection: Equatable, Sendable {
    case fullSurface
    case legacyGrid(MacScopeGhosttySurfaceStartupFallbackReason)
}

/// Process-start policy for the private full Ghostty surface.
///
/// The recovery key is deliberately interpreted more narrowly than normal `UserDefaults`
/// coercion: only a stored CFBoolean is accepted. In particular, strings and numeric values do
/// not become an accidental disable. The production value is a `static let`, so later defaults
/// mutations cannot change renderer selection inside an already-running process.
struct MacScopeGhosttySurfaceFeature: Equatable, Sendable {
    static let defaultsDomain = "org.macscope.app"
    static let recoveryDefaultsKey = "developer.fullGhosttySurfaceDisabled"

    static let compileAvailability: MacScopeGhosttySurfaceCompileAvailability = {
        #if canImport(GhosttyKit) && MACSCOPE_FULL_GHOSTTY_SURFACE
        .available
        #else
        .unavailable
        #endif
    }()

    static let production = MacScopeGhosttySurfaceFeature(
        compileAvailability: compileAvailability,
        recoveryDefaultsObject: storedRecoveryDefaultsObject(
            in: UserDefaults.standard,
            domainName: defaultsDomain
        )
    )

    let compileAvailability: MacScopeGhosttySurfaceCompileAvailability
    let recoveryOverride: MacScopeGhosttyRecoveryOverride
    let startupSelection: MacScopeGhosttySurfaceStartupSelection

    init(
        compileAvailability: MacScopeGhosttySurfaceCompileAvailability,
        recoveryDefaultsObject: Any?
    ) {
        self.compileAvailability = compileAvailability
        recoveryOverride = Self.parseRecoveryOverride(recoveryDefaultsObject)

        if compileAvailability == .unavailable {
            startupSelection = .legacyGrid(.compileTimeUnavailable)
        } else if recoveryOverride == .disabled {
            startupSelection = .legacyGrid(.recoveryOverride)
        } else {
            startupSelection = .fullSurface
        }
    }

    /// Reads only the named persistent application domain. Argument, global, volatile, and
    /// registration domains are not explicit process-recovery choices and must not disable the
    /// default-on renderer.
    static func storedRecoveryDefaultsObject(
        in defaults: UserDefaults,
        domainName: String
    ) -> Any? {
        defaults.persistentDomain(forName: domainName)?[recoveryDefaultsKey]
    }

    private static func parseRecoveryOverride(_ object: Any?) -> MacScopeGhosttyRecoveryOverride {
        guard let object else { return .absent }
        let bridged = object as AnyObject
        guard CFGetTypeID(bridged) == CFBooleanGetTypeID(),
              let boolean = bridged as? NSNumber
        else {
            return .invalid
        }
        return boolean.boolValue ? .disabled : .explicitlyAllowed
    }
}
