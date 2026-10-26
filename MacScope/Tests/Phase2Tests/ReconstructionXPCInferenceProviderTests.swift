import XCTest

@testable import MacScope

final class ReconstructionXPCInferenceProviderTests: XCTestCase {
    func testFailureReasonSurvivesTerminalAuthorityAndConnectionIsRetired() async throws {
        let transport = TerminalReconstructionTransport(
            status: .failed,
            reason: .streamInactivityTimeout,
            semanticRequestAccepted: true
        )
        let provider = ReconstructionXPCInferenceProvider(transport: transport)
        do {
            _ = try await ReconstructionInferenceRunner().run(
                requestID: providerID(94), request: providerRoundRequest(), provider: provider
            )
            XCTFail("Expected provider timeout")
        } catch let failure as ReconstructionInferenceRunnerTerminalFailure {
            XCTAssertEqual(failure.failure, .retryableProviderFailure(.streamInactivityTimeout))
            XCTAssertEqual(failure.terminalReceipt.providerFailureReason, .streamInactivityTimeout)
        }
        let resetsBeforeFinish = await transport.resetCount
        XCTAssertEqual(resetsBeforeFinish, 0)
        await provider.finishRequest()
        let resetsAfterFinish = await transport.resetCount
        XCTAssertEqual(resetsAfterFinish, 1)
    }

    func testProviderAcceptsOrderedRoundEventsAndTerminalReceipt() async throws {
        let transport = ScriptedReconstructionTransport()
        let provider = ReconstructionXPCInferenceProvider(transport: transport)
        let request = providerRoundRequest()
        let probe = ReconstructionProviderEventProbe()

        let receipt = try await provider.runRound(
            requestID: providerID(90), request: request,
            emit: { await probe.append($0) }
        )

        let sequences = await probe.events.map(\.sequence)
        XCTAssertEqual(sequences, [1, 2, 3])
        XCTAssertEqual(receipt.requestID, providerID(90))
        XCTAssertEqual(receipt.jobID, request.jobID)
        XCTAssertEqual(receipt.checkpointRevision, request.checkpointRevision)
        XCTAssertEqual(receipt.roundID, request.roundID)
        XCTAssertEqual(receipt.status, .completed)
    }

