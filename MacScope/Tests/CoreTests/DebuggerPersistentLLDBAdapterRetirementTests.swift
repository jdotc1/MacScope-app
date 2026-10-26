import CryptoKit
import Foundation
import XCTest

@testable import MacScope

@MainActor
final class DebuggerPersistentLLDBAdapterRetirementTests: XCTestCase {
    private let epoch = DebuggerSessionEpoch(
        rawValue: UUID(uuidString: "D4D4D4D4-D4D4-D4D4-D4D4-D4D4D4D4D4D4")!
    )
    private let adapterGeneration: UInt64 = 1

    func testExactAttachedRetirementReturnsSealedProofBoundToEvidence() async throws {
        let channel = RetirementByteChannel()
        let retainedProcess = RetirementProcess(waitResults: [false, false, true])
        let adapter = PersistentLLDBCLIAdapter(
            epoch: epoch,
            channel: channel,
            retainedProcess: retainedProcess,
            markerSecret: Data(repeating: 0x4d, count: 32),
            shutdownStepTimeout: .milliseconds(25)
        )
        let evidence = try await exactAttachedSessionEvidence(
            adapterInstanceBinding: await adapter.adapterInstanceBinding()
        )

        let outcome = await adapter.retireExactAttachedAdapterWithoutDebuggerCommand(
            boundTo: evidence
        )
        let writes = await channel.writes
        let closedInputCount = await channel.closedInputCount
        let closedHandleCount = await channel.closedHandleCount
        let processCalls = await retainedProcess.calls

        guard case .proven(let proof) = outcome else {
            return XCTFail("complete command-free exit and reap must return sealed proof")
        }
        XCTAssertEqual(proof.sessionEpoch, epoch)
        XCTAssertEqual(proof.adapterGeneration, adapterGeneration)
        XCTAssertEqual(proof.adapterInstanceBindingDigest, evidence.adapterInstanceBinding.digest)
        XCTAssertEqual(proof.attachedSessionBindingDigest, evidence.bindingDigest)
        XCTAssertTrue(proof.verifiedCommandQuiescence)
        XCTAssertEqual(writes, [])
        XCTAssertEqual(closedInputCount, 1)
        XCTAssertEqual(closedHandleCount, 1)
        XCTAssertEqual(
            processCalls,
            [
                .wait(PersistentLLDBCLIAdapter.defaultRetirementStdinEOFGracePeriod),
                .terminateRetainedAdapter,
                .wait(.milliseconds(25)),
                .killRetainedAdapterIfStillRunning,
                .wait(.milliseconds(25)),
                .reapAndClose,
            ]
        )
    }

    func testGracefulFirstShutdownCannotYieldCommandFreeProof() async throws {
        let channel = RetirementByteChannel()
        let retainedProcess = RetirementProcess(waitResults: [true])
        let adapter = makeAdapter(channel: channel, retainedProcess: retainedProcess)

        let gracefulReceipt = await adapter.shutdown()
        let outcome = await adapter.retireExactAttachedAdapterWithoutDebuggerCommand(
            boundTo: try await exactAttachedSessionEvidence(
                adapterInstanceBinding: await adapter.adapterInstanceBinding()
            )
        )

        XCTAssertTrue(gracefulReceipt.requestedGracefulQuit)
        guard case .unproven(let receipt) = outcome else {
            return XCTFail("a graceful-first race must never mint command-free proof")
        }
        XCTAssertEqual(receipt, gracefulReceipt)
        let writes = await channel.writes
        XCTAssertEqual(writes, [Data("quit\n".utf8)])
    }

    func testMissingRetainedAdapterExitCannotYieldProof() async throws {
        let channel = RetirementByteChannel()
        let retainedProcess = RetirementProcess(waitResults: [false, false, false, false])
        let adapter = makeAdapter(channel: channel, retainedProcess: retainedProcess)

        let outcome = await adapter.retireExactAttachedAdapterWithoutDebuggerCommand(
            boundTo: try await exactAttachedSessionEvidence(
                adapterInstanceBinding: await adapter.adapterInstanceBinding()
            )
        )

        guard case .unproven(let receipt) = outcome else {
            return XCTFail("missing retained-adapter exit must remain unproven")
        }
        XCTAssertFalse(receipt.requestedGracefulQuit)
        XCTAssertFalse(receipt.didExit)
        XCTAssertTrue(receipt.didReap)
        let writes = await channel.writes
        XCTAssertEqual(writes, [])
    }

