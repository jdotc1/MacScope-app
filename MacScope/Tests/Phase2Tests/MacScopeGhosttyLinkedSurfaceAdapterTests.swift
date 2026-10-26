import AppKit
import Foundation

#if MACSCOPE_GHOSTTY_LINKED_ADAPTER_FOCUSED_MAIN
@main
private enum MacScopeGhosttyLinkedAdapterFocusedMain {
    static func main() async {
        let scenarios: [(String, @MainActor () async throws -> Void)] = [
            ("typed feed vocabulary", MacScopeGhosttyLinkedAdapterScenarios.typedFeedVocabulary),
            ("health detail preservation", MacScopeGhosttyLinkedAdapterScenarios.healthDetailPreservation),
            ("coordinator neutral submissions", MacScopeGhosttyLinkedAdapterScenarios.coordinatorNeutralSubmissions),
            ("interactive host event forwarding", MacScopeGhosttyLinkedAdapterScenarios.interactiveHostEventForwarding),
            ("compile-disabled factory", MacScopeGhosttyLinkedAdapterScenarios.compileDisabledFactory),
            ("reentrant representable replacement", MacScopeGhosttyLinkedAdapterScenarios.reentrantRepresentableReplacement),
            ("bounded exact-once wakeup drain", MacScopeGhosttyLinkedAdapterScenarios.boundedWakeupBurstAndExactOnceDrain),
            ("queued-generation replacement", MacScopeGhosttyLinkedAdapterScenarios.queuedGenerationReplacement),
            ("late callback pin deallocation", MacScopeGhosttyLinkedAdapterScenarios.lateCallbackPinAndDeallocation),
        ]
        var failures = 0
        for (name, scenario) in scenarios {
            do {
                try await scenario()
                print("PASS: \(name)")
            } catch {
                failures += 1
                FileHandle.standardError.write(Data("FAIL: \(name): \(error)\n".utf8))
            }
        }
        if failures > 0 { exit(1) }
    }
}
#else
import XCTest

@testable import MacScope

@MainActor
final class MacScopeGhosttyLinkedSurfaceAdapterTests: XCTestCase {
    func testTypedFeedVocabularyIsLossless() throws {
        try MacScopeGhosttyLinkedAdapterScenarios.typedFeedVocabulary()
    }

    func testBridgePreservesEveryHealthEventAndDetail() throws {
        try MacScopeGhosttyLinkedAdapterScenarios.healthDetailPreservation()
    }

    func testCoordinatorExposesGenerationFencedNeutralSubmissions() throws {
        try MacScopeGhosttyLinkedAdapterScenarios.coordinatorNeutralSubmissions()
    }

    func testInteractiveHostEventsReachTheAdapterBoundary() throws {
        try MacScopeGhosttyLinkedAdapterScenarios.interactiveHostEventForwarding()
    }

    func testCompileDisabledFactoryFailsClosed() throws {
        try MacScopeGhosttyLinkedAdapterScenarios.compileDisabledFactory()
    }

    func testNativeWakeupBurstUsesOneExactOnceDrain() throws {
        try MacScopeGhosttyLinkedAdapterScenarios.boundedWakeupBurstAndExactOnceDrain()
    }

    func testQueuedRetiredGenerationCannotDriveReplacement() throws {
        try MacScopeGhosttyLinkedAdapterScenarios.queuedGenerationReplacement()
    }

    func testLatePinnedCallbackRejectsAndOwnersDeallocate() throws {
        try MacScopeGhosttyLinkedAdapterScenarios.lateCallbackPinAndDeallocation()
    }
}
#endif

private enum MacScopeGhosttyLinkedAdapterScenarioError: Error, CustomStringConvertible {
    case assertion(String)

    var description: String {
        switch self {
        case let .assertion(message): message
        }
    }
}

private enum MacScopeGhosttyLinkedAdapterScenarios {
    @MainActor
    static func typedFeedVocabulary() throws {
        let values: Set<MacScopeGhosttySurfaceFeedAdmission> = [
            .accepted, .backpressured, .closed, .invalid, .internalError,
        ]
        try require(values.count == 5, "the MacScope feed vocabulary must preserve all ABI outcomes")
    }

