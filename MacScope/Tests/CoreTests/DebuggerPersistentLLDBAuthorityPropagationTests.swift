import XCTest
@testable import MacScope

final class DebuggerPersistentLLDBAuthorityPropagationTests: XCTestCase {
    private let epoch = DebuggerSessionEpoch(
        rawValue: UUID(uuidString: "A0A0A0A0-A0A0-A0A0-A0A0-A0A0A0A0A0A0")!
    )

    func testGenericAttachCannotExecuteEvenWhenTransportCapabilityIsEnabled() async throws {
        let executor = AuthorityPropagationExecutor(responses: [])
        let preparer = AuthorityPropagationPreparer()
        let coordinator = makeCoordinator(
            executor: executor,
            preparer: preparer,
            capabilities: allOperationsEnabledCapabilities()
        )
        let initial = await coordinator.reducerState

        do {
            _ = try await coordinator.perform(
                .attach,
                expectedSession: initial.sessionCoordinate,
                requiredStop: nil
            )
            XCTFail("Expected generic attach to fail before preparation or execution.")
        } catch let failure as PersistentLLDBSessionCoordinatorFailure {
            XCTAssertEqual(failure.code, .admissionRejected)
            XCTAssertEqual(failure.reducerRejection, .missingTargetAuthority)
        }

        let executionCount = await executor.executionCount
        let preparationCount = await preparer.preparationCount
        let finalState = await coordinator.reducerState
        XCTAssertEqual(executionCount, 0)
        XCTAssertEqual(preparationCount, 0)
        XCTAssertEqual(finalState, initial)
    }

    func testLegacyLaunchAndOrdinaryOperationKeepNilAuthority() async throws {
        let executor = AuthorityPropagationExecutor(responses: [
            response(sequence: 1, processID: 611, state: .stopped(processID: 611)),
            response(sequence: 2, processID: 611, state: .stopped(processID: 611)),
        ])
        let coordinator = makeCoordinator(executor: executor)
        let initial = await coordinator.reducerState

        let launched = try await coordinator.perform(
            .launch,
            expectedSession: initial.sessionCoordinate,
            requiredStop: nil
        )
        _ = try await coordinator.perform(
            .pollProcessStatus,
            expectedSession: launched.reducerState.sessionCoordinate,
            requiredStop: nil
        )

        let contexts = await executor.contexts
        XCTAssertEqual(contexts.count, 2)
        XCTAssertTrue(contexts.allSatisfy { $0.targetAuthority == nil })
        XCTAssertNil(launched.reducerState.acceptedTargetAuthority)
    }

    func testProjectionUsesOnlyAcceptedReducerAuthorityForEveryOrdinaryOperation() throws {
        for authority in [
            launchedAuthority(try identity(processID: 719)),
            attachedAuthority(try identity(processID: 720)),
        ] {
            var state = reducerState()
            state.acceptedTargetAuthority = authority
            state.observedProcessID = authority.processID

            for operation in DebuggerOperation.allCases {
                let projected = PersistentLLDBSessionCoordinator.sessionScopedTargetAuthority(
                    for: operation,
                    reducerState: state
                )
                if operation.classification == .sessionEstablishing {
                    XCTAssertNil(projected, "Generic \(operation) must not receive authority.")
                } else {
                    XCTAssertEqual(projected, authority, "Lost authority for \(operation).")
                }
            }
        }
    }

    func testProjectionCannotInventAuthorityForLegacyOrMissingState() {
        let state = reducerState()

        for operation in DebuggerOperation.allCases {
            XCTAssertNil(
                PersistentLLDBSessionCoordinator.sessionScopedTargetAuthority(
                    for: operation,
                    reducerState: state
                )
            )
        }
    }

