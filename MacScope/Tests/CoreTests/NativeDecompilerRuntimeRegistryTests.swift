import Foundation
import XCTest
@testable import MacScope

#if DEBUG
// Injected registry construction is intentionally unavailable to Release product code.
@MainActor
private extension NativeDecompilerSessionProviding {
    func makeWorkspaceSession(
        owner: WorkspaceWindowID,
        presentation: NativeDecompilerPresentationModel
    ) -> any NativeDecompilerWorkspaceSessionHandling {
        makeWorkspaceSession(windowID: owner, presentation: presentation)
    }
}

@MainActor
private extension NativeDecompilerWorkspaceSessionHandling {
    func acceptedAnalysisDidLand(
        snapshot: WorkspaceSnapshot,
        imageSlot: ImageSlot,
        functionID: UUID
    ) {
        guard let binary = snapshot.binary(in: imageSlot),
              let analysis = snapshot.analysis(in: imageSlot),
              let function = analysis.functions.first(where: { $0.id == functionID }),
              let fingerprint = analysis.analysisInputFingerprint?.overallSHA256 else {
            cancelOutstanding()
            return
        }
        let context = NativeDriveContext(
            documentID: UUID(),
            workspaceID: UUID(),
            driveGeneration: 1,
            origin: .freshImport
        )
        let ticket = NativeDriveSubmissionTicket(
            driveGeneration: 1,
            handlerBindingGeneration: 1,
            semanticInputGeneration: 1,
            manualIntentGeneration: 0,
            target: NativeDriveResolvedTarget(
                context: context,
                owner: NativeDriveImageOwner(imageSlot: imageSlot, binaryID: binary.id),
                functionID: functionID,
                functionStart: function.startAddress,
                analysisFingerprintSHA256: fingerprint
            )
        )
        submit(
            NativeDecompilerWorkspaceSubmission(
                ticket: ticket,
                snapshot: snapshot,
                snapshotRevision: UUID(),
                imageSlot: imageSlot,
                functionID: functionID,
                cacheLookupPolicy: .allowValidatedCache
            )
        )
    }

    func authoritativeSnapshotWillReplace() {
        cancelOutstanding()
    }

    func cancel() {
        terminateSession()
    }
}

@MainActor
private extension WorkspaceStore {
    func installNativeDecompilerLandingHandler(
        _ session: any NativeDecompilerWorkspaceSessionHandling
    ) {
        bindNativeDecompilerSession(session)
    }
}

@MainActor
final class NativeDecompilerRuntimeRegistryTests: XCTestCase {
    func testSnapshotSubmissionAdapterPreservesFrozenRequestAuthority() throws {
        let fixture = try makeVerifiedFixture()
        let projection = try NativeDecompilerSnapshotBuilder.build(
            from: fixture,
            imageSlot: .primary,
            functionID: functionID,
            budgets: budgets
        )

        let submission = try NativeDecompilerSubmission(snapshot: projection)
        let requestID = UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
        let request = submission.projection.makeRequestEnvelope(requestID: requestID).body

        XCTAssertEqual(request.requestID, requestID)
        XCTAssertEqual(request.requestSHA256, submission.projection.requestSHA256)
        XCTAssertEqual(request.image, projection.image)
        XCTAssertEqual(request.function, projection.function)
        XCTAssertEqual(request.memoryRegions, projection.memoryRegions)
        XCTAssertEqual(request.symbols, projection.symbols)
        XCTAssertEqual(request.target, projection.target)
        XCTAssertEqual(request.authoredInputs, projection.authoredInputs)
        XCTAssertEqual(request.budgets, NativeDecompilerProductBudgetProfile.v3.wireValue)
    }

    func testAdmissionFenceExhaustionFailsClosedWithoutWrapping() throws {
        let fence = NativeDecompilerAdmissionFence(generation: .max - 1)

        let terminal = try XCTUnwrap(fence.advance())
        XCTAssertEqual(terminal.generation, .max)
        XCTAssertNil(fence.advance())
        XCTAssertNil(fence.advance(), "an exhausted fence must remain terminal")
        fence.revoke()
        XCTAssertFalse(terminal.isCurrent, "exhausted session retirement must revoke the final token")
    }

    func testBatchCaptureReusesOneImageValidationAndCancelsSynchronously() async throws {
        let workspace = try makeVerifiedFixture()
        let dispatcher = ControllableNativeDecompilerDispatcher()
        let runtime = makeTestNativeDecompilerRuntimeRegistry(
            policy: .enabled, dispatcher: dispatcher
        )
        let lease = try await runtime.beginNativeBatchCapture(
            snapshot: workspace, imageSlot: .primary
        )
        let initialValidationCount = await runtime.validatedImageValidationCountForTesting()
        XCTAssertEqual(initialValidationCount, 1)

        let first = Task {
            try await runtime.decompileNativeBatchFunction(lease: lease, functionID: functionID)
        }
        try await waitUntil { dispatcher.requestCount == 1 }
        dispatcher.completeFirst(with: .success)
        let firstResult = try await first.value
        XCTAssertEqual(firstResult.functionID, functionID)

        let secondResult = try await runtime.decompileNativeBatchFunction(
            lease: lease, functionID: functionID
        )
        XCTAssertEqual(secondResult.functionID, functionID)
        let finalValidationCount = await runtime.validatedImageValidationCountForTesting()
        XCTAssertEqual(finalValidationCount, 1)
        lease.cancel()
        do {
            _ = try await runtime.decompileNativeBatchFunction(
                lease: lease, functionID: functionID
            )
            XCTFail("a cancelled batch lease must reject a new function")
        } catch is CancellationError {
            // The lease closes before asynchronous retirement.
        }
        await runtime.retireNativeBatchCapture(lease)
        await runtime.shutdown()

        let blocking = BlockingNativeDecompilerDispatcher()
        let activeRuntime = makeTestNativeDecompilerRuntimeRegistry(
            policy: .enabled, dispatcher: blocking
        )
        let activeLease = try await activeRuntime.beginNativeBatchCapture(
            snapshot: workspace, imageSlot: .primary
        )
        let inFlight = Task {
            try await activeRuntime.decompileNativeBatchFunction(
                lease: activeLease, functionID: functionID
            )
        }
        try await waitUntil { blocking.dispatchCount == 1 }
        activeLease.cancel()
        try await waitUntil(timeout: .milliseconds(250)) {
            blocking.cancellationCount == 1
        }
        _ = try? await inFlight.value
        await activeRuntime.retireNativeBatchCapture(activeLease)
        await activeRuntime.shutdown()
    }

    func testReconstructionCallerCancellationCancelsItsOwnedRuntimeTask() async throws {
        let workspace = try makeVerifiedFixture()
        let analysis = try XCTUnwrap(workspace.analysis(in: .primary))
        let fingerprint = try XCTUnwrap(analysis.analysisInputFingerprint?.overallSHA256)
        let dispatcher = BlockingNativeDecompilerDispatcher()
        let runtime = makeTestNativeDecompilerRuntimeRegistry(
            policy: .enabled,
            dispatcher: dispatcher
        )
        let admission = try await ReconstructionNativeDecompilerAdmissionFactory(
            runtime: runtime,
            durable: AlwaysActiveReconstructionNativeJobValidator()
        ).admission(forDurableJobID: UUID())
        let request = try NativeDecompilerProjectionRequest(
            workspace: workspace,
            imageSlot: .primary,
            functionID: functionID,
            analysisInputFingerprintSHA256: fingerprint
        )

        let operation = Task {
            try await admission.decompile(request, cacheLookupPolicy: .bypassCacheLookup)
        }
        try await waitUntil { dispatcher.dispatchCount == 1 }
        operation.cancel()
        try await waitUntil(timeout: .milliseconds(250)) {
            dispatcher.cancellationCount == 1
        }
        _ = try? await operation.value
        await admission.retire()
        await runtime.shutdown()
    }

    func testStoreSubmitsExactlyOnceForEachEligibleAcceptedAnalysisLanding() async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-native-runtime-\(UUID().uuidString)")
        try Data(repeating: 0, count: 32).write(to: fixtureURL)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let fixture = try makeVerifiedFixture(path: fixtureURL.path)
        let provider = FixedNativeAnalysisProvider(result: fixture)
        let recorder = RecordingNativeDecompilerLandingHandler()
        let store = WorkspaceStore(
            workspaceName: "native-runtime",
            snapshot: WorkspaceSnapshot(binaries: [], analysisBySlot: [:]),
            engine: provider,
            autosaveScheduler: nil
        )
        store.installNativeDecompilerLandingHandler(recorder)

        await store.importBinary(url: fixtureURL)
        XCTAssertEqual(recorder.acceptedSlots, [.primary])

        await store.loadAdditionalBinary(url: fixtureURL)
        XCTAssertEqual(recorder.acceptedSlots, [.primary, ImageSlot(rawValue: 1)])