    @MainActor
    static func healthDetailPreservation() throws {
        let generation = fixtureGeneration(1)
        let recorder = MacScopeGhosttyLinkedWorkRecorder()
        let delivered = DispatchSemaphore(value: 0)
        let bridge = MacScopeGhosttyExternalIOBridge(generation: generation) { work in
            recorder.append(work)
            delivered.signal()
        }
        let expected: [(MacScopeGhosttyExternalIOBridge.HealthEvent, UInt64)] = [
            (.feedReady, 1_048_576),
            (.outputBackpressured, 64),
            (.outputOverflow, 262_144),
            (.outputSuppressed, 17),
        ]

        for (event, detail) in expected {
            try require(
                bridge.callbackBox.reportHealth(event, detail: detail) == .accepted,
                "health callback should be admitted"
            )
        }
        for _ in expected {
            try require(
                delivered.wait(timeout: .now() + 2) == .success,
                "health callback delivery timed out"
            )
        }

        let actual = recorder.values.compactMap { work -> (MacScopeGhosttyExternalIOBridge.HealthEvent, UInt64)? in
            guard case let .health(deliveredGeneration, event, detail) = work,
                  deliveredGeneration == generation
            else { return nil }
            return (event, detail)
        }
        try require(actual.count == expected.count, "all four health reports must be delivered")
        for (index, pair) in expected.enumerated() {
            try require(actual[index].0 == pair.0, "health event order changed")
            try require(actual[index].1 == pair.1, "health detail was discarded")
        }
        _ = bridge.retire(generation: generation)
        bridge.invalidateCallbacks()
    }

    @MainActor
    static func coordinatorNeutralSubmissions() throws {
        let generation = fixtureGeneration(2)
        let stale = MacScopeGhosttySurfaceGeneration(
            sessionID: generation.sessionID,
            requestID: UUID(),
            generation: generation.generation
        )
        let backend = MacScopeGhosttyLinkedScenarioBackend(feedAdmission: .backpressured)
        let coordinator = MacScopeGhosttySurfaceCoordinator(
            generation: generation,
            backend: backend
        )
        let host = MacScopeGhosttySurfaceHostView(frame: .zero)
        let window = hostWindow(containing: host)
        defer { window.contentView = nil }
        try coordinator.attach(to: host)

        try require(
            coordinator.feed(Data([0x41]), for: generation) == .backpressured,
            "backpressure must not collapse to a Boolean rejection"
        )
        try require(
            coordinator.feed(Data([0x42]), for: stale) == .closed,
            "a different request with the same counter must fail closed"
        )
        try require(
            coordinator.setProcessState(.exited(status: 7), for: generation) == .accepted,
            "exact-generation process state should reach the backend"
        )
        try require(
            coordinator.setProcessState(.closed, for: stale) == .closed,
            "stale process state must fail closed"
        )
        try require(
            backend.processStates == [.exited(status: 7)],
            "the renderer must receive only exact-generation host evidence"
        )
        coordinator.shutdown()
    }

    @MainActor
    static func compileDisabledFactory() throws {
        guard !MacScopeGhosttyLinkedSurfaceFactory.isCompiled else { return }
        let backend = MacScopeGhosttyLinkedSurfaceFactory.make(
            generation: fixtureGeneration(3),
            workHandler: { _ in }
        )
        try require(backend == nil, "an ordinary build must not construct a linked surface")
    }

    @MainActor
    static func reentrantRepresentableReplacement() async throws {
        let firstGeneration = fixtureGeneration(40)
        let replacementGeneration = fixtureGeneration(41)
        let first = MacScopeGhosttyLinkedScenarioBackend(feedAdmission: .accepted)
        let replacement = MacScopeGhosttyLinkedScenarioBackend(feedAdmission: .accepted)
        let coordinator = MacScopeGhosttySurfaceRepresentable(generation: firstGeneration)
            .makeCoordinator()
        let host = MacScopeGhosttySurfaceHostView(frame: .zero)
        let window = hostWindow(containing: host)
        defer { window.contentView = nil }
        var availability: [String] = []
        first.onAttach = {
            coordinator.reconcile(
                hostView: host,
                generation: replacementGeneration,
                backendFactory: { _ in replacement },
                availabilityChanged: { availability.append("41:\($0)") }
            )
        }

        coordinator.reconcile(
            hostView: host,
            generation: firstGeneration,
            backendFactory: { _ in first },
            availabilityChanged: { availability.append("40:\($0)") }
        )

        try require(first.attachCount == 1, "reentrant first backend was never attached")
        try require(
            first.teardownSteps == MacScopeGhosttySurfaceTeardownStep.allCases,
            "reentrant first backend escaped ordered teardown"
        )
        try require(replacement.attachCount == 1, "newest reentrant request did not attach")
        try require(
            coordinator.feed(Data([0x41]), generation: replacementGeneration) == .accepted,
            "newest reentrant generation was not authoritative"
        )
        try require(availability.isEmpty, "availability published during representable update")
        for _ in 0..<4 { await Task.yield() }
        try require(availability == ["41:true"], "deferred availability was stale or duplicated")
        coordinator.dismantle(hostView: host)
        try require(
            replacement.teardownSteps == MacScopeGhosttySurfaceTeardownStep.allCases,
            "replacement did not dismantle in order"
        )
    }

