import Foundation
import XCTest
@testable import MacScope

@MainActor
final class DebuggerPersistentLLDBExactLaunchTransactionTests: XCTestCase {
    private let epoch = DebuggerSessionEpoch(
        rawValue: UUID(uuidString: "DADADADA-DADA-DADA-DADA-DADADADADADA")!
    )

    func testExactLaunchStagesOneCommandPerRequestAndPublishesOnlySealedAuthority() async throws {
        let plan = try await makePlan(path: "/bin/echo")
        let identity = processIdentity(processID: 701, seal: plan.executableSeal)
        let evidence = authorizationEvidence(identity: identity)
        let observer = ExactLaunchEvidenceProvider(resolutions: [
            .resolved(evidence),
            .resolved(evidence),
        ])
        let executor = ExactLaunchExecutor(steps: successfulSteps(
            plan: plan,
            generation: 9,
            processID: identity.processID,
            finalState: .stopped(processID: identity.processID)
        ))
        let coordinator = makeCoordinator(executor: executor, observer: observer)
        let initial = await coordinator.reducerState

        let result = try await coordinator.performExactLaunchTransaction(
            PersistentLLDBExactLaunchTransactionInput(
                plan: plan,
                expectedSession: initial.sessionCoordinate,
                adapterGeneration: 9
            )
        )

        let authority = DebuggerSessionTargetAuthority(
            origin: .launched(DebuggerLaunchTargetAuthority(identity: identity))
        )
        XCTAssertEqual(result.authority, authority)
        XCTAssertEqual(result.reducerState.acceptedTargetAuthority, authority)
        XCTAssertEqual(result.reducerState.observedProcessID, identity.processID)
        XCTAssertEqual(
            result.reducerState.processPhase,
            .stopped(processID: identity.processID, reason: .unknown("launch stop-at-entry"))
        )
        XCTAssertEqual(result.reducerState.targetDisposition, .stopped(processID: identity.processID))
        XCTAssertNil(result.reducerState.pendingRequest)
        XCTAssertEqual(result.reducerState.lastAcceptedEventSequence.rawValue, 4)
        XCTAssertEqual(result.requestID.epoch, epoch)
        XCTAssertEqual(
            result.requestID.sequence,
            result.reducerState.lastAdmittedRequestSequence
        )

        let execution = PersistentLLDBProductionController.exactLaunchExecutionResult(result)
        XCTAssertEqual(execution.requestID, result.requestID)
        XCTAssertEqual(execution.reducerState, result.reducerState)
        let projected = DebuggerTransportSnapshotProjector.project(
            execution.reducerState,
            executableName: plan.normalizedDisplayName
        )
        XCTAssertEqual(projected.transportTargetAuthority, authority)
        XCTAssertEqual(
            projected.processState,
            .paused(processID: identity.processID, reason: .unknown("launch stop-at-entry"))
        )
        XCTAssertNil(projected.lastCommandRun)

        let requests = await executor.requests
        XCTAssertEqual(requests.count, plan.semanticCommands.count)
        XCTAssertEqual(requests.map(\.semanticCommands), plan.semanticCommands.map { [$0] })
        XCTAssertTrue(requests.allSatisfy { $0.context.operation == .launch })
        XCTAssertTrue(requests.allSatisfy { $0.context.targetAuthority == nil })
        XCTAssertTrue(requests.dropLast().allSatisfy { $0.observedPIDRequirement == .optional })
        XCTAssertEqual(requests.last?.observedPIDRequirement, .required)
        XCTAssertEqual(requests.last?.context.id.sequence, UInt64(plan.semanticCommands.count))
        let observedProcessIDs = await observer.observedProcessIDs
        XCTAssertEqual(observedProcessIDs, [identity.processID, identity.processID])
    }

