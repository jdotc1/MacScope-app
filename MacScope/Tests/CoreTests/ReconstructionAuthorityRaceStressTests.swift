import Foundation
import XCTest

@testable import MacScope

final class ReconstructionAuthorityRaceStressTests: XCTestCase {
    func testCompiledAuthorityRaceScenario() async throws {
        let configurations = try AuthorityRaceStressConfiguration.configurations()
        let ledger = try AuthorityRaceStressLedgerWriter.fromEnvironment()
        XCTAssertFalse(configurations.isEmpty)
        for configuration in configurations {
            do {
                try configuration.validateSemanticParameterVocabulary()
                XCTAssertTrue([
                    "swift-pairwise-composite",
                    "swift-product-race",
                ].contains(configuration.adapter))
                XCTAssertFalse(configuration.scenarioID.isEmpty)
                XCTAssertGreaterThanOrEqual(configuration.seed, 0)
                let observedAxes = try await exercise(configuration)
                XCTAssertEqual(observedAxes, Set(configuration.semanticAxes))
                try ledger?.record(
                    configuration: configuration,
                    observedAxes: observedAxes,
                    status: "passed"
                )
            } catch {
                try? ledger?.record(
                    configuration: configuration,
                    observedAxes: [],
                    status: "failed"
                )
                throw error
            }
        }
    }

    private func exercise(
        _ configuration: AuthorityRaceStressConfiguration
    ) async throws -> Set<String> {
        if configuration.adapter == "swift-pairwise-composite" {
            try await exercisePairwiseComposite(configuration)
            return ["batch-scheduler-provider-pairwise-composite"]
        }
        guard configuration.adapter == "swift-product-race" else {
            throw AuthorityRaceStressConfigurationError.invalidAdapter
        }
        var observed: Set<String> = []
        for axis in configuration.semanticAxes {
            switch axis {
            case "batch-scheduler-job-authority":
                try await exerciseBatchSchedulerJobAuthority(configuration)
            case "provider-budget":
                try exerciseBudgetBoundary(configuration)
            case "provider-pool-cancellation":
                try await exerciseProviderCancellation(configuration)
            case "provider-pool-lifecycle":
                try await exerciseProviderLifecycle(configuration)
            case "destination-session-authority":
                try await exerciseSessionAuthority(configuration)
            case "xpc-event-sequencing":
                try await exerciseProtocolSequencing(configuration)
            case "presentation-command-aba":
                try exercisePresentationCommandABA(configuration)
            case "terminal-reset-stale-resolution-composite":
                try await exerciseTerminalResetStaleResolutionComposite(
                    configuration
                )
            default:
                throw AuthorityRaceStressConfigurationError.invalidSemanticAxes
            }
            observed.insert(axis)
        }
        return observed
    }

    private func exercisePairwiseComposite(
        _ configuration: AuthorityRaceStressConfiguration
    ) async throws {
        guard let authority = configuration.parameters["authority"],
              let cancellation = configuration.parameters["cancellation"],
              let publication = configuration.parameters["publication"],
              let resource = configuration.parameters["resource"],
              let session = configuration.parameters["session"]
        else {
            throw AuthorityRaceStressConfigurationError.invalidParameters
        }
        guard configuration.semanticAxes
                == ["batch-scheduler-provider-pairwise-composite"],
              Set(configuration.parameters.keys) == [
                "authority", "cancellation", "publication", "resource", "session",
              ],
              ["exact-job", "foreign-job", "foreign-window", "stale-revision"]
                .contains(authority),
              ["after-enqueue", "before-enqueue", "during-release", "during-removal", "none"]
                .contains(cancellation),
              ["after-terminal", "before-terminal", "none"]
                .contains(publication),
              ["combined-extremes", "insufficient-memory", "memory-extreme", "nominal", "processor-extreme"]
                .contains(resource),
              ["concurrent-resolution", "existing", "reset-race"]
                .contains(session)
        else {
            throw AuthorityRaceStressConfigurationError.invalidParameters
        }

        // The batch scheduler invokes an executor that must acquire the
        // production provider pool. This is one nested execution boundary,
        // not two independent assertions. The remaining selected values are
        // then exercised by their closed production seams in the same seeded
        // invocation.
        try await exerciseBatchSchedulerProviderAuthority(configuration)
        try exerciseBudgetBoundary(configuration)
        try await exerciseProviderCancellation(configuration)
        try await exerciseSessionAuthority(configuration)
        try await exerciseProtocolSequencing(configuration)
    }

    private func exerciseBatchSchedulerJobAuthority(
        _ configuration: AuthorityRaceStressConfiguration
    ) async throws {
        guard let authority = configuration.parameters["authority"],
              configuration.parameters["scheduler"] == "batch",
              Set(configuration.parameters.keys) == ["authority", "scheduler"],
              ["exact-job", "foreign-job"]
                .contains(authority)
        else {
            throw AuthorityRaceStressConfigurationError.invalidParameters
        }
        try await exerciseBatchSchedulerProviderAuthority(configuration)
    }

