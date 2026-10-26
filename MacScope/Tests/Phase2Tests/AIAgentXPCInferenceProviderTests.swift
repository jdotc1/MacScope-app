import XCTest

@testable import MacScope

final class AIAgentXPCInferenceProviderTests: XCTestCase {
    func testOptInMTPLXSignedWorkerRealBinaryKnownAnswer() async throws {
        let configuration = try await mtplxQualityCanaryConfiguration()
        let root = TestWorkRoot.authority
            .appendingPathComponent("mtplx-integer-canary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("integer.c")
        let executable = root.appendingPathComponent("integer-canary")
        // The source and executed oracle remain test inputs, never model evidence. Only
        // MacScope's recovered binary evidence crosses the inference boundary below.
        try """
        #include <stdio.h>
        #include <stdlib.h>
        __attribute__((noinline)) long mtplx_integer_target(long a, long b) {
            return a * 3 + b * 5 + 17;
        }
        int main(int argc, char **argv) {
            if (argc != 3) return 2;
            printf("%ld\\n", mtplx_integer_target(strtol(argv[1], 0, 10), strtol(argv[2], 0, 10)));
            return 0;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        _ = try mtplxRunBoundedTool(URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["clang", "-arch", "arm64", "-O1", "-g0", source.path, "-o", executable.path])
        let oracle = try mtplxRunBoundedTool(executable, arguments: ["7", "11"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let oracleValue = try XCTUnwrap(Int64(oracle), "The independent executable must return one integer")
        XCTAssertEqual(oracle, String(oracleValue))
        let snapshot = try AnalysisEngine().analyze(url: executable)
        let binary = try XCTUnwrap(snapshot.binaries.first)
        XCTAssertTrue(binary.architecture.hasPrefix("arm64"))
        let function = try XCTUnwrap(snapshot.functions.first {
            $0.name == "_mtplx_integer_target" || $0.name == "mtplx_integer_target"
        })
        let target = try XCTUnwrap(snapshot.pseudocodeTarget(selectedAddress: function.startAddress))
        XCTAssertFalse(target.instructions.isEmpty)
        XCTAssertLessThan(target.instructions.count, 64)
        let pseudocode = PseudocodePrinter().print(functionName: target.function.name,
            startAddress: target.function.startAddress,
            jumpTables: snapshot.resolvedJumpTables(in: snapshot.primarySlot),
            objcSelectors: snapshot.objcSelectors, instructions: target.instructions)
        let listing = target.instructions.map {
            "\($0.address.hexAddress): \($0.bytes)  \($0.mnemonic) \($0.operands)"
        }.joined(separator: "\n")
        let recovered = """
        MacScope AnalysisEngine recovered ARM64 function \(function.name),
        range \(function.startAddress.hexAddress)..<\(function.endAddress.hexAddress).
        Original binary instruction listing:
        \(listing)
        MacScope fallback PseudocodePrinter output (not native decompiler output):
        \(pseudocode.lines.map(\.text).joined(separator: "\n"))
        """
        let fixture = MTPLXLiveFixture(binaryID: binary.id,
            functionRange: function.startAddress..<function.endAddress)
        let evidenceID = UUID()
        let accepted = try fixture.accepted(candidate: UUID(), invocation: UUID(),
            evidence: evidenceID, data: .value(.text(recovered)))
        let context = try Phase2GroundedContextCompiler().compile(records: [accepted],
            currentStateByEvidenceID: [evidenceID: fixture.current])
        let request = mtplxQualityRequest(fixture: fixture, context: context,
            goal: "Using the recovered ARM64 instructions, determine mtplx_integer_target(7, 11). Treat x0 and x1 as the first two signed integer arguments under the ARM64 calling convention. Begin your answer with exactly 'Result: <integer>' on its own line, then explain the arithmetic and cite this evidence. Resolve any disagreement with fallback pseudocode from the original instructions.")
        let outcome = try await mtplxRunQualityCanary(request, configuration: configuration)
        let answer = try XCTUnwrap(outcome.finalCandidate)
        XCTAssertEqual(answer.kind, .answer)
        XCTAssertEqual(answer.evidenceIDs, [evidenceID])
        XCTAssertEqual(answer.text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init),
            "Result: \(oracle)", "Compare the exact result against independently executed fixture bytes")
        XCTAssertNotNil(outcome.providerUsage)
        print("MTPLX_REAL_BINARY_CANARY function=\(function.startAddress.hexAddress) instruction_count=\(target.instructions.count) oracle=\(oracle) answer=\(answer.text)")
    }

    func testOptInMTPLXSignedWorkerInsufficientEvidenceAbstains() async throws {
        let configuration = try await mtplxQualityCanaryConfiguration()
        let fixture = MTPLXLiveFixture()
        let context = try Phase2GroundedContextCompiler().compile(records: [], currentStateByEvidenceID: [:])
        let request = mtplxQualityRequest(fixture: fixture, context: context,
            goal: "What is the exact original source filename and line number of the selected binary's mtplx_integer_target function? No binary, debug information, source map, or accepted evidence has been supplied. Give the specific fact only if supported; otherwise explain why it cannot be determined.")
        let outcome = try await mtplxRunQualityCanary(request, configuration: configuration)
        let answer = try XCTUnwrap(outcome.finalCandidate)
        XCTAssertEqual(answer.kind, .insufficientEvidence)
        XCTAssertTrue(answer.evidenceIDs.isEmpty)
        XCTAssertFalse(answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let text = answer.text.lowercased()
        XCTAssertTrue(["cannot", "can't", "unable", "insufficient", "not possible", "no evidence", "not enough"]
            .contains { text.contains($0) }, "The answer must explicitly acknowledge the missing evidence")
        XCTAssertTrue(text.contains("source") || text.contains("debug") || text.contains("evidence"))
        XCTAssertFalse(answer.text.contains("integer.c"), "The test fixture's unprovided source filename must not be invented")
        XCTAssertTrue(outcome.toolProposals.isEmpty)
        XCTAssertTrue(outcome.shellProposals.isEmpty)
        XCTAssertNotNil(outcome.providerUsage)
        print("MTPLX_ABSTENTION_CANARY answer=\(answer.text)")
    }

    func testOptInMTPLXSignedWorkerGroundedCanaryAndLongerEvidence() async throws {
        guard ProcessInfo.processInfo.environment["MACSCOPE_RUN_MTPLX_LIVE_CANARY"] == "1" else {
            throw XCTSkip("Set MACSCOPE_RUN_MTPLX_LIVE_CANARY=1 for the installed exact Quality runtime")
        }
        let catalog = try await Phase2NativeModelDiscoveryHTTPClient().discover(
            at: .init(validating: "http://127.0.0.1:8000"), provider: .mtplx)
        XCTAssertEqual(catalog.models.map(\.key), [Phase2MTPLXQualityRuntimeExpectation.servedModelID])
        XCTAssertEqual(catalog.models.first?.loadedInstances.first?.configuration.contextLength, 65_536)
        let fixture = MTPLXLiveFixture()
        let config = try Phase2AIProviderConfiguration(profileID: UUID(), generation: 1,
            endpointOrigin: "http://127.0.0.1:8000",
            model: Phase2MTPLXQualityRuntimeExpectation.servedModelID,
            maximumTokens: 16_384, requestTimeoutMilliseconds: 300_000,
            resourceTimeoutMilliseconds: 1_800_000, inferencePolicy: .init())
        let corpus = TestSourceRoot.url.appendingPathComponent("MacScope/Tests/CoreTests/GoldenFixtures/corpus")
        let swiftSource = try String(contentsOf: corpus.appendingPathComponent("swift_corpus.swift"), encoding: .utf8)
        let objcSource = try String(contentsOf: corpus.appendingPathComponent("objc_corpus.m"), encoding: .utf8)
        for (index, evidence) in ["public func sum(_ xs: [Int]) -> Int { xs.reduce(0, +) }",
                                  "Golden source fixture swift_corpus.swift:\n" + swiftSource + "\nGolden source fixture objc_corpus.m:\n" + objcSource].enumerated() {
            let evidenceID = UUID()
            let accepted = try fixture.accepted(candidate: UUID(), invocation: UUID(),
                evidence: evidenceID, data: .value(.text(evidence)))
            let grounded = try Phase2GroundedContextCompiler().compile(records: [accepted],
                currentStateByEvidenceID: [evidenceID: fixture.current])
            XCTAssertEqual(grounded.records.count, 1)
            let request = Phase2InferenceRequest(protocolVersion: .init(rawValue:
                Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion), phase: .finalization,
                sessionID: UUID(), turnID: UUID(), requestID: UUID(), document: fixture.document,
                workspace: fixture.workspace, lifecycleRevision: 1,
                userGoal: index == 0 ? "Explain the supplied sum function and its result for [2, 3, 5]. Cite the evidence."
                    : "Explain the supplied Swift functions sum, mapDouble, and Point.distance; use the source fixture as evidence. Compare what is known from source with what would require executable/disassembly evidence. Do not invent machine instructions.",
                groundedContext: grounded, toolHandles: [],
                conversationContext: .init(turns: [], omittedTurnCount: 0), limits: .maximum)
            let transport = NSXPCAIAgentTransport(configuration: config)
            let workerReceipt = try await transport.prepareWorkerProcessReceipt()
            XCTAssertGreaterThan(workerReceipt.processIdentifier, 1)
            let provider = AIAgentXPCInferenceProvider(transport: transport)
            let errorProbe = MTPLXLiveProviderErrorProbe()
            let observed = MTPLXLiveDiagnosticProvider(provider: provider, errors: errorProbe)
            let outcome = await Phase2InferenceRunner().run(request: request, provider: observed)
            let failure = await errorProbe.failureDescription
            XCTAssertEqual(outcome.disposition, .completed, "Live fixture \(index): \(outcome); transport=\(failure ?? "none")")
            let answer = try XCTUnwrap(outcome.finalCandidate)
            XCTAssertEqual(answer.kind, .answer)
            XCTAssertEqual(answer.evidenceIDs, [evidenceID])
            XCTAssertNotNil(outcome.providerUsage)
            if index == 0 { XCTAssertTrue(answer.text.contains("10")) }
            print("MTPLX_LIVE_CANARY fixture=\(index) answer=\(answer.text) usage=\(String(describing: outcome.providerUsage))")
            await transport.reset()
        }
    }

    func testOptInMTPLXSignedWorkerCancellationDrainsBeforeIsolatedReplacement() async throws {
        guard ProcessInfo.processInfo.environment["MACSCOPE_RUN_MTPLX_LIVE_CANARY"] == "1" else {
            throw XCTSkip("Set MACSCOPE_RUN_MTPLX_LIVE_CANARY=1 for the installed exact Quality runtime")
        }
        let catalog = try await Phase2NativeModelDiscoveryHTTPClient().discover(
            at: .init(validating: "http://127.0.0.1:8000"), provider: .mtplx)
        XCTAssertEqual(catalog.models.map(\.key), [Phase2MTPLXQualityRuntimeExpectation.servedModelID])
        XCTAssertEqual(catalog.models.first?.loadedInstances.first?.configuration.contextLength, 65_536)
        let configuration = try Phase2AIProviderConfiguration(profileID: UUID(), generation: 1,
            endpointOrigin: "http://127.0.0.1:8000", model: Phase2MTPLXQualityRuntimeExpectation.servedModelID,
            maximumTokens: 16_384, requestTimeoutMilliseconds: 300_000,
            resourceTimeoutMilliseconds: 1_800_000, inferencePolicy: .init())
        let fixture = MTPLXLiveFixture()
        func groundedRequest(evidenceID: UUID, source: String, goal: String) throws -> Phase2InferenceRequest {
            let accepted = try fixture.accepted(candidate: UUID(), invocation: UUID(), evidence: evidenceID,
                data: .value(.text(source)))
            let context = try Phase2GroundedContextCompiler().compile(records: [accepted],
                currentStateByEvidenceID: [evidenceID: fixture.current])
            return .init(protocolVersion: .init(rawValue: Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion),
                phase: .finalization, sessionID: UUID(), turnID: UUID(), requestID: UUID(),
                document: fixture.document, workspace: fixture.workspace, lifecycleRevision: 1,
                userGoal: goal, groundedContext: context, toolHandles: [],
                conversationContext: .init(turns: [], omittedTurnCount: 0), limits: .maximum)
        }
        let firstEvidenceID = UUID()
        let first = try groundedRequest(evidenceID: firstEvidenceID,
            source: "public func sum(_ xs: [Int]) -> Int { xs.reduce(0, +) }",
            goal: "Explain the supplied sum function, its loop invariant, and the result for [2, 3, 5]. Cite the evidence.")
        let transport = NSXPCAIAgentTransport(configuration: configuration)
        let provider = AIAgentXPCInferenceProvider(transport: transport)
        let workerReceipt = try await transport.prepareWorkerProcessReceipt()
        XCTAssertGreaterThan(workerReceipt.processIdentifier, 1)
        let probe = MTPLXLiveCancellationProbe(requestID: first.requestID)
        let cancellationErrors = MTPLXLiveProviderErrorProbe()
        let observing = MTPLXLiveCancellationProvider(provider: provider, probe: probe, errors: cancellationErrors)
        let firstRun = Task { await Phase2InferenceRunner().run(request: first, provider: observing) }
        let dispatched = await probe.waitUntilDispatched(timeout: .seconds(60))
        guard dispatched else {
            await probe.issueCancellation()
            firstRun.cancel()
            await provider.resetConnection()
            _ = await firstRun.value
            let failure = await cancellationErrors.failureDescription
            XCTFail("The signed worker did not acknowledge request-specific HTTP response headers within 60 seconds; transport=\(failure ?? "none")")
            return
        }
        await probe.issueCancellation()
        let cancellationStart = ContinuousClock.now
        firstRun.cancel()
        // A failed cancellation must not hold the live test for the 30-minute inference budget.
        // Reset only this test-owned connection after ten seconds, and fail that outcome below.
        let drainWatchdog = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            await probe.markDrainTimeout()
            await provider.resetConnection()
        }
        let cancelled = await firstRun.value
        drainWatchdog.cancel()
        let drainDuration = cancellationStart.duration(to: ContinuousClock.now)
        let drainTimedOut = await probe.drainTimedOut
        XCTAssertFalse(drainTimedOut, "Cancellation required resetting the test-owned connection")
        XCTAssertLessThan(drainDuration, .seconds(10))
        XCTAssertEqual(cancelled.disposition, .cancelled)
        XCTAssertEqual(cancelled.acceptedEventCount, 0)
        XCTAssertNil(cancelled.finalCandidate)
        XCTAssertTrue(cancelled.toolProposals.isEmpty)
        XCTAssertTrue(cancelled.shellProposals.isEmpty)
        let stateAfterCancellation = await provider.connectionState
        XCTAssertEqual(stateAfterCancellation, .idle)
        guard !drainTimedOut else { return }

        // Fresh discovery and different request/evidence identities prevent a cancelled result
        // from masquerading as the replacement's answer, while retaining the same XPC provider.
        let refreshed = try await Phase2NativeModelDiscoveryHTTPClient().discover(
            at: .init(validating: "http://127.0.0.1:8000"), provider: .mtplx)
        XCTAssertEqual(refreshed.models.map(\.key), [Phase2MTPLXQualityRuntimeExpectation.servedModelID])
        XCTAssertEqual(refreshed.models.first?.loadedInstances.first?.configuration.contextLength, 65_536)
        let replacementEvidenceID = UUID()
        let replacement = try groundedRequest(evidenceID: replacementEvidenceID,
            source: "public func add(_ a: Int, _ b: Int) -> Int { a + b }",
            goal: "Explain the supplied add function and its result for add(7, 11). Cite only this request's evidence.")
        XCTAssertNotEqual(replacement.requestID, first.requestID)
        let replacementErrors = MTPLXLiveProviderErrorProbe()
        let observedReplacement = MTPLXLiveDiagnosticProvider(provider: provider, errors: replacementErrors)
        let outcome = await Phase2InferenceRunner().run(request: replacement, provider: observedReplacement)
        let replacementFailure = await replacementErrors.failureDescription
        XCTAssertEqual(outcome.disposition, .completed, "Replacement transport=\(replacementFailure ?? "none")")
        let answer = try XCTUnwrap(outcome.finalCandidate)
        XCTAssertEqual(answer.kind, .answer)
        XCTAssertEqual(answer.evidenceIDs, [replacementEvidenceID])
        XCTAssertFalse(answer.evidenceIDs.contains(firstEvidenceID))
        XCTAssertTrue(answer.text.contains("18"))
        XCTAssertNotNil(outcome.providerUsage)
        let stateAfterReplacement = await provider.connectionState
        XCTAssertEqual(stateAfterReplacement, .idle)
        print("MTPLX_LIVE_CANCELLATION cancelled_request=\(first.requestID) replacement_request=\(replacement.requestID) cancellation_drain=\(drainDuration) replacement_usage=\(String(describing: outcome.providerUsage))")
        await transport.reset()
    }

    func testSignedEmbeddedWorkerConfiguresAndFailsClosedWithoutProvider() async throws {
        let request = aiProviderRequest()
        let configuration = aiProviderConfiguration()
        XCTAssertEqual(configuration.inferencePolicy, Phase2LocalInferencePolicy())
        let transport = NSXPCAIAgentTransport(configuration: configuration)
        let payload = try Phase2AIWorkerAppCodec().encodeRequest(request)
        let collector = AIWorkerEventCollector()

        do {
            try await transport.run(requestID: request.requestID, requestData: payload) { data in
                await collector.append(try Phase2AIWorkerAppCodec().decodeEvent(data))
            }
            XCTFail("Expected the live worker to fail closed without a loopback provider")
        } catch {
            XCTAssertEqual(
                error as? AIAgentXPCTransportError,
                .unavailable("worker handler failed")
            )
        }

        let events = await collector.events
        XCTAssertTrue(events.isEmpty)
    }

    func testDeterministicTransportFeedsExistingInferenceRunner() async {
        let request = aiProviderRequest()
        let transport = ScriptedAIAgentTransport()
        let provider = AIAgentXPCInferenceProvider(transport: transport)

        let outcome = await Phase2InferenceRunner().run(request: request, provider: provider)

        XCTAssertEqual(outcome.disposition, .completed)
        XCTAssertEqual(outcome.previewDeltas, ["worker preview"])
        XCTAssertEqual(outcome.finalCandidate?.text, "worker final")
        XCTAssertEqual(
            outcome.providerUsage,
            Phase2ProviderUsage(promptTokens: 7, completionTokens: 3, totalTokens: 10)!
        )
        XCTAssertEqual(outcome.acceptedEventCount, 4)
    }

    func testProviderRelaysExactCancellationOnlyOnce() async {
        let transport = ScriptedAIAgentTransport()
        let provider = AIAgentXPCInferenceProvider(transport: transport)
        let requestID = aiProviderID(77)

        await provider.cancel(requestID: requestID)
        await provider.cancel(requestID: requestID)

        let cancelledRequestIDs = await transport.cancelledRequestIDs()
        XCTAssertEqual(cancelledRequestIDs, [requestID])
    }

    func testRunnerCancellationReachesConcreteProviderTransportExactlyOnce() async {
        let request = aiProviderRequest()
        let transport = BlockingAIAgentTransport()
        let provider = AIAgentXPCInferenceProvider(transport: transport)
        let turn = Task {
            await Phase2InferenceRunner().run(request: request, provider: provider)
        }
        await transport.waitUntilStarted()

        turn.cancel()
        let outcome = await turn.value

        XCTAssertEqual(outcome.disposition, .cancelled)
        let cancelledRequestIDs = await transport.cancelledRequestIDs()
        XCTAssertEqual(cancelledRequestIDs, [request.requestID])
    }

    func testCancelAfterDispatchClearsOrdinaryReceiptBeforeNextRequest() async throws {
        let transport = DispatchThenBlockFirstAIAgentTransport()
        let provider = AIAgentXPCInferenceProvider(transport: transport)
        let firstRequest = aiProviderRequest(requestID: aiProviderID(501))
        let firstRun = Task {
            try await provider.run(request: firstRequest) { _ in }
        }
        await transport.waitUntilFirstDispatchIsBlocked()

        await provider.cancel(requestID: firstRequest.requestID)
        try await firstRun.value

        let secondRequest = aiProviderRequest(requestID: aiProviderID(502))
        try await provider.run(request: secondRequest) { _ in }

        let requestIDs = await transport.requestIDs()
        let cancelledRequestIDs = await transport.cancelledRequestIDs()
        let connectionState = await provider.connectionState
        XCTAssertEqual(requestIDs, [
            firstRequest.requestID,
            secondRequest.requestID,
        ])
        XCTAssertEqual(cancelledRequestIDs, [firstRequest.requestID])
        XCTAssertEqual(connectionState, .idle)
    }

    func testStickyInvalidationRequiresExplicitReset() async throws {
        let request = aiProviderRequest()
        let transport = InvalidatingAIAgentTransport()
        let provider = AIAgentXPCInferenceProvider(transport: transport)

        do {
            try await provider.run(request: request) { _ in }
            XCTFail("Expected the first worker connection to invalidate")
        } catch {
            XCTAssertEqual(
                error as? AIAgentXPCTransportError,
                .invalidated("simulated invalidation")
            )
        }
        let invalidatedState = await provider.connectionState
        XCTAssertEqual(invalidatedState, .invalidated("simulated invalidation"))

        await provider.resetConnection()
        let resetState = await provider.connectionState
        XCTAssertEqual(resetState, .idle)
        try await provider.run(request: request) { _ in }
        let resetCount = await transport.resetCount()
        XCTAssertEqual(resetCount, 1)
    }
}

private actor AIWorkerEventCollector {
    private(set) var events: [Phase2InferenceEvent] = []
    func append(_ event: Phase2InferenceEvent) { events.append(event) }
}

private actor ScriptedAIAgentTransport: AIAgentXPCTransport {
    private var cancellations: [UUID] = []
    private let codec = Phase2AIWorkerWireCodec()

    func run(
        requestID: UUID,
        requestData: Data,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        let request = try codec.decodeRequest(requestData)
        let bodies: [Phase2AIWorkerWireEventBody] = [
            .contentDelta("worker preview"),
            .finalCandidate(
                kind: .insufficientEvidence,
                text: "worker final",
                evidenceIDs: []
            ),
            .usage(.init(promptTokens: 7, completionTokens: 3, totalTokens: 10)),
            .completed,
        ]
        for (offset, body) in bodies.enumerated() {
            let event = Phase2AIWorkerWireEvent(
                wireProtocol: request.wireProtocol,
                protocolVersion: request.protocolVersion,
                phase: request.phase,
                sessionID: request.sessionID,
                turnID: request.turnID,
                requestID: request.requestID,
                documentID: request.documentID,
                workspaceID: request.workspaceID,
                lifecycleRevision: request.lifecycleRevision,
                sequence: UInt64(offset + 1),
                body: body
            )
            try await receive(try codec.encodeEvent(event))
        }
    }

    func cancel(requestID: UUID) async { cancellations.append(requestID) }
    func reset() async {}
    func cancelledRequestIDs() -> [UUID] { cancellations }
}

private actor InvalidatingAIAgentTransport: AIAgentXPCTransport {
    private var shouldInvalidate = true
    private var resets = 0

    func run(
        requestID: UUID,
        requestData: Data,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        if shouldInvalidate {
            shouldInvalidate = false
            throw AIAgentXPCTransportError.invalidated("simulated invalidation")
        }
    }

    func cancel(requestID: UUID) async {}
    func reset() async { resets += 1 }
    func resetCount() -> Int { resets }
}

private actor BlockingAIAgentTransport: AIAgentXPCTransport {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var runContinuation: CheckedContinuation<Void, Never>?
    private var cancellations: [UUID] = []

    func run(
        requestID: UUID,
        requestData: Data,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            runContinuation = continuation
        }
    }

    func cancel(requestID: UUID) async {
        cancellations.append(requestID)
        runContinuation?.resume()
        runContinuation = nil
    }

    func reset() async {}

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func cancelledRequestIDs() -> [UUID] { cancellations }
}

private actor DispatchThenBlockFirstAIAgentTransport: AIAgentXPCTransport {
    private let codec = Phase2AIWorkerWireCodec()
    private var requests: [UUID] = []
    private var cancellations: [UUID] = []
    private var firstDispatchIsBlocked = false
    private var firstDispatchWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRunContinuation: CheckedContinuation<Void, Never>?

    func run(
        requestID: UUID,
        requestData: Data,
        receive: @escaping @Sendable (Data) async throws -> Void
    ) async throws {
        let request = try codec.decodeRequest(requestData)
        requests.append(requestID)
        try await receive(try codec.encodeEvent(.init(
            wireProtocol: request.wireProtocol,
            protocolVersion: request.protocolVersion,
            phase: request.phase,
            sessionID: request.sessionID,
            turnID: request.turnID,
            requestID: request.requestID,
            documentID: request.documentID,
            workspaceID: request.workspaceID,
            lifecycleRevision: request.lifecycleRevision,
            sequence: UInt64.max - 1,
            body: .providerDispatch
        )))
        guard requests.count == 1 else { return }
        await withCheckedContinuation { continuation in
            firstRunContinuation = continuation
            firstDispatchIsBlocked = true
            let waiters = firstDispatchWaiters
            firstDispatchWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func cancel(requestID: UUID) async {
        cancellations.append(requestID)
        firstRunContinuation?.resume()
        firstRunContinuation = nil
    }

    func reset() async {}

    func waitUntilFirstDispatchIsBlocked() async {
        guard !firstDispatchIsBlocked else { return }
        await withCheckedContinuation { continuation in
            firstDispatchWaiters.append(continuation)
        }
    }

    func requestIDs() -> [UUID] { requests }
    func cancelledRequestIDs() -> [UUID] { cancellations }
}

private func aiProviderRequest(requestID: UUID = aiProviderID(5)) -> Phase2InferenceRequest {
    let document = Phase2ReadDocumentIdentity(instanceID: aiProviderID(1))
    let workspace = Phase2ReadWorkspaceIdentity(document: document, instanceID: aiProviderID(2))
    return .init(
        protocolVersion: .init(
            rawValue: Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion
        ),
        phase: .finalization,
        sessionID: aiProviderID(3),
        turnID: aiProviderID(4),
        requestID: requestID,
        document: document,
        workspace: workspace,
        lifecycleRevision: 6,
        userGoal: "Explain the selected function",
        groundedContext: try! Phase2GroundedContextCompiler().compile(
            records: [],
            currentStateByEvidenceID: [:]
        ),
        toolHandles: [],
        conversationContext: .init(turns: [], omittedTurnCount: 0),
        limits: .maximum
    )
}

private func aiProviderConfiguration() -> Phase2AIProviderConfiguration {
    try! .init(
        profileID: aiProviderID(100),
        generation: 1,
        endpointOrigin: "http://127.0.0.1:9",
        model: "test-model",
        maximumTokens: 1_024,
        requestTimeoutMilliseconds: 10_000,
        resourceTimeoutMilliseconds: 60_000,
        inferencePolicy: .init()
    )
}

private func aiProviderID(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
}

private struct MTPLXLiveFixture {
    let document = Phase2ReadDocumentIdentity(instanceID: mtplxLiveID(1))
    let workspace: Phase2ReadWorkspaceIdentity
    let image: Phase2ReadImageIdentity
    let precondition: Phase2ReadPrecondition
    let current: Phase2ReadCurrentState
    let citation: Phase2ReadCitation
    let operationID: Phase2ReadOperationID
    let subject: Phase2ReadSubject

    init(fingerprint: String? = nil, binaryID: UUID = mtplxLiveID(3),
         functionRange: Range<UInt64>? = nil) {
        workspace = .init(document: document, instanceID: mtplxLiveID(2))
        image = .init(
            owner: .init(
                slot: .primary,
                binaryID: binaryID,
                architecture: "arm64",
                sliceIndex: 0,
                ownerGeneration: 1
            ),
            analysisRevision: 1,
            analysisFingerprintSHA256: fingerprint
        )
        let dependency = Phase2ReadFacetDependency(
            scope: .image(image.owner),
            facet: .functionBoundaries,
            requiredRevision: 1
        )
        precondition = .init(
            workspace: workspace,
            workspaceRevision: 1,
            strictWholeWorkspace: false,
            image: image,
            dependencies: [dependency]
        )
        current = .init(
            workspace: workspace,
            workspaceRevision: 1,
            image: image,
            facetRevisions: [
                .init(scope: .image(image.owner), facet: .functionBoundaries, revision: 1),
            ]
        )
        let citationTarget: Phase2ReadCitationTarget
        if let functionRange {
            let range = Phase2ReadFunctionRange(image: image,
                start: functionRange.lowerBound, endExclusive: functionRange.upperBound)
            citationTarget = .functionRange(range)
            operationID = .functionReview
            subject = .functionRange(range)
        } else {
            citationTarget = .image(image)
            operationID = .workspaceSummary
            subject = .workspace(workspace)
        }
        citation = .init(
            id: mtplxLiveID(4),
            target: citationTarget,
            dependencies: [dependency]
        )
    }

    func candidate(
        candidateID: UUID,
        invocationID: UUID,
        principal: Phase2Principal = .app,
        data: Phase2ReadCandidateData = .value(.text("grounded"))
    ) -> Phase2ReadEvidenceCandidate {
        .init(
            candidateID: candidateID,
            invocationID: invocationID,
            sequence: 1,
            registryVersion: .v1,
            operationID: operationID,
            operationVersion: .v1,
            producingPrincipal: principal,
            precondition: precondition,
            citations: [citation],
            data: data,
            cancelled: false
        )
    }

    func authorization(for candidate: Phase2ReadEvidenceCandidate) -> Phase2ReadAuthorization {
        let descriptor = Phase2ReadOperationDescriptor(
            registryVersion: .v1,
            id: operationID,
            operationVersion: .v1,
            effects: operationID == .functionReview ? [.a1, .a2] : [.a1]
        )
        let request = Phase2ReadRequest(
            requestID: mtplxLiveID(5),
            invocationID: candidate.invocationID,
            sequence: candidate.sequence,
            proposingPrincipal: .model,
            descriptor: descriptor,
            subject: subject,
            precondition: precondition,
            limits: .maximum
        )
        return .init(
            request: request,
            canonicalDescriptor: descriptor,
            authorizingPrincipal: .app,
            approvedLimits: .maximum
        )
    }

    func accepted(
        candidate candidateID: UUID,
        invocation invocationID: UUID,
        evidence evidenceID: UUID,
        data: Phase2ReadCandidateData = .value(.text("grounded"))
    ) throws -> Phase2AcceptedEvidence {
        let candidate = candidate(
            candidateID: candidateID,
            invocationID: invocationID,
            data: data
        )
        var acceptor = Phase2EvidenceAcceptor()
        let authorization = authorization(for: candidate)
        XCTAssertTrue(authorization.isValid, "Fixture authorization must satisfy its typed read contract")
        let terminal = acceptor.evaluate(
            candidate,
            authorization: authorization,
            against: current,
            acceptingEvidenceID: evidenceID
        )
        XCTAssertEqual(terminal.disposition, .accepted, "Fixture evidence acceptance: \(terminal)")
        return try XCTUnwrap(acceptor.acceptedEvidence(for: invocationID))
    }

    func current(
        binaryByte: UInt8 = 3,
        analysisRevision: UInt64 = 1,
        fingerprint: String? = nil
    ) -> Phase2ReadCurrentState {
        let currentImage = Phase2ReadImageIdentity(
            owner: .init(
                slot: .primary,
                binaryID: mtplxLiveID(binaryByte),
                architecture: "arm64",
                sliceIndex: 0,
                ownerGeneration: binaryByte == 3 ? 1 : 2
            ),
            analysisRevision: analysisRevision,
            analysisFingerprintSHA256: fingerprint ?? image.analysisFingerprintSHA256
        )
        return .init(
            workspace: workspace,
            workspaceRevision: 1,
            image: currentImage,
            facetRevisions: [
                .init(
                    scope: .image(currentImage.owner),
                    facet: .functionBoundaries,
                    revision: analysisRevision
                ),
            ]
        )
    }
}

private func mtplxLiveID(_ byte: UInt8) -> UUID {
    UUID(uuid: (byte, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, byte))
}

private func mtplxQualityCanaryConfiguration() async throws -> Phase2AIProviderConfiguration {
    guard ProcessInfo.processInfo.environment["MACSCOPE_RUN_MTPLX_LIVE_CANARY"] == "1" else {
        throw XCTSkip("Set MACSCOPE_RUN_MTPLX_LIVE_CANARY=1 for the installed exact Quality runtime")
    }
    let catalog = try await Phase2NativeModelDiscoveryHTTPClient().discover(
        at: .init(validating: "http://127.0.0.1:8000"), provider: .mtplx)
    XCTAssertEqual(catalog.models.map(\.key), [Phase2MTPLXQualityRuntimeExpectation.servedModelID])
    XCTAssertEqual(catalog.models.first?.loadedInstances.first?.configuration.contextLength, 65_536)
    return try .init(profileID: UUID(), generation: 1, endpointOrigin: "http://127.0.0.1:8000",
        model: Phase2MTPLXQualityRuntimeExpectation.servedModelID, maximumTokens: 16_384,
        requestTimeoutMilliseconds: 300_000, resourceTimeoutMilliseconds: 1_800_000,
        inferencePolicy: .init())
}

private func mtplxQualityRequest(fixture: MTPLXLiveFixture,
                               context: Phase2GroundedContext,
                               goal: String) -> Phase2InferenceRequest {
    .init(protocolVersion: .init(rawValue: Phase2AIWorkerProductionProtocol.assistantR4.inferenceVersion),
        phase: .finalization, sessionID: UUID(), turnID: UUID(), requestID: UUID(),
        document: fixture.document, workspace: fixture.workspace, lifecycleRevision: 1,
        userGoal: goal, groundedContext: context, toolHandles: [],
        conversationContext: .init(turns: [], omittedTurnCount: 0), limits: .maximum)
}

private func mtplxRunQualityCanary(_ request: Phase2InferenceRequest,
                                 configuration: Phase2AIProviderConfiguration) async throws -> Phase2InferenceOutcome {
    let transport = NSXPCAIAgentTransport(configuration: configuration)
    let receipt = try await transport.prepareWorkerProcessReceipt()
    XCTAssertGreaterThan(receipt.processIdentifier, 1)
    let provider = AIAgentXPCInferenceProvider(transport: transport)
    let errors = MTPLXLiveProviderErrorProbe()
    let outcome = await Phase2InferenceRunner().run(request: request,
        provider: MTPLXLiveDiagnosticProvider(provider: provider, errors: errors))
    let failure = await errors.failureDescription
    XCTAssertEqual(outcome.disposition, .completed, "Signed worker transport=\(failure ?? "none")")
    await transport.reset()
    return outcome
}

/// The developer-owned compiler and integer executable have bounded time and output.
/// No shell is involved, and stdout is kept outside the model's evidence context.
private func mtplxRunBoundedTool(_ executable: URL, arguments: [String]) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let drain = CoreTestPipeDrain(output)
    let deadline = Date().addingTimeInterval(30)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    if process.isRunning {
        process.terminate()
        throw NSError(domain: "MTPLXQualityCanary", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Bounded fixture tool exceeded 30 seconds"])
    }
    let data = drain.data()
    guard process.terminationStatus == 0, data.count < 4_096 else {
        throw NSError(domain: "MTPLXQualityCanary", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Fixture tool failed or exceeded its output limit"])
    }
    return String(decoding: data, as: UTF8.self)
}

/// Observes the real signed-worker dispatch receipt and gates only the cancelled test request's
/// semantic callback. HTTP, model output, XPC, and replacement execution remain production paths.
private struct MTPLXLiveCancellationProvider: Phase2InferenceProviding {
    let provider: AIAgentXPCInferenceProvider
    let probe: MTPLXLiveCancellationProbe
    let errors: MTPLXLiveProviderErrorProbe

    func run(request: Phase2InferenceRequest,
             emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void) async throws {
        do {
            try await provider.run(request: request, onDispatched: { receipt in
                Task { await probe.record(receipt) }
            }, emit: { _ in
                try await probe.waitForCancellation()
                throw CancellationError()
            })
        } catch { await errors.record(error); throw error }
    }

    func cancel(requestID: UUID) async { await provider.cancel(requestID: requestID) }
}

private actor MTPLXLiveCancellationProbe {
    private let requestID: UUID
    private var dispatched = false
    private var invalidReceipt = false
    private var cancellationIssued = false
    private(set) var drainTimedOut = false

    init(requestID: UUID) { self.requestID = requestID }

    func record(_ receipt: Phase2InferenceDispatchReceipt) {
        guard receipt.requestID == requestID, receipt.boundary == .httpResponseHeaders,
              !dispatched, !cancellationIssued else { invalidReceipt = true; return }
        dispatched = true
    }

    func waitUntilDispatched(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !dispatched, !invalidReceipt, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return false }
        }
        return dispatched && !invalidReceipt
    }

    func issueCancellation() { cancellationIssued = true }
    func markDrainTimeout() { drainTimedOut = true }

    func waitForCancellation() async throws {
        while !cancellationIssued {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct MTPLXLiveDiagnosticProvider: Phase2InferenceProviding {
    let provider: AIAgentXPCInferenceProvider
    let errors: MTPLXLiveProviderErrorProbe

    func run(request: Phase2InferenceRequest,
             emit: @escaping @Sendable (Phase2InferenceEvent) async throws -> Void) async throws {
        do { try await provider.run(request: request, emit: emit) }
        catch { await errors.record(error); throw error }
    }

    func cancel(requestID: UUID) async { await provider.cancel(requestID: requestID) }
}

private actor MTPLXLiveProviderErrorProbe {
    private(set) var failureDescription: String?

    func record(_ error: Error) {
        if let transport = error as? AIAgentXPCTransportError {
            failureDescription = String(String(describing: transport).prefix(512))
        } else if error is CancellationError {
            failureDescription = "cancelled"
        } else {
            // Arbitrary provider NSError payloads can contain server text; record only its type.
            failureDescription = String(reflecting: type(of: error))
        }
    }
}