    func testMissingRetainedAdapterReapCannotYieldProof() async throws {
        let channel = RetirementByteChannel()
        let retainedProcess = RetirementProcess(waitResults: [true], reapResult: false)
        let adapter = makeAdapter(channel: channel, retainedProcess: retainedProcess)

        let outcome = await adapter.retireExactAttachedAdapterWithoutDebuggerCommand(
            boundTo: try await exactAttachedSessionEvidence(
                adapterInstanceBinding: await adapter.adapterInstanceBinding()
            )
        )

        guard case .unproven(let receipt) = outcome else {
            return XCTFail("missing retained-adapter reap must remain unproven")
        }
        XCTAssertFalse(receipt.requestedGracefulQuit)
        XCTAssertTrue(receipt.didExit)
        XCTAssertFalse(receipt.didReap)
        let writes = await channel.writes
        XCTAssertEqual(writes, [])
    }

    func testSameEpochAndGenerationDecoyAdapterCannotYieldProof() async throws {
        let realAdapter = makeAdapter(
            channel: RetirementByteChannel(),
            retainedProcess: RetirementProcess(waitResults: [true])
        )
        let evidence = try await exactAttachedSessionEvidence(
            adapterInstanceBinding: await realAdapter.adapterInstanceBinding()
        )
        let decoyChannel = RetirementByteChannel()
        let decoyAdapter = makeAdapter(
            channel: decoyChannel,
            retainedProcess: RetirementProcess(waitResults: [true])
        )

        let outcome = await decoyAdapter.retireExactAttachedAdapterWithoutDebuggerCommand(
            boundTo: evidence
        )

        guard case .unproven = outcome else {
            return XCTFail("a same-epoch/generation decoy must not mint exact release proof")
        }
        let realBinding = await realAdapter.adapterInstanceBinding()
        let decoyBinding = await decoyAdapter.adapterInstanceBinding()
        XCTAssertNotEqual(realBinding, decoyBinding)
        let writes = await decoyChannel.writes
        XCTAssertEqual(writes, [])
    }

    func testRacingOutstandingWritePreventsCommandFreeProof() async throws {
        let channel = RetirementByteChannel(blockWrite: true, blockRead: true)
        let adapter = makeAdapter(
            channel: channel,
            retainedProcess: RetirementProcess(waitResults: [true])
        )
        let evidence = try await exactAttachedSessionEvidence(
            adapterInstanceBinding: await adapter.adapterInstanceBinding()
        )
        let execution = Task {
            try await adapter.executeCoordinatorSelected(try retirementRequest())
        }
        await channel.waitUntilWriteStarts()

        let retirement = Task {
            await adapter.retireExactAttachedAdapterWithoutDebuggerCommand(boundTo: evidence)
        }
        await Task.yield()
        await channel.releaseWrite()
        let outcome = await retirement.value

        guard case .unproven = outcome else {
            return XCTFail("retirement admitted with an in-flight write must never yield proof")
        }
        _ = try? await execution.value
        let writes = await channel.writes
        XCTAssertEqual(writes.count, 1)
        XCTAssertFalse(writes.contains(Data("quit\n".utf8)))
    }