    func testOrdinaryModeConsumesProviderControlsWithoutEmittingSemanticEvents() async throws {
        let provider = ReconstructionXPCInferenceProvider(
            transport: ReceiptBoundReconstructionTransport()
        )
        let request = providerRoundRequest()
        let probe = ReconstructionProviderEventProbe()

        let receipt = try await provider.runRound(
            requestID: providerID(89),
            request: request,
            emit: { await probe.append($0) }
        )

        let events = await probe.events
        XCTAssertEqual(events.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(receipt.status, .completed)
    }

    func testProviderPreservesFailedAndCancelledWorkerTerminalAuthority() async {
        let request = providerRoundRequest()
        let cases: [(Phase2AIWorkerTerminal.Status, ReconstructionReadyInferenceFailure)] = [
            (.failed, .retryableProviderFailure(.workerHandlerFailed)),
            (.cancelled, .retryableProviderFailure(nil)),
        ]
        for (offset, testCase) in cases.enumerated() {
            let provider = ReconstructionXPCInferenceProvider(
                transport: TerminalReconstructionTransport(
                    status: testCase.0,
                    semanticRequestAccepted: true
                )
            )
            let requestID = providerID(92 + offset)
            do {
                _ = try await ReconstructionInferenceRunner().run(
                    requestID: requestID,
                    request: request,
                    provider: provider
                )
                XCTFail(
                    "Expected a terminal-authorized "
                        + String(describing: testCase.0)
                        + " failure"
                )
            } catch let failure as ReconstructionInferenceRunnerTerminalFailure {
                XCTAssertEqual(failure.failure, testCase.1)
                XCTAssertEqual(failure.terminalReceipt.requestID, requestID)
                XCTAssertEqual(failure.terminalReceipt.jobID, request.jobID)
                XCTAssertEqual(
                    failure.terminalReceipt.checkpointRevision,
                    request.checkpointRevision
                )
                XCTAssertEqual(failure.terminalReceipt.roundID, request.roundID)
                XCTAssertEqual(
                    failure.terminalReceipt.status,
                    testCase.0 == .failed ? .failed : .cancelled
                )
            } catch {
                XCTFail("Expected terminal authority, got " + String(describing: error))
            }
        }
    }

    func testIgnoredRequestDataFailedAndCancelledTerminalsCannotMintRequestSemantics() async {
        let cases: [(
            Phase2AIWorkerTerminal.Status,
            Phase2AIWorkerTerminal.Reason?
        )] = [
            (.failed, .invalidRequest),
            (.cancelled, nil),
        ]
        for (offset, testCase) in cases.enumerated() {
            let provider = ReconstructionXPCInferenceProvider(
                transport: TerminalReconstructionTransport(
                    status: testCase.0,
                    reason: testCase.1
                )
            )
            do {
                _ = try await provider.runRound(
                    requestID: providerID(110 + offset),
                    request: providerRoundRequest(),
                    emit: { _ in }
                )
                XCTFail("An unaccepted worker terminal must not mint request semantics")
            } catch let error as ReconstructionXPCInferenceProviderError {
                guard case .terminalWithoutSemanticRequestAuthority(let terminal) = error else {
                    return XCTFail("Unexpected provider error: \(error)")
                }
                XCTAssertEqual(terminal.status, testCase.0)
                XCTAssertEqual(terminal.reason, testCase.1)
                XCTAssertFalse(terminal.semanticRequestAccepted)
            } catch {
                XCTFail("Expected the exact rejected terminal, got \(error)")
            }
        }
    }

    func testWrongTerminalProtocolBundleAndPhaseFailWithExactTerminalVisible() async {
        let cases: [(
            Phase2AIWorkerProductionProtocolBundle,
            Phase2AIWorkerWirePhase
        )] = [
            (Phase2AIWorkerProductionProtocol.assistantR4, .finalization),
            (Phase2AIWorkerProductionProtocol.reconstructionR1, .toolSelection),
        ]
        for (offset, testCase) in cases.enumerated() {
            let provider = ReconstructionXPCInferenceProvider(
                transport: TerminalReconstructionTransport(
                    status: .failed,
                    reason: .workerHandlerFailed,
                    protocolBundle: testCase.0,
                    phase: testCase.1,
                    semanticRequestAccepted: true
                )
            )
            do {
                _ = try await provider.runRound(
                    requestID: providerID(120 + offset),
                    request: providerRoundRequest(),
                    emit: { _ in }
                )
                XCTFail("A terminal from the wrong protocol authority must fail")
            } catch let error as AIAgentXPCTransportError {
                guard case .terminalProtocolMismatch(let terminal) = error else {
                    return XCTFail("Unexpected transport error: \(error)")
                }
                XCTAssertEqual(terminal.reason, .workerHandlerFailed)
                XCTAssertEqual(terminal.phase, testCase.1)
                XCTAssertEqual(
                    terminal.negotiatedProtocolManifestDigest,
                    testCase.0.manifestDigest
                )
            } catch {
                XCTFail("Expected exact protocol-terminal rejection, got \(error)")
            }
        }
    }

    func testTransportInterruptionCannotMintTerminalAuthority() async {
        let provider = ReconstructionXPCInferenceProvider(
            transport: InterruptedReconstructionTransport()
        )
        do {
            _ = try await ReconstructionInferenceRunner().run(
                requestID: providerID(94),
                request: providerRoundRequest(),
                provider: provider
            )
            XCTFail("Expected transport interruption")
        } catch let error as AIAgentXPCTransportError {
            XCTAssertEqual(error, .invalidated("simulated interruption"))
        } catch {
            XCTFail(
                "An interruption must not become a worker terminal: "
                    + String(describing: error)
            )
        }
    }

    func testProviderRelaysCancellationOnceAndRejectsLateEvents() async {
        let transport = BlockingReconstructionTransport()
        let provider = ReconstructionXPCInferenceProvider(transport: transport)
        let request = providerRoundRequest()
        let task = Task {
            try await provider.runRound(
                requestID: providerID(91), request: request, emit: { _ in }
            )
        }
        await transport.waitUntilStarted()
        task.cancel()
        _ = try? await task.value
        await provider.cancel(requestID: providerID(91))
        let cancellations = await transport.cancelledRequestIDs
        XCTAssertEqual(cancellations, [providerID(91)])
    }

    func testReceiptCapabilityBindsExactConnectionAndDispatchAndRevalidates() async throws {
        let transport = ReceiptBoundReconstructionTransport()
        let provider = ReconstructionXPCInferenceProvider(transport: transport)
        let workerReceipt = try await provider.prepareWorkerProcessReceipt()
        XCTAssertEqual(
            workerReceipt.protocolManifestDigest,
            Phase2AIWorkerProductionProtocol.reconstructionR1.manifestDigest
        )
        let connectionBound = await provider.bindProviderConnectionValidator(
            workerReceipt: workerReceipt,
            validator: { receipt in
                receipt.localAddress == "127.0.0.1"
                    && receipt.remoteAddress == "127.0.0.1"
            }
        )
        let dispatchBound = await provider.bindProviderDispatchValidator(
            workerReceipt: workerReceipt,
            validator: { $0.boundary == .httpResponseHeaders }
        )
        XCTAssertTrue(connectionBound)
        XCTAssertTrue(dispatchBound)

        let requestID = providerID(130)
        _ = try await provider.runRound(
            requestID: requestID,
            request: providerRoundRequest(),
            emit: { _ in }
        )

        let accepted = await provider.acceptedProviderConnectionReceipt(
            requestID: requestID,
            workerReceipt: workerReceipt
        )
        let remainsValid = await provider.revalidateWorkerProcessReceipt(workerReceipt)
        let revalidatedIdentity = await transport.revalidatedReceipt?.connectionIdentity
        XCTAssertTrue(accepted)
        XCTAssertTrue(remainsValid)
        XCTAssertEqual(revalidatedIdentity, workerReceipt.connectionIdentity)
    }

    func testReceiptCapabilityRejectsControlForAnotherRequest() async throws {
        let transport = ReceiptBoundReconstructionTransport(
            controlRequestID: providerID(141)
        )
        let provider = ReconstructionXPCInferenceProvider(transport: transport)
        let workerReceipt = try await provider.prepareWorkerProcessReceipt()
        let connectionBound = await provider.bindProviderConnectionValidator(
            workerReceipt: workerReceipt,
            validator: { _ in true }
        )
        let dispatchBound = await provider.bindProviderDispatchValidator(
            workerReceipt: workerReceipt,
            validator: { _ in true }
        )
        XCTAssertTrue(connectionBound)
        XCTAssertTrue(dispatchBound)

        do {
            _ = try await provider.runRound(
                requestID: providerID(140),
                request: providerRoundRequest(),
                emit: { _ in }
            )
            XCTFail("A control receipt from another request must fail closed")
        } catch let error as AIAgentXPCTransportError {
            XCTAssertEqual(error, .malformedReply)
        } catch {
            XCTFail("Expected exact control rejection, got \(error)")
        }
        let accepted = await provider.acceptedProviderConnectionReceipt(
            requestID: providerID(140),
            workerReceipt: workerReceipt
        )
        XCTAssertFalse(accepted)
    }

    func testTransportDefaultsRemainAssistantR4WhileReconstructionOptsIn() {
        XCTAssertEqual(
            NSXPCAIAgentTransport.defaultProtocolBundle,
            Phase2AIWorkerProductionProtocol.assistantR4
        )
        XCTAssertEqual(
            ReconstructionXPCInferenceProvider.protocolBundle,
            Phase2AIWorkerProductionProtocol.reconstructionR1
        )
    }

    func testPrincipalHandshakeSelectsOneImmutableBundleAndKeepsLegacyAssistantPayload() async throws {
        let legacyPrincipal = Phase2AIWorkerPrincipal()
        let legacyData = await handshakeData(from: legacyPrincipal)
        let legacy = try Phase2AIWorkerWireCodec().decodeHandshake(legacyData)
        XCTAssertEqual(legacy.wireProtocol, Phase2AIWorkerProductionProtocol.assistantR4.wireIdentity)
        XCTAssertEqual(
            legacy.manifestIdentity,
            Phase2AIWorkerProductionProtocol.assistantR4.manifestIdentity
        )

        let reconstructionPrincipal = Phase2AIWorkerPrincipal()
        let reconstructionData = await handshakeData(
            from: reconstructionPrincipal,
            manifestIdentity: Phase2AIWorkerProductionProtocol.reconstructionR1.manifestIdentity
        )
        let reconstruction = try Phase2AIWorkerWireCodec().decodeHandshake(reconstructionData)
        XCTAssertEqual(
            reconstruction.manifestIdentity,
            Phase2AIWorkerProductionProtocol.reconstructionR1.manifestIdentity
        )
        let conflictingLegacy = await handshakeData(from: reconstructionPrincipal)
        XCTAssertTrue(conflictingLegacy.isEmpty)
    }
}

private func handshakeData(
    from principal: Phase2AIWorkerPrincipal,
    manifestIdentity: String? = nil
) async -> Data {
    await withCheckedContinuation { continuation in
        if let manifestIdentity {
            principal.handshake(protocolManifestIdentity: manifestIdentity) {
                continuation.resume(returning: $0)
            }
        } else {
            principal.handshake { continuation.resume(returning: $0) }
        }
    }
}

private actor ReconstructionProviderEventProbe {
    private(set) var events: [ReconstructionAIWorkerEvent] = []
    func append(_ event: ReconstructionAIWorkerEvent) { events.append(event) }
}

private actor ScriptedReconstructionTransport: AIAgentXPCTerminalPreservingTransport {
    private let codec = Phase2ReconstructionAIWorkerWireCodec()

    func run(
        requestID: UUID, requestData: Data,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        _ = try await runPreservingTerminal(
            requestID: requestID,
            requestData: requestData,
            receive: receive
        )
    }

    func runPreservingTerminal(
        requestID: UUID, requestData: Data,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> AIAgentXPCTransportTerminal {
        guard case .round(_, let request) = try codec.decodeRequest(requestData) else {
            throw AIAgentXPCTransportError.malformedReply
        }
        let bodies: [ReconstructionAIWorkerEventBody] = [
            .roundCandidate(.init(
                jobID: request.jobID, checkpointRevision: request.checkpointRevision,
                roundID: request.roundID, selectedHandleIDs: [],
                disposition: .sufficientEvidence, unresolvedGaps: []
            )),
            .usage(.init(promptTokens: 2, completionTokens: 1, totalTokens: 3)),
            .completed,
        ]
        for (index, body) in bodies.enumerated() {
            try await receive(try codec.encodeEvent(.init(
                requestID: requestID, sequence: UInt64(index + 1), body: body
            ), authority: .round(request)))
        }
        return .init(requestID: requestID, status: .completed, reason: nil)
    }

    func cancel(requestID: UUID) async {}
    func reset() async {}
}

private actor ReceiptBoundReconstructionTransport: AIAgentXPCTerminalPreservingTransport {
    private let reconstructionCodec = Phase2ReconstructionAIWorkerWireCodec()
    private let controlCodec = Phase2AIWorkerWireCodec()
    private let controlRequestID: UUID?
    private let workerReceipt = AIAgentXPCWorkerProcessReceipt(
        processIdentifier: 42,
        connectionIdentity: providerID(150),
        profileID: providerID(151),
        configurationGeneration: 1,
        protocolManifestDigest:
            Phase2AIWorkerProductionProtocol.reconstructionR1.manifestDigest
    )
    private(set) var revalidatedReceipt: AIAgentXPCWorkerProcessReceipt?

    init(controlRequestID: UUID? = nil) {
        self.controlRequestID = controlRequestID
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
        guard case .round(_, let request) = try reconstructionCodec.decodeRequest(requestData)
        else { throw AIAgentXPCTransportError.malformedReply }
        let boundRequestID = controlRequestID ?? requestID
        let bundle = Phase2AIWorkerProductionProtocol.reconstructionR1
        let controlBodies: [Phase2AIWorkerWireEventBody] = [
            .providerDispatch,
            .providerConnection(.init(
                localAddress: "127.0.0.1",
                localPort: 51_234,
                remoteAddress: "127.0.0.1",
                remotePort: 12_345
            )),
        ]
        for (index, body) in controlBodies.enumerated() {
            try await receive(try controlCodec.encodeEvent(.init(
                wireProtocol: bundle.wireIdentity,
                protocolVersion: bundle.inferenceVersion,
                phase: .finalization,
                sessionID: providerID(152),
                turnID: providerID(153),
                requestID: boundRequestID,
                documentID: providerID(154),
                workspaceID: providerID(155),
                lifecycleRevision: 1,
                sequence: UInt64(index + 1),
                body: body
            )))
        }
        let semanticBodies: [ReconstructionAIWorkerEventBody] = [
            .roundCandidate(.init(
                jobID: request.jobID,
                checkpointRevision: request.checkpointRevision,
                roundID: request.roundID,
                selectedHandleIDs: [],
                disposition: .sufficientEvidence,
                unresolvedGaps: []
            )),
            .usage(.init(promptTokens: 2, completionTokens: 1, totalTokens: 3)),
            .completed,
        ]
        for (index, body) in semanticBodies.enumerated() {
            try await receive(try reconstructionCodec.encodeEvent(.init(
                requestID: requestID,
                sequence: UInt64(index + 1),
                body: body
            ), authority: .round(request)))
        }
        return .init(requestID: requestID, status: .completed, reason: nil)
    }

    func prepareWorkerProcessReceipt() async throws -> AIAgentXPCWorkerProcessReceipt {
        workerReceipt
    }

    func revalidateWorkerProcessReceipt(
        _ receipt: AIAgentXPCWorkerProcessReceipt
    ) async -> Bool {
        revalidatedReceipt = receipt
        return receipt == workerReceipt
    }

    func cancel(requestID: UUID) async {}
    func reset() async {}
}

private actor BlockingReconstructionTransport: AIAgentXPCTerminalPreservingTransport {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var cancelledRequestIDs: [UUID] = []

    func run(
        requestID: UUID, requestData: Data,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        _ = try await runPreservingTerminal(
            requestID: requestID,
            requestData: requestData,
            receive: receive
        )
    }

    func runPreservingTerminal(
        requestID: UUID, requestData: Data,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> AIAgentXPCTransportTerminal {
        _ = requestData
        _ = receive
        started = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
        return .init(requestID: requestID, status: .completed, reason: nil)
    }

    func cancel(requestID: UUID) async {
        if !cancelledRequestIDs.contains(requestID) { cancelledRequestIDs.append(requestID) }
        continuation?.resume()
        continuation = nil
    }

    func reset() async {}
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private actor TerminalReconstructionTransport: AIAgentXPCTerminalPreservingTransport {
    private(set) var resetCount = 0
    private let status: Phase2AIWorkerTerminal.Status
    private let reason: Phase2AIWorkerTerminal.Reason?
    private let protocolBundle: Phase2AIWorkerProductionProtocolBundle
    private let phase: Phase2AIWorkerWirePhase
    private let semanticRequestAccepted: Bool?

    init(
        status: Phase2AIWorkerTerminal.Status,
        reason: Phase2AIWorkerTerminal.Reason? = nil,
        protocolBundle: Phase2AIWorkerProductionProtocolBundle =
            Phase2AIWorkerProductionProtocol.reconstructionR1,
        phase: Phase2AIWorkerWirePhase = .finalization,
        semanticRequestAccepted: Bool? = nil
    ) {
        self.status = status
        self.reason = reason ?? (status == .failed ? .workerHandlerFailed : nil)
        self.protocolBundle = protocolBundle
        self.phase = phase
        self.semanticRequestAccepted = semanticRequestAccepted
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
        _ = requestData
        _ = receive
        return .init(
            requestID: requestID,
            status: status,
            reason: reason,
            protocolBundle: protocolBundle,
            phase: phase,
            semanticRequestAccepted: semanticRequestAccepted
        )
    }

    func cancel(requestID: UUID) async {}
    func reset() async { resetCount += 1 }
}

private actor InterruptedReconstructionTransport: AIAgentXPCTerminalPreservingTransport {
    func run(
        requestID: UUID,
        requestData: Data,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        throw AIAgentXPCTransportError.invalidated("simulated interruption")
    }

    func runPreservingTerminal(
        requestID: UUID,
        requestData: Data,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> AIAgentXPCTransportTerminal {
        throw AIAgentXPCTransportError.invalidated("simulated interruption")
    }

    func cancel(requestID: UUID) async {}
    func reset() async {}
}

private func providerRoundRequest() -> ReconstructionInferenceRoundRequest {
    .init(
        protocolVersion: 8, jobID: providerID(1), checkpointRevision: 3,
        roundID: providerID(2), corpusManifestSHA256: providerDigest(1),
        evidenceFrontierSHA256: providerDigest(2),
        registryManifestSHA256: Phase2ReconstructionProtocolArtifacts.make().toolRegistry.identity.sha256,
        context: .init(canonicalBytes: Data(#"{"records":[]}"#.utf8), canonicalSHA256: "1b8b4c0b6f6ad1d32565952720bc004eeb1f188f62045e4d5525ae2af8c78432", evidenceIDs: [], allowedGapSubjects: [], allowedGapCategories: [], allowedGapIDs: []),
        handles: [.init(handleID: providerID(10), operationID: .corpusSummary)]
    )
}

private func providerID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "40000000-0000-4000-8000-%012d", value))!
}

private func providerDigest(_ value: Int) -> String { String(format: "%064x", value) }