    @MainActor
    static func interactiveHostEventForwarding() throws {
        let generation = fixtureGeneration(4)
        let backend = MacScopeGhosttyLinkedScenarioBackend(feedAdmission: .accepted)
        let coordinator = MacScopeGhosttySurfaceCoordinator(
            generation: generation,
            backend: backend
        )
        let host = MacScopeGhosttySurfaceHostView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let window = hostWindow(containing: host)
        defer { window.contentView = nil }
        try coordinator.attach(to: host)
        let initialEventCount = backend.events.count

        let key = MacScopeGhosttyKeyInput(
            keyCode: 0,
            characters: "a",
            charactersIgnoringModifiers: "a",
            modifierFlags: 0,
            isRepeat: false
        )
        let pointer = MacScopeGhosttyPointerInput(
            phase: .pressed,
            button: .left,
            location: CGPoint(x: 12, y: 34),
            modifierFlags: 0,
            clickCount: 1,
            pressure: 0
        )
        let events: [MacScopeGhosttySurfaceHostEvent] = [
            .key(key), .modifierFlagsChanged(key), .text("a", replacementRange: NSRange()),
            .preedit("候", selectedRange: NSRange(location: 0, length: 1), replacementRange: NSRange()),
            .unmarkText, .pointer(pointer),
            .scroll(.init(deltaX: 1, deltaY: -2, hasPreciseDeltas: true, modifierFlags: 0, phaseRawValue: 0, momentumPhaseRawValue: 0)),
            .paste("paste"), .focus(true), .resize(size: host.bounds.size, backingScale: 2),
            .display(scale: 2, displayID: 7), .occlusion(true), .draw(host.bounds), .wakeup,
        ]
        for event in events {
            try require(
                coordinator.ghosttyHostView(host, handle: event),
                "interactive event was not accepted by the backend boundary"
            )
        }
        try require(
            Array(backend.events.dropFirst(initialEventCount)) == events,
            "host event normalization changed event order or data"
        )
        coordinator.shutdown()
    }

