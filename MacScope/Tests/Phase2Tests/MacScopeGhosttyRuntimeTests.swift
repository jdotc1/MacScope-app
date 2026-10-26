import Combine
import Foundation

#if MACSCOPE_GHOSTTY_RUNTIME_FOCUSED_MAIN
@main
private enum MacScopeGhosttyRuntimeFocusedMain {
    private typealias Scenario = @MainActor @Sendable () async throws -> Void

    static func main() async {
        let scenarios: [(String, Scenario)] = [
            ("default-on feature selection", { try MacScopeGhosttyRuntimeScenarios.defaultOnFeatureSelection() }),
            ("strict recovery parsing", { try MacScopeGhosttyRuntimeScenarios.strictRecoveryParsing() }),
            ("persistent-domain recovery policy", { try MacScopeGhosttyRuntimeScenarios.persistentDomainRecoveryPolicy() }),
            ("app process-start policy composition", { try MacScopeGhosttyRuntimeScenarios.appProcessStartPolicyComposition() }),
            ("compile-time unavailability", { try MacScopeGhosttyRuntimeScenarios.compileTimeUnavailability() }),
            ("recovery override prevents initialization", { try MacScopeGhosttyRuntimeScenarios.recoveryOverridePreventsInitialization() }),
            ("one production runtime", { try MacScopeGhosttyRuntimeScenarios.oneProductionRuntime() }),
            ("initialize exactly once", { try MacScopeGhosttyRuntimeScenarios.initializeExactlyOnce() }),
            ("concurrent and reentrant initialization", MacScopeGhosttyRuntimeScenarios.concurrentAndReentrantInitialization),
            ("initialization failure falls back", { try MacScopeGhosttyRuntimeScenarios.initializationFailureFallsBack() }),
            ("pre-start health failure latches", { try MacScopeGhosttyRuntimeScenarios.preStartHealthFailureLatches() }),
            ("initializing health failure cannot drift", { try MacScopeGhosttyRuntimeScenarios.initializingHealthFailureCannotDrift() }),
            ("health failure falls back", { try MacScopeGhosttyRuntimeScenarios.healthFailureFallsBack() }),
            ("concurrent and reentrant health failure", MacScopeGhosttyRuntimeScenarios.concurrentAndReentrantHealthFailure),
            ("failed runtime rejects replacement surface", MacScopeGhosttyRuntimeScenarios.failedRuntimeRejectsReplacementSurface),
            ("minimal terminal configuration", { try MacScopeGhosttyRuntimeScenarios.minimalTerminalConfiguration() }),
        ]

        var failureCount = 0
        for (name, scenario) in scenarios {
            do {
                try await scenario()
                print("PASS: \(name)")
            } catch {
                failureCount += 1
                FileHandle.standardError.write(Data("FAIL: \(name): \(error)\n".utf8))
            }
        }
        if failureCount > 0 { exit(1) }
    }
}
#else
import XCTest
@testable import MacScope

final class MacScopeGhosttyRuntimeTests: XCTestCase {
    @MainActor
    func testQualifiedFeatureDefaultsToFullSurface() throws {
        try MacScopeGhosttyRuntimeScenarios.defaultOnFeatureSelection()
    }

    @MainActor
    func testRecoveryOverrideParsingIsStrictAndStartupFrozen() throws {
        try MacScopeGhosttyRuntimeScenarios.strictRecoveryParsing()
    }

    @MainActor
    func testProductionRecoveryPolicyReadsOnlyThePersistentApplicationDomain() throws {
        try MacScopeGhosttyRuntimeScenarios.persistentDomainRecoveryPolicy()
    }

    @MainActor
    func testAppCompositionFreezesOneProcessStartGhosttyPolicySnapshot() throws {
        try MacScopeGhosttyRuntimeScenarios.appProcessStartPolicyComposition()
    }

    @MainActor
    func testCompileTimeUnavailabilitySelectsFallbackWithoutInitializing() throws {
        try MacScopeGhosttyRuntimeScenarios.compileTimeUnavailability()
    }