    private func exerciseBatchSchedulerProviderAuthority(
        _ configuration: AuthorityRaceStressConfiguration
    ) async throws {
        let durableJobID = authorityRaceID(201)
        let exactAuthority = try authorityRaceBatchAuthority(jobID: durableJobID)
        let task = try authorityRaceBatchTask(jobID: durableJobID)
        let pool = try ReconstructionAnalysisProviderPool(
            factory: AuthorityRaceStressProviderFactory(),
            budget: .init(
                maximumActiveAnalyses: 1,
                estimatedResidentBytesPerAnalysis: 1,
                reservedHostBytes: 0
            ),
            processorCount: 1,
            physicalMemory: 8
        )
        let executor = AuthorityRaceStressCompositeBatchExecutor(pool: pool)
        let scheduler = ReconstructionBatchScheduler(
            durableJobID: durableJobID,
            executor: executor
        )
        let exact = try await scheduler.executeReadyTasks(
            [task],
            authority: exactAuthority,
            budget: .init(maximumTasks: 1, maximumConcurrentTasks: 1)
        )
        XCTAssertEqual(exact.map(\.outcome), [.completed])
        let exactOperationCount = await executor.operationCount
        let exactPoolSnapshot = await pool.snapshot()
        XCTAssertEqual(exactOperationCount, 1)
        XCTAssertEqual(exactPoolSnapshot.activeProviderCount, 0)

        switch configuration.parameters["authority"] {
        case "exact-job":
            break
        case "foreign-job", "foreign-window":
            let foreignJobID = authorityRaceID(202)
            let foreignAuthority = try authorityRaceBatchAuthority(jobID: foreignJobID)
            do {
                _ = try await scheduler.executeReadyTasks(
                    [task],
                    authority: foreignAuthority,
                    budget: .init(maximumTasks: 1, maximumConcurrentTasks: 1)
                )
                XCTFail("foreign durable job authority must not reach the executor")
            } catch let error as ReconstructionBatchSchedulerError {
                XCTAssertEqual(
                    error,
                    .jobAuthorityMismatch(
                        expected: durableJobID,
                        actual: foreignJobID
                    )
                )
            }
            let foreignOperationCount = await executor.operationCount
            XCTAssertEqual(foreignOperationCount, 1)
        case "stale-revision":
            let staleExecutor = AuthorityRaceStressCompositeBatchExecutor(
                pool: pool,
                returnsStaleRevision: true
            )
            let staleScheduler = ReconstructionBatchScheduler(
                durableJobID: durableJobID,
                executor: staleExecutor
            )
            let stale = try await staleScheduler.executeReadyTasks(
                [task],
                authority: exactAuthority,
                budget: .init(maximumTasks: 1, maximumConcurrentTasks: 1)
            )
            XCTAssertEqual(stale.map(\.outcome), [.staleAuthority])
            let staleOperationCount = await staleExecutor.operationCount
            XCTAssertEqual(staleOperationCount, 1)
        default:
            throw AuthorityRaceStressConfigurationError.invalidParameters
        }
    }

    private func exerciseBudgetBoundary(
        _ configuration: AuthorityRaceStressConfiguration
    ) throws {
        let resource = configuration.parameters["resource"]
        let explicitlyInsufficient = resource == "insufficient-memory"
        let budget = ReconstructionAnalysisProviderPoolBudget(
            maximumActiveAnalyses: 32,
            estimatedResidentBytesPerAnalysis: explicitlyInsufficient ? 2 : 1,
            reservedHostBytes: explicitlyInsufficient ? 1 : 0
        )

        if explicitlyInsufficient {
            XCTAssertThrowsError(
                try budget.width(processorCount: 32, physicalMemory: 1)
            ) { error in
                XCTAssertEqual(
                    error as? ReconstructionAnalysisProviderPoolBudgetError,
                    .insufficientHostMemory
                )
            }
            return
        }

        let processorCount = resource == "processor-extreme"
            || resource == "combined-extremes"
            || configuration.parameters["processor"] == "extreme"
            ? Int.max
            : 8
        let physicalMemory: UInt64 = resource == "memory-extreme"
            || resource == "combined-extremes"
            || configuration.parameters["memory"] == "extreme"
            ? UInt64.max
            : 64
        let width = try budget.width(
            processorCount: processorCount,
            physicalMemory: physicalMemory
        )
        XCTAssertGreaterThan(width, 0)
        XCTAssertLessThanOrEqual(width, 32)
    }

    private func exerciseProviderCancellation(
        _ configuration: AuthorityRaceStressConfiguration
    ) async throws {
        let cancellation = configuration.parameters["cancellation"] ?? "none"
        if cancellation == "during-removal" {
            try await exerciseDelayedRemovalReleaseRace(configuration)
            return
        }
        let providerCancellation = cancellation == "after-terminal"
            ? "none"
            : cancellation
        let gate = AuthorityRaceStressGate()
        let beforeEnqueueGate = AuthorityRaceStressGate()
        let operations = AuthorityRaceStressCounter()
        let pool = try ReconstructionAnalysisProviderPool(
            factory: AuthorityRaceStressProviderFactory(),
            budget: .init(
                maximumActiveAnalyses: 1,
                estimatedResidentBytesPerAnalysis: 1,
                reservedHostBytes: 0
            ),
            processorCount: 1,
            physicalMemory: 8,
            hooks: providerCancellation == "before-enqueue"
                ? .init(beforeWaiterEnqueue: { _ in
                    await beforeEnqueueGate.wait()
                })
                : .none
        )
        let active = Task {
            try await pool.withProvider { _ in
                await gate.wait()
                return "active"
            }
        }
        await waitForAuthorityRace {
            await pool.snapshot().activeProviderCount == 1
        }

        let queued = Task {
            try await pool.withProvider { _ in
                await operations.increment()
                return "queued"
            }
        }
        if providerCancellation == "before-enqueue" {
            await waitForAuthorityRace { await beforeEnqueueGate.waiterCount == 1 }
            queued.cancel()
            await beforeEnqueueGate.open()
        } else {
            await waitForAuthorityRace {
                await pool.snapshot().queuedWaiterCount == 1
            }
            if providerCancellation != "none" {
                queued.cancel()
            }
        }

        if providerCancellation == "during-release" {
            let release = Task { await gate.open() }
            queued.cancel()
            await release.value
        } else {
            for _ in 0..<configuration.yieldCount {
                await Task.yield()
            }
            await gate.open()
        }
        let activeValue = try await active.value
        XCTAssertEqual(activeValue, "active")

        if providerCancellation == "none" {
            let queuedValue = try await queued.value
            let operationCount = await operations.value
            XCTAssertEqual(queuedValue, "queued")
            XCTAssertEqual(operationCount, 1)
        } else {
            do {
                _ = try await queued.value
                XCTFail("cancelled acquisition must not execute its operation")
            } catch is CancellationError {
                // Expected.
            }
            let operationCount = await operations.value
            XCTAssertEqual(operationCount, 0)
        }
        let snapshot = await pool.snapshot()
        XCTAssertEqual(snapshot.activeProviderCount, 0)
        XCTAssertEqual(snapshot.queuedWaiterCount, 0)
    }