    func testCallerCancellationCannotShortCircuitTwoAuthorizationObservations() async throws {
        let plan = try await makePlan(path: "/bin/echo")
        let identity = processIdentity(processID: 702, seal: plan.executableSeal)
        let observer = SuspendedExactLaunchEvidenceProvider(
            evidence: authorizationEvidence(identity: identity)
        )
        let executor = ExactLaunchExecutor(steps: successfulSteps(
            plan: plan,
            generation: 11,
            processID: identity.processID,
            finalState: .stopped(processID: identity.processID)
        ))
        let coordinator = makeCoordinator(executor: executor, observer: observer)
        let initial = await coordinator.reducerState

        let task = Task {
            try await coordinator.performExactLaunchTransaction(
                PersistentLLDBExactLaunchTransactionInput(
                    plan: plan,
                    expectedSession: initial.sessionCoordinate,
                    adapterGeneration: 11
                )
            )
        }
        await observer.waitUntilFirstObservationStarts()
        task.cancel()

        let whileObserving = await coordinator.reducerState
        XCTAssertEqual(whileObserving.pendingRequest?.context.operation, .launch)
        XCTAssertEqual(whileObserving.pendingRequest?.context.id.sequence, UInt64(plan.semanticCommands.count))
        XCTAssertEqual(whileObserving.pendingRequest?.hasStarted, true)
        XCTAssertNil(whileObserving.pendingRequest?.context.targetAuthority)
        XCTAssertNil(whileObserving.acceptedTargetAuthority)
        XCTAssertEqual(whileObserving.processPhase, .noTarget)

        await observer.resumeFirstObservation()
        let result = try await task.value
        XCTAssertEqual(
            result.requestID.sequence,
            UInt64(plan.semanticCommands.count)
        )
        XCTAssertEqual(result.requestID.epoch, epoch)
        XCTAssertEqual(result.reducerState.lastAcceptedEventSequence.rawValue, 4)
        XCTAssertNil(result.reducerState.pendingRequest)
        let observationCount = await observer.observationCount
        let cancellationStates = await observer.cancellationStates
        XCTAssertEqual(observationCount, 2)
        XCTAssertEqual(cancellationStates, [false, false])
    }

    func testExactLaunchRejectsContradictoryFinalStateWithoutIdentityObservation() async throws {
        let plan = try await makePlan(path: "/bin/echo")
        let observer = ExactLaunchEvidenceProvider(resolutions: [])
        let executor = ExactLaunchExecutor(steps: successfulSteps(
            plan: plan,
            generation: 13,
            processID: 703,
            finalState: .running(processID: 703)
        ))
        let coordinator = makeCoordinator(executor: executor, observer: observer)
        let initial = await coordinator.reducerState

        do {
            _ = try await coordinator.performExactLaunchTransaction(
                PersistentLLDBExactLaunchTransactionInput(
                    plan: plan,
                    expectedSession: initial.sessionCoordinate,
                    adapterGeneration: 13
                )
            )
            XCTFail("Expected a non-stopped launch observation to fail closed.")
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            XCTAssertEqual(failure.code, .invalidObservedProcess)
        }

        let observedProcessIDs = await observer.observedProcessIDs
        let requests = await executor.requests
        XCTAssertEqual(observedProcessIDs, [])
        XCTAssertEqual(requests.count, plan.semanticCommands.count)
        let state = await coordinator.reducerState
        XCTAssertTrue(state.isInvalidated)
        XCTAssertEqual(state.processPhase, .invalidated)
        XCTAssertEqual(state.targetDisposition, .unknown)
        XCTAssertNil(state.acceptedTargetAuthority)
    }