    @MainActor
    static func boundedWakeupBurstAndExactOnceDrain() throws {
        let scheduler = MacScopeGhosttyManualMainActorScheduler()
        let registry = MacScopeGhosttyLinkedRuntimeCallbackRegistry(
            enqueueOnMainActor: { scheduler.enqueue($0) }
        )
        let generation = fixtureGeneration(5)
        let registration = registry.pin(generation: generation)
        let recorder = MacScopeGhosttyIntentRecorder()
        let surface = UnsafeMutableRawPointer(bitPattern: 0x401)!
        let otherSurface = UnsafeMutableRawPointer(bitPattern: 0x402)!
        let userdataBits = UInt(bitPattern: registration.userdata)
        let concurrentAdmissionFailures = MacScopeGhosttyLockedCounter()
        let reentrantAdmissionFailures = MacScopeGhosttyLockedCounter()

        let router = MacScopeGhosttyActionRouter()
        try require(
            MacScopeGhosttyApplicationAction.allCases.allSatisfy {
                router.route(.application($0)) == .denied(.applicationAuthority)
            },
            "every application action must remain denied"
        )

        for _ in 0..<32 {
            try require(
                registry.submitWakeup(userdata: registration.userdata),
                "pre-install wakeup should be retained"
            )
            try require(
                registry.submit(.render, surfaceToken: surface, userdata: registration.userdata),
                "pre-install render should be retained"
            )
        }
        try require(
            registry.submit(
                .titleChanged("first"),
                surfaceToken: surface,
                userdata: registration.userdata
            ),
            "initial metadata should be retained"
        )
        try require(
            registry.submit(
                .titleChanged("latest"),
                surfaceToken: surface,
                userdata: registration.userdata
            ),
            "newer metadata should replace older metadata"
        )
        try require(
            registry.submit(
                .rendererHealth(.unhealthy),
                surfaceToken: surface,
                userdata: registration.userdata
            ),
            "unhealthy renderer state should be retained"
        )
        try require(
            registry.submit(
                .rendererHealth(.healthy),
                surfaceToken: surface,
                userdata: registration.userdata
            ),
            "later health callbacks should remain bounded"
        )
        try require(
            !registry.submit(
                .render,
                surfaceToken: otherSurface,
                userdata: registration.userdata
            ),
            "a second surface token must fail closed before installation"
        )
        try require(
            !registry.submit(
                .application(.newWindow),
                surfaceToken: surface,
                userdata: registration.userdata
            ),
            "application actions must never enter the callback queue"
        )
        try require(
            !registry.submit(
                .activateHyperlink("https://example.com", activation: .terminalProgram),
                surfaceToken: surface,
                userdata: registration.userdata
            ),
            "terminal-controlled hyperlinks must never enter the callback queue"
        )

        recorder.onFirstDelivery = {
            for _ in 0..<4_096 {
                let userdata = UnsafeMutableRawPointer(bitPattern: userdataBits)
                if !registry.submitWakeup(userdata: userdata) {
                    reentrantAdmissionFailures.increment()
                }
            }
        }
        try require(
            registry.install(registration, surfaceToken: surface) { [weak recorder] generation, intents in
                recorder?.append(generation: generation, intents: intents)
            },
            "active callback registration should install exactly once"
        )
        try require(
            scheduler.pendingCount == 1,
            "installation must enqueue exactly one global MainActor turn"
        )

        DispatchQueue.concurrentPerform(iterations: 10_000) { _ in
            let userdata = UnsafeMutableRawPointer(bitPattern: userdataBits)
            if !registry.submitWakeup(userdata: userdata) {
                concurrentAdmissionFailures.increment()
            }
        }
        try require(
            concurrentAdmissionFailures.value == 0,
            "an active native wakeup burst was rejected"
        )
        try require(
            scheduler.pendingCount == 1,
            "10,000 native wakeups must not enqueue another MainActor turn"
        )
        try require(
            registry.snapshot() == .init(
                pinnedGenerationCount: 1,
                pendingGenerationCount: 1,
                hasScheduledOrRunningMainActorTurn: true
            ),
            "the registry must hold one pin and one pending generation"
        )
        try require(
            registration.callbackBox.snapshot().pendingIntentCount <= 10,
            "callback intent storage exceeded its fixed category count"
        )

        try require(scheduler.runNext(), "the first global MainActor turn was missing")
        try require(recorder.batches.count == 1, "the first drain was not exact-once")
        try require(
            recorder.generations == [generation],
            "the first drain lost its immutable generation"
        )

        let delivered = recorder.batches[0]
        try require(
            delivered.filter { $0 == .wakeup }.count == 1,
            "wakeup callbacks were not coalesced"
        )
        try require(
            delivered.filter { $0 == .scheduleRender }.count == 1,
            "render callbacks were not coalesced"
        )
        try require(
            delivered.contains(.updateTitleMetadata("latest"))
                && !delivered.contains(.updateTitleMetadata("first")),
            "metadata coalescing did not preserve the latest value"
        )
        try require(
            delivered.contains(.rendererHealth(.unhealthy))
                && !delivered.contains(.rendererHealth(.healthy)),
            "an unhealthy renderer state must not be overwritten before delivery"
        )
        try require(
            reentrantAdmissionFailures.value == 0,
            "wakeups submitted synchronously during delivery were rejected"
        )
        try require(
            scheduler.pendingCount == 1,
            "a reentrant burst must produce exactly one successor turn"
        )
        try require(
            registry.snapshot().pendingGenerationCount == 1,
            "the reentrant generation was not scheduled after handler finalization"
        )

        try require(scheduler.runNext(), "the successor MainActor turn was missing")
        try require(recorder.batches.count == 2, "the successor drain was not exact-once")
        try require(
            recorder.generations == [generation, generation],
            "a successor drain crossed generation identity"
        )
        try require(
            recorder.batches[1] == [.wakeup],
            "the successor drain must contain one coalesced wakeup"
        )
        try require(!scheduler.runNext(), "an empty third drain was enqueued")
        try require(
            registry.snapshot() == .init(
                pinnedGenerationCount: 1,
                pendingGenerationCount: 0,
                hasScheduledOrRunningMainActorTurn: false
            ),
            "the completed registry turn did not return to idle"
        )

        try require(registry.retireAndUnpin(registration), "active generation did not retire")
        try require(
            !registry.submitWakeup(userdata: registration.userdata),
            "an unpinned native token must fail closed"
        )
    }