    @MainActor
    func testRecoveryOverridePreventsRuntimeAndSurfaceConstruction() throws {
        try MacScopeGhosttyRuntimeScenarios.recoveryOverridePreventsInitialization()
    }

    @MainActor
    func testProductionRuntimeHasOneProcessIdentity() throws {
        try MacScopeGhosttyRuntimeScenarios.oneProductionRuntime()
    }

    @MainActor
    func testRuntimeInitializationIsAttemptedExactlyOnce() throws {
        try MacScopeGhosttyRuntimeScenarios.initializeExactlyOnce()
    }

    @MainActor
    func testConcurrentAndReentrantInitializationIsAttemptedExactlyOnce() async throws {
        try await MacScopeGhosttyRuntimeScenarios.concurrentAndReentrantInitialization()
    }

    @MainActor
    func testInitializationFailureLatchesLegacyFallback() throws {
        try MacScopeGhosttyRuntimeScenarios.initializationFailureFallsBack()
    }

    @MainActor
    func testPreStartHealthFailureLatchesWithoutInitialization() throws {
        try MacScopeGhosttyRuntimeScenarios.preStartHealthFailureLatches()
    }

    @MainActor
    func testInitializingHealthFailureCannotDriftBackToReady() throws {
        try MacScopeGhosttyRuntimeScenarios.initializingHealthFailureCannotDrift()
    }

    @MainActor
    func testHealthFailureLatchesLegacyFallback() throws {
        try MacScopeGhosttyRuntimeScenarios.healthFailureFallsBack()
    }

    @MainActor
    func testConcurrentAndReentrantHealthFailurePublishesOneOrderedTransition() async throws {
        try await MacScopeGhosttyRuntimeScenarios.concurrentAndReentrantHealthFailure()
    }

    @MainActor
    func testFailedRuntimeRejectsReplacementFullSurfaceConstruction() async throws {
        try await MacScopeGhosttyRuntimeScenarios.failedRuntimeRejectsReplacementSurface()
    }

    @MainActor
    func testConfigurationIsTerminalOnlyAndBounded() throws {
        try MacScopeGhosttyRuntimeScenarios.minimalTerminalConfiguration()
    }
}
#endif

private enum MacScopeGhosttyRuntimeScenarioError: Error, CustomStringConvertible {
    case assertion(String)
    case injectedInitializationFailure

    var description: String {
        switch self {
        case let .assertion(message): message
        case .injectedInitializationFailure: "injected initialization failure"
        }
    }
}

private enum MacScopeGhosttyRuntimeScenarios {
    @MainActor
    static func defaultOnFeatureSelection() throws {
        let feature = MacScopeGhosttySurfaceFeature(
            compileAvailability: .available,
            recoveryDefaultsObject: nil
        )
        try require(feature.recoveryOverride == .absent, "an absent recovery key must stay absent")
        try require(feature.startupSelection == .fullSurface, "an available qualified build must default to the full surface")
    }

    @MainActor
    static func strictRecoveryParsing() throws {
        let disabled = MacScopeGhosttySurfaceFeature(
            compileAvailability: .available,
            recoveryDefaultsObject: NSNumber(value: true)
        )
        let explicitlyAllowed = MacScopeGhosttySurfaceFeature(
            compileAvailability: .available,
            recoveryDefaultsObject: NSNumber(value: false)
        )

        try require(disabled.recoveryOverride == .disabled, "Boolean true must disable the full surface")
        try require(disabled.startupSelection == .legacyGrid(.recoveryOverride), "the recovery override must choose the legacy grid")
        try require(explicitlyAllowed.recoveryOverride == .explicitlyAllowed, "Boolean false must explicitly preserve the product default")
        try require(explicitlyAllowed.startupSelection == .fullSurface, "Boolean false must not disable the full surface")

        let malformedValues: [(String, Any)] = [
            ("string", "true"),
            ("integer", NSNumber(value: 1)),
            ("zero integer", NSNumber(value: 0)),
            ("floating point", NSNumber(value: 1.0)),
            ("data", Data([1])),
            ("array", [true]),
            ("dictionary", ["value": true]),
            ("null", NSNull()),
        ]
        for (label, value) in malformedValues {
            let feature = MacScopeGhosttySurfaceFeature(
                compileAvailability: .available,
                recoveryDefaultsObject: value
            )
            try require(feature.recoveryOverride == .invalid, "\(label) must not be coerced into a recovery override")
            try require(feature.startupSelection == .fullSurface, "\(label) must preserve the default-on full surface")
        }
    }