    private func exerciseDelayedRemovalReleaseRace(
        _ configuration: AuthorityRaceStressConfiguration
    ) async throws {
        if let release = configuration.parameters["release"], release != "concurrent" {
            throw AuthorityRaceStressConfigurationError.invalidParameters
        }
        if let removal = configuration.parameters["removal"], removal != "delayed" {
            throw AuthorityRaceStressConfigurationError.invalidParameters
        }
        if let waiter = configuration.parameters["waiter"], waiter != "cancelled" {
            throw AuthorityRaceStressConfigurationError.invalidParameters
        }

        let activeGate = AuthorityRaceStressGate()
        let removalGate = AuthorityRaceStressGate()
        let cancelledOperations = AuthorityRaceStressCounter()
        let successorOperations = AuthorityRaceStressCounter()
        let pool = try ReconstructionAnalysisProviderPool(
            factory: AuthorityRaceStressProviderFactory(),
            budget: .init(
                maximumActiveAnalyses: 1,
                estimatedResidentBytesPerAnalysis: 1,
                reservedHostBytes: 0
            ),
            processorCount: 1,
            physicalMemory: 8,
            hooks: .init(beforeWaiterCancellationRemoval: { _ in
                await removalGate.wait()
            })
        )
        let active = Task {
            try await pool.withProvider { _ in
                await activeGate.wait()
                return "active"
            }
        }
        await waitForAuthorityRace {
            await pool.snapshot().activeProviderCount == 1
        }
        let cancelled = Task {
            try await pool.withProvider { _ in
                await cancelledOperations.increment()
                return "cancelled"
            }
        }
        await waitForAuthorityRace { await pool.snapshot().queuedWaiterCount == 1 }
        let successor = Task {
            try await pool.withProvider { _ in
                await successorOperations.increment()
                return "successor"
            }
        }
        await waitForAuthorityRace { await pool.snapshot().queuedWaiterCount == 2 }

        cancelled.cancel()
        await waitForAuthorityRace { await removalGate.waiterCount == 1 }
        let release = Task { await activeGate.open() }
        let activeValue = try await active.value
        let successorValue = try await successor.value
        await release.value
        XCTAssertEqual(activeValue, "active")
        XCTAssertEqual(successorValue, "successor")
        do {
            _ = try await cancelled.value
            XCTFail("cancelled delayed-removal waiter must remain skipped")
        } catch is CancellationError {
            // Expected.
        }
        let cancelledCount = await cancelledOperations.value
        let successorCount = await successorOperations.value
        XCTAssertEqual(cancelledCount, 0)
        XCTAssertEqual(successorCount, 1)

        await removalGate.open()
        await waitForAuthorityRace { await pool.snapshot().queuedWaiterCount == 0 }
    }

    private func exerciseProviderLifecycle(
        _ configuration: AuthorityRaceStressConfiguration
    ) async throws {
        guard configuration.parameters["lifecycle"] == "pause-resume-retire" else {
            throw AuthorityRaceStressConfigurationError.invalidParameters
        }
        let gate = AuthorityRaceStressGate()
        let pool = try ReconstructionAnalysisProviderPool(
            factory: AuthorityRaceStressProviderFactory(),
            budget: .init(
                maximumActiveAnalyses: 1,
                estimatedResidentBytesPerAnalysis: 1,
                reservedHostBytes: 0
            ),
            processorCount: 1,
            physicalMemory: 8
        )
        let active = Task {
            try await pool.withProvider { _ in
                await gate.wait()
                return "active"
            }
        }
        await waitForAuthorityRace { await pool.snapshot().activeProviderCount == 1 }
        let pause = Task { await pool.pause() }
        await waitForAuthorityRace { await pool.snapshot().lifecycle == .paused }
        await gate.open()
        let activeValue = try await active.value
        XCTAssertEqual(activeValue, "active")
        await pause.value
        let pausedLifecycle = await pool.snapshot().lifecycle
        XCTAssertEqual(pausedLifecycle, .paused)
        await pool.resume()
        let activeLifecycle = await pool.snapshot().lifecycle
        XCTAssertEqual(activeLifecycle, .active)
        await pool.retire()
        let retiredLifecycle = await pool.snapshot().lifecycle
        XCTAssertEqual(retiredLifecycle, .retired)
    }

    private func exerciseSessionAuthority(
        _ configuration: AuthorityRaceStressConfiguration
    ) async throws {
        if configuration.parameters["authority"] == "foreign-window",
           configuration.parameters["resolution"] == "concurrent",
           configuration.parameters["session"] == "reset-race" {
            try await exerciseConcurrentResolutionResetForeignWindow(configuration)
            return
        }
        if configuration.parameters["window"] == "session-owner" {
            try await exerciseOneWindowOneSession(configuration)
            return
        }
        let resetRequested = configuration.parameters["session"] == "reset-race"
            || configuration.parameters["authority"] == "stale-revision"
            || configuration.parameters["revision"] == "stale"
            || configuration.parameters["scope"] == "old"
        if resetRequested {
            try await exerciseResetFencing(configuration)
        } else {
            try await exerciseCoalescingAndForeignAuthority(configuration)
        }
    }

    private func exerciseOneWindowOneSession(
        _ configuration: AuthorityRaceStressConfiguration
    ) async throws {
        guard configuration.parameters["session"] == "existing" else {
            throw AuthorityRaceStressConfigurationError.invalidParameters
        }
        let firstFactory = AuthorityRaceStressSessionFactory(
            yieldCount: configuration.yieldCount
        )
        let secondFactory = AuthorityRaceStressSessionFactory(
            yieldCount: configuration.yieldCount
        )
        let first = ReconstructionDestinationSessionResolver<AuthorityRaceStressSession> {
            await firstFactory.make(jobID: $0)
        }
        let second = ReconstructionDestinationSessionResolver<AuthorityRaceStressSession> {
            await secondFactory.make(jobID: $0)
        }
        let jobID = UUID()
        let firstSession = try await first.resolve(forDurableJobID: jobID)
        let repeated = try await first.resolve(forDurableJobID: jobID)
        let siblingWindowSession = try await second.resolve(forDurableJobID: jobID)
        XCTAssertEqual(firstSession, repeated)
        XCTAssertNotEqual(firstSession.instanceID, siblingWindowSession.instanceID)
        let firstFactoryCount = await firstFactory.callCount
        let secondFactoryCount = await secondFactory.callCount
        XCTAssertEqual(firstFactoryCount, 1)
        XCTAssertEqual(secondFactoryCount, 1)
    }