    @MainActor
    static func queuedGenerationReplacement() throws {
        let scheduler = MacScopeGhosttyManualMainActorScheduler()
        let registry = MacScopeGhosttyLinkedRuntimeCallbackRegistry(
            enqueueOnMainActor: { scheduler.enqueue($0) }
        )
        let oldGeneration = fixtureGeneration(6)
        let replacementGeneration = fixtureGeneration(7)
        let oldRegistration = registry.pin(generation: oldGeneration)
        let oldRecorder = MacScopeGhosttyIntentRecorder()
        let replacementRecorder = MacScopeGhosttyIntentRecorder()
        let oldSurface = UnsafeMutableRawPointer(bitPattern: 0x501)!
        let replacementSurface = UnsafeMutableRawPointer(bitPattern: 0x502)!
        let oldUserdataBits = UInt(bitPattern: oldRegistration.userdata)

        try require(
            registry.install(oldRegistration, surfaceToken: oldSurface) { [weak oldRecorder] generation, intents in
                oldRecorder?.append(generation: generation, intents: intents)
            },
            "old generation should install"
        )
        try require(
            registry.submit(
                .render,
                surfaceToken: oldSurface,
                userdata: oldRegistration.userdata
            ),
            "old generation render should be queued"
        )
        try require(scheduler.pendingCount == 1, "old generation should own one queued turn")

        try require(
            registry.retireAndUnpin(oldRegistration),
            "old generation should synchronously retire and unpin"
        )
        try require(
            oldRegistration.callbackBox.snapshot() == .init(
                generation: oldGeneration,
                drainState: .retired,
                pendingIntentCount: 0,
                hasHandler: false
            ),
            "retirement did not synchronously clear the old box"
        )

        let replacementRegistration = registry.pin(generation: replacementGeneration)
        try require(
            UInt(bitPattern: replacementRegistration.userdata) != oldUserdataBits,
            "a replacement generation reused a stale native token"
        )
        try require(
            registry.install(
                replacementRegistration,
                surfaceToken: replacementSurface
            ) { [weak replacementRecorder] generation, intents in
                replacementRecorder?.append(generation: generation, intents: intents)
            },
            "replacement generation should install"
        )
        for _ in 0..<2_048 {
            try require(
                registry.submitWakeup(userdata: replacementRegistration.userdata),
                "replacement wakeup should be admitted"
            )
        }
        try require(
            scheduler.pendingCount == 1,
            "replacement must reuse the already-enqueued global turn"
        )
        try require(
            !registry.submitWakeup(
                userdata: UnsafeMutableRawPointer(bitPattern: oldUserdataBits)
            ),
            "a late old-generation token must miss the registry"
        )
        try require(
            !oldRegistration.callbackBox.submitWakeup(),
            "an already-pinned old callback must observe retirement"
        )

        try require(scheduler.runNext(), "the replacement carrier turn was missing")
        try require(oldRecorder.batches.isEmpty, "retired generation drove its old handler")
        try require(
            replacementRecorder.generations == [replacementGeneration],
            "the queued turn did not resolve only the replacement generation"
        )
        try require(
            replacementRecorder.batches == [[.wakeup]],
            "replacement wakeups did not drain exactly once"
        )
        try require(!scheduler.runNext(), "replacement scheduled a duplicate turn")
        try require(
            !registry.retireAndUnpin(oldRegistration),
            "repeated old-generation retirement must be harmless"
        )
        try require(
            registry.retireAndUnpin(replacementRegistration),
            "replacement generation should retire"
        )
    }