    @MainActor
    static func persistentDomainRecoveryPolicy() throws {
        let domainName = "org.macscope.app.runtime-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: domainName) else {
            throw MacScopeGhosttyRuntimeScenarioError.assertion("could not create isolated defaults suite")
        }
        defaults.removePersistentDomain(forName: domainName)
        defer { defaults.removePersistentDomain(forName: domainName) }

        defaults.register(defaults: [MacScopeGhosttySurfaceFeature.recoveryDefaultsKey: true])
        try require(
            defaults.object(forKey: MacScopeGhosttySurfaceFeature.recoveryDefaultsKey) != nil,
            "the fixture registration domain must participate in the ordinary defaults search list"
        )
        let registeredOnlyObject = MacScopeGhosttySurfaceFeature.storedRecoveryDefaultsObject(
            in: defaults,
            domainName: domainName
        )
        let registeredOnlyFeature = MacScopeGhosttySurfaceFeature(
            compileAvailability: .available,
            recoveryDefaultsObject: registeredOnlyObject
        )
        try require(registeredOnlyObject == nil, "a registration-domain value must not count as explicitly stored")
        try require(registeredOnlyFeature.startupSelection == .fullSurface, "registration defaults must not disable the product default")

        defaults.setPersistentDomain(
            [MacScopeGhosttySurfaceFeature.recoveryDefaultsKey: true],
            forName: domainName
        )
        let storedTrueFeature = MacScopeGhosttySurfaceFeature(
            compileAvailability: .available,
            recoveryDefaultsObject: MacScopeGhosttySurfaceFeature.storedRecoveryDefaultsObject(
                in: defaults,
                domainName: domainName
            )
        )
        try require(storedTrueFeature.startupSelection == .legacyGrid(.recoveryOverride), "stored CFBoolean true must select recovery")

        defaults.setPersistentDomain(
            [MacScopeGhosttySurfaceFeature.recoveryDefaultsKey: false],
            forName: domainName
        )
        let storedFalseFeature = MacScopeGhosttySurfaceFeature(
            compileAvailability: .available,
            recoveryDefaultsObject: MacScopeGhosttySurfaceFeature.storedRecoveryDefaultsObject(
                in: defaults,
                domainName: domainName
            )
        )
        try require(storedFalseFeature.startupSelection == .fullSurface, "stored CFBoolean false must preserve the product default")
        try require(
            storedTrueFeature.startupSelection == .legacyGrid(.recoveryOverride),
            "a sampled startup policy must not drift after later defaults mutation"
        )