    private func exerciseConcurrentResolutionResetForeignWindow(
        _ configuration: AuthorityRaceStressConfiguration
    ) async throws {
        let factory = AuthorityRaceStressLateSessionFactory()
        let retired = AuthorityRaceStressCounter()
        let owningWindow = ReconstructionDestinationSessionResolver<AuthorityRaceStressSession>(
            factory: { jobID in await factory.make(jobID: jobID) },
            retire: { _ in await retired.increment() }
        )
        let foreignFactory = AuthorityRaceStressSessionFactory(
            yieldCount: configuration.yieldCount
        )
        let foreignWindow = ReconstructionDestinationSessionResolver<AuthorityRaceStressSession> {
            await foreignFactory.make(jobID: $0)
        }
        let owningJobID = UUID()
        let foreignJobID = UUID()
        let first = Task { try await owningWindow.resolve(forDurableJobID: owningJobID) }
        let second = Task { try await owningWindow.resolve(forDurableJobID: owningJobID) }
        await waitForAuthorityRace { await factory.callCount == 1 }
        let reset = Task { await owningWindow.reset() }
        await waitForAuthorityRace { await factory.cancellationObserved }
        let foreignSession = try await foreignWindow.resolve(forDurableJobID: foreignJobID)
        await factory.release()
        await reset.value
        for resolution in [first, second] {
            do {
                _ = try await resolution.value
                XCTFail("reset must fence every coalesced late resolution")
            } catch {
                XCTAssertEqual(
                    error as? ReconstructionDestinationSessionResolutionError,
                    .staleResolution
                )
            }
        }
        XCTAssertEqual(foreignSession.jobID, foreignJobID)
        let foreignFactoryCount = await foreignFactory.callCount
        let retiredCount = await retired.value
        let owningWindowJobID = await owningWindow.resolvedDurableJobID()
        XCTAssertEqual(foreignFactoryCount, 1)
        XCTAssertEqual(retiredCount, 1)
        XCTAssertNil(owningWindowJobID)
    }

    private func exerciseCoalescingAndForeignAuthority(
        _ configuration: AuthorityRaceStressConfiguration
    ) async throws {
        let factory = AuthorityRaceStressSessionFactory(
            yieldCount: configuration.yieldCount
        )
        let resolver = ReconstructionDestinationSessionResolver<AuthorityRaceStressSession> {
            jobID in
            await factory.make(jobID: jobID)
        }
        let jobID = UUID()
        let existing = configuration.parameters["session"] == "existing"
            ? try await resolver.resolve(forDurableJobID: jobID)
            : nil
        let taskCount = 4 + Int(configuration.seed % 13)
        let sessions = try await withThrowingTaskGroup(
            of: AuthorityRaceStressSession.self
        ) { group in
            for _ in 0..<taskCount {
                group.addTask {
                    try await resolver.resolve(forDurableJobID: jobID)
                }
            }
            var values: [AuthorityRaceStressSession] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        let factoryCallCount = await factory.callCount
        XCTAssertEqual(factoryCallCount, 1)
        XCTAssertEqual(Set(sessions.map(\.instanceID)).count, 1)
        XCTAssertTrue(sessions.allSatisfy { $0.jobID == jobID })
        if let existing {
            XCTAssertTrue(sessions.allSatisfy { $0 == existing })
        }

        let authority = configuration.parameters["authority"]
        if authority == "foreign-job" || authority == "foreign-window" {
            let foreignJobID = UUID()
            do {
                _ = try await resolver.resolve(forDurableJobID: foreignJobID)
                XCTFail("foreign durable authority must not rebind the resolver")
            } catch {
                XCTAssertEqual(
                    error as? ReconstructionDestinationSessionResolutionError,
                    .jobIdentityMismatch(expected: jobID, actual: foreignJobID)
                )
            }
        }
    }

    private func exerciseResetFencing(
        _ configuration: AuthorityRaceStressConfiguration
    ) async throws {
        let factory = AuthorityRaceStressLateSessionFactory()
        let retired = AuthorityRaceStressCounter()
        let resolver = ReconstructionDestinationSessionResolver<AuthorityRaceStressSession>(
            factory: { jobID in await factory.make(jobID: jobID) },
            retire: { _ in await retired.increment() }
        )
        let oldJobID = UUID()
        let newJobID = UUID()
        let oldResolution = Task { () -> ReconstructionDestinationSessionResolutionError? in
            do {
                _ = try await resolver.resolve(forDurableJobID: oldJobID)
                return nil
            } catch {
                return error as? ReconstructionDestinationSessionResolutionError
            }
        }
        await waitForAuthorityRace { await factory.callCount == 1 }

        for _ in 0..<configuration.yieldCount {
            await Task.yield()
        }
        let reset = Task { await resolver.reset() }
        await waitForAuthorityRace { await factory.cancellationObserved }
        await factory.release()
        await reset.value

        let oldResolutionError = await oldResolution.value
        let retirementCount = await retired.value
        XCTAssertEqual(oldResolutionError, .staleResolution)
        XCTAssertEqual(retirementCount, 1)
        let replacement = try await resolver.resolve(forDurableJobID: newJobID)
        let resolvedJobID = await resolver.resolvedDurableJobID()
        XCTAssertEqual(replacement.jobID, newJobID)
        XCTAssertEqual(resolvedJobID, newJobID)
    }

    private func exerciseProtocolSequencing(
        _ configuration: AuthorityRaceStressConfiguration
    ) async throws {
        let publication = configuration.parameters["publication"]
        let event = configuration.parameters["event"]
        let ordering = configuration.parameters["ordering"]
        let correlation = configuration.parameters["correlation"]
        let cancellation = configuration.parameters["cancellation"]
        guard publication != nil || event != nil || ordering != nil
                || correlation != nil || cancellation == "after-terminal"
                || cancellation == "before-terminal"
        else { return }

        if cancellation == "before-terminal" {
            try await expectCancellationBeforeTerminal()
            return
        }

        if publication == "post-terminal", event == "duplicate",
           ordering == "reordered" {
            try await expectProtocolSequence(
                .postTerminalDuplicateReordered,
                expectedError: .invalidEventSequence
            )
            return
        }
        if ordering == "reordered" {
            try await expectProtocolSequence(
                .reordered,
                expectedError: .invalidEventSequence
            )
        }
        if event == "duplicate" {
            try await expectProtocolSequence(
                .duplicate,
                expectedError: .invalidEventSequence
            )
        }
        switch publication {
        case "after-terminal", "post-terminal":
            try await expectProtocolSequence(
                .postTerminal,
                expectedError: .invalidEventSequence
            )
        case "none":
            try await expectProtocolSequence(
                .missingTerminal,
                expectedError: .missingCompletion
            )
        case "before-terminal", "terminal":
            try await expectProtocolSequence(.valid, expectedError: nil)
        case nil:
            break
        default:
            throw AuthorityRaceStressConfigurationError.invalidParameters
        }
        if correlation == "exact" || (cancellation == "after-terminal" && publication == nil) {
            try await expectProtocolSequence(.valid, expectedError: nil)
        }
    }

    private func exerciseTerminalResetStaleResolutionComposite(
        _ configuration: AuthorityRaceStressConfiguration
    ) async throws {
        guard configuration.scenarioID
                == "race.cancel-terminal-reset-stale-revision",
              configuration.parameters == [
                "cancellation": "after-terminal",
                "publication": "terminal",
                "revision": "stale",
                "session": "reset-race",
              ]
        else {
            throw AuthorityRaceStressConfigurationError.invalidParameters
        }

        let factory = AuthorityRaceStressLateSessionFactory()
        let retired = AuthorityRaceStressCounter()
        let resolver = ReconstructionDestinationSessionResolver<AuthorityRaceStressSession>(
            factory: { jobID in await factory.make(jobID: jobID) },
            retire: { _ in await retired.increment() }
        )
        let staleJobID = UUID()
        let replacementJobID = UUID()
        let staleResolution = Task {
            () -> ReconstructionDestinationSessionResolutionError? in
            do {
                _ = try await resolver.resolve(forDurableJobID: staleJobID)
                return nil
            } catch {
                return error as? ReconstructionDestinationSessionResolutionError
            }
        }
        await waitForAuthorityRace { await factory.callCount == 1 }

        let requestID = authorityRaceID(92)
        let transport = AuthorityRaceStressProtocolTransport(
            mode: .terminalAwaitingCancellation
        )
        let provider = ReconstructionXPCInferenceProvider(transport: transport)
        let round = Task {
            try await provider.runRound(
                requestID: requestID,
                request: authorityRaceRoundRequest(),
                emit: { _ in }
            )
        }
        await waitForAuthorityRace { await transport.terminalPublished }

        // These operations intentionally overlap while both production seams
        // still have live, test-controlled work.  The XPC transport cannot
        // return until cancel opens its gate, while the stale resolver cannot
        // return until reset cancels and the test later releases its factory.
        let terminalCancellation = Task {
            await provider.cancel(requestID: requestID)
        }
        let resolverReset = Task { await resolver.reset() }
        await waitForAuthorityRace {
            let cancellationCount = await transport.cancellationCount
            let cancellationObserved = await factory.cancellationObserved
            return cancellationCount == 1 && cancellationObserved
        }
        await factory.release()
        await terminalCancellation.value
        await resolverReset.value

        let receipt = try await round.value
        let cancellationCount = await transport.cancellationCount
        let staleResolutionError = await staleResolution.value
        let retirementCount = await retired.value
        XCTAssertEqual(receipt.status, .completed)
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertEqual(staleResolutionError, .staleResolution)
        XCTAssertEqual(retirementCount, 1)

        let replacement = try await resolver.resolve(
            forDurableJobID: replacementJobID
        )
        let resolvedJobID = await resolver.resolvedDurableJobID()
        XCTAssertEqual(replacement.jobID, replacementJobID)
        XCTAssertEqual(resolvedJobID, replacementJobID)
    }

    private func expectCancellationBeforeTerminal() async throws {
        let transport = AuthorityRaceStressProtocolTransport(mode: .cancelBeforeTerminal)
        let provider = ReconstructionXPCInferenceProvider(transport: transport)
        let task = Task {
            try await provider.runRound(
                requestID: authorityRaceID(91),
                request: authorityRaceRoundRequest(),
                emit: { _ in }
            )
        }
        await waitForAuthorityRace { await transport.started }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("pre-terminal cancellation must cancel the active round")
        } catch is CancellationError {
            // Expected.
        }
        await waitForAuthorityRace { await transport.cancellationCount == 1 }
    }