    func testExactLaunchFailsClosedWhenObservedIdentityDiffersFromFrozenExecutableSeal() async throws {
        let plan = try await makePlan(path: "/bin/echo")
        let exact = processIdentity(processID: 704, seal: plan.executableSeal)
        let drifted = processIdentity(
            processID: 704,
            seal: plan.executableSeal,
            sha256: String(repeating: "c", count: 64)
        )
        let observer = ExactLaunchEvidenceProvider(resolutions: [
            .resolved(authorizationEvidence(identity: exact)),
            .resolved(authorizationEvidence(identity: drifted)),
        ])
        let executor = ExactLaunchExecutor(steps: successfulSteps(
            plan: plan,
            generation: 15,
            processID: exact.processID,
            finalState: .stopped(processID: exact.processID)
        ))
        let coordinator = makeCoordinator(executor: executor, observer: observer)
        let initial = await coordinator.reducerState

        do {
            _ = try await coordinator.performExactLaunchTransaction(
                PersistentLLDBExactLaunchTransactionInput(
                    plan: plan,
                    expectedSession: initial.sessionCoordinate,
                    adapterGeneration: 15
                )
            )
            XCTFail("Expected identity drift to prevent authority publication.")
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            XCTAssertEqual(failure.code, .invalidObservedProcess)
        }

        let observedProcessIDs = await observer.observedProcessIDs
        XCTAssertEqual(observedProcessIDs, [exact.processID, exact.processID])
        let state = await coordinator.reducerState
        XCTAssertTrue(state.isInvalidated)
        XCTAssertNil(state.acceptedTargetAuthority)
        XCTAssertNil(state.observedProcessID)
    }