    func testCommandFreeRetirementHonoursStdinEOFGraceBeforeSignalling() async throws {
        XCTAssertEqual(PersistentLLDBCLIAdapter.defaultRetirementStdinEOFGracePeriod, .seconds(2))
        let channel = RetirementByteChannel()
        // LLDB exits on its own within the grace period after stdin closes.
        let retainedProcess = RetirementProcess(waitResults: [true])
        let adapter = PersistentLLDBCLIAdapter(
            epoch: epoch,
            channel: channel,
            retainedProcess: retainedProcess,
            markerSecret: Data(repeating: 0x4d, count: 32),
            shutdownStepTimeout: .milliseconds(25),
            retirementStdinEOFGracePeriod: .milliseconds(40)
        )

        let receipt = await adapter.retireRetainedAdapterWithoutDebuggerCommand()

        XCTAssertFalse(receipt.requestedGracefulQuit)
        XCTAssertFalse(receipt.sentTerminate)
        XCTAssertFalse(receipt.sentKill)
        XCTAssertTrue(receipt.didExit)
        XCTAssertTrue(receipt.didReap)
        let closedInputCount = await channel.closedInputCount
        let writes = await channel.writes
        let processCalls = await retainedProcess.calls
        XCTAssertEqual(closedInputCount, 1)
        XCTAssertEqual(writes, [])
        XCTAssertEqual(processCalls, [.wait(.milliseconds(40)), .reapAndClose])
    }

    func testCommandFreeRetirementSignalsOnlyAfterGraceExpires() async throws {
        let channel = RetirementByteChannel()
        let retainedProcess = RetirementProcess(waitResults: [false, true])
        let adapter = PersistentLLDBCLIAdapter(
            epoch: epoch,
            channel: channel,
            retainedProcess: retainedProcess,
            markerSecret: Data(repeating: 0x4d, count: 32),
            shutdownStepTimeout: .milliseconds(25),
            retirementStdinEOFGracePeriod: .milliseconds(40)
        )

        let receipt = await adapter.retireRetainedAdapterWithoutDebuggerCommand()

        XCTAssertTrue(receipt.sentTerminate)
        XCTAssertFalse(receipt.sentKill)
        XCTAssertTrue(receipt.didExit)
        let processCalls = await retainedProcess.calls
        XCTAssertEqual(
            processCalls,
            [
                .wait(.milliseconds(40)),
                .terminateRetainedAdapter,
                .wait(.milliseconds(25)),
                .reapAndClose,
            ]
        )
    }

    private func makeAdapter(
        channel: RetirementByteChannel,
        retainedProcess: RetirementProcess
    ) -> PersistentLLDBCLIAdapter {
        PersistentLLDBCLIAdapter(
            epoch: epoch,
            channel: channel,
            retainedProcess: retainedProcess,
            markerSecret: Data(repeating: 0x4d, count: 32),
            shutdownStepTimeout: .milliseconds(25)
        )
    }

    private func retirementRequest() throws -> PersistentLLDBCLIRequest {
        let session = DebuggerSessionCoordinate(
            epoch: epoch,
            lifecycleRevision: .initial
        )
        return try PersistentLLDBCLIRequest(
            context: DebuggerRequestContext(
                id: DebuggerRequestID(epoch: epoch, sequence: 1),
                operation: .refreshSnapshot,
                expectedSession: session,
                requiredStop: DebuggerStopCoordinate(
                    session: session,
                    stopRevision: .initial
                )
            ),
            semanticCommands: ["process status"],
            observedPIDRequirement: .optional,
            timeout: .seconds(30)
        )
    }

    private func exactAttachedSessionEvidence(
        adapterInstanceBinding: PersistentLLDBCLIAdapterInstanceBinding
    ) async throws
        -> PersistentLLDBExactAttachedSessionEvidence {
        let identity = try exactAttachIdentity()
        let authority = DebuggerSessionTargetAuthority(origin: .attached(identity))
        let request = DebuggerLocalAttachRequest(selectedIdentity: identity)
        let registry = DebuggerSessionLeaseRegistry()
        let executor = RetirementExactAttachExecutor(
            epoch: epoch,
            attachRequest: request,
            generation: adapterGeneration,
            instanceBinding: adapterInstanceBinding,
            attachWriteInterlock: registry.attachWriteInterlock
        )
        let coordinator = PersistentLLDBSessionCoordinator(
            epoch: epoch,
            executor: executor,
            requestPreparer: RetirementRejectingRequestPreparer(),
            capabilities: DebuggerTransportCapabilities(
                operationStates: Dictionary(
                    uniqueKeysWithValues: DebuggerOperation.allCases.map {
                        ($0, DebuggerOperationCapability.supportedAndObserved)
                    }
                ),
                mechanics: .persistentCLI
            ),
            attachWriteInterlock: executor.attachWriteInterlock
        )
        let initial = await coordinator.reducerState
        let reservation = try await registry.reserve(
            ownerID: DebuggerSessionLeaseOwnerID(rawValue: UUID()),
            sessionEpoch: epoch,
            authority: authority
        )
        let permit = try await registry.armExactAttach(
            reservation,
            admissionSession: initial.sessionCoordinate,
            adapterGeneration: adapterGeneration
        )
        await executor.configure(correlationToken: permit.correlationToken)
        let result = try await coordinator.performExactAttachTransaction(
            PersistentLLDBExactAttachTransactionInput(
                request: request,
                permit: permit
            )
        )
        return result.attachedSession
    }