    private func expectProtocolSequence(
        _ mode: AuthorityRaceStressProtocolMode,
        expectedError: ReconstructionXPCInferenceProviderError?
    ) async throws {
        let transport = AuthorityRaceStressProtocolTransport(mode: mode)
        let provider = ReconstructionXPCInferenceProvider(transport: transport)
        let request = authorityRaceRoundRequest()
        do {
            let receipt = try await provider.runRound(
                requestID: authorityRaceID(90),
                request: request,
                emit: { _ in }
            )
            XCTAssertNil(expectedError)
            XCTAssertEqual(receipt.status, .completed)
            await provider.cancel(requestID: authorityRaceID(90))
            let cancellationCount = await transport.cancellationCount
            XCTAssertEqual(cancellationCount, 0)
        } catch {
            XCTAssertEqual(
                error as? ReconstructionXPCInferenceProviderError,
                expectedError
            )
        }
    }

    private func exercisePresentationCommandABA(
        _ configuration: AuthorityRaceStressConfiguration
    ) throws {
        let abaNames: Set<String> = [
            "completion", "generation", "revision", "scope", "window",
        ]
        guard !abaNames.isDisjoint(with: configuration.parameters.keys) else {
            return
        }
        guard configuration.parameters["completion"] == "late",
              configuration.parameters["generation"] == "repeated",
              configuration.parameters["revision"] == "repeated",
              configuration.parameters["scope"] == "old",
              configuration.parameters["window"] == "replacement"
        else {
            throw AuthorityRaceStressConfigurationError.invalidParameters
        }

        let windowID = UUID()
        let jobID = UUID()
        let oldScopeID = UUID()
        let newScopeID = UUID()
        let base = ReconstructionDurablePresentationIdentity(
            jobID: jobID,
            state: .created,
            projectionRevision: 6,
            checkpointRevision: 0
        )
        let initial = ReconstructionWindowPresentationState(
            windowID: windowID,
            selectedJobID: jobID
        )
        let oldPending = try XCTUnwrap(initial.beginningCommand(
            .start,
            commandScopeID: oldScopeID,
            against: base,
            expectedCommittedState: .ingesting
        ))
        let newPending = try XCTUnwrap(initial.beginningCommand(
            .start,
            commandScopeID: newScopeID,
            against: base,
            expectedCommittedState: .ingesting
        ))
        XCTAssertEqual(newPending.windowID, oldPending.windowID)
        XCTAssertEqual(newPending.commandGeneration, oldPending.commandGeneration)
        XCTAssertEqual(
            newPending.pendingIntent.baseProjectionRevision,
            oldPending.pendingIntent.baseProjectionRevision
        )

        let lateOldCompletion = ReconstructionCommandCompletion(
            windowID: windowID,
            commandScopeID: oldScopeID,
            commandGeneration: newPending.commandGeneration,
            baseProjectionRevision: base.projectionRevision,
            jobID: jobID,
            selectedTaskID: nil,
            selectedEvidenceID: nil
        )
        let replacement = ReconstructionWindowPresentationState(
            windowID: UUID(),
            selectedJobID: jobID,
            pendingIntent: newPending.pendingIntent,
            commandGeneration: newPending.commandGeneration
        )
        let rejected = replacement.accepting(
            lateOldCompletion,
            durableProjectionRevision: base.projectionRevision
        )
        XCTAssertFalse(rejected.accepted)
        XCTAssertEqual(rejected.window, replacement)
        XCTAssertTrue(rejected.rejectionReasons.contains(.windowMismatch))
        XCTAssertTrue(rejected.rejectionReasons.contains(.commandScopeMismatch))
    }
}