    func testStagingFailureBeforeFinalLaunchLeavesPristineNoTargetState() async throws {
        let plan = try await makePlan(path: "/bin/echo")
        let observer = ExactLaunchEvidenceProvider(resolutions: [])
        let executor = ExactLaunchExecutor(steps: [
            .failure(PersistentLLDBCLIAdapterFailure(
                code: .invalidRequest,
                requestID: DebuggerRequestID(epoch: epoch, sequence: 1),
                generation: 17,
                disposition: .failedBeforeWrite
            )),
        ])
        let coordinator = makeCoordinator(executor: executor, observer: observer)
        let initial = await coordinator.reducerState

        do {
            _ = try await coordinator.performExactLaunchTransaction(
                PersistentLLDBExactLaunchTransactionInput(
                    plan: plan,
                    expectedSession: initial.sessionCoordinate,
                    adapterGeneration: 17
                )
            )
            XCTFail("Expected a staging before-write adapter failure.")
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            XCTAssertEqual(failure.code, .adapterFailedBeforeWrite)
        }

        let observedProcessIDs = await observer.observedProcessIDs
        XCTAssertEqual(observedProcessIDs, [])
        let state = await coordinator.reducerState
        XCTAssertEqual(state.processPhase, .noTarget)
        XCTAssertEqual(state.targetDisposition, .notStarted)
        XCTAssertNil(state.pendingRequest)
        XCTAssertFalse(state.isInvalidated)
        XCTAssertNil(state.acceptedTargetAuthority)

        do {
            _ = try await coordinator.performExactLaunchTransaction(
                PersistentLLDBExactLaunchTransactionInput(
                    plan: plan,
                    expectedSession: state.sessionCoordinate,
                    adapterGeneration: 17
                )
            )
            XCTFail("Expected the consumed plan to reject retry after staging failure.")
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            XCTAssertEqual(failure.code, .admissionRejected)
        }
        let requests = await executor.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testCopiedPlanTicketAllowsExactlyOneConcurrentCoordinatorToExecute() async throws {
        let plan = try await makePlan(path: "/bin/echo")
        let copiedPlan = plan
        let identity = processIdentity(processID: 705, seal: plan.executableSeal)
        let evidence = authorizationEvidence(identity: identity)
        let firstObserver = ExactLaunchEvidenceProvider(resolutions: [
            .resolved(evidence), .resolved(evidence),
        ])
        let secondObserver = ExactLaunchEvidenceProvider(resolutions: [
            .resolved(evidence), .resolved(evidence),
        ])
        let firstExecutor = ExactLaunchExecutor(steps: successfulSteps(
            plan: plan,
            generation: 19,
            processID: identity.processID,
            finalState: .stopped(processID: identity.processID)
        ))
        let secondExecutor = ExactLaunchExecutor(steps: successfulSteps(
            plan: plan,
            generation: 19,
            processID: identity.processID,
            finalState: .stopped(processID: identity.processID)
        ))
        let firstCoordinator = makeCoordinator(executor: firstExecutor, observer: firstObserver)
        let secondCoordinator = makeCoordinator(executor: secondExecutor, observer: secondObserver)
        let firstState = await firstCoordinator.reducerState
        let secondState = await secondCoordinator.reducerState

        let firstTask = Task {
            await launchFailureCode(
                coordinator: firstCoordinator,
                plan: plan,
                session: firstState.sessionCoordinate,
                generation: 19
            )
        }
        let secondTask = Task {
            await launchFailureCode(
                coordinator: secondCoordinator,
                plan: copiedPlan,
                session: secondState.sessionCoordinate,
                generation: 19
            )
        }
        let firstOutcome = await firstTask.value
        let secondOutcome = await secondTask.value
        let outcomes = [firstOutcome, secondOutcome]

        XCTAssertEqual(outcomes.compactMap { $0 }, [.admissionRejected])
        XCTAssertEqual(outcomes.filter { $0 == nil }.count, 1)
        let firstRequests = await firstExecutor.requests
        let secondRequests = await secondExecutor.requests
        XCTAssertEqual(
            firstRequests.count + secondRequests.count,
            plan.semanticCommands.count
        )
    }

    func testFinalAdapterDispositionPreservesTruthfulStartedOrdering() async throws {
        let cases: [(
            DebuggerRequestDisposition,
            PersistentLLDBSessionCoordinatorFailureCode,
            Bool,
            UInt64
        )] = [
            (.cancelledBeforeWrite, .adapterCancelled, false, 1),
            (.failedBeforeWrite, .adapterFailedBeforeWrite, false, 1),
            (
                .invalidatedAfterWrite(reason: .timeoutAfterWrite, target: .unknown),
                .adapterInvalidated,
                true,
                2
            ),
            (.completed(target: .unknown), .adapterInvalidated, true, 2),
        ]

        for (offset, item) in cases.enumerated() {
            let (disposition, expectedCode, expectedInvalidated, expectedEvents) = item
            let generation = UInt64(30 + offset)
            let plan = try await makePlan(path: "/bin/echo")
            let observer = ExactLaunchEvidenceProvider(resolutions: [])
            let executor = ExactLaunchExecutor(steps: finalFailureSteps(
                plan: plan,
                generation: generation,
                disposition: disposition
            ))
            let coordinator = makeCoordinator(executor: executor, observer: observer)
            let initial = await coordinator.reducerState

            let failureCode = await launchFailureCode(
                coordinator: coordinator,
                plan: plan,
                session: initial.sessionCoordinate,
                generation: generation
            )
            XCTAssertEqual(failureCode, expectedCode)
            let state = await coordinator.reducerState
            XCTAssertEqual(state.isInvalidated, expectedInvalidated)
            XCTAssertEqual(state.lastAcceptedEventSequence.rawValue, expectedEvents)
            XCTAssertNil(state.pendingRequest)
            XCTAssertNil(state.acceptedTargetAuthority)
            if expectedInvalidated {
                XCTAssertEqual(state.processPhase, .invalidated)
                XCTAssertEqual(state.targetDisposition, .unknown)
            } else {
                XCTAssertEqual(state.processPhase, .noTarget)
                XCTAssertEqual(state.targetDisposition, .notStarted)
            }
        }
    }

    func testUnexpectedStagingPIDInvalidatesWithoutDispatchingFinalLaunch() async throws {
        let plan = try await makePlan(path: "/bin/echo")
        let observer = ExactLaunchEvidenceProvider(resolutions: [])
        let executor = ExactLaunchExecutor(steps: [
            .response(response(
                sequence: 1,
                generation: 41,
                processID: 706,
                state: .stopped(processID: 706)
            )),
        ])
        let coordinator = makeCoordinator(executor: executor, observer: observer)
        let initial = await coordinator.reducerState

        let failureCode = await launchFailureCode(
            coordinator: coordinator,
            plan: plan,
            session: initial.sessionCoordinate,
            generation: 41
        )

        XCTAssertEqual(failureCode, .invalidObservedProcess)
        let requests = await executor.requests
        XCTAssertEqual(requests.count, 1)
        let state = await coordinator.reducerState
        XCTAssertTrue(state.isInvalidated)
        XCTAssertNil(state.acceptedTargetAuthority)
    }

    func testWrongFinalFailureCorrelationMarksStartedThenInvalidates() async throws {
        let plan = try await makePlan(path: "/bin/echo")
        let generation: UInt64 = 43
        let staging = plan.semanticCommands.indices.dropLast().map { offset in
            ExactLaunchExecutor.Step.response(response(
                sequence: UInt64(offset + 1),
                generation: generation,
                processID: nil,
                state: nil
            ))
        }
        let executor = ExactLaunchExecutor(steps: staging + [
            .failure(PersistentLLDBCLIAdapterFailure(
                code: .invalidRequest,
                requestID: DebuggerRequestID(
                    epoch: epoch,
                    sequence: UInt64(plan.semanticCommands.count + 1)
                ),
                generation: generation,
                disposition: .failedBeforeWrite
            )),
        ])
        let observer = ExactLaunchEvidenceProvider(resolutions: [])
        let coordinator = makeCoordinator(executor: executor, observer: observer)
        let initial = await coordinator.reducerState

        let failureCode = await launchFailureCode(
            coordinator: coordinator,
            plan: plan,
            session: initial.sessionCoordinate,
            generation: generation
        )

        XCTAssertEqual(failureCode, .adapterInvalidated)
        let state = await coordinator.reducerState
        XCTAssertTrue(state.isInvalidated)
        XCTAssertEqual(state.lastAcceptedEventSequence.rawValue, 2)
        XCTAssertEqual(state.processPhase, .invalidated)
        XCTAssertEqual(state.targetDisposition, .unknown)
    }

    private func makeCoordinator(
        executor: ExactLaunchExecutor,
        observer: any DebuggerLocalProcessEvidenceProviding
    ) -> PersistentLLDBSessionCoordinator {
        PersistentLLDBSessionCoordinator(
            epoch: epoch,
            executor: executor,
            requestPreparer: ExactLaunchUnusedPreparer(),
            launchedProcessEvidenceProvider: observer
        )
    }

    private func launchFailureCode(
        coordinator: PersistentLLDBSessionCoordinator,
        plan: DebuggerLLDBSealedLaunchPlan,
        session: DebuggerSessionCoordinate,
        generation: UInt64
    ) async -> PersistentLLDBSessionCoordinatorFailureCode? {
        do {
            _ = try await coordinator.performExactLaunchTransaction(
                PersistentLLDBExactLaunchTransactionInput(
                    plan: plan,
                    expectedSession: session,
                    adapterGeneration: generation
                )
            )
            return nil
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            return failure.code
        } catch {
            XCTFail("Unexpected exact launch error: \(error)")
            return .requestPreparationFailed
        }
    }

    private func successfulSteps(
        plan: DebuggerLLDBSealedLaunchPlan,
        generation: UInt64,
        processID: Int32,
        finalState: LLDBCLIObservedProcessState
    ) -> [ExactLaunchExecutor.Step] {
        plan.semanticCommands.indices.map { offset in
            let isFinal = offset == plan.semanticCommands.count - 1
            return .response(response(
                sequence: UInt64(offset + 1),
                generation: generation,
                processID: isFinal ? processID : nil,
                state: isFinal ? finalState : nil
            ))
        }
    }

    private func finalFailureSteps(
        plan: DebuggerLLDBSealedLaunchPlan,
        generation: UInt64,
        disposition: DebuggerRequestDisposition
    ) -> [ExactLaunchExecutor.Step] {
        let staging = plan.semanticCommands.indices.dropLast().map { offset in
            ExactLaunchExecutor.Step.response(response(
                sequence: UInt64(offset + 1),
                generation: generation,
                processID: nil,
                state: nil
            ))
        }
        return staging + [
            .failure(PersistentLLDBCLIAdapterFailure(
                code: .invalidRequest,
                requestID: DebuggerRequestID(
                    epoch: epoch,
                    sequence: UInt64(plan.semanticCommands.count)
                ),
                generation: generation,
                disposition: disposition
            )),
        ]
    }

    private func response(
        sequence: UInt64,
        generation: UInt64,
        processID: Int32?,
        state: LLDBCLIObservedProcessState?
    ) -> PersistentLLDBCLIResponse {
        PersistentLLDBCLIResponse(
            requestID: DebuggerRequestID(epoch: epoch, sequence: sequence),
            generation: generation,
            transcript: LLDBCLITranscriptResult(
                transcript: "bounded launch",
                authoritativeStatusTranscript: processID.map { "Process \($0) stopped" } ?? "",
                observedProcessID: processID,
                observedProcessState: state,
                exchangeByteCount: 64,
                exchangeSHA256: String(repeating: "a", count: 64),
                semanticCommandsSucceeded: true,
                firstFailedSemanticCommandIndex: nil,
                semanticCommandTranscripts: [""],
                semanticCommandResultLineByteCounts: [1]
            )
        )
    }

    private func makePlan(path: String) async throws -> DebuggerLLDBSealedLaunchPlan {
        let developerDirectory = "/Applications/Xcode-beta.app/Contents/Developer"
        let configuration = DebuggerLaunchConfiguration(executablePath: path)
        let canonicalExecutablePath = try DebuggerLLDBSealedLaunchPlan
            .prepareCanonicalExecutablePath(configuration: configuration)
        let grant = try await DebuggerExecutableSealer.seal(
            canonicalExecutablePath: canonicalExecutablePath,
            timeout: .seconds(3)
        )
        return try DebuggerLLDBSealedLaunchPlan.make(
            configuration: configuration,
            executableSealingGrant: grant,
            toolchain: DebuggerLLDBToolchain(
                executablePath: developerDirectory + "/usr/bin/lldb",
                developerDirectory: developerDirectory,
                discoverySource: "test",
                candidatePaths: []
            ),
            environment: [:],
            fallbackWorkingDirectory: "/tmp",
            timeout: .seconds(3)
        )
    }

    private func processIdentity(
        processID: Int32,
        seal: DebuggerImportedExecutableSeal,
        sha256: String? = nil
    ) -> DebuggerLocalProcessIdentity {
        DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: DebuggerProcessStartIdentity(seconds: 90_001, microseconds: 71)!,
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: seal.canonicalPath,
            executableDeviceID: seal.deviceID,
            executableFileID: seal.fileID,
            executableByteCount: seal.byteCount,
            executableSHA256: sha256 ?? seal.sha256,
            architecture: seal.architecture == .arm64 ? .arm64 : .arm64e,
            machOUUID: seal.machOUUID,
            codeIdentity: nil
        )!
    }