    private func makeCoordinator(
        executor: AuthorityPropagationExecutor,
        preparer: AuthorityPropagationPreparer = AuthorityPropagationPreparer(),
        capabilities: DebuggerTransportCapabilities = .persistentCLI(
            attachPolicyReason: "Attach remains disabled on the generic coordinator path."
        )
    ) -> PersistentLLDBSessionCoordinator {
        PersistentLLDBSessionCoordinator(
            epoch: epoch,
            executor: executor,
            requestPreparer: preparer,
            capabilities: capabilities
        )
    }

    private func reducerState() -> DebuggerReducerState {
        DebuggerReducerState(
            epoch: epoch,
            capabilities: allOperationsEnabledCapabilities()
        )
    }

    private func allOperationsEnabledCapabilities() -> DebuggerTransportCapabilities {
        DebuggerTransportCapabilities(
            operationStates: Dictionary(
                uniqueKeysWithValues: DebuggerOperation.allCases.map {
                    ($0, DebuggerOperationCapability.supportedAndObserved)
                }
            ),
            mechanics: .persistentCLI
        )
    }

    private func response(
        sequence: UInt64,
        processID: Int32,
        state: LLDBCLIObservedProcessState
    ) -> PersistentLLDBCLIResponse {
        PersistentLLDBCLIResponse(
            requestID: DebuggerRequestID(epoch: epoch, sequence: sequence),
            generation: 1,
            transcript: LLDBCLITranscriptResult(
                transcript: "bounded console",
                authoritativeStatusTranscript: "bounded status",
                observedProcessID: processID,
                observedProcessState: state,
                exchangeByteCount: 1,
                exchangeSHA256: String(repeating: "a", count: 64)
            )
        )
    }

    private func identity(processID: Int32) throws -> DebuggerLocalProcessIdentity {
        try XCTUnwrap(DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: DebuggerProcessStartIdentity(seconds: 9_000_001, microseconds: 17)!,
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/tmp/MacScopeAuthorityPropagationFixture",
            executableDeviceID: 7,
            executableFileID: 7_001,
            executableByteCount: 4_096,
            executableSHA256: String(repeating: "a", count: 64),
            architecture: .arm64,
            machOUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555"),
            codeIdentity: nil
        ))
    }

    private func launchedAuthority(
        _ identity: DebuggerLocalProcessIdentity
    ) -> DebuggerSessionTargetAuthority {
        DebuggerSessionTargetAuthority(
            origin: .launched(DebuggerLaunchTargetAuthority(identity: identity))
        )
    }

    private func attachedAuthority(
        _ identity: DebuggerLocalProcessIdentity
    ) -> DebuggerSessionTargetAuthority {
        DebuggerSessionTargetAuthority(origin: .attached(identity))
    }
}

private actor AuthorityPropagationExecutor: PersistentLLDBCLIExecuting {
    private var responses: [PersistentLLDBCLIResponse]
    private(set) var contexts: [DebuggerRequestContext] = []

    init(responses: [PersistentLLDBCLIResponse]) {
        self.responses = responses
    }

    var executionCount: Int { contexts.count }

    func execute(_ request: PersistentLLDBCLIRequest) async throws -> PersistentLLDBCLIResponse {
        contexts.append(request.context)
        guard !responses.isEmpty else { throw AuthorityPropagationTestError.unexpectedExecution }
        return responses.removeFirst()
    }
}

private actor AuthorityPropagationPreparer: PersistentLLDBCLIRequestPreparing {
    private(set) var preparedContexts: [DebuggerRequestContext] = []

    var preparationCount: Int { preparedContexts.count }

    func prepareRequest(
        for context: DebuggerRequestContext
    ) async throws -> PersistentLLDBCLIRequest {
        preparedContexts.append(context)
        return try PersistentLLDBCLIRequest(
            context: context,
            semanticCommands: context.operation == .pollProcessStatus ? [] : ["script pass"],
            observedPIDRequirement: .required,
            timeout: .seconds(2)
        )
    }
}

private enum AuthorityPropagationTestError: Error {
    case unexpectedExecution
}