private final class AuthorityRaceStressLedgerWriter {
    private let url: URL
    private var attempts: [[String: Any]] = []

    private init(url: URL) {
        self.url = url
    }

    static func fromEnvironment() throws -> AuthorityRaceStressLedgerWriter? {
        guard let path = ProcessInfo.processInfo.environment[
            "MACSCOPE_RECONSTRUCTION_STRESS_LEDGER"
        ] else { return nil }
        guard path.hasPrefix("/"), !path.contains("/../") else {
            throw AuthorityRaceStressConfigurationError.invalidLedger
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard !FileManager.default.fileExists(atPath: url.path),
              FileManager.default.fileExists(
                atPath: url.deletingLastPathComponent().path,
                isDirectory: &isDirectory
              ), isDirectory.boolValue else {
            throw AuthorityRaceStressConfigurationError.invalidLedger
        }
        return .init(url: url)
    }

    func record(
        configuration: AuthorityRaceStressConfiguration,
        observedAxes: Set<String>,
        status: String
    ) throws {
        attempts.append([
            "iteration": configuration.iteration,
            "observed_semantic_axes": observedAxes.sorted(),
            "scenario_id": configuration.scenarioID,
            "seed": Int64(configuration.seed),
            "status": status,
        ])
        let document: [String: Any] = [
            "attempts": attempts,
            "schema_version": 1,
        ]
        guard JSONSerialization.isValidJSONObject(document) else {
            throw AuthorityRaceStressConfigurationError.invalidLedger
        }
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.sortedKeys]
        )
        try data.write(to: url, options: [.atomic])
    }
}

private struct AuthorityRaceStressConfiguration {
    let adapter: String
    let scenarioID: String
    let iteration: Int
    let seed: UInt64
    let parameters: [String: String]
    let semanticAxes: [String]

    var yieldCount: Int {
        1 + Int(seed % 32)
    }

    func validateSemanticParameterVocabulary() throws {
        for name in parameters.keys {
            switch name {
            case "authority", "cancellation", "completion", "correlation",
                 "event", "generation", "lifecycle", "memory", "ordering",
                 "policy", "processor", "publication", "release", "removal",
                 "resolution", "resource", "revision", "scheduler", "scope", "session",
                 "waiter", "window":
                continue
            default:
                throw AuthorityRaceStressConfigurationError.invalidParameters
            }
        }
    }

    static func configurations() throws -> [Self] {
        let environment = ProcessInfo.processInfo.environment
        if let planPath = environment["MACSCOPE_RECONSTRUCTION_STRESS_PLAN"] {
            return try plan(path: planPath)
        }
        guard let scenarioID = environment[
            "MACSCOPE_RECONSTRUCTION_STRESS_SCENARIO_ID"
        ] else {
            return [.init(
                adapter: "swift-product-race",
                scenarioID: "durable.concurrent-session-resolution-coalesces",
                iteration: 0,
                seed: 0,
                parameters: [
                    "authority": "exact-job",
                    "session": "concurrent-resolution",
                ],
                semanticAxes: ["destination-session-authority"]
            )]
        }
        guard let adapter = environment[
            "MACSCOPE_RECONSTRUCTION_STRESS_ADAPTER"
        ], ["swift-pairwise-composite", "swift-product-race"].contains(adapter) else {
            throw AuthorityRaceStressConfigurationError.invalidAdapter
        }
        guard let seedText = environment[
            "MACSCOPE_RECONSTRUCTION_STRESS_SEED"
        ], let seed = UInt64(seedText), seed <= UInt64(Int64.max) else {
            throw AuthorityRaceStressConfigurationError.invalidSeed
        }
        guard let parametersText = environment[
            "MACSCOPE_RECONSTRUCTION_STRESS_PARAMETERS_JSON"
        ], let parametersData = parametersText.data(using: .utf8),
              let parameters = try JSONSerialization.jsonObject(
                with: parametersData
        ) as? [String: String] else {
            throw AuthorityRaceStressConfigurationError.invalidParameters
        }
        guard let semanticAxesText = environment[
            "MACSCOPE_RECONSTRUCTION_STRESS_SEMANTIC_AXES_JSON"
        ], let semanticAxesData = semanticAxesText.data(using: .utf8),
              let semanticAxes = try JSONSerialization.jsonObject(
                with: semanticAxesData
              ) as? [String], !semanticAxes.isEmpty,
              semanticAxes == Array(Set(semanticAxes)).sorted() else {
            throw AuthorityRaceStressConfigurationError.invalidSemanticAxes
        }
        guard scenarioID.range(
            of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#,
            options: .regularExpression
        ) != nil else {
            throw AuthorityRaceStressConfigurationError.invalidScenarioID
        }
        return [.init(
            adapter: adapter,
            scenarioID: scenarioID,
            iteration: 0,
            seed: seed,
            parameters: parameters,
            semanticAxes: semanticAxes
        )]
    }