    private func authorizationEvidence(
        identity: DebuggerLocalProcessIdentity
    ) -> DebuggerLocalProcessAuthorizationEvidence {
        let fingerprint = DebuggerLocalProcessCatalogFingerprint(
            processID: identity.processID,
            startTime: identity.startTime,
            realUserID: identity.realUserID,
            effectiveUserID: identity.effectiveUserID,
            canonicalExecutablePath: identity.canonicalExecutablePath,
            executableDeviceID: identity.executableDeviceID,
            executableFileID: identity.executableFileID,
            executableByteCount: identity.executableByteCount,
            executableChangeTimeNanoseconds: 1,
            architecture: identity.architecture,
            machOUUID: identity.machOUUID,
            codeIdentity: identity.codeIdentity
        )!
        return DebuggerLocalProcessAuthorizationEvidence(
            catalogEvidence: DebuggerLocalProcessCatalogEvidence(
                fingerprint: fingerprint,
                displayName: URL(fileURLWithPath: identity.canonicalExecutablePath)
                    .lastPathComponent,
                parentProcessID: 1,
                savedUserID: identity.realUserID,
                dynamicState: DebuggerLocalProcessDynamicState(isTraced: true)
            ),
            identity: identity
        )
    }
}

private actor ExactLaunchExecutor: PersistentLLDBCLIExecuting {
    enum Step: Sendable {
        case response(PersistentLLDBCLIResponse)
        case failure(PersistentLLDBCLIAdapterFailure)
    }

    private var steps: [Step]
    private(set) var requests: [PersistentLLDBCLIRequest] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func execute(_ request: PersistentLLDBCLIRequest) async throws -> PersistentLLDBCLIResponse {
        requests.append(request)
        guard !steps.isEmpty else { throw ExactLaunchTestError.unexpectedExecution }
        switch steps.removeFirst() {
        case .response(let response):
            return response
        case .failure(let failure):
            throw failure
        }
    }
}