        defaults.setPersistentDomain(
            [MacScopeGhosttySurfaceFeature.recoveryDefaultsKey: "true"],
            forName: domainName
        )
        let malformedStoredFeature = MacScopeGhosttySurfaceFeature(
            compileAvailability: .available,
            recoveryDefaultsObject: MacScopeGhosttySurfaceFeature.storedRecoveryDefaultsObject(
                in: defaults,
                domainName: domainName
            )
        )
        try require(malformedStoredFeature.recoveryOverride == .invalid, "malformed stored policy must remain invalid")
        try require(malformedStoredFeature.startupSelection == .fullSurface, "malformed stored policy must not disable the product default")
    }

    @MainActor
    static func appProcessStartPolicyComposition() throws {
        let coreTests = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
        let macScope = coreTests.deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: macScope
                .appendingPathComponent("App")
                .appendingPathComponent("MacScopeApp.swift"),
            encoding: .utf8
        )

        try require(
            source.contains("struct MacScopeAppProcessStartSnapshot"),
            "app entry must declare one explicit process-start snapshot"
        )
        try require(
            source.contains("static let production"),
            "the production process-start snapshot must be immutable"
        )
        try require(
            source.contains("ghosttySurfaceFeature: MacScopeGhosttySurfaceFeature.production"),
            "the process-start snapshot must eagerly freeze the static Ghostty recovery policy"
        )
        try require(
            source.components(separatedBy: "MacScopeAppProcessStartSnapshot.production").count - 1 == 2,
            "AppEntry and MacScopeApp must consume the same process-start snapshot"
        )
        try require(
            source.contains("ghosttyRuntime.feature == processStartSnapshot.ghosttySurfaceFeature"),
            "ordinary renderer runtime composition must bind to the captured Ghostty policy"
        )
        guard let bodyStart = source.range(of: "    var body: some Scene {") else {
            throw MacScopeGhosttyRuntimeScenarioError.assertion("MacScopeApp scene body is missing")
        }
        let sceneBody = source[bodyStart.lowerBound...]
        try require(
            !sceneBody.contains("ProcessInfo.processInfo"),
            "view reconstruction must not reread process arguments or environment"
        )
        try require(
            sceneBody.contains("if processStartSnapshot.installedRendererSmokeRequested"),
            "installed-smoke presentation must consume the captured process-local override"
        )
    }

    @MainActor
    static func compileTimeUnavailability() throws {
        let counter = MacScopeGhosttyRuntimeCounter()
        let feature = MacScopeGhosttySurfaceFeature(
            compileAvailability: .unavailable,
            recoveryDefaultsObject: nil
        )
        let runtime = MacScopeGhosttyRuntime(feature: feature) { _ in
            counter.value += 1
            return NSObject()
        }

        try require(runtime.prepare() == .unavailable(.notCompiled), "an unavailable module must select fallback")
        try require(counter.value == 0, "an unavailable feature must not invoke its initializer")
        try require(runtime.fallbackReason == .compileTimeUnavailable, "fallback must retain the exact unavailability cause")
    }

    @MainActor
    static func recoveryOverridePreventsInitialization() throws {
        let counter = MacScopeGhosttyRuntimeCounter()
        let feature = MacScopeGhosttySurfaceFeature(
            compileAvailability: .available,
            recoveryDefaultsObject: NSNumber(value: true)
        )
        let runtime = MacScopeGhosttyRuntime(feature: feature) { _ in
            counter.value += 1
            return NSObject()
        }
        let surfaceFactory = MacScopeGhosttyRuntimeSurfaceFactoryProbe(runtime: runtime)

        try require(runtime.prepare() == .unavailable(.recoveryOverride), "explicit recovery must remain unavailable")
        try require(runtime.prepare() == .unavailable(.recoveryOverride), "recovery selection must be process-static")
        try require(counter.value == 0, "recovery selection must not invoke the native initializer")
        try require(surfaceFactory.makeSurface() == nil, "recovery selection must not construct a full surface")
        try require(surfaceFactory.constructionCount == 0, "recovery selection must retain no full surface")
        try require(runtime.fallbackReason == .recoveryOverride, "recovery selection must expose only its closed reason")
    }

    @MainActor
    static func oneProductionRuntime() throws {
        try require(
            MacScopeGhosttyRuntime.productionShared === MacScopeGhosttyRuntime.productionShared,
            "production access must return one process-level runtime identity"
        )
    }

    @MainActor
    static func initializeExactlyOnce() throws {
        let counter = MacScopeGhosttyRuntimeCounter()
        let runtime = MacScopeGhosttyRuntime(feature: availableFeature) { configuration in
            MainActor.preconditionIsolated()
            try require(configuration == .terminalOnlyDefault, "the initializer must receive the frozen configuration")
            counter.value += 1
            return NSObject()
        }

        try require(runtime.state == .notStarted, "an enabled runtime must begin uninitialized")
        try require(runtime.prepare() == .ready, "the first preparation must become ready")
        try require(runtime.prepare() == .ready, "later preparation must reuse the ready runtime")
        try require(counter.value == 1, "the process runtime initializer must execute once")
        try require(runtime.isFullSurfaceUsable, "a ready runtime must be usable")
    }

    @MainActor
    static func concurrentAndReentrantInitialization() async throws {
        let counter = MacScopeGhosttyRuntimeCounter()
        let holder = MacScopeGhosttyRuntimeHolder()
        let runtime = MacScopeGhosttyRuntime(feature: availableFeature) { _ in
            MainActor.preconditionIsolated()
            counter.value += 1
            if holder.reentrantPrepareState == nil {
                holder.reentrantPrepareState = holder.runtime?.prepare()
            }
            return NSObject()
        }
        holder.runtime = runtime

        var observed: [MacScopeGhosttyRuntime.State] = []
        let observation = runtime.$state.dropFirst().sink { observed.append($0) }
        let results = await withTaskGroup(
            of: MacScopeGhosttyRuntime.State.self,
            returning: [MacScopeGhosttyRuntime.State].self
        ) { group in
            for _ in 0 ..< 32 {
                group.addTask { await runtime.prepare() }
            }
            var values: [MacScopeGhosttyRuntime.State] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        try require(counter.value == 1, "concurrent and reentrant preparation must invoke the initializer once")
        try require(holder.reentrantPrepareState == .notStarted, "reentrant preparation must observe a conservative non-ready state")
        try require(results.count == 32 && results.allSatisfy { $0 == .ready }, "all independent callers must converge on one ready runtime")
        try require(runtime.state == .ready && runtime.isFullSurfaceUsable, "one successful attempt must establish ready authority")
        try require(observed == [.ready], "observers must receive one ready transition")
        withExtendedLifetime(observation) {}
    }

    @MainActor
    static func initializationFailureFallsBack() throws {
        let counter = MacScopeGhosttyRuntimeCounter()
        let runtime = MacScopeGhosttyRuntime(feature: availableFeature) { _ in
            counter.value += 1
            throw MacScopeGhosttyRuntimeScenarioError.injectedInitializationFailure
        }
        var observed: [MacScopeGhosttyRuntime.State] = []
        let observation = runtime.$state.dropFirst().sink { observed.append($0) }

        try require(runtime.prepare() == .failed(.initialization), "initialization failure must be observational state")
        try require(runtime.prepare() == .failed(.initialization), "initialization failure must be latched without retries")
        try require(runtime.recordHealthFailure() == .failed(.initialization), "a later report must not replace the first failure authority")
        try require(counter.value == 1, "a failed runtime must not retry inside the same process")
        try require(runtime.fallbackReason == .runtimeInitializationFailure, "initialization failure must select the legacy grid")
        try require(!runtime.isFullSurfaceUsable, "a failed runtime must not remain usable")
        try require(observed == [.failed(.initialization)], "initialization failure must publish one content-free transition")
        withExtendedLifetime(observation) {}
    }

    @MainActor
    static func preStartHealthFailureLatches() throws {
        let counter = MacScopeGhosttyRuntimeCounter()
        let runtime = MacScopeGhosttyRuntime(feature: availableFeature) { _ in
            counter.value += 1
            return NSObject()
        }
        var observed: [MacScopeGhosttyRuntime.State] = []
        let observation = runtime.$state.dropFirst().sink { observed.append($0) }

        try require(runtime.recordHealthFailure() == .failed(.initialization), "pre-start health must fail closed")
        try require(runtime.recordHealthFailure() == .failed(.initialization), "pre-start failure must be idempotent")
        try require(runtime.prepare() == .failed(.initialization), "pre-start failure must prohibit later initialization")
        try require(counter.value == 0, "pre-start failure must not initialize or retry")
        try require(observed == [.failed(.initialization)], "pre-start failure must publish exactly once")
        withExtendedLifetime(observation) {}
    }

    @MainActor
    static func initializingHealthFailureCannotDrift() throws {
        let counter = MacScopeGhosttyRuntimeCounter()
        let holder = MacScopeGhosttyRuntimeHolder()
        let weakLifetime = MacScopeGhosttyRuntimeWeakLifetimeHolder()
        let runtime = MacScopeGhosttyRuntime(feature: availableFeature) { _ in
            counter.value += 1
            let lifetime = MacScopeGhosttyRuntimeLifetimeProbe()
            weakLifetime.value = lifetime
            holder.reentrantHealthState = holder.runtime?.recordHealthFailure()
            return lifetime
        }
        holder.runtime = runtime
        var observed: [MacScopeGhosttyRuntime.State] = []
        let observation = runtime.$state.dropFirst().sink { observed.append($0) }

        try require(runtime.prepare() == .failed(.initialization), "health during initialization must remain terminal")
        try require(holder.reentrantHealthState == .failed(.initialization), "the reentrant caller must observe the terminal latch")
        try require(runtime.prepare() == .failed(.initialization), "a reentrant failure must prevent retry")
        try require(counter.value == 1, "reentrant health must not create replacement runtime state")
        try require(weakLifetime.value != nil, "successful native state must remain retained after a reentrant failure")
        try require(observed == [.failed(.initialization)], "reentrant failure must not drift through ready")
        withExtendedLifetime(observation) {}
    }

    @MainActor
    static func healthFailureFallsBack() throws {
        let counter = MacScopeGhosttyRuntimeCounter()
        let weakLifetime = MacScopeGhosttyRuntimeWeakLifetimeHolder()
        let runtime = MacScopeGhosttyRuntime(feature: availableFeature) { _ in
            counter.value += 1
            let lifetime = MacScopeGhosttyRuntimeLifetimeProbe()
            weakLifetime.value = lifetime
            return lifetime
        }

        try require(runtime.prepare() == .ready, "fixture runtime must become ready")
        try require(runtime.recordHealthFailure() == .failed(.health), "health failure must select terminal failed state")
        try require(runtime.recordHealthFailure() == .failed(.health), "health failure must be idempotent")
        try require(runtime.prepare() == .failed(.health), "health failure must not reinitialize")
        try require(counter.value == 1, "health failure must not create a second process runtime")
        try require(runtime.fallbackReason == .runtimeHealthFailure, "health failure must expose the fallback cause")
        try require(weakLifetime.value != nil, "health failure must retain process runtime state through surface teardown")
    }

    @MainActor
    static func concurrentAndReentrantHealthFailure() async throws {
        let counter = MacScopeGhosttyRuntimeCounter()
        let runtime = MacScopeGhosttyRuntime(feature: availableFeature) { _ in
            counter.value += 1
            return NSObject()
        }
        let observer = MacScopeGhosttyRuntimeObserverProbe()
        let observation = runtime.$state.dropFirst().sink { state in
            observer.states.append(state)
            if state == .ready, !observer.didReportFromReady {
                observer.didReportFromReady = true
                observer.reentrantResult = runtime.recordHealthFailure()
            } else if state == .failed(.health) {
                observer.failureNotificationCount += 1
                _ = runtime.recordHealthFailure()
            }
        }

        try require(runtime.prepare() == .failed(.health), "a health report reentered from ready publication must stay latched")
        let results = await withTaskGroup(
            of: MacScopeGhosttyRuntime.State.self,
            returning: [MacScopeGhosttyRuntime.State].self
        ) { group in
            for _ in 0 ..< 32 {
                group.addTask { await runtime.recordHealthFailure() }
            }
            var values: [MacScopeGhosttyRuntime.State] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        try require(observer.reentrantResult == .failed(.health), "the reentrant caller must receive the authoritative failure")
        try require(results.count == 32 && results.allSatisfy { $0 == .failed(.health) }, "all concurrent reports must converge on one failure")
        try require(observer.states == [.ready, .failed(.health)], "every observer transition must remain ordered and unique")
        try require(observer.failureNotificationCount == 1, "reentrant reports must not republish the terminal failure")
        try require(runtime.state == .failed(.health), "published state must converge with terminal authority")
        try require(runtime.prepare() == .failed(.health), "health failure must prohibit later initialization")
        try require(counter.value == 1, "health reports must not retry initialization")
        withExtendedLifetime(observation) {}
    }

    @MainActor
    static func failedRuntimeRejectsReplacementSurface() async throws {
        let initializerCounter = MacScopeGhosttyRuntimeCounter()
        let runtime = MacScopeGhosttyRuntime(feature: availableFeature) { _ in
            initializerCounter.value += 1
            return NSObject()
        }
        let factory = MacScopeGhosttyRuntimeSurfaceFactoryProbe(runtime: runtime)
        let initialSurface = factory.makeSurface()

        try require(initialSurface != nil, "a ready runtime must admit the initial full surface")
        try require(runtime.recordHealthFailure() == .failed(.health), "fixture health failure must latch")
        let replacementResults = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for _ in 0 ..< 32 {
                group.addTask { await factory.attemptConstruction() }
            }
            var values: [Bool] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        try require(replacementResults.count == 32 && replacementResults.allSatisfy { !$0 }, "a failed process runtime must reject every replacement")
        try require(factory.constructionCount == 1, "only the pre-failure surface may have been constructed")
        try require(initializerCounter.value == 1, "replacement attempts must not retry initialization")
        try require(runtime.prepare() == .failed(.health), "failure authority must remain process-lifetime terminal")
        withExtendedLifetime(initialSurface) {}
    }

    @MainActor
    static func minimalTerminalConfiguration() throws {
        let configuration = MacScopeGhosttyConfiguration.terminalOnlyDefault
        try require(configuration.font == .systemMonospaced(sizePoints: 13), "the default font must be bounded and app-owned")
        try require(configuration.theme == .followSystem, "theme must remain app-owned")
        try require(configuration.scrollbackLimitBytes == 16 * 1_048_576, "scrollback must have a fixed byte budget")
        try require(configuration.cursor == .block(blinks: true), "cursor behavior must be explicit")
        try require(configuration.backgroundOpacity == 1, "terminal opacity must be explicit")
        try require(configuration.hyperlinkPolicy == .humanActivatedHTTPAndHTTPSOnly, "links must require a human and a closed scheme set")
        try require(configuration.keyboardProtocol == .kitty, "the keyboard protocol must be explicit")
        try require(configuration.shellIntegration == .disabled, "Ghostty shell integration must remain disabled")
        try require(configuration.applicationCommands == .disabled, "Ghostty application commands must remain disabled")
    }

    @MainActor
    private static var availableFeature: MacScopeGhosttySurfaceFeature {
        MacScopeGhosttySurfaceFeature(
            compileAvailability: .available,
            recoveryDefaultsObject: nil
        )
    }

    @MainActor
    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw MacScopeGhosttyRuntimeScenarioError.assertion(message)
        }
    }
}