    private static func plan(path: String) throws -> [Self] {
        guard path.hasPrefix("/"), !path.contains("/../") else {
            throw AuthorityRaceStressConfigurationError.invalidPlan
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let document = try JSONSerialization.jsonObject(with: data)
            as? [String: Any],
              document["schema_version"] as? Int == 1,
              let invocations = document["invocations"] as? [[String: Any]]
        else {
            throw AuthorityRaceStressConfigurationError.invalidPlan
        }
        var observed: Set<String> = []
        let configurations = try invocations.compactMap { invocation -> Self? in
            guard let adapter = invocation["adapter"] as? String else {
                throw AuthorityRaceStressConfigurationError.invalidPlan
            }
            if adapter == "python-evidence-movement" { return nil }
            guard ["swift-pairwise-composite", "swift-product-race"]
                    .contains(adapter) else {
                throw AuthorityRaceStressConfigurationError.invalidAdapter
            }
            guard let scenarioID = invocation["scenario_id"] as? String,
                  let iteration = invocation["iteration"] as? Int,
                  iteration >= 0,
                  let seedNumber = invocation["seed"] as? NSNumber,
                  seedNumber.int64Value >= 0,
                  let parameters = invocation["parameters"] as? [String: String],
                  let semanticAxes = invocation["semantic_axes"] as? [String],
                  !semanticAxes.isEmpty,
                  semanticAxes == Array(Set(semanticAxes)).sorted(),
                  let semanticGaps = invocation["semantic_gaps"] as? [String],
                  semanticGaps.isEmpty,
                  invocation["semantic_status"] as? String == "fully-executable",
                  scenarioID.range(
                    of: #"^[a-z0-9][a-z0-9._-]{0,127}$"#,
                    options: .regularExpression
                  ) != nil
            else {
                throw AuthorityRaceStressConfigurationError.invalidPlan
            }
            let identity = "\(scenarioID)#\(iteration)"
            guard observed.insert(identity).inserted else {
                throw AuthorityRaceStressConfigurationError.invalidPlan
            }
            return .init(
                adapter: adapter,
                scenarioID: scenarioID,
                iteration: iteration,
                seed: seedNumber.uint64Value,
                parameters: parameters,
                semanticAxes: semanticAxes
            )
        }
        guard !configurations.isEmpty else {
            throw AuthorityRaceStressConfigurationError.invalidPlan
        }
        return configurations
    }
}

private enum AuthorityRaceStressConfigurationError: Error {
    case invalidAdapter
    case invalidLedger
    case invalidParameters
    case invalidPlan
    case invalidScenarioID
    case invalidSeed
    case invalidSemanticAxes
}

private struct AuthorityRaceStressSession: Equatable, Sendable {
    let jobID: UUID
    let instanceID: UUID
}

private actor AuthorityRaceStressSessionFactory {
    private(set) var callCount = 0
    private let yieldCount: Int

    init(yieldCount: Int) {
        self.yieldCount = yieldCount
    }

    func make(jobID: UUID) async -> AuthorityRaceStressSession {
        callCount += 1
        for _ in 0..<yieldCount {
            await Task.yield()
        }
        return .init(jobID: jobID, instanceID: UUID())
    }
}

private actor AuthorityRaceStressLateSessionFactory {
    private(set) var callCount = 0
    private(set) var cancellationObserved = false
    private var isReleased = false

    func make(jobID: UUID) async -> AuthorityRaceStressSession {
        callCount += 1
        while !isReleased {
            if Task.isCancelled {
                cancellationObserved = true
            }
            await Task.yield()
        }
        return .init(jobID: jobID, instanceID: UUID())
    }

    func release() {
        isReleased = true
    }
}

private actor AuthorityRaceStressGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiterCount: Int { waiters.count }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }
}

private actor AuthorityRaceStressCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private enum AuthorityRaceStressProtocolMode {
    case cancelBeforeTerminal
    case duplicate
    case missingTerminal
    case postTerminal
    case postTerminalDuplicateReordered
    case reordered
    case terminalAwaitingCancellation
    case valid
}

