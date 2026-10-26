import AppKit
import XCTest

@testable import MacScope

@MainActor
final class MacScopeGhosttyLifecycleTests: XCTestCase {
    func testModifierEventForwardsFlagsWithoutReadingKeyOnlyProperties() throws {
        let host = MacScopeGhosttySurfaceHostView(frame: .zero)
        let sink = ModifierHostEventSink()
        XCTAssertTrue(host.installEventSink(sink))
        for flags in [NSEvent.ModifierFlags.shift, []] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .flagsChanged,
                location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                context: nil, characters: "", charactersIgnoringModifiers: "",
                isARepeat: false, keyCode: 56))
            host.flagsChanged(with: event)
            XCTAssertEqual(sink.events.last, .modifierFlagsChanged(MacScopeGhosttyKeyInput(
                keyCode: 56, characters: nil, charactersIgnoringModifiers: nil,
                modifierFlags: flags.rawValue, isRepeat: false)))
            XCTAssertFalse(host.performKeyEquivalent(with: event))
        }
        XCTAssertEqual(sink.events.count, 2)
    }

    func testKeyDownPreservesCharactersAndRepeat() throws {
        let host = MacScopeGhosttySurfaceHostView(frame: .zero)
        let sink = ModifierHostEventSink()
        XCTAssertTrue(host.installEventSink(sink))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown,
            location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0,
            context: nil, characters: "A", charactersIgnoringModifiers: "a",
            isARepeat: true, keyCode: 0))
        host.keyDown(with: event)
        XCTAssertEqual(sink.events, [.key(MacScopeGhosttyKeyInput(
            keyCode: 0, characters: "A", charactersIgnoringModifiers: "a",
            modifierFlags: NSEvent.ModifierFlags.shift.rawValue, isRepeat: true))])
    }

    func testGenerationIdentityIncludesSessionRequestAndMonotonicGeneration() {
        let session = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
        let request = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!

        let first = MacScopeGhosttySurfaceGeneration(
            sessionID: session,
            requestID: request,
            generation: 1
        )
        let same = MacScopeGhosttySurfaceGeneration(
            sessionID: session,
            requestID: request,
            generation: 1
        )
        let replacement = MacScopeGhosttySurfaceGeneration(
            sessionID: session,
            requestID: request,
            generation: 2
        )

        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, replacement)
        XCTAssertEqual(Set([first, same, replacement]).count, 2)
    }

    func testShutdownUsesBindingOrderAndIsIdempotent() throws {
        let backend = RecordingBackend()
        let coordinator = MacScopeGhosttySurfaceCoordinator(
            generation: generation(1),
            backend: backend
        )
        let host = MacScopeGhosttySurfaceHostView(frame: .zero)
        XCTAssertThrowsError(try coordinator.attach(to: host))
        XCTAssertEqual(backend.attachCount, 0)

        let window = hostWindow(containing: host)
        defer { window.contentView = nil }
        try coordinator.attach(to: host)

        let competingBackend = RecordingBackend()
        let competingCoordinator = MacScopeGhosttySurfaceCoordinator(
            generation: generation(2),
            backend: competingBackend
        )
        XCTAssertThrowsError(try competingCoordinator.attach(to: host))
        XCTAssertEqual(competingBackend.attachCount, 0)
        competingCoordinator.shutdown()

        coordinator.shutdown()
        coordinator.shutdown()

        XCTAssertEqual(coordinator.phase, .destroyed)
        XCTAssertEqual(
            coordinator.teardownSteps,
            MacScopeGhosttySurfaceTeardownStep.allCases
        )
        XCTAssertEqual(
            backend.recordedSteps,
            [
                .retireGeneration,
                .stopFeed,
                .invalidateCallbacks,
                .detachDisplayAndWakeup,
                .destroySurface,
                .releaseBridgeBox,
            ]
        )
        XCTAssertNil(host.eventSink)
    }

    func testFixtureAdmissionCopiesAllChunksAndNeverRunsBackendOnMainThread() throws {
        let backend = RecordingBackend()
        let coordinator = MacScopeGhosttySurfaceCoordinator(
            generation: generation(2),
            backend: backend
        )
        let host = MacScopeGhosttySurfaceHostView(frame: .zero)
        let window = hostWindow(containing: host)
        defer { window.contentView = nil }
        try coordinator.attach(to: host)
        let fixture = MacScopeGhosttySurfaceFixture.canonical(.grapheme)
        let completion = expectation(description: "fixture admitted")
        let result = LockedValue<MacScopeGhosttyFixtureAdmission?>(nil)

        coordinator.admitFixture(fixture) { admission in
            result.set(admission)
            completion.fulfill()
        }
        wait(for: [completion], timeout: 2)

        XCTAssertEqual(
            result.value,
            .accepted(
                byteCount: fixture.byteCount,
                chunkCount: fixture.chunks.count,
                ranOnMainThread: false
            )
        )
        XCTAssertEqual(backend.fixtureBytes, fixture.chunks.reduce(Data(), +))
        XCTAssertEqual(backend.fixtureMainThreadFlags, Array(repeating: false, count: fixture.chunks.count))
        coordinator.shutdown()
    }

    func testFixtureAdmissionRejectsUnboundedChunkBeforeBackendDelivery() throws {
        let backend = RecordingBackend()
        let coordinator = MacScopeGhosttySurfaceCoordinator(
            generation: generation(2),
            backend: backend
        )
        let host = MacScopeGhosttySurfaceHostView(frame: .zero)
        let window = hostWindow(containing: host)
        defer { window.contentView = nil }
        try coordinator.attach(to: host)
        let result = LockedValue<MacScopeGhosttyFixtureAdmission?>(nil)

        coordinator.admitFixture(.init(
            kind: .teardown,
            chunks: [Data(repeating: 0x41, count: (1 << 20) + 1)]
        )) { result.set($0) }

        XCTAssertEqual(result.value, .rejected(.fixtureBudgetExceeded))
        XCTAssertTrue(backend.fixtureBytes.isEmpty)
        coordinator.shutdown()
    }

    func testDirectFeedRejectsUnboundedBytesBeforeBackendCopy() throws {
        let backend = RecordingBackend()
        let coordinator = MacScopeGhosttySurfaceCoordinator(
            generation: generation(2),
            backend: backend
        )
        let host = MacScopeGhosttySurfaceHostView(frame: .zero)
        let window = hostWindow(containing: host)
        defer { window.contentView = nil }
        try coordinator.attach(to: host)

        XCTAssertEqual(
            coordinator.feed(Data(repeating: 0x41, count: (4 << 20) + 1)),
            .invalid
        )
        XCTAssertTrue(backend.fixtureBytes.isEmpty)
        coordinator.shutdown()
    }

    func testStaleGenerationAndCallbackDuringRetirementFailClosed() throws {
        let backend = RecordingBackend()
        let current = generation(3)
        let coordinator = MacScopeGhosttySurfaceCoordinator(
            generation: current,
            backend: backend
        )
        let host = MacScopeGhosttySurfaceHostView(frame: .zero)
        let window = hostWindow(containing: host)
        defer { window.contentView = nil }
        try coordinator.attach(to: host)

        let staleCompletion = expectation(description: "stale generation rejected")
        let staleResult = LockedValue<MacScopeGhosttyFixtureAdmission?>(nil)
        coordinator.admitFixture(
            .canonical(.ansi),
            for: generation(2)
        ) { admission in
            staleResult.set(admission)
            staleCompletion.fulfill()
        }
        wait(for: [staleCompletion], timeout: 2)
        XCTAssertEqual(staleResult.value, .rejected(.staleOrRetiredGeneration))

        let retirementCompletion = expectation(description: "callback during close rejected")
        let retirementResult = LockedValue<MacScopeGhosttyFixtureAdmission?>(nil)
        backend.onRetire = { [weak coordinator] in
            coordinator?.admitFixture(.canonical(.teardown)) { admission in
                retirementResult.set(admission)
                retirementCompletion.fulfill()
            }
        }
        coordinator.shutdown()
        wait(for: [retirementCompletion], timeout: 2)

        XCTAssertEqual(retirementResult.value, .rejected(.staleOrRetiredGeneration))
        XCTAssertTrue(backend.fixtureBytes.isEmpty)
    }

    func testHostForwardsTextPreeditPastePointerScrollScaleAndOcclusionValues() throws {
        let backend = RecordingBackend()
        backend.selectedTextValue = "selected"
        let coordinator = MacScopeGhosttySurfaceCoordinator(
            generation: generation(4),
            backend: backend
        )
        let host = MacScopeGhosttySurfaceHostView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let window = hostWindow(containing: host)
        defer { window.contentView = nil }
        try coordinator.attach(to: host)
        let initialEnvironmentEvents = backend.events
        backend.clearEvents()

        host.setMarkedText(
            "候補",
            selectedRange: NSRange(location: 1, length: 1),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        host.unmarkText()
        host.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(host.forwardPaste("paste\n"))

        let mouse = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 8, y: 12),
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 0,
            pressure: 0
        ))
        host.mouseMoved(with: mouse)

        let scrollEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: -3,
            wheel2: 1,
            wheel3: 0
        ))
        let scroll = try XCTUnwrap(NSEvent(cgEvent: scrollEvent))
        host.scrollWheel(with: scroll)

        XCTAssertTrue(backend.events.contains {
            if case .preedit("候補", selectedRange: NSRange(location: 1, length: 1), replacementRange: _) = $0 {
                return true
            }
            return false
        })
        XCTAssertTrue(backend.events.contains(.unmarkText))
        XCTAssertTrue(backend.events.contains {
            if case .text("é", replacementRange: _) = $0 { return true }
            return false
        })
        XCTAssertTrue(backend.events.contains(.paste("paste\n")))
        XCTAssertTrue(backend.events.contains {
            if case .pointer(let input) = $0 { return input.phase == .moved }
            return false
        })
        XCTAssertTrue(backend.events.contains {
            if case .scroll(let input) = $0 { return input.deltaX == 1 && input.deltaY == -3 }
            return false
        })
        XCTAssertTrue(initialEnvironmentEvents.contains {
            if case .display = $0 { return true }
            return false
        })
        XCTAssertTrue(initialEnvironmentEvents.contains {
            if case .resize = $0 { return true }
            return false
        })
        XCTAssertTrue(initialEnvironmentEvents.contains {
            if case .occlusion = $0 { return true }
            return false
        })

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(host.copySelection(to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "selected")
        coordinator.shutdown()
    }

    func testCanonicalFixtureCatalogIsCompleteStableAndNonempty() {
        let first = MacScopeGhosttyFixtureKind.allCases.map(MacScopeGhosttySurfaceFixture.canonical)
        let second = MacScopeGhosttyFixtureKind.allCases.map(MacScopeGhosttySurfaceFixture.canonical)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.map(\.kind), MacScopeGhosttyFixtureKind.allCases)
        XCTAssertTrue(first.allSatisfy { !$0.chunks.isEmpty && $0.byteCount > 0 })
    }

    func testUnavailableRepresentableReportsFallbackWithoutConstructingBackend() async {
        let representable = MacScopeGhosttySurfaceRepresentable(
            generation: generation(5)
        )
        let coordinator = representable.makeCoordinator()
        let host = MacScopeGhosttySurfaceHostView(frame: .zero)
        let window = hostWindow(containing: host)
        defer { window.contentView = nil }
        var availability: [Bool] = []

        coordinator.reconcile(
            hostView: host,
            generation: generation(5),
            backendFactory: { _ in nil },
            availabilityChanged: { availability.append($0) }
        )

        XCTAssertTrue(availability.isEmpty, "availability mutated during representable update")
        await drainMainActorTurns()
        XCTAssertEqual(availability, [false])
        XCTAssertNil(host.eventSink)
        coordinator.dismantle(hostView: host)
    }

    func testRepresentableDefersNativeAttachmentAndDoesNotPublishRendererEvidence() async {
        let rendererEvidenceBefore = MacScopeGhosttySurfaceDiagnostics
            .rendererEvidenceShared
            .rendererSnapshot()
        let current = generation(7)
        let replacement = generation(8)
        let staleBackend = RecordingBackend()
        let backend = RecordingBackend()
        let representable = MacScopeGhosttySurfaceRepresentable(generation: current)
        let coordinator = representable.makeCoordinator()
        let host = MacScopeGhosttySurfaceHostView(frame: .zero)
        var factoryCallCount = 0
        var availability: [Bool] = []

        coordinator.reconcile(
            hostView: host,
            generation: current,
            backendFactory: { _ in
                factoryCallCount += 1
                return staleBackend
            },
            availabilityChanged: { availability.append($0) }
        )
        coordinator.reconcile(
            hostView: host,
            generation: replacement,
            backendFactory: { _ in
                factoryCallCount += 1
                return backend
            },
            availabilityChanged: { availability.append($0) }
        )
        coordinator.reconcile(
            hostView: host,
            generation: current,
            backendFactory: { _ in
                factoryCallCount += 1
                return staleBackend
            },
            availabilityChanged: { availability.append($0) }
        )

        XCTAssertEqual(factoryCallCount, 0)
        XCTAssertTrue(availability.isEmpty)
        XCTAssertNil(host.eventSink)

        let window = hostWindow(containing: host)
        defer { window.contentView = nil }

        XCTAssertEqual(factoryCallCount, 1)
        XCTAssertEqual(staleBackend.attachCount, 0)
        XCTAssertEqual(backend.attachCount, 1)
        XCTAssertTrue(availability.isEmpty, "availability mutated during AppKit attachment")
        await drainMainActorTurns()
        XCTAssertEqual(availability, [true])
        XCTAssertNotNil(host.eventSink)

        var sinkWasClearedAtFirstNativeStep = false
        backend.onStep = { step in
            guard step == .retireGeneration else { return }
            sinkWasClearedAtFirstNativeStep = host.eventSink == nil
        }

        coordinator.dismantle(hostView: host)
        coordinator.dismantle(hostView: host)

        XCTAssertTrue(sinkWasClearedAtFirstNativeStep)
        XCTAssertEqual(backend.recordedSteps, MacScopeGhosttySurfaceTeardownStep.allCases)
        XCTAssertNil(host.eventSink)
        XCTAssertFalse(host.isObservingWindow)
        XCTAssertEqual(
            MacScopeGhosttySurfaceDiagnostics.rendererEvidenceShared.rendererSnapshot(),
            rendererEvidenceBefore
        )
    }

    func testRapidGenerationAndHostReplacementCannotReviveRetiredSurface() async {
        let firstGeneration = generation(8)
        let secondGeneration = generation(9)
        let firstBackend = RecordingBackend()
        let secondBackend = RecordingBackend()
        let representable = MacScopeGhosttySurfaceRepresentable(generation: firstGeneration)
        let coordinator = representable.makeCoordinator()
        let firstHost = MacScopeGhosttySurfaceHostView(frame: .zero)
        let firstWindow = hostWindow(containing: firstHost)
        var availability: [String] = []

        coordinator.reconcile(
            hostView: firstHost,
            generation: firstGeneration,
            backendFactory: { _ in firstBackend },
            availabilityChanged: { availability.append("8:\($0)") }
        )
        coordinator.reconcile(
            hostView: firstHost,
            generation: secondGeneration,
            backendFactory: { _ in secondBackend },
            availabilityChanged: { availability.append("9:\($0)") }
        )

        XCTAssertTrue(availability.isEmpty)
        await drainMainActorTurns()
        XCTAssertEqual(availability, ["9:true"])
        XCTAssertEqual(firstBackend.recordedSteps, MacScopeGhosttySurfaceTeardownStep.allCases)

        let staleCallback = expectation(description: "queued stale generation callback")
        var forbiddenFactoryCallCount = 0
        DispatchQueue.main.async {
            coordinator.reconcile(
                hostView: firstHost,
                generation: firstGeneration,
                backendFactory: { _ in
                    forbiddenFactoryCallCount += 1
                    return RecordingBackend()
                },
                availabilityChanged: { availability.append("8:\($0)") }
            )
            staleCallback.fulfill()
        }
        await fulfillment(of: [staleCallback], timeout: 2)

        XCTAssertEqual(forbiddenFactoryCallCount, 0)
        XCTAssertEqual(availability, ["9:true"])
        XCTAssertTrue(secondBackend.recordedSteps.isEmpty)
        XCTAssertEqual(
            coordinator.feed(Data([0x41]), generation: secondGeneration),
            .accepted
        )

        let replacementHost = MacScopeGhosttySurfaceHostView(frame: .zero)
        let replacementWindow = hostWindow(containing: replacementHost)
        coordinator.reconcile(
            hostView: replacementHost,
            generation: secondGeneration,
            backendFactory: { _ in
                forbiddenFactoryCallCount += 1
                return RecordingBackend()
            },
            availabilityChanged: { availability.append("9:\($0)") }
        )

        XCTAssertEqual(forbiddenFactoryCallCount, 0)
        XCTAssertEqual(availability, ["9:true"])
        XCTAssertTrue(secondBackend.recordedSteps.isEmpty)
        XCTAssertNotNil(firstHost.eventSink)
        XCTAssertNil(replacementHost.eventSink)

        firstWindow.contentView = nil
        let thirdGeneration = replacementSessionGeneration()
        let thirdBackend = RecordingBackend()
        var thirdFactoryCallCount = 0
        coordinator.reconcile(
            hostView: firstHost,
            generation: thirdGeneration,
            backendFactory: { _ in
                thirdFactoryCallCount += 1
                return thirdBackend
            },
            availabilityChanged: { availability.append("10:\($0)") }
        )

        XCTAssertEqual(thirdFactoryCallCount, 0)
        XCTAssertEqual(secondBackend.recordedSteps, MacScopeGhosttySurfaceTeardownStep.allCases)
        XCTAssertEqual(coordinator.feed(Data([0x42]), generation: secondGeneration), .closed)

        replacementWindow.contentView = nil
        replacementWindow.contentView = firstHost
        XCTAssertEqual(thirdFactoryCallCount, 1)
        await drainMainActorTurns()
        XCTAssertEqual(availability.last, "10:true")
        XCTAssertEqual(coordinator.feed(Data([0x43]), generation: thirdGeneration), .accepted)

        let retiredSessionCallback = expectation(description: "queued retired session callback")
        DispatchQueue.main.async {
            coordinator.reconcile(
                hostView: firstHost,
                generation: secondGeneration,
                backendFactory: { _ in
                    forbiddenFactoryCallCount += 1
                    return RecordingBackend()
                },
                availabilityChanged: { availability.append("9:\($0)") }
            )
            retiredSessionCallback.fulfill()
        }
        await fulfillment(of: [retiredSessionCallback], timeout: 2)
        XCTAssertEqual(forbiddenFactoryCallCount, 0)
        XCTAssertTrue(thirdBackend.recordedSteps.isEmpty)
        XCTAssertEqual(coordinator.feed(Data([0x44]), generation: thirdGeneration), .accepted)

        coordinator.dismantle(hostView: firstHost)
        coordinator.dismantle(hostView: firstHost)
        XCTAssertEqual(thirdBackend.recordedSteps, MacScopeGhosttySurfaceTeardownStep.allCases)
        XCTAssertNil(firstHost.eventSink)
        replacementWindow.contentView = nil
    }

    func testReentrantFactoryAttachAndRetirementKeepOnlyNewestGeneration() async {
        let coordinator = MacScopeGhosttySurfaceRepresentable(generation: generation(20))
            .makeCoordinator()
        let host = MacScopeGhosttySurfaceHostView(frame: .zero)
        let window = hostWindow(containing: host)
        defer { window.contentView = nil }

        let first = RecordingBackend()
        let factoryReentrant = RecordingBackend()
        let attachReentrant = RecordingBackend()
        let retirementReentrant = RecordingBackend()

        coordinator.reconcile(
            hostView: host,
            generation: generation(20),
            backendFactory: { _ in first },
            availabilityChanged: { _ in }
        )
        first.onRetire = {
            coordinator.reconcile(
                hostView: host,
                generation: self.generation(23),
                backendFactory: { _ in retirementReentrant },
                availabilityChanged: { _ in }
            )
        }

        coordinator.reconcile(
            hostView: host,
            generation: generation(21),
            backendFactory: { _ in
                coordinator.reconcile(
                    hostView: host,
                    generation: self.generation(22),
                    backendFactory: { _ in attachReentrant },
                    availabilityChanged: { _ in }
                )
                return factoryReentrant
            },
            availabilityChanged: { _ in }
        )

        XCTAssertEqual(first.recordedSteps, MacScopeGhosttySurfaceTeardownStep.allCases)
        XCTAssertEqual(factoryReentrant.attachCount, 0)
        XCTAssertEqual(attachReentrant.attachCount, 0)
        XCTAssertEqual(retirementReentrant.attachCount, 1)
        XCTAssertEqual(
            coordinator.feed(Data([0x41]), generation: generation(23)),
            .accepted
        )
        await drainMainActorTurns()
        coordinator.dismantle(hostView: host)
        XCTAssertEqual(
            retirementReentrant.recordedSteps,
            MacScopeGhosttySurfaceTeardownStep.allCases
        )
    }

    func testReentrantBackendAttachCannotPublishOrRetainStaleCoordinator() {
        let coordinator = MacScopeGhosttySurfaceRepresentable(generation: generation(24))
            .makeCoordinator()
        let host = MacScopeGhosttySurfaceHostView(frame: .zero)
        let window = hostWindow(containing: host)
        defer { window.contentView = nil }
        let stale = RecordingBackend()
        let replacement = RecordingBackend()
        stale.onAttach = {
            coordinator.reconcile(
                hostView: host,
                generation: self.generation(25),
                backendFactory: { _ in replacement },
                availabilityChanged: { _ in }
            )
        }

        coordinator.reconcile(
            hostView: host,
            generation: generation(24),
            backendFactory: { _ in stale },
            availabilityChanged: { _ in }
        )

        XCTAssertEqual(stale.attachCount, 1)
        XCTAssertEqual(stale.recordedSteps, MacScopeGhosttySurfaceTeardownStep.allCases)
        XCTAssertEqual(replacement.attachCount, 1)
        XCTAssertEqual(coordinator.feed(Data([0x42]), generation: generation(24)), .closed)
        XCTAssertEqual(coordinator.feed(Data([0x43]), generation: generation(25)), .accepted)
        coordinator.dismantle(hostView: host)
    }

    func testReentrantBackendFactoryCannotOverwriteNewerPendingRequest() {
        let coordinator = MacScopeGhosttySurfaceRepresentable(generation: generation(34))
            .makeCoordinator()
        let host = MacScopeGhosttySurfaceHostView(frame: .zero)
        let window = hostWindow(containing: host)
        defer { window.contentView = nil }
        let stale = RecordingBackend()
        let replacement = RecordingBackend()

        coordinator.reconcile(
            hostView: host,
            generation: generation(34),
            backendFactory: { _ in
                coordinator.reconcile(
                    hostView: host,
                    generation: self.generation(35),
                    backendFactory: { _ in replacement },
                    availabilityChanged: { _ in }
                )
                return stale
            },
            availabilityChanged: { _ in }
        )

        XCTAssertEqual(stale.attachCount, 0)
        XCTAssertTrue(stale.recordedSteps.isEmpty)
        XCTAssertEqual(replacement.attachCount, 1)
        XCTAssertEqual(coordinator.feed(Data([0x45]), generation: generation(35)), .accepted)
        coordinator.dismantle(hostView: host)
    }

    func testSharedOrDestroyedBackendAttachFailureCannotDestroyCurrentOwner() throws {
        let backend = RecordingBackend()
        backend.rejectRepeatedAttach = true
        let first = MacScopeGhosttySurfaceCoordinator(
            generation: generation(26),
            backend: backend
        )
        let firstHost = MacScopeGhosttySurfaceHostView(frame: .zero)
        let firstWindow = hostWindow(containing: firstHost)
        defer { firstWindow.contentView = nil }
        try first.attach(to: firstHost)

        let contender = MacScopeGhosttySurfaceCoordinator(
            generation: generation(27),
            backend: backend
        )
        let contenderHost = MacScopeGhosttySurfaceHostView(frame: .zero)
        let contenderWindow = hostWindow(containing: contenderHost)
        defer { contenderWindow.contentView = nil }
        XCTAssertThrowsError(try contender.attach(to: contenderHost))
        contender.shutdown()

        XCTAssertTrue(backend.recordedSteps.isEmpty)
        XCTAssertEqual(first.feed(Data([0x41])), .accepted)
        first.shutdown()
        XCTAssertEqual(backend.recordedSteps, MacScopeGhosttySurfaceTeardownStep.allCases)

        let postDestroy = MacScopeGhosttySurfaceCoordinator(
            generation: generation(28),
            backend: backend
        )
        XCTAssertThrowsError(try postDestroy.attach(to: contenderHost))
        postDestroy.shutdown()
        XCTAssertEqual(backend.recordedSteps, MacScopeGhosttySurfaceTeardownStep.allCases)
    }

    func testDeferredRetirementBlocksReplacementUntilOldNativeSurfaceIsDestroyed() async {
        let feedEntered = DispatchSemaphore(value: 0)
        let releaseFeed = DispatchSemaphore(value: 0)
        defer { releaseFeed.signal() }
        let first = RecordingBackend(feedEntered: feedEntered, releaseFeed: releaseFeed)
        let replacement = RecordingBackend()
        let coordinator = MacScopeGhosttySurfaceRepresentable(generation: generation(29))
            .makeCoordinator()
        let host = MacScopeGhosttySurfaceHostView(frame: .zero)
        let window = hostWindow(containing: host)
        defer { window.contentView = nil }
        let fixtureCompleted = expectation(description: "retired fixture completed")
        let destructionCompleted = expectation(description: "old native surface destroyed")
        first.onStep = { step in
            if step == .releaseBridgeBox { destructionCompleted.fulfill() }
        }

        coordinator.reconcile(
            hostView: host,
            generation: generation(29),
            backendFactory: { _ in first },
            availabilityChanged: { _ in }
        )
        coordinator.admitFixture(.canonical(.teardown), generation: generation(29)) { _ in
            fixtureCompleted.fulfill()
        }
        XCTAssertEqual(feedEntered.wait(timeout: .now() + 2), .success)

        coordinator.reconcile(
            hostView: host,
            generation: generation(30),
            backendFactory: { _ in replacement },
            availabilityChanged: { _ in }
        )
        XCTAssertEqual(replacement.attachCount, 0)
        XCTAssertEqual(
            first.recordedSteps,
            [.retireGeneration, .stopFeed, .invalidateCallbacks, .detachDisplayAndWakeup]
        )

        releaseFeed.signal()
        await fulfillment(of: [fixtureCompleted, destructionCompleted], timeout: 2)
        await drainMainActorTurns()
        XCTAssertEqual(first.recordedSteps, MacScopeGhosttySurfaceTeardownStep.allCases)
        XCTAssertEqual(replacement.attachCount, 1)
        XCTAssertEqual(coordinator.feed(Data([0x44]), generation: generation(30)), .accepted)
        coordinator.dismantle(hostView: host)
    }

    func testDeferredShutdownRetainsPassUnretainedHostUntilNativeDestruction() async throws {
        let feedEntered = DispatchSemaphore(value: 0)
        let releaseFeed = DispatchSemaphore(value: 0)
        defer { releaseFeed.signal() }
        let backend = RecordingBackend(feedEntered: feedEntered, releaseFeed: releaseFeed)
        var coordinator: MacScopeGhosttySurfaceCoordinator? = .init(
            generation: generation(31),
            backend: backend
        )
        var host: MacScopeGhosttySurfaceHostView? = .init(frame: .zero)
        var window: NSWindow? = hostWindow(containing: host!)
        weak let weakHost = host
        let fixtureCompleted = expectation(description: "fixture completed")
        let destructionCompleted = expectation(description: "native destruction completed")
        backend.onStep = { step in
            if step == .releaseBridgeBox { destructionCompleted.fulfill() }
        }
        try coordinator?.attach(to: host!)
        coordinator?.admitFixture(.canonical(.teardown)) { _ in fixtureCompleted.fulfill() }
        XCTAssertEqual(feedEntered.wait(timeout: .now() + 2), .success)

        coordinator?.shutdown()
        window?.contentView = nil
        window = nil
        host = nil
        XCTAssertNotNil(weakHost)

        releaseFeed.signal()
        await fulfillment(of: [fixtureCompleted, destructionCompleted], timeout: 2)
        await drainMainActorTurns()
        XCTAssertNil(weakHost)
        coordinator = nil
    }

    func testHostFocusTracksOnlyKeyWindowAndClosesBeforeDetach() throws {
        let backend = RecordingBackend()
        let coordinator = MacScopeGhosttySurfaceCoordinator(
            generation: generation(32),
            backend: backend
        )
        let host = MacScopeGhosttySurfaceHostView(frame: .zero)
        let window = FocusStateWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer { window.contentView = nil }
        try coordinator.attach(to: host)
        backend.clearEvents()

        window.simulatesKeyWindow = false
        XCTAssertTrue(window.makeFirstResponder(host))
        host.publishCurrentEnvironment()
        XCTAssertFalse(backend.focusEvents.contains(true))

        window.simulatesKeyWindow = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertEqual(backend.focusEvents, [true])

        window.contentView = nil
        XCTAssertEqual(backend.focusEvents, [true, false])
        coordinator.shutdown()
    }

    func testHostRejectsOversizedTextSelectionAndPixelGeometryAtomically() throws {
        let backend = RecordingBackend()
        let coordinator = MacScopeGhosttySurfaceCoordinator(
            generation: generation(33),
            backend: backend
        )
        let host = MacScopeGhosttySurfaceHostView(frame: .zero)
        let window = hostWindow(containing: host)
        defer { window.contentView = nil }
        try coordinator.attach(to: host)
        backend.clearEvents()
        let oversizedInput = String(repeating: "x", count: (32 << 10) + 1)

        XCTAssertFalse(host.forwardPaste(oversizedInput))
        host.insertText(oversizedInput, replacementRange: NSRange(location: NSNotFound, length: 0))
        host.setMarkedText(
            oversizedInput,
            selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertFalse(backend.events.contains {
            if case .paste = $0 { return true }
            if case .text = $0 { return true }
            if case .preedit = $0 { return true }
            return false
        })
        XCTAssertTrue(backend.events.contains(.unmarkText))

        backend.selectedTextValue = String(repeating: "s", count: (4 << 20) + 1)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertFalse(host.copySelection(to: pasteboard))

        backend.clearEvents()
        host.setFrameSize(NSSize(width: 2_000_000, height: 400))
        XCTAssertFalse(backend.events.contains {
            if case .resize = $0 { return true }
            return false
        })
        coordinator.shutdown()
    }

    func testHostBoundsEnvironmentAndRenderTrafficAndRemovesWindowObservers() throws {
        let backend = RecordingBackend()
        let coordinator = MacScopeGhosttySurfaceCoordinator(
            generation: generation(10),
            backend: backend
        )
        let host = MacScopeGhosttySurfaceHostView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400)
        )
        let firstWindow = hostWindow(containing: host)
        try coordinator.attach(to: host)
        XCTAssertTrue(host.isObservingWindow)
        backend.clearEvents()

        host.publishCurrentEnvironment()
        host.publishCurrentEnvironment()
        host.setFrameSize(host.frame.size)
        host.setFrameSize(host.frame.size)
        host.requestRender()
        host.requestRender()

        XCTAssertTrue(backend.events.isEmpty)
        XCTAssertTrue(host.needsDisplay)

        host.setFrameSize(NSSize(width: 700, height: 420))
        XCTAssertEqual(backend.events.filter { event in
            if case .resize = event { return true }
            return false
        }.count, 1)
        XCTAssertFalse(backend.events.contains(.wakeup))

        let secondWindow = NSWindow(
            contentRect: NSRect(x: 20, y: 20, width: 700, height: 420),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        firstWindow.contentView = nil
        secondWindow.contentView = host
        backend.clearEvents()

        NotificationCenter.default.post(
            name: NSWindow.didChangeScreenNotification,
            object: firstWindow
        )
        NotificationCenter.default.post(
            name: NSWindow.didChangeOcclusionStateNotification,
            object: firstWindow
        )
        XCTAssertTrue(backend.events.isEmpty)

        coordinator.shutdown()
        host.prepareForDismantle()
        backend.clearEvents()
        XCTAssertFalse(host.isObservingWindow)
        NotificationCenter.default.post(
            name: NSWindow.didChangeScreenNotification,
            object: secondWindow
        )
        XCTAssertTrue(backend.events.isEmpty)
        secondWindow.contentView = nil
    }

    func testShutdownWaitsForAdmittedFixtureAndRejectsItsPostRetirementCompletion() throws {
        let feedEntered = DispatchSemaphore(value: 0)
        let releaseFeed = DispatchSemaphore(value: 0)
        let backend = RecordingBackend(
            feedEntered: feedEntered,
            releaseFeed: releaseFeed
        )
        let coordinator = MacScopeGhosttySurfaceCoordinator(
            generation: generation(11),
            backend: backend
        )
        let host = MacScopeGhosttySurfaceHostView(frame: .zero)
        let window = hostWindow(containing: host)
        defer { window.contentView = nil }
        try coordinator.attach(to: host)
        let completion = expectation(description: "retired fixture completion")
        let destruction = expectation(description: "deferred native destruction")
        let result = LockedValue<MacScopeGhosttyFixtureAdmission?>(nil)
        backend.onStep = { step in
            if step == .releaseBridgeBox {
                destruction.fulfill()
            }
        }

        coordinator.admitFixture(.canonical(.teardown)) { admission in
            result.set(admission)
            completion.fulfill()
        }
        XCTAssertEqual(feedEntered.wait(timeout: .now() + 2), .success)

        coordinator.shutdown()
        XCTAssertEqual(coordinator.phase, .retiring)
        XCTAssertEqual(
            backend.recordedSteps,
            [.retireGeneration, .stopFeed, .invalidateCallbacks, .detachDisplayAndWakeup]
        )
        releaseFeed.signal()
        wait(for: [completion, destruction], timeout: 2)

        XCTAssertEqual(result.value, .rejected(.staleOrRetiredGeneration))
        XCTAssertEqual(coordinator.phase, .destroyed)
        XCTAssertFalse(backend.feedWaitTimedOut)
        XCTAssertFalse(backend.destroyedWhileFeedWasActive)
        XCTAssertEqual(backend.recordedSteps, MacScopeGhosttySurfaceTeardownStep.allCases)
    }

    func testRepeatedDismantleBreaksHostCoordinatorBackendOwnership() {
        weak var weakCoordinator: MacScopeGhosttySurfaceRepresentable.Coordinator?
        weak var weakBackend: RecordingBackend?
        weak var weakHost: MacScopeGhosttySurfaceHostView?

        autoreleasepool {
            let backend = RecordingBackend()
            let representable = MacScopeGhosttySurfaceRepresentable(generation: generation(6))
            var coordinator: MacScopeGhosttySurfaceRepresentable.Coordinator? =
                representable.makeCoordinator()
            var host: MacScopeGhosttySurfaceHostView? = .init(frame: .zero)
            var window: NSWindow? = hostWindow(containing: host!)
            weakBackend = backend
            weakCoordinator = coordinator
            weakHost = host

            coordinator?.reconcile(
                hostView: host!,
                generation: generation(6),
                backendFactory: { _ in backend },
                availabilityChanged: { _ in }
            )
            coordinator?.dismantle(hostView: host!)
            coordinator?.dismantle(hostView: host!)
            window?.contentView = nil
            window = nil
            host = nil
            coordinator = nil
        }

        XCTAssertNil(weakCoordinator)
        XCTAssertNil(weakBackend)
        XCTAssertNil(weakHost)
    }

    private func generation(_ value: UInt64) -> MacScopeGhosttySurfaceGeneration {
        MacScopeGhosttySurfaceGeneration(
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000302")!,
            generation: value
        )
    }

    private func replacementSessionGeneration() -> MacScopeGhosttySurfaceGeneration {
        MacScopeGhosttySurfaceGeneration(
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000311")!,
            requestID: UUID(uuidString: "00000000-0000-0000-0000-000000000312")!,
            generation: 10
        )
    }

    private func drainMainActorTurns(_ count: Int = 4) async {
        for _ in 0..<count {
            await Task.yield()
        }
    }

    private func hostWindow(containing host: MacScopeGhosttySurfaceHostView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        return window
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

private final class RecordingBackend: MacScopeGhosttySurfaceBackend, @unchecked Sendable {
    private let lock = NSLock()
    private let feedEntered: DispatchSemaphore?
    private let releaseFeed: DispatchSemaphore?
    private var stepStorage: [MacScopeGhosttySurfaceTeardownStep] = []
    private var eventStorage: [MacScopeGhosttySurfaceHostEvent] = []
    private var fixtureStorage = Data()
    private var fixtureMainStorage: [Bool] = []
    private var attachCountStorage = 0
    private var activeFeedCount = 0
    private var feedWaitTimedOutStorage = false
    private var destroyedWhileFeedWasActiveStorage = false
    private var wasDestroyedStorage = false

    @MainActor var selectedTextValue: String?
    @MainActor var rejectRepeatedAttach = false
    @MainActor var onAttach: (() -> Void)?
    @MainActor var onRetire: (() -> Void)?
    @MainActor var onStep: ((MacScopeGhosttySurfaceTeardownStep) -> Void)?

    @MainActor
    init(
        feedEntered: DispatchSemaphore? = nil,
        releaseFeed: DispatchSemaphore? = nil
    ) {
        self.feedEntered = feedEntered
        self.releaseFeed = releaseFeed
    }

    var recordedSteps: [MacScopeGhosttySurfaceTeardownStep] { locked { stepStorage } }
    var events: [MacScopeGhosttySurfaceHostEvent] { locked { eventStorage } }
    var focusEvents: [Bool] {
        events.compactMap {
            if case let .focus(focused) = $0 { return focused }
            return nil
        }
    }
    var fixtureBytes: Data { locked { fixtureStorage } }
    var fixtureMainThreadFlags: [Bool] { locked { fixtureMainStorage } }
    var attachCount: Int { locked { attachCountStorage } }
    var feedWaitTimedOut: Bool { locked { feedWaitTimedOutStorage } }
    var destroyedWhileFeedWasActive: Bool { locked { destroyedWhileFeedWasActiveStorage } }

    @MainActor
    func attach(to hostView: MacScopeGhosttySurfaceHostView) throws {
        lock.lock()
        if rejectRepeatedAttach, attachCountStorage > 0 || wasDestroyedStorage {
            lock.unlock()
            throw RecordingBackendError.exclusiveOwnership
        }
        attachCountStorage += 1
        lock.unlock()
        onAttach?()
    }

    @MainActor
    func handle(hostEvent: MacScopeGhosttySurfaceHostEvent) -> Bool {
        lock.lock()
        eventStorage.append(hostEvent)
        lock.unlock()
        return true
    }

    @MainActor
    func selectedText() -> String? { selectedTextValue }

    @MainActor
    func textInputRect() -> NSRect? {
        NSRect(x: 2, y: 3, width: 8, height: 16)
    }

    func feed(
        _ bytes: Data,
        generation: MacScopeGhosttySurfaceGeneration
    ) -> MacScopeGhosttySurfaceFeedAdmission {
        lock.lock()
        activeFeedCount += 1
        fixtureStorage.append(bytes)
        fixtureMainStorage.append(Thread.isMainThread)
        lock.unlock()

        feedEntered?.signal()
        if let releaseFeed {
            let waitResult = releaseFeed.wait(timeout: .now() + 2)
            if waitResult != .success {
                lock.lock()
                feedWaitTimedOutStorage = true
                lock.unlock()
            }
        }

        lock.lock()
        activeFeedCount -= 1
        lock.unlock()
        return .accepted
    }

    @MainActor
    func retire(generation: MacScopeGhosttySurfaceGeneration) {
        record(.retireGeneration)
        onRetire?()
    }

    @MainActor func stopFeed() { record(.stopFeed) }
    @MainActor func invalidateCallbacks() { record(.invalidateCallbacks) }
    @MainActor func detachDisplayAndWakeup() { record(.detachDisplayAndWakeup) }
    @MainActor
    func destroySurface() {
        lock.lock()
        wasDestroyedStorage = true
        if activeFeedCount > 0 {
            destroyedWhileFeedWasActiveStorage = true
        }
        lock.unlock()
        record(.destroySurface)
    }
    @MainActor func releaseBridgeBox() { record(.releaseBridgeBox) }

    @MainActor
    func clearEvents() {
        lock.lock()
        eventStorage.removeAll()
        lock.unlock()
    }

    @MainActor
    private func record(_ step: MacScopeGhosttySurfaceTeardownStep) {
        lock.lock()
        stepStorage.append(step)
        lock.unlock()
        onStep?(step)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private enum RecordingBackendError: Error {
    case exclusiveOwnership
}

private final class FocusStateWindow: NSWindow {
    var simulatesKeyWindow = false

    override var isKeyWindow: Bool { simulatesKeyWindow }
}

@MainActor
private final class ModifierHostEventSink: MacScopeGhosttySurfaceHostEventSink {
    var events: [MacScopeGhosttySurfaceHostEvent] = []
    func ghosttyHostView(_ hostView: MacScopeGhosttySurfaceHostView,
                         handle event: MacScopeGhosttySurfaceHostEvent) -> Bool {
        events.append(event)
        return true
    }
}