private actor ExactLaunchEvidenceProvider: DebuggerLocalProcessEvidenceProviding {
    private var resolutions: [
        DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence>
    ]
    private(set) var observedProcessIDs: [Int32] = []

    init(resolutions: [
        DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence>
    ]) {
        self.resolutions = resolutions
    }

    func processIDs() async -> DebuggerLocalProcessResolution<[Int32]> {
        .unknown(.adapterProtocolFailure)
    }

    func catalogEvidence(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogEvidence> {
        .unknown(.adapterProtocolFailure)
    }

    func authorizationEvidence(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence> {
        observedProcessIDs.append(processID)
        guard !resolutions.isEmpty else { return .unknown(.adapterProtocolFailure) }
        return resolutions.removeFirst()
    }
}

private actor SuspendedExactLaunchEvidenceProvider: DebuggerLocalProcessEvidenceProviding {
    private let evidence: DebuggerLocalProcessAuthorizationEvidence
    private var firstObservationStarted = false
    private var firstObservationWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstObservationContinuation: CheckedContinuation<Void, Never>?
    private(set) var observationCount = 0
    private(set) var cancellationStates: [Bool] = []

    init(evidence: DebuggerLocalProcessAuthorizationEvidence) {
        self.evidence = evidence
    }

    func waitUntilFirstObservationStarts() async {
        guard !firstObservationStarted else { return }
        await withCheckedContinuation { firstObservationWaiters.append($0) }
    }

    func resumeFirstObservation() {
        firstObservationContinuation?.resume()
        firstObservationContinuation = nil
    }

    func processIDs() async -> DebuggerLocalProcessResolution<[Int32]> {
        .unknown(.adapterProtocolFailure)
    }

    func catalogEvidence(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessCatalogEvidence> {
        .unknown(.adapterProtocolFailure)
    }

    func authorizationEvidence(
        processID: Int32
    ) async -> DebuggerLocalProcessResolution<DebuggerLocalProcessAuthorizationEvidence> {
        observationCount += 1
        cancellationStates.append(Task.isCancelled)
        if observationCount == 1 {
            firstObservationStarted = true
            let waiters = firstObservationWaiters
            firstObservationWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { firstObservationContinuation = $0 }
        }
        return .resolved(evidence)
    }
}

private actor ExactLaunchUnusedPreparer: PersistentLLDBCLIRequestPreparing {
    func prepareRequest(for context: DebuggerRequestContext) async throws
        -> PersistentLLDBCLIRequest {
        throw ExactLaunchTestError.unexpectedPreparation
    }
}

private enum ExactLaunchTestError: Error {
    case unexpectedExecution
    case unexpectedPreparation
}