    @MainActor
    static func lateCallbackPinAndDeallocation() throws {
        let scheduler = MacScopeGhosttyManualMainActorScheduler()
        var registry: MacScopeGhosttyLinkedRuntimeCallbackRegistry? =
            MacScopeGhosttyLinkedRuntimeCallbackRegistry(
                enqueueOnMainActor: { scheduler.enqueue($0) }
            )
        weak let weakRegistry = registry
        let generation = fixtureGeneration(8)
        var registration: MacScopeGhosttyLinkedRuntimeCallbackRegistry.Registration? =
            registry?.pin(generation: generation)
        guard registration != nil else {
            throw MacScopeGhosttyLinkedAdapterScenarioError.assertion(
                "callback registration was unexpectedly absent"
            )
        }
        let userdataBits = UInt(bitPattern: registration!.userdata)
        weak let weakBox = registration!.callbackBox
        let deliveryCount = MacScopeGhosttyLockedCounter()
        let deinitializationCount = MacScopeGhosttyLockedCounter()
        var owner: MacScopeGhosttyLinkedLifetimeOwner? = MacScopeGhosttyLinkedLifetimeOwner(
            deliveryCount: deliveryCount,
            deinitializationCount: deinitializationCount
        )
        weak let weakOwner = owner

        try require(
            registry?.install(
                registration!,
                surfaceToken: UnsafeMutableRawPointer(bitPattern: 0x601)!
            ) { [weak owner] generation, intents in
                owner?.receive(generation: generation, intents: intents)
            } == true,
            "lifetime-test generation should install"
        )
        try require(scheduler.pendingCount == 1, "lifetime test needs one queued old turn")

        // This strong local models a native callback that resolved the registry token immediately
        // before the MainActor begins retirement, then pauses before submitting its wakeup.
        var alreadyPinnedCallback = registry?.pinnedBox(
            for: UnsafeMutableRawPointer(bitPattern: userdataBits)
        )
        try require(alreadyPinnedCallback != nil, "native callback did not acquire its strong pin")
        try require(
            registry?.retireAndUnpin(registration!) == true,
            "lifetime-test generation did not retire"
        )
        try require(
            registry?.submitWakeup(
                userdata: UnsafeMutableRawPointer(bitPattern: userdataBits)
            ) == false,
            "a callback entering after unpin must miss"
        )
        try require(
            alreadyPinnedCallback?.submitWakeup() == false,
            "a callback pinned before unpin must observe retirement"
        )

        registration = nil
        owner = nil
        try require(weakOwner == nil, "the weak callback handler retained its owner")
        try require(
            deinitializationCount.value == 1,
            "the weak callback owner did not deallocate exactly once"
        )
        try require(weakBox != nil, "the simulated in-flight callback lost its temporary pin")
        alreadyPinnedCallback = nil
        try require(weakBox == nil, "the retired callback box did not deallocate after pin release")

        registry = nil
        try require(weakRegistry == nil, "queued MainActor work retained the registry")
        try require(scheduler.runNext(), "the harmless queued old turn was missing")
        try require(!scheduler.runNext(), "the harmless old turn created a successor")
        try require(deliveryCount.value == 0, "deallocated generation delivered callback work")
        try require(scheduler.pendingCount == 0, "queued work remained after harmless invalidation")
    }

    private static func fixtureGeneration(_ value: UInt64) -> MacScopeGhosttySurfaceGeneration {
        MacScopeGhosttySurfaceGeneration(
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000401")!,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000402")!,
            generation: value
        )
    }

    @MainActor
    private static func hostWindow(containing host: MacScopeGhosttySurfaceHostView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        return window
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw MacScopeGhosttyLinkedAdapterScenarioError.assertion(message)
        }
    }
}

@MainActor
private final class MacScopeGhosttyIntentRecorder {
    private(set) var generations: [MacScopeGhosttySurfaceGeneration] = []
    private(set) var batches: [[MacScopeGhosttyActionRouter.Intent]] = []
    var onFirstDelivery: (@MainActor () -> Void)?

    func append(
        generation: MacScopeGhosttySurfaceGeneration,
        intents: [MacScopeGhosttyActionRouter.Intent]
    ) {
        generations.append(generation)
        batches.append(intents)
        if batches.count == 1, let onFirstDelivery {
            self.onFirstDelivery = nil
            onFirstDelivery()
        }
    }
}

private final class MacScopeGhosttyManualMainActorScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [MacScopeGhosttyLinkedMainActorWork] = []

    var pendingCount: Int {
        lock.withLock { pending.count }
    }

    func enqueue(_ work: @escaping MacScopeGhosttyLinkedMainActorWork) {
        lock.withLock { pending.append(work) }
    }

    @MainActor
    @discardableResult
    func runNext() -> Bool {
        let work = lock.withLock { pending.isEmpty ? nil : pending.removeFirst() }
        guard let work else { return false }
        work()
        return true
    }
}

private final class MacScopeGhosttyLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class MacScopeGhosttyLinkedLifetimeOwner: @unchecked Sendable {
    private let deliveryCount: MacScopeGhosttyLockedCounter
    private let deinitializationCount: MacScopeGhosttyLockedCounter

    init(
        deliveryCount: MacScopeGhosttyLockedCounter,
        deinitializationCount: MacScopeGhosttyLockedCounter
    ) {
        self.deliveryCount = deliveryCount
        self.deinitializationCount = deinitializationCount
    }

    func receive(
        generation: MacScopeGhosttySurfaceGeneration,
        intents: [MacScopeGhosttyActionRouter.Intent]
    ) {
        _ = generation
        _ = intents
        deliveryCount.increment()
    }

    deinit {
        deinitializationCount.increment()
    }
}

private final class MacScopeGhosttyLinkedWorkRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MacScopeGhosttyExternalIOBridge.Work] = []

    var values: [MacScopeGhosttyExternalIOBridge.Work] {
        lock.withLock { storage }
    }

    func append(_ value: MacScopeGhosttyExternalIOBridge.Work) {
        lock.withLock { storage.append(value) }
    }
}

private final class MacScopeGhosttyLinkedScenarioBackend: MacScopeGhosttySurfaceBackend,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let feedAdmission: MacScopeGhosttySurfaceFeedAdmission
    private var processStateStorage: [MacScopeGhosttySurfaceProcessState] = []
    private var eventStorage: [MacScopeGhosttySurfaceHostEvent] = []
    private var attachCountStorage = 0
    private var teardownStepStorage: [MacScopeGhosttySurfaceTeardownStep] = []

    @MainActor var onAttach: (() -> Void)?

    @MainActor
    init(feedAdmission: MacScopeGhosttySurfaceFeedAdmission) {
        self.feedAdmission = feedAdmission
    }

    var processStates: [MacScopeGhosttySurfaceProcessState] {
        lock.withLock { processStateStorage }
    }

    var events: [MacScopeGhosttySurfaceHostEvent] {
        lock.withLock { eventStorage }
    }

    var attachCount: Int { lock.withLock { attachCountStorage } }
    var teardownSteps: [MacScopeGhosttySurfaceTeardownStep] {
        lock.withLock { teardownStepStorage }
    }

    @MainActor
    func attach(to hostView: MacScopeGhosttySurfaceHostView) throws {
        lock.withLock { attachCountStorage += 1 }
        onAttach?()
    }

    @MainActor
    func handle(hostEvent: MacScopeGhosttySurfaceHostEvent) -> Bool {
        lock.withLock { eventStorage.append(hostEvent) }
        return true
    }

    func feed(
        _ bytes: Data,
        generation: MacScopeGhosttySurfaceGeneration
    ) -> MacScopeGhosttySurfaceFeedAdmission {
        _ = bytes
        _ = generation
        return feedAdmission
    }

    func setProcessState(
        _ state: MacScopeGhosttySurfaceProcessState,
        generation: MacScopeGhosttySurfaceGeneration
    ) -> MacScopeGhosttySurfaceFeedAdmission {
        _ = generation
        lock.withLock { processStateStorage.append(state) }
        return .accepted
    }

    @MainActor func retire(generation: MacScopeGhosttySurfaceGeneration) {
        _ = generation
        record(.retireGeneration)
    }
    @MainActor func stopFeed() { record(.stopFeed) }
    @MainActor func invalidateCallbacks() { record(.invalidateCallbacks) }
    @MainActor func detachDisplayAndWakeup() { record(.detachDisplayAndWakeup) }
    @MainActor func destroySurface() { record(.destroySurface) }
    @MainActor func releaseBridgeBox() { record(.releaseBridgeBox) }

    private func record(_ step: MacScopeGhosttySurfaceTeardownStep) {
        lock.withLock { teardownStepStorage.append(step) }
    }
}