    private func exactAttachIdentity() throws -> DebuggerLocalProcessIdentity {
        try XCTUnwrap(DebuggerLocalProcessIdentity(
            processID: 7_777,
            startTime: DebuggerProcessStartIdentity(seconds: 9_000_001, microseconds: 17)!,
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/tmp/MacScopeRetirementExactAttachFixture",
            executableDeviceID: 7,
            executableFileID: 7_001,
            executableByteCount: 4_096,
            executableSHA256: String(repeating: "a", count: 64),
            architecture: .arm64,
            machOUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            codeIdentity: nil
        ))
    }
}

private actor RetirementExactAttachExecutor: PersistentLLDBCLIExecuting {
    private let epoch: DebuggerSessionEpoch
    private let attachRequest: DebuggerLocalAttachRequest
    private let generation: UInt64
    private let instanceBinding: PersistentLLDBCLIAdapterInstanceBinding
    let attachWriteInterlock: DebuggerLocalProcessAttachWriteInterlock
    private var correlationToken = Data()
    private var didCompleteExactAttach = false
    private var consumedStagingCommandCount = 0
    private var expectedStagingCommandCount: Int?

    init(
        epoch: DebuggerSessionEpoch,
        attachRequest: DebuggerLocalAttachRequest,
        generation: UInt64,
        instanceBinding: PersistentLLDBCLIAdapterInstanceBinding,
        attachWriteInterlock: DebuggerLocalProcessAttachWriteInterlock
    ) {
        self.epoch = epoch
        self.attachRequest = attachRequest
        self.generation = generation
        self.instanceBinding = instanceBinding
        self.attachWriteInterlock = attachWriteInterlock
    }

    func exactAdapterInstanceBinding() -> PersistentLLDBCLIAdapterInstanceBinding? {
        instanceBinding
    }

    func executeCoordinatorSelected(
        _ request: PersistentLLDBCLIRequest
    ) async throws -> PersistentLLDBCLIResponse {
        return try await execute(request)
    }

    func configure(correlationToken: Data) {
        precondition(self.correlationToken.isEmpty)
        self.correlationToken = correlationToken
    }

    func execute(_ request: PersistentLLDBCLIRequest) throws -> PersistentLLDBCLIResponse {
        if case .ordinary = request.writeRole {
            return PersistentLLDBCLIResponse(
                requestID: request.context.id,
                generation: generation,
                transcript: LLDBCLITranscriptResult(
                    transcript: "",
                    authoritativeStatusTranscript: "",
                    observedProcessID: nil,
                    observedProcessState: nil,
                    exchangeByteCount: 1,
                    exchangeSHA256: String(repeating: "a", count: 64),
                    semanticCommandTranscripts: [""],
                    semanticCommandResultLineByteCounts: [1]
                )
            )
        }
        switch request.writeRole {
        case .exactAttachStaging(let authorization?):
            let issuanceInput = authorization.issuanceInput
            guard !didCompleteExactAttach,
                  request.context == issuanceInput.stagingRequest,
                  request.observedPIDRequirement == .optional,
                  instanceBinding == issuanceInput.adapterInstanceBinding,
                  issuanceInput.stagingOrdinal == consumedStagingCommandCount,
                  expectedStagingCommandCount == nil
                    || expectedStagingCommandCount == issuanceInput.canonicalStagingCommandCount,
                  let semanticDigest = DebuggerLocalProcessAttachWriteSemanticDigest(
                    semanticCommands: request.semanticCommands
                  ),
                  semanticDigest == issuanceInput.semanticDigest else {
                throw RetirementExactAttachError.invalidWriteAuthorization
            }
            do {
                try authorization.interlock.consumeExactAttachStagingWriteAuthorization(
                    authorization.authorization,
                    matching: issuanceInput
                )
            } catch {
                throw RetirementExactAttachError.invalidWriteAuthorization
            }
            expectedStagingCommandCount = issuanceInput.canonicalStagingCommandCount
            consumedStagingCommandCount += 1
            return PersistentLLDBCLIResponse(
                requestID: request.context.id,
                generation: generation,
                transcript: LLDBCLITranscriptResult(
                    transcript: "",
                    authoritativeStatusTranscript: "",
                    observedProcessID: nil,
                    observedProcessState: nil,
                    exchangeByteCount: 1,
                    exchangeSHA256: String(repeating: "a", count: 64),
                    semanticCommandTranscripts: [""],
                    semanticCommandResultLineByteCounts: [1]
                )
            )
        case .exactAttachFinal(let authorization?):
            let issuanceInput = authorization.issuanceInput
            guard !didCompleteExactAttach,
                  request.context == issuanceInput.finalAttachRequest,
                  request.observedPIDRequirement == .required,
                  instanceBinding == issuanceInput.adapterInstanceBinding,
                  consumedStagingCommandCount == expectedStagingCommandCount,
                  let semanticDigest = DebuggerLocalProcessAttachWriteSemanticDigest(
                    semanticCommands: request.semanticCommands
                  ),
                  semanticDigest == issuanceInput.semanticDigest else {
                throw RetirementExactAttachError.invalidWriteAuthorization
            }
            let exactAttachWriteCommit: DebuggerLocalProcessAttachWriteCommit
            do {
                exactAttachWriteCommit = try authorization.interlock.commitExactAttachWrite(
                    authorization.grant,
                    matching: issuanceInput
                )
            } catch {
                throw RetirementExactAttachError.invalidWriteAuthorization
            }
            didCompleteExactAttach = true
            let authority = DebuggerSessionTargetAuthority(
                origin: .attached(attachRequest.selectedIdentity)
            )
            let programRequest = try PersistentLLDBAttachProgramRequest(
                sessionEpoch: epoch,
                requestSequence: request.context.id.sequence,
                adapterGeneration: generation,
                authority: authority,
                correlationToken: correlationToken
            )
            let framed = PersistentLLDBAttachProgram.receiptSentinel
                + receiptBytes(for: programRequest).base64EncodedString()
                + "\n"
            return PersistentLLDBCLIResponse(
                requestID: request.context.id,
                generation: generation,
                transcript: LLDBCLITranscriptResult(
                    transcript: "",
                    authoritativeStatusTranscript: "",
                    observedProcessID: authority.processID,
                    observedProcessState: .stopped(processID: authority.processID),
                    exchangeByteCount: framed.utf8.count,
                    exchangeSHA256: String(repeating: "b", count: 64),
                    semanticCommandTranscripts: [framed],
                    semanticCommandResultLineByteCounts: [framed.utf8.count]
                ),
                exactAttachWriteCommit: exactAttachWriteCommit
            )
        case .exactAttachStaging(nil), .exactAttachFinal(nil):
            throw RetirementExactAttachError.missingWriteAuthorization
        case .ordinary:
            throw RetirementExactAttachError.invalidWriteAuthorization
        }
    }

    private func receiptBytes(for request: PersistentLLDBAttachProgramRequest) -> Data {
        let payload = Phase2ProductionJSONValue.object([
            "adapter_generation": .number(String(request.adapterGeneration)),
            "correlation_token": .string(hex(request.correlationToken)),
            "error": .object([
                "code": .number("0"),
                "kind": .number("0"),
                "message_b64": .string(""),
                "message_truncated": .bool(false),
            ]),
            "lldb_unique_id": .number("8811"),
            "observed_pid": .number(String(request.authority.processID)),
            "request_sequence": .number(String(request.requestSequence)),
            "requested_pid": .number(String(request.authority.processID)),
            "schema": .number("1"),
            "selected_thread_id": .number("44"),
            "session_epoch": .string(request.sessionEpoch.rawValue.uuidString.lowercased()),
            "state": .string("stopped"),
            "stop_id": .number("19"),
            "stop_reason": .object([
                "data": .array([.number("5")]),
                "data_truncated": .bool(false),
                "kind": .string("signal"),
            ]),
            "target_path_b64": .string(
                Data(attachRequest.selectedIdentity.canonicalExecutablePath.utf8)
                    .base64EncodedString()
            ),
            "target_uuid": .string(
                attachRequest.selectedIdentity.machOUUID!.uuidString.lowercased()
            ),
        ])
        let payloadBytes = payload.canonicalJSONBytes()
        return Phase2ProductionJSONValue.object([
            "payload": payload,
            "payload_sha256": .string(
                SHA256.hash(data: payloadBytes).map { String(format: "%02x", $0) }.joined()
            ),
            "schema": .number("1"),
        ]).canonicalJSONBytes()
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

private actor RetirementRejectingRequestPreparer: PersistentLLDBCLIRequestPreparing {
    func prepareRequest(
        for context: DebuggerRequestContext
    ) async throws -> PersistentLLDBCLIRequest {
        throw RetirementExactAttachError.genericPreparerMustNotBeUsed
    }
}

private enum RetirementExactAttachError: Error {
    case missingPermit
    case genericPreparerMustNotBeUsed
    case missingWriteAuthorization
    case invalidWriteAuthorization
}

private actor RetirementByteChannel: PersistentLLDBCLIByteChannel {
    private(set) var writes: [Data] = []
    private(set) var closedInputCount = 0
    private(set) var closedHandleCount = 0
    private let blockWrite: Bool
    private let blockRead: Bool
    private var writeStarted = false
    private var writeStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var writeRelease: CheckedContinuation<Void, Never>?
    private var readRelease: CheckedContinuation<Void, Never>?

    init(blockWrite: Bool = false, blockRead: Bool = false) {
        self.blockWrite = blockWrite
        self.blockRead = blockRead
    }

    func write(_ data: Data) async throws {
        writes.append(data)
        writeStarted = true
        let waiters = writeStartWaiters
        writeStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if blockWrite {
            await withCheckedContinuation { continuation in
                writeRelease = continuation
            }
        }
    }

    func nextBytes() async throws -> Data? {
        if blockRead {
            await withCheckedContinuation { continuation in
                readRelease = continuation
            }
        }
        return nil
    }

    func waitUntilWriteStarts() async {
        if writeStarted { return }
        await withCheckedContinuation { continuation in
            writeStartWaiters.append(continuation)
        }
    }

    func releaseWrite() {
        writeRelease?.resume()
        writeRelease = nil
    }

    func closeInput() async {
        closedInputCount += 1
    }

    func closeHandles() async {
        closedHandleCount += 1
        readRelease?.resume()
        readRelease = nil
    }
}

private actor RetirementProcess: PersistentLLDBCLIRetainedProcess {
    enum Call: Equatable {
        case wait(Duration)
        case terminateRetainedAdapter
        case killRetainedAdapterIfStillRunning
        case reapAndClose
    }

    private(set) var calls: [Call] = []
    private var waitResults: [Bool]
    private let reapResult: Bool

    init(waitResults: [Bool], reapResult: Bool = true) {
        self.waitResults = waitResults
        self.reapResult = reapResult
    }

    func waitForExit(maximumDuration: Duration) async -> Bool {
        calls.append(.wait(maximumDuration))
        return waitResults.isEmpty ? true : waitResults.removeFirst()
    }

    func terminateRetainedAdapter() async {
        calls.append(.terminateRetainedAdapter)
    }

    func killRetainedAdapterIfStillRunning() async -> Bool {
        calls.append(.killRetainedAdapterIfStillRunning)
        return true
    }

    func reapAndClose() async -> Bool {
        calls.append(.reapAndClose)
        return reapResult
    }
}