@MainActor
private final class MacScopeGhosttyRuntimeCounter {
    var value = 0
}

@MainActor
private final class MacScopeGhosttyRuntimeHolder {
    var runtime: MacScopeGhosttyRuntime?
    var reentrantPrepareState: MacScopeGhosttyRuntime.State?
    var reentrantHealthState: MacScopeGhosttyRuntime.State?
}

@MainActor
private final class MacScopeGhosttyRuntimeObserverProbe {
    var states: [MacScopeGhosttyRuntime.State] = []
    var didReportFromReady = false
    var reentrantResult: MacScopeGhosttyRuntime.State?
    var failureNotificationCount = 0
}

@MainActor
private final class MacScopeGhosttyRuntimeWeakLifetimeHolder {
    weak var value: AnyObject?
}

private final class MacScopeGhosttyRuntimeLifetimeProbe: NSObject {}

@MainActor
private final class MacScopeGhosttyRuntimeSurfaceFactoryProbe {
    private let runtime: MacScopeGhosttyRuntime
    private(set) var constructionCount = 0

    init(runtime: MacScopeGhosttyRuntime) {
        self.runtime = runtime
    }

    func makeSurface() -> NSObject? {
        guard runtime.prepare() == .ready else { return nil }
        constructionCount += 1
        return NSObject()
    }

    func attemptConstruction() -> Bool {
        makeSurface() != nil
    }
}