private actor AuthorityRaceStressProtocolTransport: AIAgentXPCTerminalPreservingTransport {
    private let codec = Phase2ReconstructionAIWorkerWireCodec()
    private let mode: AuthorityRaceStressProtocolMode
    private(set) var cancellationCount = 0
    private(set) var started = false
    private(set) var terminalPublished = false
    private let cancellationGate = AuthorityRaceStressGate()

    init(mode: AuthorityRaceStressProtocolMode) {
        self.mode = mode
    }

    func run(
        requestID: UUID,
        requestData: Data,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        _ = try await runPreservingTerminal(
            requestID: requestID,
            requestData: requestData,
            receive: receive
        )
    }

    func runPreservingTerminal(
        requestID: UUID,
        requestData: Data,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> AIAgentXPCTransportTerminal {
        started = true
        guard case .round(_, let request) = try codec.decodeRequest(requestData) else {
            throw AIAgentXPCTransportError.malformedReply
        }
        let candidate = ReconstructionInferenceRoundCandidate(
            jobID: request.jobID,
            checkpointRevision: request.checkpointRevision,
            roundID: request.roundID,
            selectedHandleIDs: [],
            disposition: .sufficientEvidence,
            unresolvedGaps: []
        )
        let candidateBody = ReconstructionAIWorkerEventBody.roundCandidate(candidate)
        let usageBody = ReconstructionAIWorkerEventBody.usage(.init(
            promptTokens: 2,
            completionTokens: 1,
            totalTokens: 3
        ))

        switch mode {
        case .cancelBeforeTerminal:
            await cancellationGate.wait()
            throw CancellationError()
        case .reordered:
            try await send(
                requestID: requestID,
                sequence: 2,
                body: candidateBody,
                authority: request,
                receive: receive
            )
        case .duplicate:
            try await send(
                requestID: requestID,
                sequence: 1,
                body: candidateBody,
                authority: request,
                receive: receive
            )
            try await send(
                requestID: requestID,
                sequence: 1,
                body: candidateBody,
                authority: request,
                receive: receive
            )
        case .missingTerminal:
            try await sendValidPrefix(
                requestID: requestID,
                request: request,
                candidateBody: candidateBody,
                usageBody: usageBody,
                receive: receive
            )
        case .postTerminal:
            try await sendValidSequence(
                requestID: requestID,
                request: request,
                candidateBody: candidateBody,
                usageBody: usageBody,
                receive: receive
            )
            try await send(
                requestID: requestID,
                sequence: 4,
                body: usageBody,
                authority: request,
                receive: receive
            )
        case .postTerminalDuplicateReordered:
            try await sendValidSequence(
                requestID: requestID,
                request: request,
                candidateBody: candidateBody,
                usageBody: usageBody,
                receive: receive
            )
            try await send(
                requestID: requestID,
                sequence: 2,
                body: candidateBody,
                authority: request,
                receive: receive
            )
        case .terminalAwaitingCancellation:
            try await sendValidSequence(
                requestID: requestID,
                request: request,
                candidateBody: candidateBody,
                usageBody: usageBody,
                receive: receive
            )
            terminalPublished = true
            await cancellationGate.wait()
        case .valid:
            try await sendValidSequence(
                requestID: requestID,
                request: request,
                candidateBody: candidateBody,
                usageBody: usageBody,
                receive: receive
            )
        }
        return .init(requestID: requestID, status: .completed, reason: nil)
    }

    func cancel(requestID: UUID) async {
        cancellationCount += 1
        await cancellationGate.open()
    }

    func reset() async {}

    private func sendValidPrefix(
        requestID: UUID,
        request: ReconstructionInferenceRoundRequest,
        candidateBody: ReconstructionAIWorkerEventBody,
        usageBody: ReconstructionAIWorkerEventBody,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        try await send(
            requestID: requestID,
            sequence: 1,
            body: candidateBody,
            authority: request,
            receive: receive
        )
        try await send(
            requestID: requestID,
            sequence: 2,
            body: usageBody,
            authority: request,
            receive: receive
        )
    }

    private func sendValidSequence(
        requestID: UUID,
        request: ReconstructionInferenceRoundRequest,
        candidateBody: ReconstructionAIWorkerEventBody,
        usageBody: ReconstructionAIWorkerEventBody,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        try await sendValidPrefix(
            requestID: requestID,
            request: request,
            candidateBody: candidateBody,
            usageBody: usageBody,
            receive: receive
        )
        try await send(
            requestID: requestID,
            sequence: 3,
            body: .completed,
            authority: request,
            receive: receive
        )
    }

    private func send(
        requestID: UUID,
        sequence: UInt64,
        body: ReconstructionAIWorkerEventBody,
        authority: ReconstructionInferenceRoundRequest,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        let event = ReconstructionAIWorkerEvent(
            requestID: requestID,
            sequence: sequence,
            body: body
        )
        try await receive(try codec.encodeEvent(
            event,
            authority: .round(authority)
        ))
    }
}

private func authorityRaceRoundRequest() -> ReconstructionInferenceRoundRequest {
    .init(
        protocolVersion: 8,
        jobID: authorityRaceID(1),
        checkpointRevision: 3,
        roundID: authorityRaceID(2),
        corpusManifestSHA256: authorityRaceDigest(1),
        evidenceFrontierSHA256: authorityRaceDigest(2),
        registryManifestSHA256: Phase2ReconstructionProtocolArtifacts.make()
            .toolRegistry.identity.sha256,
        context: .init(
            canonicalBytes: Data(#"{"records":[]}"#.utf8),
            canonicalSHA256: "1b8b4c0b6f6ad1d32565952720bc004eeb1f188f62045e4d5525ae2af8c78432",
            evidenceIDs: [],
            allowedGapSubjects: [],
            allowedGapCategories: [],
            allowedGapIDs: []
        ),
        handles: [.init(
            handleID: authorityRaceID(10),
            operationID: .corpusSummary
        )]
    )
}

private func authorityRaceID(_ value: Int) -> UUID {
    UUID(uuidString: String(
        format: "70000000-0000-4000-8000-%012d",
        value
    ))!
}

private func authorityRaceDigest(_ value: Int) -> String {
    String(format: "%064x", value)
}

private func authorityRaceBatchAuthority(
    jobID: UUID
) throws -> ReconstructionBatchAuthority {
    try .init(
        jobID: jobID,
        checkpointID: authorityRaceID(203),
        checkpointRevision: 7,
        corpusManifestSHA256: authorityRaceDigest(203)
    )
}

private func authorityRaceBatchTask(
    jobID: UUID
) throws -> ReconstructionTaskRecord {
    .init(
        identity: try .init(
            taskID: authorityRaceID(204),
            jobID: jobID,
            kind: .ingest,
            subject: nil,
            dependencyTaskIDs: [],
            operationContractIdentity: "reconstruction.ingest.v1",
            canonicalSHA256: authorityRaceDigest(204)
        ),
        state: .pending,
        diagnostic: nil
    )
}

private actor AuthorityRaceStressCompositeBatchExecutor:
    ReconstructionBatchTaskExecuting
{
    private let pool: ReconstructionAnalysisProviderPool
    private let returnsStaleRevision: Bool
    private(set) var operationCount = 0

    init(
        pool: ReconstructionAnalysisProviderPool,
        returnsStaleRevision: Bool = false
    ) {
        self.pool = pool
        self.returnsStaleRevision = returnsStaleRevision
    }

    func execute(
        task: ReconstructionTaskRecord,
        authority: ReconstructionBatchAuthority,
        cancellation: ReconstructionCancellation
    ) async -> ReconstructionTerminalTaskResult {
        do {
            try cancellation.check()
            try await pool.withProvider { _ in
                try cancellation.check()
            }
            operationCount += 1
            return .init(
                jobID: authority.jobID,
                taskID: task.identity.taskID,
                checkpointID: authority.checkpointID,
                checkpointRevision: returnsStaleRevision
                    ? authority.checkpointRevision + 1
                    : authority.checkpointRevision,
                corpusManifestSHA256: authority.corpusManifestSHA256,
                outcome: .completed
            )
        } catch {
            return .init(
                jobID: authority.jobID,
                taskID: task.identity.taskID,
                checkpointID: authority.checkpointID,
                checkpointRevision: authority.checkpointRevision,
                corpusManifestSHA256: authority.corpusManifestSHA256,
                outcome: .cancelled
            )
        }
    }

    func pause() async { await pool.pause() }
    func resume() async { await pool.resume() }
    func retire() async { await pool.retire() }
}

private final class AuthorityRaceStressProviderFactory:
    ReconstructionAnalysisProviderFactory,
    @unchecked Sendable
{
    func makeProvider() -> any AnalysisProviding {
        AuthorityRaceStressUnusedProvider()
    }
}

private struct AuthorityRaceStressUnusedProvider: AnalysisProviding {
    func analyze(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) throws -> WorkspaceSnapshot {
        fatalError("authority stress never invokes provider analysis")
    }

    func openBinary(
        url: URL,
        requestedSliceIndex: Int?,
        overrides: [UInt64: AddressOverride],
        cancellation: AnalysisCancellationToken
    ) async throws -> WorkspaceSnapshot {
        fatalError("authority stress never invokes provider analysis")
    }
}

private func waitForAuthorityRace(
    _ predicate: @Sendable @escaping () async -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    for _ in 0..<200_000 {
        if await predicate() { return }
        await Task.yield()
    }
    XCTFail("authority race condition did not settle", file: file, line: line)
}