        let didReimport = await store.reimportBinary(in: .primary, from: fixtureURL)
        XCTAssertTrue(didReimport)
        XCTAssertEqual(
            recorder.acceptedSlots,
            [.primary, ImageSlot(rawValue: 1)],
            "an accepted landing for a background image must not replace the focused result"
        )

        store.focusImage(.primary)
        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1000)))
        store.withSynchronousReanalysis {
            store.setMarkAsProcedure(0x1000, true)
        }
        XCTAssertEqual(recorder.acceptedSlots, [.primary, ImageSlot(rawValue: 1), .primary])
    }

    func testSelectingAFunctionRequestsItsExactIdentityWithoutResubmittingWithinTheSameFunction() throws {
        var fixture = try makeVerifiedFixture()
        let secondFunctionID = UUID(
            uuidString: "10000000-0000-0000-0000-000000000021"
        )!
        fixture.analysisBySlot[.primary]?.functions.append(
            FunctionSummary(
                id: secondFunctionID,
                name: "second",
                startAddress: 0x1010,
                endAddress: 0x1018,
                confidence: 1
            )
        )
        fixture.analysisBySlot[.primary]?.instructions.append(
            InstructionRow(
                address: 0x1010,
                bytes: "c0 03 5f d6",
                mnemonic: "ret",
                operands: "",
                hasBreakpoint: false,
                comment: nil
            )
        )
        let recorder = RecordingNativeDecompilerLandingHandler()
        let store = WorkspaceStore(
            workspaceName: "native-current-function",
            snapshot: fixture,
            engine: FixedNativeAnalysisProvider(result: fixture),
            autosaveScheduler: nil
        )
        store.installNativeDecompilerLandingHandler(recorder)

        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1000)))
        XCTAssertEqual(recorder.requests, [
            .init(imageSlot: .primary, functionID: functionID),
        ])

        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1004)))
        XCTAssertEqual(
            recorder.requests.count,
            1,
            "moving within one function must not restart native decompilation"
        )

        XCTAssertTrue(store.selectAddress(ImageAddress(slot: .primary, address: 0x1010)))
        XCTAssertEqual(recorder.requests, [
            .init(imageSlot: .primary, functionID: functionID),
            .init(imageSlot: .primary, functionID: secondFunctionID),
        ])
    }

    func testCrossImageNavigationRequestsTheImageQualifiedCurrentFunction() throws {
        var fixture = try makeVerifiedFixture()
        let siblingSlot = ImageSlot(rawValue: 1)
        let primaryBinary = fixture.binaries[0]
        let siblingBinary = BinaryImage(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000022")!,
            name: "sibling",
            path: primaryBinary.path,
            kind: primaryBinary.kind,
            architecture: primaryBinary.architecture,
            selectedSliceIndex: primaryBinary.selectedSliceIndex,
            artifactIdentity: primaryBinary.artifactIdentity,
            preferredSegmentLayout: primaryBinary.preferredSegmentLayout,
            artifactIntegrityState: primaryBinary.artifactIntegrityState,
            slot: siblingSlot
        )
        var siblingAnalysis = try XCTUnwrap(fixture.analysis(in: .primary))
        siblingAnalysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(
            binary: siblingBinary,
            analysis: siblingAnalysis
        )
        fixture.insertImage(binary: siblingBinary, analysis: siblingAnalysis)
        let recorder = RecordingNativeDecompilerLandingHandler()
        let store = WorkspaceStore(
            workspaceName: "native-current-image",
            snapshot: fixture,
            engine: FixedNativeAnalysisProvider(result: fixture),
            autosaveScheduler: nil
        )
        store.installNativeDecompilerLandingHandler(recorder)

        store.navigateCrossImage(to: siblingSlot, address: 0x1000)

        XCTAssertEqual(recorder.requests, [
            .init(imageSlot: .primary, functionID: functionID),
            .init(imageSlot: siblingSlot, functionID: functionID),
        ])
    }

    func testInstallingAWindowSessionOnAPreloadedStoreRequestsItsCurrentFunction() throws {
        let fixture = try makeVerifiedFixture()
        let store = WorkspaceStore(
            workspaceName: "native-preloaded",
            snapshot: fixture,
            engine: FixedNativeAnalysisProvider(result: fixture),
            autosaveScheduler: nil
        )
        let recorder = RecordingNativeDecompilerLandingHandler()

        store.installNativeDecompilerLandingHandler(recorder)

        XCTAssertEqual(recorder.requests, [
            .init(imageSlot: .primary, functionID: functionID),
        ])
    }

    func testRegistryEvictionCancelsOnlyTheEvictedWindowHandle() {
        let provider = RecordingNativeDecompilerSessionProvider()
        let registry = WorkspaceSessionRegistry(nativeDecompilerSessions: provider)
        let firstID = WorkspaceWindowID.fresh()
        let secondID = WorkspaceWindowID.fresh()

        _ = registry.store(for: firstID, launchConfiguration: .init())
        _ = registry.store(for: secondID, launchConfiguration: .init())
        XCTAssertEqual(provider.createdOwners, [firstID, secondID])
        let firstPresentation = registry.nativeDecompilerPresentation(for: firstID)
        XCTAssertTrue(
            firstPresentation === registry.nativeDecompilerPresentation(for: firstID),
            "one window must retain one transient native presentation model"
        )

        registry.evict(firstID)
        XCTAssertEqual(provider.retiredOwners, [firstID])
        XCTAssertEqual(registry.count, 1)
        XCTAssertFalse(
            firstPresentation === registry.nativeDecompilerPresentation(for: firstID),
            "eviction must release the closed window's transient native presentation"
        )
    }

    func testExplicitlyDisabledRuntimeCreatesNoXPCConnectionOrDispatch() async throws {
        let fixture = try makeVerifiedFixture()
        let connectionCounter = LockedInt()
        let client = NativeDecompilerXPCClient(connectionFactory: {
            connectionCounter.increment()
            throw NativeDecompilerXPCClientFailure.connectionUnavailable
        })
        let runtime = makeTestNativeDecompilerRuntimeRegistry(
            policy: .disabled,
            dispatcher: client
        )
        let session = runtime.makeWorkspaceSession(owner: .fresh(), presentation: NativeDecompilerPresentationModel())

        XCTAssertTrue(session is NativeDecompilerDisabledWorkspaceSession)
        session.acceptedAnalysisDidLand(
            snapshot: fixture,
            imageSlot: .primary,
            functionID: functionID
        )
        XCTAssertEqual(connectionCounter.value, 0)
    }

    func testIneligibleLandingSupersedesPriorSameSessionRequest() async throws {
        let fixture = try makeVerifiedFixture()
        var functionless = fixture
        functionless.analysisBySlot[.primary]?.functions = []
        let dispatcher = BlockingNativeDecompilerDispatcher()
        let runtime = makeTestNativeDecompilerRuntimeRegistry(
            policy: NativeDecompilerRuntimePolicy(isEnabled: true),
            dispatcher: dispatcher
        )
        let session = runtime.makeWorkspaceSession(owner: .fresh(), presentation: NativeDecompilerPresentationModel())

        session.acceptedAnalysisDidLand(
            snapshot: fixture,
            imageSlot: .primary,
            functionID: functionID
        )
        try await waitUntil { dispatcher.dispatchCount == 1 }
        session.acceptedAnalysisDidLand(
            snapshot: functionless,
            imageSlot: .primary,
            functionID: functionID
        )
        try await waitUntil { dispatcher.cancellationCount == 1 }

        let observations = await runtime.observationSnapshot()
        XCTAssertTrue(observations.isEmpty)
    }

    func testAcceptedLandingPublishesAnalyzingThenReadyForExactWindowModel() async throws {
        let fixture = try makeVerifiedFixture()
        let dispatcher = ControllableNativeDecompilerDispatcher()
        let telemetry = NativeDecompilerTelemetryRecorder()
        let runtime = makeTestNativeDecompilerRuntimeRegistry(
            policy: .enabled,
            dispatcher: dispatcher,
            telemetry: telemetry
        )
        let presentation = NativeDecompilerPresentationModel()
        let session = runtime.makeWorkspaceSession(
            owner: .fresh(),
            presentation: presentation
        )

        session.acceptedAnalysisDidLand(
            snapshot: fixture,
            imageSlot: .primary,
            functionID: functionID
        )
        try await waitUntil { dispatcher.requestCount == 1 }
        guard case let .analyzing(coordinate) = presentation.state else {
            return XCTFail("accepted landing must publish analyzing before completion")
        }
        XCTAssertEqual(coordinate.imageSlot, .primary)
        XCTAssertEqual(coordinate.ownerBinaryID, binaryID)
        XCTAssertEqual(coordinate.functionID, functionID.uuidString.lowercased())

        dispatcher.completeFirst(with: .success)
        try await waitUntil {
            if case .ready = presentation.state { return true }
            return false
        }
        guard case let .ready(readyCoordinate, success) = presentation.state else {
            return XCTFail("validated native completion must publish ready")
        }
        XCTAssertEqual(readyCoordinate, coordinate)
        XCTAssertEqual(success.result.requestSHA256, coordinate.requestSHA256)
        XCTAssertEqual(success.result.pseudocodeDocument?.language, "c")
        let telemetrySnapshot = await runtime.telemetrySnapshotForTesting()
        XCTAssertEqual(telemetrySnapshot.activeIntervalCount, 0)
        XCTAssertEqual(telemetrySnapshot.records.count, 1)
        XCTAssertEqual(telemetrySnapshot.records[0].interval?.intervalKind, .endToEndAttempt)
        XCTAssertEqual(telemetrySnapshot.records[0].interval?.outcome, .success)
    }

    /// A graph too large to deliver degrades once to `decompile-document`: the pane publishes the
    /// text (structure omitted) instead of an error. Other failures do not retry.
    func testOversizeGraphRetriesOnceAsDocumentOnly() async throws {
        let fixture = try makeVerifiedFixture()
        let dispatcher = ControllableNativeDecompilerDispatcher()
        let runtime = makeTestNativeDecompilerRuntimeRegistry(policy: .enabled, dispatcher: dispatcher)
        let presentation = NativeDecompilerPresentationModel()
        let session = runtime.makeWorkspaceSession(owner: .fresh(), presentation: presentation)
        session.acceptedAnalysisDidLand(snapshot: fixture, imageSlot: .primary, functionID: functionID)
        try await waitUntil { dispatcher.requestCount == 1 }
        XCTAssertEqual(dispatcher.requests.first?.operation, .decompile)
        dispatcher.completeFirst(with: .providerFailure(.responseTooLarge))
        try await waitUntil { dispatcher.requestCount == 2 }
        let documentRequest = try XCTUnwrap(dispatcher.requests.last)
        XCTAssertEqual(documentRequest.operation, .decompileDocument)
        XCTAssertNotEqual(documentRequest.body.requestSHA256, dispatcher.requests.first?.body.requestSHA256)
        guard case let .analyzing(retrying) = presentation.state else { return XCTFail("retry stays analyzing") }
        XCTAssertEqual(retrying.requestSHA256, documentRequest.body.requestSHA256)
        dispatcher.completeFirst(with: .documentSuccess)
        try await waitUntil { if case .ready = presentation.state { return true }; return false }
        guard case let .ready(coordinate, success) = presentation.state else { return XCTFail("document must publish") }
        XCTAssertEqual(coordinate.requestSHA256, documentRequest.body.requestSHA256)
        XCTAssertEqual(success.result.pseudocodeDocument?.text, "void fixture(void) {}\n")
        let projected = NativePseudocodePresentation.project(
            state: presentation.state,
            expected: DecompilerPresentationIdentity(
                imageSlot: coordinate.imageSlot, ownerBinaryID: coordinate.ownerBinaryID,
                artifactUUID: coordinate.artifactUUID, functionID: coordinate.functionID,
                analysisInputFingerprintSHA256: coordinate.analysisInputFingerprintSHA256),
            macScopeIsAvailable: true)
        XCTAssertEqual(projected.status, .ready)
        XCTAssertTrue(projected.structureOmitted)

        // A failure unrelated to output size does not retry.
        let otherDispatcher = ControllableNativeDecompilerDispatcher()
        let other = makeTestNativeDecompilerRuntimeRegistry(policy: .enabled, dispatcher: otherDispatcher)
        let otherPresentation = NativeDecompilerPresentationModel()
        let otherSession = other.makeWorkspaceSession(owner: .fresh(), presentation: otherPresentation)
        otherSession.acceptedAnalysisDidLand(snapshot: fixture, imageSlot: .primary, functionID: functionID)
        try await waitUntil { otherDispatcher.requestCount == 1 }
        otherDispatcher.completeFirst(with: .providerFailure(.nativeFailure))
        try await waitUntil { if case .failed = otherPresentation.state { return true }; return false }
        XCTAssertEqual(otherDispatcher.requestCount, 1)
    }

    func testSemanticInvalidationAndRetirementRemoveReadyPublicationBeforeTaskYield() async throws {
        for terminating in [false, true] {
            let fixture = try makeVerifiedFixture()
            let dispatcher = ControllableNativeDecompilerDispatcher()
            let runtime = makeTestNativeDecompilerRuntimeRegistry(policy: .enabled, dispatcher: dispatcher)
            let presentation = NativeDecompilerPresentationModel()
            let session = runtime.makeWorkspaceSession(owner: .fresh(), presentation: presentation)
            session.acceptedAnalysisDidLand(snapshot: fixture, imageSlot: .primary, functionID: functionID)
            try await waitUntil { dispatcher.requestCount == 1 }
            dispatcher.completeFirst(with: .success)
            try await waitUntil { presentation.readyPublicationIdentity != nil }
            XCTAssertNotNil(presentation.readyPublicationIdentity)

            if terminating {
                session.terminateSession()
            } else {
                // This is the production session operation used synchronously
                // by semanticInputChanged's cancelOutstanding drive effect.
                session.cancelOutstanding()
            }
            // Deliberately no await between mutation and these assertions.
            // Queued runtime invalidation cannot provide this safety boundary.
            XCTAssertNil(presentation.readyPublicationIdentity)
            XCTAssertEqual(presentation.state, .idle)
            await Task.yield()
            XCTAssertNil(presentation.readyPublicationIdentity)
        }
    }

    func testTwoWindowsWithDistinctRequestsRunSeriallyWithoutCrossCancellation() async throws {
        let firstFixture = try makeVerifiedFixture()
        let secondFunctionID = UUID(
            uuidString: "10000000-0000-0000-0000-000000000031"
        )!
        let secondFixture = try makeVerifiedFixture(
            functionID: secondFunctionID,
            binaryID: UUID(uuidString: "20000000-0000-0000-0000-000000000032")!
        )
        let dispatcher = ControllableNativeDecompilerDispatcher()
        let runtime = makeTestNativeDecompilerRuntimeRegistry(policy: .enabled, dispatcher: dispatcher)
        let firstPresentation = NativeDecompilerPresentationModel()
        let secondPresentation = NativeDecompilerPresentationModel()
        let first = runtime.makeWorkspaceSession(
            owner: .fresh(),
            presentation: firstPresentation
        )
        let second = runtime.makeWorkspaceSession(
            owner: .fresh(),
            presentation: secondPresentation
        )

        first.acceptedAnalysisDidLand(
            snapshot: firstFixture,
            imageSlot: .primary,
            functionID: functionID
        )
        try await waitUntil { dispatcher.requestCount == 1 }
        second.acceptedAnalysisDidLand(
            snapshot: secondFixture,
            imageSlot: .primary,
            functionID: secondFunctionID
        )
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(dispatcher.requestCount, 1)
        XCTAssertEqual(dispatcher.cancellationCount, 0)

        dispatcher.completeFirst(with: .success)
        try await waitUntil { dispatcher.requestCount == 2 }
        XCTAssertEqual(dispatcher.cancellationCount, 0)
        dispatcher.completeFirst(with: .success)
        try await waitUntil {
            if case .ready = firstPresentation.state,
               case .ready = secondPresentation.state { return true }
            return false
        }
        XCTAssertEqual(dispatcher.cancellationCount, 0)
    }

    func testTwoWindowsWithIdenticalRequestShareOneDispatchAndPublishIndependently() async throws {
        let fixture = try makeVerifiedFixture()
        let dispatcher = ControllableNativeDecompilerDispatcher()
        let runtime = makeTestNativeDecompilerRuntimeRegistry(policy: .enabled, dispatcher: dispatcher)
        let firstPresentation = NativeDecompilerPresentationModel()
        let secondPresentation = NativeDecompilerPresentationModel()
        let first = runtime.makeWorkspaceSession(
            owner: .fresh(),
            presentation: firstPresentation
        )
        let second = runtime.makeWorkspaceSession(
            owner: .fresh(),
            presentation: secondPresentation
        )

        first.acceptedAnalysisDidLand(
            snapshot: fixture,
            imageSlot: .primary,
            functionID: functionID
        )
        try await waitUntil { dispatcher.requestCount == 1 }
        second.acceptedAnalysisDidLand(
            snapshot: fixture,
            imageSlot: .primary,
            functionID: functionID
        )
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(dispatcher.requestCount, 1)

        dispatcher.completeFirst(with: .success)
        try await waitUntil {
            if case .ready = firstPresentation.state,
               case .ready = secondPresentation.state { return true }
            return false
        }
        XCTAssertEqual(dispatcher.requestCount, 1)
        XCTAssertEqual(dispatcher.cancellationCount, 0)
    }

    func testLaterWindowUsesValidatedSuccessCacheWithoutRedispatch() async throws {
        let fixture = try makeVerifiedFixture()
        let dispatcher = ControllableNativeDecompilerDispatcher()
        let runtime = makeTestNativeDecompilerRuntimeRegistry(policy: .enabled, dispatcher: dispatcher)
        let firstPresentation = NativeDecompilerPresentationModel()
        let first = runtime.makeWorkspaceSession(
            owner: .fresh(),
            presentation: firstPresentation
        )

        first.acceptedAnalysisDidLand(
            snapshot: fixture,
            imageSlot: .primary,
            functionID: functionID
        )
        try await waitUntil { dispatcher.requestCount == 1 }
        dispatcher.completeFirst(with: .success)
        try await waitUntil {
            if case .ready = firstPresentation.state { return true }
            return false
        }

        let cachedPresentation = NativeDecompilerPresentationModel()
        let cached = runtime.makeWorkspaceSession(
            owner: .fresh(),
            presentation: cachedPresentation
        )
        cached.acceptedAnalysisDidLand(
            snapshot: fixture,
            imageSlot: .primary,
            functionID: functionID
        )
        try await waitUntil {
            if case .ready = cachedPresentation.state { return true }
            return false
        }

        XCTAssertEqual(dispatcher.requestCount, 1)
        XCTAssertEqual(dispatcher.cancellationCount, 0)
    }

    func testMemoryPressureClearsCacheWithoutMasqueradingAsLifecycleReplacement() async throws {
        let fixture = try makeVerifiedFixture()
        let dispatcher = ControllableNativeDecompilerDispatcher()
        let runtime = makeTestNativeDecompilerRuntimeRegistry(policy: .enabled, dispatcher: dispatcher)
        let firstPresentation = NativeDecompilerPresentationModel()
        let first = runtime.makeWorkspaceSession(
            owner: .fresh(),
            presentation: firstPresentation
        )

        first.acceptedAnalysisDidLand(
            snapshot: fixture,
            imageSlot: .primary,
            functionID: functionID
        )
        try await waitUntil { dispatcher.requestCount == 1 }
        dispatcher.completeFirst(with: .success)
        try await waitUntil {
            if case .ready = firstPresentation.state { return true }
            return false
        }
        let beforePressure = await runtime.processRuntimeSnapshotForTesting()
        XCTAssertEqual(beforePressure.epoch, 1)
        XCTAssertEqual(beforePressure.validatedCacheEntryCount, 1)
        XCTAssertGreaterThan(beforePressure.validatedCacheByteCount, 0)

        await runtime.memoryPressureDidOccur(.critical)

        let afterPressure = await runtime.processRuntimeSnapshotForTesting()
        XCTAssertEqual(afterPressure.epoch, 1)
        XCTAssertEqual(afterPressure.validatedCacheEntryCount, 0)
        XCTAssertEqual(afterPressure.validatedCacheByteCount, 0)

        let successorPresentation = NativeDecompilerPresentationModel()
        let successor = runtime.makeWorkspaceSession(
            owner: .fresh(),
            presentation: successorPresentation
        )
        successor.acceptedAnalysisDidLand(
            snapshot: fixture,
            imageSlot: .primary,
            functionID: functionID
        )
        try await waitUntil { dispatcher.requestCount == 2 }
        dispatcher.completeFirst(with: .success)
        try await waitUntil {
            if case .ready = successorPresentation.state { return true }
            return false
        }

        XCTAssertEqual(dispatcher.requestCount, 2)
    }

    func testWholeWorkspaceRestoreInvalidatesWithoutSubmittingRestoredState() async throws {
        let fixture = try makeVerifiedFixture()
        let dispatcher = BlockingNativeDecompilerDispatcher()
        let runtime = makeTestNativeDecompilerRuntimeRegistry(
            policy: NativeDecompilerRuntimePolicy(isEnabled: true),
            dispatcher: dispatcher
        )
        let store = WorkspaceStore(
            workspaceName: "restore-native-runtime",
            snapshot: fixture,
            engine: FixedNativeAnalysisProvider(result: fixture),
            autosaveScheduler: nil
        )
        let session = runtime.makeWorkspaceSession(owner: .fresh(), presentation: NativeDecompilerPresentationModel())
        store.installNativeDecompilerLandingHandler(session)
        try await waitUntil { dispatcher.dispatchCount == 1 }

        store.restoreWorkspace(makePersistedWorkspace(snapshot: fixture))
        try await waitUntil { dispatcher.cancellationCount == 1 }

        XCTAssertEqual(dispatcher.dispatchCount, 1)
        let observations = await runtime.observationSnapshot()
        XCTAssertTrue(observations.isEmpty)
    }

    func testProjectionFailurePublishesExactTypedUnavailableReasonWithoutDispatch() async throws {
        var fixture = try makeVerifiedFixture()
        fixture.binaries[0].artifactIdentity = nil
        let dispatcher = BlockingNativeDecompilerDispatcher()
        let telemetry = NativeDecompilerTelemetryRecorder()
        let runtime = makeTestNativeDecompilerRuntimeRegistry(
            policy: .enabled,
            dispatcher: dispatcher,
            telemetry: telemetry
        )
        let presentation = NativeDecompilerPresentationModel()
        let session = runtime.makeWorkspaceSession(
            owner: .fresh(),
            presentation: presentation
        )

        session.acceptedAnalysisDidLand(
            snapshot: fixture,
            imageSlot: .primary,
            functionID: functionID
        )
        try await waitUntil {
            presentation.state == .unavailable(
                coordinate: nil,
                reason: .projection(.missingArtifactIdentity)
            )
        }

        XCTAssertEqual(dispatcher.dispatchCount, 0)
        let telemetrySnapshot = await runtime.telemetrySnapshotForTesting()
        XCTAssertEqual(telemetrySnapshot.activeIntervalCount, 0)
        XCTAssertEqual(telemetrySnapshot.records.count, 1)
        XCTAssertEqual(telemetrySnapshot.records[0].interval?.outcome, .rejected)
    }

    func testOlderLandingArrivingAfterNewerGenerationIsRejected() async throws {
        let fixture = try makeVerifiedFixture()
        let admission = NativeRuntimeSubmissionAdmissionGate()
        let dispatcher = BlockingNativeDecompilerDispatcher()
        let runtime = makeTestNativeDecompilerRuntimeRegistry(
            policy: NativeDecompilerRuntimePolicy(isEnabled: true),
            dispatcher: dispatcher,
            submissionAdmission: { generation in
                await admission.admit(generation: generation)
            }
        )
        let session = runtime.makeWorkspaceSession(owner: .fresh(), presentation: NativeDecompilerPresentationModel())

        session.acceptedAnalysisDidLand(
            snapshot: fixture,
            imageSlot: .primary,
            functionID: functionID
        )
        await admission.waitUntilFirstGenerationIsBlocked()
        session.acceptedAnalysisDidLand(
            snapshot: fixture,
            imageSlot: .primary,
            functionID: functionID
        )
        try await waitUntil { dispatcher.dispatchCount == 1 }
        await admission.releaseFirstGeneration()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(dispatcher.dispatchCount, 1)
    }

    func testCancelledOlderLandingCannotReadmitAfterNewerCoordinatorAdmission() async throws {
        let obsoleteFixture = try makeVerifiedFixture()
        let currentFunctionID = UUID(
            uuidString: "10000000-0000-0000-0000-000000000013"
        )!
        let currentFixture = try makeVerifiedFixture(
            functionID: currentFunctionID,
            binaryID: UUID(uuidString: "20000000-0000-0000-0000-000000000014")!
        )
        let admission = NativeRuntimeCoordinatorAdmissionGate()
        let dispatcher = ControllableNativeDecompilerDispatcher()
        let runtime = makeTestNativeDecompilerRuntimeRegistry(
            policy: NativeDecompilerRuntimePolicy(isEnabled: true),
            dispatcher: dispatcher,
            coordinatorAdmission: { generation in
                await admission.admit(generation: generation)
            }
        )
        let session = runtime.makeWorkspaceSession(owner: .fresh(), presentation: NativeDecompilerPresentationModel())

        session.acceptedAnalysisDidLand(
            snapshot: obsoleteFixture,
            imageSlot: .primary,
            functionID: functionID
        )
        await admission.waitUntilFirstGenerationIsBlocked()
        session.acceptedAnalysisDidLand(
            snapshot: currentFixture,
            imageSlot: .primary,
            functionID: currentFunctionID
        )
        try await waitUntil { dispatcher.requestCount == 1 }
        XCTAssertEqual(
            dispatcher.requests.first?.body.function.functionID,
            currentFunctionID.uuidString.lowercased()
        )

        await admission.releaseFirstGeneration()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            dispatcher.requestCount,
            1,
            "a cancelled older landing must fail coordinator admission after its replacement"
        )
        XCTAssertEqual(
            dispatcher.requests.first?.body.function.functionID,
            currentFunctionID.uuidString.lowercased()
        )
    }

    func testCancellingInactiveWindowDoesNotCancelActiveWindow() async throws {
        let fixture = try makeVerifiedFixture()
        let dispatcher = BlockingNativeDecompilerDispatcher()
        let runtime = makeTestNativeDecompilerRuntimeRegistry(
            policy: NativeDecompilerRuntimePolicy(isEnabled: true),
            dispatcher: dispatcher
        )
        let active = runtime.makeWorkspaceSession(owner: .fresh(), presentation: NativeDecompilerPresentationModel())
        let inactive = runtime.makeWorkspaceSession(owner: .fresh(), presentation: NativeDecompilerPresentationModel())

        active.acceptedAnalysisDidLand(
            snapshot: fixture,
            imageSlot: .primary,
            functionID: functionID
        )
        try await waitUntil { dispatcher.dispatchCount == 1 }
        inactive.cancel()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(dispatcher.cancellationCount, 0)
        active.cancel()
        try await waitUntil { dispatcher.cancellationCount == 1 }
        try await waitUntilAsync {
            await runtime.activeSessionOwnerCountForTesting() == 0
        }
    }

    func testProjectionWeightChargesEveryRetainedImageByteAndMetadata() throws {
        var fixture = try makeVerifiedFixture()
        let secondaryBytes = Data(repeating: 0xa5, count: 2 * 1_048_576)
        fixture.analysisBySlot[ImageSlot(rawValue: 1)] = ImageAnalysis(
            functions: [FunctionSummary(
                id: UUID(),
                name: "secondary",
                startAddress: 0x2000,
                endAddress: 0x2004,
                confidence: 1
            )],
            imageBytes: secondaryBytes
        )

        let charged = NativeDecompilerRuntimeRegistry.retainedProjectionWeight(for: fixture)
        let rawBytes = UInt64(
            fixture.analysisBySlot.values.reduce(0) { $0 + $1.imageBytes.count }
        )

        XCTAssertGreaterThan(charged, rawBytes)
        XCTAssertGreaterThan(
            charged,
            UInt64(NativeDecompilerRuntimeRegistry.productBudgets.maxCodeBytes)
        )
    }

    func testLateCancelFromReplacedSameWindowSessionCannotCancelNewGeneration() async throws {
        let fixture = try makeVerifiedFixture()
        let dispatcher = BlockingNativeDecompilerDispatcher()
        let runtime = makeTestNativeDecompilerRuntimeRegistry(
            policy: NativeDecompilerRuntimePolicy(isEnabled: true),
            dispatcher: dispatcher
        )
        let windowID = WorkspaceWindowID.fresh()
        let displaced = runtime.makeWorkspaceSession(owner: windowID, presentation: NativeDecompilerPresentationModel())
        let replacement = runtime.makeWorkspaceSession(owner: windowID, presentation: NativeDecompilerPresentationModel())

        displaced.acceptedAnalysisDidLand(
            snapshot: fixture,
            imageSlot: .primary,
            functionID: functionID
        )
        try await waitUntil { dispatcher.dispatchCount == 1 }

        replacement.acceptedAnalysisDidLand(
            snapshot: fixture,
            imageSlot: .primary,
            functionID: functionID
        )
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(dispatcher.dispatchCount, 1)
        XCTAssertEqual(dispatcher.cancellationCount, 0)

        displaced.cancel()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            dispatcher.cancellationCount,
            0,
            "a displaced session's late cancel must remove only its shared waiter"
        )

        replacement.cancel()
        try await waitUntil { dispatcher.cancellationCount == 1 }
    }

    func testSuccessfulNativeCompletionCannotChangeStoreAuthorityOrPersistence() async throws {
        try await assertNativeCompletionPreservesStoreAuthority(outcome: .success)
    }

    func testProviderFailureCannotChangeStoreAuthorityOrPersistence() async throws {
        try await assertNativeCompletionPreservesStoreAuthority(
            outcome: .providerFailure(.nativeFailure)
        )
    }

    func testProviderUnavailablePublishesExactReasonWithoutChangingAuthority() async throws {
        try await assertNativeCompletionPreservesStoreAuthority(
            outcome: .providerFailure(.unavailable)
        )
    }

    func testReorderedCrossOwnerAdmissionAndLateCancellationPreserveReplacement() async throws {
        let displacedFixture = try makeVerifiedFixture()
        let replacementFunctionID = UUID(
            uuidString: "10000000-0000-0000-0000-000000000011"
        )!
        let replacementFixture = try makeVerifiedFixture(
            functionID: replacementFunctionID,
            binaryID: UUID(uuidString: "20000000-0000-0000-0000-000000000012")!
        )
        let admission = ReorderedNativeSubmissionAdmissionGate()
        let dispatcher = ControllableNativeDecompilerDispatcher()
        let runtime = makeTestNativeDecompilerRuntimeRegistry(
            policy: NativeDecompilerRuntimePolicy(isEnabled: true),
            dispatcher: dispatcher,
            submissionAdmission: { _ in await admission.admit() }
        )
        let displaced = runtime.makeWorkspaceSession(owner: .fresh(), presentation: NativeDecompilerPresentationModel())
        let replacement = runtime.makeWorkspaceSession(owner: .fresh(), presentation: NativeDecompilerPresentationModel())

        displaced.acceptedAnalysisDidLand(
            snapshot: displacedFixture,
            imageSlot: .primary,
            functionID: functionID
        )
        try await waitUntilAsync { await admission.entryCount == 1 }
        replacement.acceptedAnalysisDidLand(
            snapshot: replacementFixture,
            imageSlot: .primary,
            functionID: replacementFunctionID
        )
        try await waitUntilAsync { await admission.entryCount == 2 }

        await admission.release(entry: 2)
        try await waitUntil { dispatcher.requestCount == 1 }
        XCTAssertEqual(
            dispatcher.requests.first?.body.function.functionID,
            replacementFunctionID.uuidString.lowercased()
        )

        displaced.cancel()
        await admission.release(entry: 1)
        try await waitUntilAsync { await admission.returnCount == 2 }
        _ = await runtime.observationSnapshot()
        XCTAssertEqual(dispatcher.requestCount, 1)
        XCTAssertEqual(
            dispatcher.cancellationCount,
            0,
            "a displaced owner's late invalidation must not cancel the admitted replacement"
        )

        dispatcher.completeFirst(with: .success)
        try await waitUntilAsync { await runtime.observationSnapshot().count == 1 }

        let observations = await runtime.observationSnapshot()
        let observation = try XCTUnwrap(observations.first)
        XCTAssertEqual(observation.status, .success)
        XCTAssertEqual(
            observation.function.functionID,
            replacementFunctionID.uuidString.lowercased()
        )
        XCTAssertEqual(observation.requestID, dispatcher.requests.first?.requestID)
        XCTAssertEqual(dispatcher.requestCount, 1)
        XCTAssertEqual(dispatcher.cancellationCount, 0)
    }

    func testSameSessionBindingIsIdempotentAndReplacementFencesLatePublication() async throws {
        let registry = try source("App/NativeDecompilerRuntimeRegistry.swift")
        XCTAssertTrue(registry.contains("windowID"))
        XCTAssertTrue(registry.contains("admissionFence.advance()"))
        XCTAssertFalse(registry.contains("NativeDecompilerLandingHandling"))
    }

    func testCancelOutstandingKeepsSessionReusableAndTerminateRetiresIt() async throws {
        try assertRegistry(["func cancelOutstanding()", "func terminateSession()", "await runtime.retire("])
        let file = try source("App/NativeDecompilerRuntimeRegistry.swift")
        // The registry session itself exposes no unscoped cancel(); the #588 batch
        // capture lease types legitimately cancel their own lease.
        let start = try XCTUnwrap(file.range(of: "actor NativeDecompilerRuntimeRegistry"))
        let rest = file[start.upperBound...]
        let end = rest.range(of: "\n@MainActor\nfinal class ")?.lowerBound ?? rest.endIndex
        let registry = rest[..<end]
        XCTAssertFalse(registry.contains("func cancel()"))
        XCTAssertTrue(file.contains("struct NativeDecompilerBatchCaptureLease"))
    }

    private let functionID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    private let binaryID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!

    private var budgets: NativeDecompilerWireAnalysisBudgets {
        NativeDecompilerWireAnalysisBudgets(
            maxCodeBytes: 1_048_576,
            maxInstructions: 65_536,
            maxOperations: 262_144,
            maxOutputBytes: 1_048_576,
            maxWallTimeMilliseconds: .init(5_000)
        )
    }

    private func assertNativeCompletionPreservesStoreAuthority(
        outcome: ControllableNativeDecompilerDispatcher.Outcome
    ) async throws {
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacScope-native-authority-\(UUID().uuidString)")
        try Data(repeating: 0, count: 32).write(to: fixtureURL)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let fixture = try makeVerifiedFixture(path: fixtureURL.path)
        let provider = FixedNativeAnalysisProvider(result: fixture)
        let dispatcher = ControllableNativeDecompilerDispatcher()
        let runtime = makeTestNativeDecompilerRuntimeRegistry(
            policy: NativeDecompilerRuntimePolicy(isEnabled: true),
            dispatcher: dispatcher
        )
        let nativePresentation = NativeDecompilerPresentationModel()
        let autosave = ManualAutosaveTrigger()
        let store = WorkspaceStore(
            workspaceName: "native-authority",
            snapshot: WorkspaceSnapshot(binaries: [], analysisBySlot: [:]),
            engine: provider,
            autosaveScheduler: autosave
        )
        store.installNativeDecompilerLandingHandler(
            runtime.makeWorkspaceSession(
                owner: .fresh(),
                presentation: nativePresentation
            )
        )

        await store.importBinary(url: fixtureURL)
        try await waitUntil { dispatcher.requestCount == 1 }
        XCTAssertEqual(provider.callCount, 1, "the authoritative landing must occur exactly once")

        store.selectedAddress = 0x1004
        store.selectedSidebarItemID = "function:\(functionID.uuidString)"
        store.selectedGraphElementID = "block:authoritative"
        store.selectedTool = .xrefs
        store.editorMode = .pseudocode
        store.isInspectorPresented = false
        store.sidebarSearchText = "entry"
        store.setCustomName(0x1000, name: "authoritative-entry")
        store.beginRenameAtSelection()
        try await waitUntil { dispatcher.requestCount == 2 }

        let database = try WorkspaceDatabase.inMemory()
        try database.applySchema()
        let saveDate = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try store.saveWorkspace(to: database, now: saveDate)

        let authoritativeBefore = StoreAuthoritativeCheckpoint(store: store)
        let persistableBefore = StorePersistableCheckpoint(snapshot: store.snapshot)
        let renderInputBefore = store.focusedPseudocodeRenderInput
        let presentationBefore = StorePresentationCheckpoint(store: store)
        let dirtyBefore = StoreDirtyCheckpoint(store: store, autosave: autosave)
        let providerCallCountBefore = provider.callCount
        let databaseBefore = try StoreDatabaseCheckpoint(database: database)

        XCTAssertEqual(authoritativeBefore.imageBytesBySlot[.primary]?.count, 32)
        XCTAssertEqual(authoritativeBefore.analysisBySlot[.primary]?.instructions.count, 2)
        XCTAssertTrue(dirtyBefore.isDirty)
        XCTAssertTrue(dirtyBefore.autosavePending)

        dispatcher.completeFirst(with: outcome)
        dispatcher.completeFirst(with: outcome)
        try await waitUntilAsync { await runtime.observationSnapshot().count == 1 }

        let expectedStatus: NativeDecompilerTerminalStatus = switch outcome {
        case .success, .documentSuccess:
            .success
        case let .providerFailure(code):
            .providerFailure(code)
        }
        let observations = await runtime.observationSnapshot()
        XCTAssertEqual(observations.first?.status, expectedStatus)
        try await waitUntil {
            switch (outcome, nativePresentation.state) {
            case (.success, .ready):
                true
            case let (.providerFailure(expected), .unavailable(_, .provider(actual, _))),
                 let (.providerFailure(expected), .failed(_, .provider(actual, _))):
                expected == actual
            default:
                false
            }
        }

        XCTAssertEqual(StoreAuthoritativeCheckpoint(store: store), authoritativeBefore)
        XCTAssertEqual(StorePersistableCheckpoint(snapshot: store.snapshot), persistableBefore)
        XCTAssertEqual(store.focusedPseudocodeRenderInput, renderInputBefore)
        XCTAssertEqual(StorePresentationCheckpoint(store: store), presentationBefore)
        XCTAssertEqual(StoreDirtyCheckpoint(store: store, autosave: autosave), dirtyBefore)
        XCTAssertEqual(provider.callCount, providerCallCountBefore)

        _ = try store.saveWorkspace(to: database, now: saveDate)
        XCTAssertEqual(try StoreDatabaseCheckpoint(database: database), databaseBefore)
    }

    private func makeVerifiedFixture(
        path: String = "/not-opened-by-native-runtime",
        functionID: UUID? = nil,
        binaryID: UUID? = nil
    ) throws -> WorkspaceSnapshot {
        let functionID = functionID ?? self.functionID
        let binaryID = binaryID ?? self.binaryID
        let bytes = Data((0 ..< 32).map { UInt8($0) })
        let artifact = try MachOSliceArtifactIdentity(
            uuid: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0,
            selectedSliceSHA256: AnalysisFingerprintBuilder.sha256Hex(bytes),
            selectedSliceByteCount: UInt64(bytes.count)
        )
        let layout = try MachOPreferredSegmentLayout(
            records: [
                .init(
                    name: "__TEXT",
                    preferredVMStart: 0x1000,
                    preferredVMSize: UInt64(bytes.count),
                    sliceRelativeFileOffset: 0,
                    fileSize: UInt64(bytes.count),
                    initialProtections: 5
                ),
            ],
            selectedSliceByteCount: UInt64(bytes.count)
        )
        let binary = BinaryImage(
            id: binaryID,
            name: "fixture",
            path: path,
            kind: "Mach-O 64-bit",
            architecture: "arm64",
            artifactIdentity: artifact,
            preferredSegmentLayout: layout,
            artifactIntegrityState: .verified,
            slot: .primary
        )
        var analysis = ImageAnalysis(
            functions: [
                FunctionSummary(
                    id: functionID,
                    name: "entry",
                    startAddress: 0x1000,
                    endAddress: 0x1008,
                    confidence: 1
                ),
            ],
            basicBlocks: [
                BasicBlockSummary(
                    id: UUID(),
                    functionID: functionID,
                    startAddress: 0x1000,
                    endAddress: 0x1008,
                    instructionCount: 2
                ),
            ],
            instructions: [
                InstructionRow(
                    address: 0x1000,
                    bytes: "1f 20 03 d5",
                    mnemonic: "nop",
                    operands: "",
                    hasBreakpoint: false,
                    comment: nil
                ),
                InstructionRow(
                    address: 0x1004,
                    bytes: "c0 03 5f d6",
                    mnemonic: "ret",
                    operands: "",
                    hasBreakpoint: false,
                    comment: nil
                ),
            ],
            sections: [
                SectionSummary(
                    id: UUID(uuidString: "50000000-0000-0000-0000-000000000005")!,
                    name: "__TEXT,__text",
                    address: 0x1000,
                    size: UInt64(bytes.count),
                    fileOffset: 0,
                    isExecutable: true
                ),
            ],
            identityEffectiveByteRanges: [try IdentityEffectiveByteRangeAttestation(
                artifactIdentity: artifact,
                segmentName: "__TEXT",
                startAddress: 0x1000,
                endAddressExclusive: 0x1000 + UInt64(bytes.count),
                sliceRelativeFileOffset: 0,
                byteCount: UInt64(bytes.count),
                initialProtections: 5,
                rawBytesSHA256: AnalysisFingerprintBuilder.sha256Hex(bytes)
            )],
            imageBytes: bytes
        )
        analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(
            binary: binary,
            analysis: analysis
        )
        return WorkspaceSnapshot(binaries: [binary], analysisBySlot: [.primary: analysis])
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ predicate: @escaping @MainActor @Sendable () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate() {
            guard clock.now < deadline else {
                throw NativeRuntimeTestFailure.timedOutWaitingForSynchronousState
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func assertRegistry(
        _ required: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let registry = try source("App/NativeDecompilerRuntimeRegistry.swift")
        for token in required {
            XCTAssertTrue(registry.contains(token), "Missing Task 10 token: \(token)", file: file, line: line)
        }
    }

    private func source(_ relativePath: String) throws -> String {
        let tests = TestSourceRoot.fileURL(#filePath).deletingLastPathComponent()
        let root = tests.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func waitUntilAsync(
        timeout: Duration = .seconds(2),
        _ predicate: @escaping @MainActor @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await predicate()) {
            guard clock.now < deadline else {
                throw NativeRuntimeTestFailure.timedOutWaitingForAsynchronousState
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makePersistedWorkspace(
        snapshot: WorkspaceSnapshot
    ) -> WorkspaceDatabase.PersistedWorkspace {
        WorkspaceDatabase.PersistedWorkspace(
            workspace: .init(
                id: 1,
                uuid: UUID(),
                name: "restored",
                createdAt: Date(timeIntervalSince1970: 1),
                modifiedAt: Date(timeIntervalSince1970: 2)
            ),
            snapshot: snapshot,
            session: .init(
                workspaceID: 1,
                selectedSidebarItemID: nil,
                selectedAddress: nil,
                selectedTool: .project,
                editorMode: .disassembly,
                isInspectorPresented: true,
                sidebarSearchText: "",
                updatedAt: Date(timeIntervalSince1970: 2),
                focusedImageSlot: .primary
            )
        )
    }
}

private enum NativeRuntimeTestFailure: Error {
    case timedOutWaitingForSynchronousState
    case timedOutWaitingForAsynchronousState
}

private struct StoreAuthoritativeCheckpoint: Equatable {
    let binaries: [BinaryImage]
    let analysisBySlot: [ImageSlot: WorkspacePackageAnalysis]
    let identityEffectiveByteRangesBySlot: [ImageSlot: [IdentityEffectiveByteRangeAttestation]]
    let imageBytesBySlot: [ImageSlot: Data]
    let hexBytesBySlot: [ImageSlot: Data]
    let crossImageXRefs: [CrossImageXRef]

    @MainActor
    init(store: WorkspaceStore) {
        let snapshot = store.snapshot
        binaries = snapshot.binaries
        analysisBySlot = snapshot.analysisBySlot.mapValues {
            normalizedImageAnalysisCheckpoint($0, snapshot: snapshot)
        }
        identityEffectiveByteRangesBySlot = snapshot.analysisBySlot.mapValues(
            \.identityEffectiveByteRanges
        )
        imageBytesBySlot = snapshot.analysisBySlot.mapValues(\.imageBytes)
        hexBytesBySlot = snapshot.analysisBySlot.mapValues(\.hexBytes)
        crossImageXRefs = snapshot.crossImageXrefs
    }
}

private struct StorePersistableCheckpoint: Equatable {
    let binaries: [BinaryImage]
    let analysisBySlot: [ImageSlot: WorkspacePackageAnalysis]
    let authoring: WorkspacePackageAnalysis

    init(snapshot: WorkspaceSnapshot) {
        binaries = snapshot.binaries
        analysisBySlot = snapshot.analysisBySlot.mapValues {
            normalizedImageAnalysisCheckpoint($0, snapshot: snapshot)
        }
        authoring = WorkspacePackageAnalysis(authoringFrom: snapshot)
    }
}

private func normalizedImageAnalysisCheckpoint(
    _ imageAnalysis: ImageAnalysis,
    snapshot: WorkspaceSnapshot
) -> WorkspacePackageAnalysis {
    var checkpoint = WorkspacePackageAnalysis(imageAnalysis: imageAnalysis)
    checkpoint.logicalBreakpointCatalog = snapshot.logicalBreakpointCatalog.isPristine
        ? .freshPristine(catalogID: StoreCheckpointIdentity.pristineLogicalBreakpointCatalogID)
        : snapshot.logicalBreakpointCatalog
    checkpoint.launchProfileCatalog = snapshot.launchProfileCatalog.isPristine
        ? .freshPristine(catalogID: StoreCheckpointIdentity.pristineLaunchProfileCatalogID)
        : snapshot.launchProfileCatalog
    return checkpoint
}

private enum StoreCheckpointIdentity {
    static let pristineLogicalBreakpointCatalogID = UUID(
        uuidString: "60000000-0000-0000-0000-000000000006"
    )!
    static let pristineLaunchProfileCatalogID = UUID(
        uuidString: "70000000-0000-0000-0000-000000000007"
    )!
}

private struct StorePresentationCheckpoint: Equatable {
    let selectedSidebarItemID: String?
    let selectedImageAddress: ImageAddress?
    let selectedGraphElementID: String?
    let selectedTool: String
    let editorMode: String
    let isInspectorPresented: Bool
    let sidebarSearchText: String
    let focusedImageSlot: ImageSlot
    let overrideEditorRequest: OverrideEditorRequest?
    let signatureEditorRequest: SignatureEditorRequest?
    let typeEditorRequest: TypeEditorRequest?
    let switchHintEditorRequest: SwitchHintEditorRequest?

    @MainActor
    init(store: WorkspaceStore) {
        selectedSidebarItemID = store.selectedSidebarItemID
        selectedImageAddress = store.selectedImageAddress
        selectedGraphElementID = store.selectedGraphElementID
        selectedTool = store.selectedTool.rawValue
        editorMode = store.editorMode.rawValue
        isInspectorPresented = store.isInspectorPresented
        sidebarSearchText = store.sidebarSearchText
        focusedImageSlot = store.focusedImageSlot
        overrideEditorRequest = store.overrideEditorRequest
        signatureEditorRequest = store.signatureEditorRequest
        typeEditorRequest = store.typeEditorRequest
        switchHintEditorRequest = store.switchHintEditorRequest
    }
}

private struct StoreDirtyCheckpoint: Equatable {
    let isDirty: Bool
    let autosaveDecision: AutosaveDecision
    let autosavePending: Bool
    let autosaveScheduleCount: Int

    @MainActor
    init(store: WorkspaceStore, autosave: ManualAutosaveTrigger) {
        isDirty = store.isDirty
        autosaveDecision = store.autosaveDecision
        autosavePending = autosave.isPending
        autosaveScheduleCount = autosave.scheduleCount
    }
}

private struct StoreDatabaseCheckpoint: Equatable {
    let userVersion: Int
    let tableNames: [String]
    let workspace: WorkspaceDatabase.WorkspaceRecord
    let session: WorkspaceDatabase.WorkspaceSessionRecord
    let persistable: StorePersistableCheckpoint
    let phase2ShellSession: WorkspaceDatabase.Phase2ShellSessionPersistenceRecord?
    let assistantSessions: [WorkspaceDatabase.Phase2AssistantSessionPersistenceRecord]
    let runtimeAuthorities: [WorkspaceDatabase.Phase2RuntimeAuthorityPersistenceRecord]

    init(database: WorkspaceDatabase) throws {
        let workspace = try XCTUnwrap(database.workspaces().first)
        let workspaceID = try XCTUnwrap(workspace.id)
        let persisted = try XCTUnwrap(database.loadWorkspaceState(workspaceID: workspaceID))

        userVersion = try database.userVersion()
        tableNames = try database.tableNames().sorted()
        self.workspace = persisted.workspace
        session = persisted.session
        persistable = StorePersistableCheckpoint(snapshot: persisted.snapshot)
        phase2ShellSession = persisted.phase2ShellSessionRecord
        assistantSessions = persisted.assistantSessionRecords
        runtimeAuthorities = persisted.runtimeAuthorityRecords
    }
}

private final class RecordingNativeDecompilerLandingHandler:
    NativeDecompilerWorkspaceSessionHandling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedRequests: [RecordedNativeDecompilerRequest] = []
    private var storedCancellationCount = 0
    private var storedTerminationCount = 0

    var acceptedSlots: [ImageSlot] { lock.withLock { storedRequests.map(\.imageSlot) } }
    var requests: [RecordedNativeDecompilerRequest] { lock.withLock { storedRequests } }
    var cancellationCount: Int { lock.withLock { storedCancellationCount } }
    var terminationCount: Int { lock.withLock { storedTerminationCount } }

    func submit(_ submission: NativeDecompilerWorkspaceSubmission) {
        lock.withLock {
            storedRequests.append(
                .init(imageSlot: submission.imageSlot, functionID: submission.functionID)
            )
        }
    }

    func retry(_ retry: NativeDecompilerWorkspaceRetry) {
        lock.withLock {
            storedRequests.append(.init(imageSlot: retry.imageSlot, functionID: retry.functionID))
        }
    }

    func publishAuthoredProjectionFailure(
        _ diagnostic: NativeAuthoredProjectionDiagnostic,
        ticket: NativeDriveSubmissionTicket
    ) {
        _ = diagnostic
        _ = ticket
    }

    func cancelOutstanding() {
        lock.withLock { storedCancellationCount += 1 }
    }

    func terminateSession() {
        lock.withLock { storedTerminationCount += 1 }
    }
}

private struct RecordedNativeDecompilerRequest: Equatable {
    let imageSlot: ImageSlot
    let functionID: UUID
}

private actor NativeRuntimeSubmissionAdmissionGate {
    private var firstGenerationContinuation: CheckedContinuation<Void, Never>?
    private var firstGenerationDidBlock = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func admit(generation: UInt64) async {
        guard generation == 1 else { return }
        firstGenerationDidBlock = true
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            firstGenerationContinuation = continuation
        }
    }

    func waitUntilFirstGenerationIsBlocked() async {
        guard !firstGenerationDidBlock else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func releaseFirstGeneration() {
        firstGenerationContinuation?.resume()
        firstGenerationContinuation = nil
    }
}

private actor NativeRuntimeCoordinatorAdmissionGate {
    private var firstGenerationContinuation: CheckedContinuation<Void, Never>?
    private var firstGenerationDidBlock = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func admit(generation: UInt64) async {
        guard generation == 1 else { return }
        firstGenerationDidBlock = true
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            firstGenerationContinuation = continuation
        }
    }

    func waitUntilFirstGenerationIsBlocked() async {
        guard !firstGenerationDidBlock else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func releaseFirstGeneration() {
        firstGenerationContinuation?.resume()
        firstGenerationContinuation = nil
    }
}

@MainActor
private final class RecordingNativeDecompilerSessionProvider:
    NativeDecompilerSessionProviding,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var owners: [WorkspaceWindowID] = []
    private var handlers: [WorkspaceWindowID: RecordingNativeDecompilerLandingHandler] = [:]

    var createdOwners: [WorkspaceWindowID] { lock.withLock { owners } }
    var retiredOwners: [WorkspaceWindowID] {
        lock.withLock {
            owners.filter { handlers[$0]?.terminationCount == 1 }
        }
    }

    @MainActor
    func makeWorkspaceSession(
        windowID: WorkspaceWindowID,
        presentation: NativeDecompilerPresentationModel
    ) -> any NativeDecompilerWorkspaceSessionHandling {
        _ = presentation
        return lock.withLock {
            let handler = RecordingNativeDecompilerLandingHandler()
            owners.append(windowID)
            handlers[windowID] = handler
            return handler
        }
    }
}

private final class FixedNativeAnalysisProvider: AnalysisProviding, @unchecked Sendable {
    private let result: WorkspaceSnapshot
    private let calls = LockedInt()

    var callCount: Int { calls.value }

    init(result: WorkspaceSnapshot) {
        self.result = result
    }

    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        calls.increment()
        return result
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        calls.increment()
        return result
    }
}

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int { lock.withLock { storedValue } }

    func increment() {
        lock.withLock { storedValue += 1 }
    }
}

private final class BlockingNativeDecompilerDispatcher:
    NativeDecompilerDispatching,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storedDispatchCount = 0
    private var storedCancellationCount = 0

    var dispatchCount: Int { lock.withLock { storedDispatchCount } }
    var cancellationCount: Int { lock.withLock { storedCancellationCount } }

    func decompile(
        request _: NativeDecompilerPreencodedDispatchRequest,
        elapsedTimeBudget: Duration?
    ) async throws -> NativeDecompilerWireReplyEnvelope {
        lock.withLock { storedDispatchCount += 1 }
        return try await withTaskCancellationHandler {
            try await Task.sleep(for: .seconds(30))
            throw NativeDecompilerXPCClientFailure.timedOut
        } onCancel: {
            self.lock.withLock { self.storedCancellationCount += 1 }
        }
    }
}

private actor ReorderedNativeSubmissionAdmissionGate {
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var entryCount = 0
    private(set) var returnCount = 0

    func admit() async {
        entryCount += 1
        let entry = entryCount
        await withCheckedContinuation { continuation in
            continuations[entry] = continuation
        }
        returnCount += 1
    }

    func release(entry: Int) {
        continuations.removeValue(forKey: entry)?.resume()
    }
}

private struct TestNativeRuntimeAuthorityProvider: NativeDecompilerRuntimeAuthorityProviding {
    func attestRuntimeAuthority() async throws -> NativeDecompilerRuntimeIdentity {
        ControllableNativeDecompilerDispatcher.runtimeIdentity
    }
}

private struct AlwaysActiveReconstructionNativeJobValidator:
    ReconstructionNativeDecompilerDurableJobValidating
{
    func validateActiveDurableJobID(_: UUID) async throws {}
}

private func makeTestNativeDecompilerRuntimeRegistry(
    policy: NativeDecompilerRuntimePolicy,
    dispatcher: any NativeDecompilerDispatching,
    telemetry: NativeDecompilerTelemetryRecorder = .init(),
    submissionAdmission: @escaping NativeDecompilerRuntimeRegistry.SubmissionAdmission = { _ in },
    coordinatorAdmission: @escaping NativeDecompilerRuntimeRegistry.CoordinatorAdmission = { _ in }
) -> NativeDecompilerRuntimeRegistry {
    .testing(
        policy: policy,
        dispatcher: dispatcher,
        authorityProvider: TestNativeRuntimeAuthorityProvider(),
        telemetry: telemetry,
        submissionAdmission: submissionAdmission,
        coordinatorAdmission: coordinatorAdmission
    )
}

private final class ControllableNativeDecompilerDispatcher:
    NativeDecompilerDispatching,
    @unchecked Sendable
{
    static let runtimeIdentity = NativeDecompilerRuntimeIdentity(
        backendID: "native-decompiler-test",
        engineVersion: "12.1.2",
        engineRevision: String(repeating: "b", count: 40),
        wrapperVersion: "dcp03b5-v1",
        wrapperRevision: String(repeating: "c", count: 40),
        packageManifestSHA256: String(repeating: "d", count: 64),
        packageTreeSHA256: String(repeating: "e", count: 64),
        languageID: "AARCH64:LE:64:AppleSilicon",
        compilerSpecID: "default",
        targetProfileID: "apple-aarch64-pac-visible-clobber-v1",
        contextProfileSHA256: "6aa45ea9206f967c095d175b05c6c0d7980cd15a0702826d7ab38e4fd37c8ca5"
    )

    enum Outcome: Sendable {
        case success
        /// A `decompile-document` reply: the document plus `native-structure-omitted`.
        case documentSuccess
        case providerFailure(NativeDecompilerWireFailureCode)
    }

    private struct Pending {
        let request: NativeDecompilerWireRequestEnvelope
        let continuation: CheckedContinuation<NativeDecompilerWireReplyEnvelope, Error>
    }

    private let lock = NSLock()
    private var storedRequests: [NativeDecompilerWireRequestEnvelope] = []
    private var pending: [Pending] = []
    private var storedCancellationCount = 0

    var requests: [NativeDecompilerWireRequestEnvelope] { lock.withLock { storedRequests } }
    var requestCount: Int { lock.withLock { storedRequests.count } }
    var cancellationCount: Int { lock.withLock { storedCancellationCount } }

    func decompile(
        request dispatchRequest: NativeDecompilerPreencodedDispatchRequest,
        elapsedTimeBudget _: Duration?
    ) async throws -> NativeDecompilerWireReplyEnvelope {
        let request = dispatchRequest.envelope
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    storedRequests.append(request)
                    pending.append(Pending(request: request, continuation: continuation))
                }
            }
        } onCancel: {
            self.lock.withLock { self.storedCancellationCount += 1 }
        }
    }

    func completeFirst(with outcome: Outcome) {
        let suspended: Pending? = lock.withLock {
            guard !pending.isEmpty else { return nil }
            return pending.removeFirst()
        }
        guard let suspended else {
            XCTFail("Controllable native dispatcher has no pending request to complete")
            return
        }
        suspended.continuation.resume(
            returning: Self.reply(for: suspended.request, outcome: outcome)
        )
    }

    private static func reply(
        for request: NativeDecompilerWireRequestEnvelope,
        outcome: Outcome
    ) -> NativeDecompilerWireReplyEnvelope {
        switch outcome {
        case .success, .documentSuccess:
            let result = NativeDecompilerWireStructuredResult(
                requestID: request.requestID,
                requestSHA256: request.body.requestSHA256,
                image: request.body.image,
                function: request.body.function,
                addressSpaces: [],
                types: [],
                instructions: [],
                varnodes: [],
                operations: [],
                blocks: [],
                edges: [],
                ssaValues: [],
                ssaBindings: [],
                phis: [],
                memoryVersions: [],
                memoryPhis: [],
                memoryEffects: [],
                variables: [],
                calls: [],
                regions: [],
                tokens: [],
                pseudocodeDocument: NativeDecompilerWirePseudocodeDocument(
                    text: "void fixture(void) {}\n",
                    language: "c",
                    isComplete: true,
                    isTruncated: false
                ),
                warnings: outcome.isDocument ? [.init(
                    code: "native-structure-omitted", severity: .warning,
                    message: "Document-only request: the structured graph was not exported.", sourceRanges: []
                )] : []
            )
            let availability = NativeDecompilerWireBackendAvailability(
                available: true,
                reasonCode: "",
                runtimeIdentity: runtimeIdentity,
                capabilities: .init(
                    nativeDecompilerHeritage: true,
                    completeRegisterSSA: false,
                    memorySSA: false,
                    recoveredVariables: false,
                    recoveredTypes: false,
                    structuredControlFlow: false,
                    tokenizedPseudocode: false,
                    imageQualifiedSourceRanges: true
                )
            )
            return NativeDecompilerWireReplyEnvelope(
                requestID: request.requestID,
                success: .init(availability: availability, result: result)
            )
        case let .providerFailure(code):
            return NativeDecompilerWireReplyEnvelope(
                requestID: request.requestID,
                failure: .init(code: code, detail: "representative-test-failure")
            )
        }
    }
}
#endif

private extension ControllableNativeDecompilerDispatcher.Outcome {
    var isDocument: Bool { if case .documentSuccess = self { true } else { false } }
}
