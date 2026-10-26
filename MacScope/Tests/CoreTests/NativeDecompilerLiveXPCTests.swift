import Darwin
import Foundation
import Security
import XCTest

@testable import MacScope

final class NativeDecompilerLiveXPCTests: XCTestCase {
    func testSignedServiceReturnsMalformedFailureAndHonorsCooperativeCancellation() async throws {
        #if MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING
        let signedProduct = try NativeDecompilerLiveSignedProduct.resolveFromTestHost()
        let authority = try NativeDecompilerLiveCodeAuthority(product: signedProduct)
        let session = try await NativeDecompilerLiveControlSession.open(authority: authority)
        defer { session.cleanupExactAuthenticatedProcessIfNeeded() }

        try await proveMalformedRawDataReturnsWireFailure(session: session)
        try await proveCooperativeCancellation(session: session)
        #else
        throw XCTSkip(
            "Run Scripts/native-decompiler-xpc/run_live_xpc_tests.sh with the exact "
                + "signed error-and-cancellation selector."
        )
        #endif
    }

    func testSignedServiceHonorsSupervisionAndRelaunchContract() async throws {
        #if MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING
        let signedProduct = try NativeDecompilerLiveSignedProduct.resolveFromTestHost()
        let authority = try NativeDecompilerLiveCodeAuthority(product: signedProduct)

        var cleanupSession: NativeDecompilerLiveControlSession?
        defer { cleanupSession?.cleanupExactAuthenticatedProcessIfNeeded() }

        let first = try await NativeDecompilerLiveControlSession.open(authority: authority)
        cleanupSession = first
        let firstIdentity = first.processIdentity
        try await proveRealNormalRequest(session: first)
        try await proveManualReleaseRunsRealProvider(session: first)
        try await proveBoundedQueueReturnsRealBusy(session: first)
        try await proveMalformedRawDataReturnsWireFailure(session: first)
        try await proveStaleReplyCannotAffectReplacementGeneration(session: first)
        try await proveCooperativeCancellation(session: first)
        try await proveUnresponsiveWatchdogTriggersServiceHardDeadline(session: first)
        try await first.waitUntilAutomaticallyTerminated(timeout: .seconds(8))
        first.invalidateAfterTermination()
        cleanupSession = nil

        let second = try await NativeDecompilerLiveControlSession.open(authority: authority)
        cleanupSession = second
        assertNewProcessInstance(second, differsFrom: firstIdentity)
        try await proveRealNormalRequest(session: second)
        let runtimeProbe = try await proveAuthenticatedCrashInterruptsWithoutRetry(session: second)
        second.invalidateAfterTermination()
        cleanupSession = nil

        let third = try await NativeDecompilerLiveControlSession.open(authority: authority)
        cleanupSession = third
        assertNewProcessInstance(third, differsFrom: second.processIdentity)
        try await proveAppRuntimeAcceptsReplacement(
            session: third,
            client: runtimeProbe.client,
            registry: runtimeProbe.registry,
            successorRequestID: runtimeProbe.successorRequestID
        )
        try await third.terminateUsingAuthenticatedSelfSIGKILL()
        third.invalidateAfterTermination()
        cleanupSession = nil

        try await NativeDecompilerLiveControlSession.proveWrongServiceRequirementRejected()
        #else
        throw XCTSkip(
            "Run Scripts/native-decompiler-xpc/run_live_xpc_tests.sh to compile the signed "
                + "test-control seam and execute this destructive lifecycle gate."
        )
        #endif
    }

    func testSignedProviderPreservesAuthoredSnapshotCalleeAndReadonlyDataContext() async throws {
        #if MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING
        let fixture = try Self.makeAuthoredSnapshotFixture()
        let projection = try NativeDecompilerSnapshotBuilder.build(from: fixture.snapshot,
            imageSlot: fixture.slot, functionID: fixture.functionID,
            budgets: NativeDecompilerProductBudgetProfile.v1.wireValue)
        XCTAssertEqual(projection.function.entryAddress.value, 0x1000)
        XCTAssertEqual(projection.function.endAddressExclusive.value, 0x1020)
        XCTAssertEqual(projection.memoryRegions.first?.rawBytes, fixture.callerBytes)
        XCTAssertTrue(projection.memoryRegions.allSatisfy {
            $0.rawBytes == $0.effectiveBytes && $0.appliedPatchIDs.isEmpty
        })
        XCTAssertTrue(projection.memoryRegions.contains {
            $0.startAddress.value == 0x1100 && $0.rawBytes == fixture.calleeBytes && $0.permissions == .readExecute
        })
        XCTAssertTrue(projection.memoryRegions.contains {
            $0.startAddress.value == 0x2000 && $0.rawBytes == Data([7, 0, 0, 0]) && $0.permissions == .read
        })
        XCTAssertEqual(Set(projection.authoredInputs.names.map(\.name)),
            ["authored_signed_callee", "authored_table"])
        XCTAssertFalse(projection.symbols.contains { $0.name.contains("sibling") })
        let request = try NativeDecompilerRequestProjection(snapshotProjection: projection)
            .makeRequestEnvelope(requestID: UUID())
        let encoded = try NativeDecompilerWireCodec().encodeRequest(request, matching: request.requestID)
        XCTAssertEqual(try NativeDecompilerWireCodec().decodeRequest(encoded, matching: request.requestID), request)

        let product = try NativeDecompilerLiveSignedProduct.resolveFromTestHost()
        let authority = try NativeDecompilerLiveCodeAuthority(product: product)
        let session = try await NativeDecompilerLiveControlSession.open(authority: authority)
        defer { session.cleanupExactAuthenticatedProcessIfNeeded() }
        let success = try await requestRealSuccess(session: session, envelope: request)
        let result = success.result
        XCTAssertEqual(result.image, projection.image)
        XCTAssertEqual(result.function, projection.function)
        XCTAssertEqual(result.requestSHA256, request.body.requestSHA256)
        _ = try assertProviderDocumentProjection(result, expectsTruncation: false)
        let call = try XCTUnwrap(result.calls.first { $0.targetAddress?.value == 0x1100 })
        XCTAssertEqual(call.targetSymbol, "authored_signed_callee")
        let prototypeID = try XCTUnwrap(call.prototypeTypeID)
        let prototype = try XCTUnwrap(result.types.first { $0.id == prototypeID })
        XCTAssertEqual(prototype.kind, .function)
        let returnID = try XCTUnwrap(prototype.returnTypeID)
        let returnType = try XCTUnwrap(result.types.first { $0.id == returnID })
        XCTAssertEqual(returnType.kind, .integer)
        XCTAssertEqual(returnType.byteSize?.value, 4)
        XCTAssertEqual(returnType.isSigned, true)
        XCTAssertEqual(prototype.parameterTypeIDs.count, 2)
        let pointerID = try XCTUnwrap(prototype.parameterTypeIDs.first)
        let pointer = try XCTUnwrap(result.types.first { $0.id == pointerID })
        XCTAssertEqual(pointer.kind, .pointer)
        let scalarID = try XCTUnwrap(pointer.pointeeTypeID)
        let scalar = try XCTUnwrap(result.types.first { $0.id == scalarID })
        XCTAssertEqual(scalar.kind, .structure)
        XCTAssertEqual(scalar.name, "Scalar")
        XCTAssertEqual(scalar.byteSize?.value, 4)
        XCTAssertEqual(scalar.fields.map(\.name), ["value"])
        let calleeTokens = result.tokens.filter { $0.text == "authored_signed_callee" }
        XCTAssertFalse(calleeTokens.isEmpty)
        XCTAssertTrue(calleeTokens.contains { token in
            token.entityReferences.contains { ($0.kind == .call && $0.id == call.id)
                || ($0.kind == .operation && $0.id == call.operationID) }
        })
        // Passing the object's address keeps its authored identity relevant even when the
        // readonly load is legitimately constant-folded. Never require a literal LOAD opcode.
        let dataTokens = result.tokens.filter { $0.text == "authored_table" }
        XCTAssertFalse(dataTokens.isEmpty)
        XCTAssertTrue(dataTokens.contains { !$0.entityReferences.isEmpty })
        XCTAssertFalse(result.tokens.contains { $0.text.contains("sibling") })
        for range in result.tokens.flatMap(\.sourceRanges) + call.sourceRanges {
            XCTAssertEqual(range.imageID, projection.image.imageID)
            XCTAssertGreaterThanOrEqual(range.startAddress.value, 0x1000)
            XCTAssertLessThanOrEqual(range.endAddressExclusive.value, 0x1020)
        }
        try await proveCP4ProductionReplies(session: session)
        #else
        throw XCTSkip("Run the signing-aware authored snapshot/context live-XPC selector.")
        #endif
    }

    func testSignedProviderTokenAndSourceScalarsProjectForCompleteAndTruncatedDocuments() async throws {
        #if MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING
        let product = try NativeDecompilerLiveSignedProduct.resolveFromTestHost()
        let authority = try NativeDecompilerLiveCodeAuthority(product: product)
        let session = try await NativeDecompilerLiveControlSession.open(authority: authority)
        defer { session.cleanupExactAuthenticatedProcessIfNeeded() }

        let complete = try await requestRealSuccess(
            session: session,
            envelope: Self.makeRequest(requestID: UUID())
        )
        let completeProjection = try assertProviderDocumentProjection(
            complete.result,
            expectsTruncation: false
        )
        XCTAssertEqual(completeProjection.mappingState, .verified)
        XCTAssertEqual(completeProjection.tokenRuns.count, complete.result.tokens.count)

        let truncated = try await requestRealSuccess(
            session: session,
            envelope: Self.makeTruncatingTokenRequest(requestID: UUID())
        )
        let truncatedProjection = try assertProviderDocumentProjection(
            truncated.result,
            expectsTruncation: true
        )
        XCTAssertEqual(truncatedProjection.mappingState, .verified)
        XCTAssertLessThan(truncatedProjection.tokenRuns.count, truncated.result.tokens.count)

        let omissions = classifyTruncatedTokenOmissions(
            document: try XCTUnwrap(truncated.result.pseudocodeDocument),
            tokens: truncated.result.tokens
        )
        XCTAssertGreaterThan(omissions.boundaryCrossing, 0)
        XCTAssertGreaterThan(omissions.beyondVisiblePrefix, 0)
        #else
        throw XCTSkip("Run the signing-aware provider-token live-XPC selector.")
        #endif
    }
}

#if MACSCOPE_NATIVE_DECOMPILER_LIVE_XPC_TESTING
private extension NativeDecompilerLiveXPCTests {
    struct TruncatedTokenOmissions {
        var boundaryCrossing = 0
        var beyondVisiblePrefix = 0
    }

    func requestRealSuccess(
        session: NativeDecompilerLiveControlSession,
        envelope: NativeDecompilerWireRequestEnvelope,
        expectedSchemaVersion: UInt32? = nil
    ) async throws -> NativeDecompilerWireSuccess {
        let requestID = envelope.requestID
        try await session.configure(requestID: requestID, mode: .normal)
        let client = makeClient()
        let request = NativeDecompilerLiveAsyncRequest()
        await request.start(
            client: client,
            requestID: requestID,
            envelope: envelope,
            elapsedTimeBudget: .seconds(10)
        )
        try await session.waitUntilEntered(requestID: requestID)

        let reply = try await request.value()
        XCTAssertEqual(reply.requestID, requestID)
        XCTAssertEqual(reply.outcome, .success)
        if let expectedSchemaVersion { XCTAssertEqual(reply.schemaVersion, expectedSchemaVersion) }
        XCTAssertNil(reply.failure)
        XCTAssertEqual(client.snapshot.pendingRequestCount, 0)
        return try XCTUnwrap(reply.success)
    }

    func proveCP4ProductionReplies(session: NativeDecompilerLiveControlSession) async throws {
        // Small checked-in vectors from the CP4 contract suite. They exercise
        // final-CFG ownership and AuthIB through the signed production worker.
        let fixtures: [(String, [UInt32])] = [
            ("multi-owner-csel", [0x7100_001f, 0x1a82_0020, 0xd65f_03c0]),
            ("zero-op-loop", [0x3400_0060, 0x5100_0400, 0x17ff_fffe, 0xd65f_03c0]),
            ("standalone-autibsp", [0xd503_23ff, 0xd65f_03c0]),
        ]
        for (name, words) in fixtures {
            var bytes = Data()
            for word in words { Self.appendLittleEndian(word, to: &bytes) }
            let envelope = Self.makeRequest(
                requestID: UUID(), functionID: "function.cp4.\(name)",
                functionName: "_cp4_\(name)", functionBytes: bytes, additionalSymbols: []
            )
            XCTAssertEqual(envelope.schemaVersion, 3)
            let success = try await requestRealSuccess(
                session: session, envelope: envelope, expectedSchemaVersion: 4
            )
            let result = success.result
            XCTAssertEqual(success.availability.runtimeIdentity.backendID, "ghidra-native-decompiler")
            XCTAssertEqual(result.requestSHA256, envelope.body.requestSHA256)
            XCTAssertEqual(result.instructions.reduce(into: Data()) { $0.append($1.bytes) }, bytes)
            XCTAssertFalse(result.warnings.contains { $0.code.contains("fallback") })
            if name == "standalone-autibsp" {
                let effect = try XCTUnwrap(result.operations.first {
                    $0.authenticationEffect.kind == .standaloneAuthenticationWithoutTransformedOutput
                })
                XCTAssertEqual(effect.userOperationName, "AuthIB")
                XCTAssertNil(effect.outputVarnodeID)
                XCTAssertNil(effect.authenticationEffect.outputSSAValueID)
            } else {
                let partition = try XCTUnwrap(result.blockPartition, name)
                XCTAssertEqual(partition.version, 1)
                XCTAssertEqual(partition.blocks.count, result.blocks.count)
                XCTAssertEqual(partition.instructions.count, result.instructions.count)
                XCTAssertEqual(partition.edges.count, result.edges.count)
                if name == "zero-op-loop" {
                    XCTAssertTrue(result.blocks.contains { $0.operationIDs.isEmpty })
                    XCTAssertTrue(partition.edges.contains { $0.transferKind == .splice })
                } else {
                    XCTAssertTrue(partition.instructions.contains { $0.spans.count > 1 })
                }
            }
        }
    }

    func assertProviderDocumentProjection(
        _ result: NativeDecompilerWireStructuredResult,
        expectsTruncation: Bool
    ) throws -> NativeDecompilerDocumentProjection {
        let document = try XCTUnwrap(result.pseudocodeDocument)
        XCTAssertFalse(result.tokens.isEmpty)
        XCTAssertEqual(document.isComplete, !expectsTruncation)
        XCTAssertEqual(document.isTruncated, expectsTruncation)
        for token in result.tokens {
            XCTAssertGreaterThan(token.line, 0)
            XCTAssertGreaterThan(token.column, 0)
            XCTAssertFalse(token.sourceRanges.isEmpty)
            for range in token.sourceRanges {
                XCTAssertEqual(range.imageID, result.image.imageID)
                XCTAssertLessThan(range.startAddress.value, range.endAddressExclusive.value)
            }
        }
        let projection = try NativeDecompilerDocumentProjector.project(
            document: document,
            tokens: result.tokens,
            isCancelled: { false }
        )
        XCTAssertTrue(projection.text.utf8.elementsEqual(document.text.utf8))
        return projection
    }

    func classifyTruncatedTokenOmissions(
        document: NativeDecompilerWirePseudocodeDocument,
        tokens: [NativeDecompilerWirePseudocodeTokenRecord]
    ) -> TruncatedTokenOmissions {
        XCTAssertTrue(document.isTruncated)
        let lines = Self.scalarLines(in: document.text)
        var omissions = TruncatedTokenOmissions()
        for token in tokens {
            guard token.line > 0, token.column > 0 else {
                omissions.beyondVisiblePrefix += 1
                continue
            }
            let lineIndex = Int(token.line - 1)
            guard lineIndex < lines.count else {
                omissions.beyondVisiblePrefix += 1
                continue
            }
            let columnIndex = Int(token.column - 1)
            guard columnIndex < lines[lineIndex].count else {
                omissions.beyondVisiblePrefix += 1
                continue
            }
            if columnIndex + token.text.unicodeScalars.count > lines[lineIndex].count {
                omissions.boundaryCrossing += 1
            }
        }
        return omissions
    }

    static func scalarLines(in text: String) -> [[Unicode.Scalar]] {
        var lines: [[Unicode.Scalar]] = [[]]
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                lines.append([])
            } else if scalar != "\r" {
                lines[lines.index(before: lines.endIndex)].append(scalar)
            }
        }
        return lines
    }

    func proveRealNormalRequest(session: NativeDecompilerLiveControlSession) async throws {
        let requestID = UUID()
        try await session.configure(requestID: requestID, mode: .normal)
        let client = makeClient()
        let request = await startRequest(client: client, requestID: requestID)

        try await session.waitUntilEntered(requestID: requestID)
        let reply = try await request.value()

        assertRealSuccess(reply, requestID: requestID)
        XCTAssertEqual(client.snapshot.connectionGeneration, 1)
        XCTAssertEqual(client.snapshot.pendingRequestCount, 0)
    }

    func proveManualReleaseRunsRealProvider(
        session: NativeDecompilerLiveControlSession
    ) async throws {
        let requestID = UUID()
        try await session.configure(requestID: requestID, mode: .manual)
        let client = makeClient()
        let request = await startRequest(client: client, requestID: requestID)

        try await session.waitUntilEntered(requestID: requestID)
        XCTAssertEqual(client.snapshot.pendingRequestCount, 1)
        try await session.releaseManual(requestID: requestID)
        let reply = try await request.value()

        assertRealSuccess(reply, requestID: requestID)
        XCTAssertEqual(client.snapshot.connectionGeneration, 1)
        XCTAssertEqual(client.snapshot.pendingRequestCount, 0)
    }

    func proveCooperativeCancellation(
        session: NativeDecompilerLiveControlSession
    ) async throws {
        let requestID = UUID()
        try await session.configure(requestID: requestID, mode: .cooperativeCancellation)
        let client = makeClient()
        let request = await startRequest(client: client, requestID: requestID)

        try await session.waitUntilEntered(requestID: requestID)
        await request.cancel()
        await assertFailure(.cancelled, from: request)

        XCTAssertEqual(client.snapshot.connectionGeneration, 1)
        XCTAssertEqual(client.snapshot.pendingRequestCount, 0)
    }

    func proveBoundedQueueReturnsRealBusy(
        session: NativeDecompilerLiveControlSession
    ) async throws {
        let activeRequestID = UUID()
        let queuedRequestID = UUID()
        let busyRequestID = UUID()
        try await session.configure(requestID: activeRequestID, mode: .manual)
        try await session.configure(requestID: queuedRequestID, mode: .manual)

        let activeClient = makeClient()
        let queuedClient = makeClient()
        let busyClient = makeClient()
        let activeRequest = await startRequest(
            client: activeClient,
            requestID: activeRequestID
        )
        try await session.waitUntilEntered(requestID: activeRequestID)

        let queuedRequest = await startRequest(
            client: queuedClient,
            requestID: queuedRequestID
        )
        try await session.waitUntilEvent(
            requestID: queuedRequestID,
            event: .submittedQueued
        )

        let busyRequest = await startRequest(
            client: busyClient,
            requestID: busyRequestID
        )
        let busyReply = try await busyRequest.value()
        assertWireFailure(busyReply, requestID: busyRequestID, code: .busy)

        try await session.releaseManual(requestID: activeRequestID)
        try await session.waitUntilEntered(requestID: queuedRequestID)
        try await session.releaseManual(requestID: queuedRequestID)
        assertRealSuccess(try await activeRequest.value(), requestID: activeRequestID)
        assertRealSuccess(try await queuedRequest.value(), requestID: queuedRequestID)

        XCTAssertEqual(activeClient.snapshot.pendingRequestCount, 0)
        XCTAssertEqual(queuedClient.snapshot.pendingRequestCount, 0)
        XCTAssertEqual(busyClient.snapshot.pendingRequestCount, 0)
    }

    func proveMalformedRawDataReturnsWireFailure(
        session: NativeDecompilerLiveControlSession
    ) async throws {
        let requestID = UUID()
        try await session.configure(requestID: requestID, mode: .normal)
        let replyData = try await session.decompileRaw(
            requestID: requestID,
            payload: Data([0x00, 0x01])
        )
        let reply = try NativeDecompilerWireCodec().decodeReply(
            replyData,
            matching: requestID
        )
        assertWireFailure(reply, requestID: requestID, code: .malformedRequest)
    }

    func proveStaleReplyCannotAffectReplacementGeneration(
        session: NativeDecompilerLiveControlSession
    ) async throws {
        let staleRequestID = UUID()
        let replacementRequestID = UUID()
        let client = makeClient(
            watchdog: .seconds(10),
            cooperativeGrace: .milliseconds(100)
        )

        try await session.configure(requestID: staleRequestID, mode: .manual)
        let staleRequest = await startRequest(
            client: client,
            requestID: staleRequestID,
            elapsedTimeBudget: .milliseconds(200)
        )
        try await session.waitUntilEntered(requestID: staleRequestID)
        await assertFailure(.timedOut, from: staleRequest)

        let timedOutSnapshot = client.snapshot
        XCTAssertEqual(timedOutSnapshot.connectionGeneration, 1)
        XCTAssertFalse(timedOutSnapshot.hasConnection)
        XCTAssertEqual(timedOutSnapshot.pendingRequestCount, 0)

        try await session.configure(requestID: replacementRequestID, mode: .normal)
        let replacementRequest = await startRequest(
            client: client,
            requestID: replacementRequestID
        )
        try await session.waitUntilEvent(
            requestID: replacementRequestID,
            event: .submittedQueued
        )
        let queuedSnapshot = client.snapshot
        XCTAssertEqual(queuedSnapshot.connectionGeneration, 2)
        XCTAssertEqual(queuedSnapshot.pendingRequestCount, 1)

        try await session.releaseManual(requestID: staleRequestID)
        try await session.waitUntilEvent(
            requestID: staleRequestID,
            event: .replyAttempted
        )
        try await session.waitUntilEntered(requestID: replacementRequestID)
        assertRealSuccess(
            try await replacementRequest.value(),
            requestID: replacementRequestID
        )

        let replacementSnapshot = client.snapshot
        XCTAssertEqual(replacementSnapshot.connectionGeneration, 2)
        XCTAssertTrue(replacementSnapshot.hasConnection)
        XCTAssertEqual(replacementSnapshot.pendingRequestCount, 0)
        try await session.pingAndReauthenticate()
    }

    func proveUnresponsiveWatchdogTriggersServiceHardDeadline(
        session: NativeDecompilerLiveControlSession
    ) async throws {
        let requestID = UUID()
        try await session.configure(requestID: requestID, mode: .unresponsive)
        let client = makeClient(
            watchdog: .milliseconds(200),
            cooperativeGrace: .milliseconds(100)
        )
        let request = await startRequest(
            client: client,
            requestID: requestID,
            elapsedTimeBudget: .milliseconds(200)
        )

        try await session.waitUntilEntered(requestID: requestID)
        await assertFailure(.timedOut, from: request)

        let snapshot = client.snapshot
        XCTAssertEqual(snapshot.connectionGeneration, 1, "timed-out work must never retry")
        XCTAssertFalse(snapshot.hasConnection, "watchdog grace must invalidate the exact connection")
        XCTAssertEqual(snapshot.pendingRequestCount, 0, "late service work has no publishable request")
    }

    func proveAuthenticatedCrashInterruptsWithoutRetry(
        session: NativeDecompilerLiveControlSession
    ) async throws -> (
        client: NativeDecompilerXPCClient,
        registry: NativeDecompilerRuntimeRegistry,
        successorRequestID: UUID
    ) {
        let requestID = UUID()
        let successorRequestID = UUID()
        try await session.configure(requestID: requestID, mode: .manual)
        let client = makeClient(
            watchdog: .seconds(5),
            cooperativeGrace: .milliseconds(100)
        )
        let registry = NativeDecompilerRuntimeRegistry.testing(
            policy: NativeDecompilerRuntimePolicy(isEnabled: true),
            dispatcher: client,
            authorityProvider: NativeDecompilerBundleRuntimeAuthorityProvider()
        )
        registry.bindProcessLifecycle(to: client)
        let request = await startRequest(client: client, requestID: requestID)

        try await session.waitUntilEntered(requestID: requestID)
        try await session.terminateUsingAuthenticatedSelfSIGKILL()
        await assertFailure(.interrupted, from: request)
        try await assertRuntimeEpoch(2, registry: registry)

        let snapshot = client.snapshot
        XCTAssertEqual(snapshot.connectionGeneration, 1, "a crash must never retry the request")
        XCTAssertFalse(snapshot.hasConnection)
        XCTAssertEqual(snapshot.pendingRequestCount, 0)
        return (client, registry, successorRequestID)
    }

    func proveAppRuntimeAcceptsReplacement(
        session: NativeDecompilerLiveControlSession,
        client: NativeDecompilerXPCClient,
        registry: NativeDecompilerRuntimeRegistry,
        successorRequestID: UUID
    ) async throws {
        try await session.configure(
            requestID: successorRequestID,
            mode: .normal,
            timeout: .seconds(20)
        )
        let successorRequest = await startRequest(
            client: client,
            requestID: successorRequestID
        )
        assertRealSuccess(
            try await successorRequest.value(),
            requestID: successorRequestID
        )
        XCTAssertEqual(client.snapshot.connectionGeneration, 2)
        XCTAssertEqual(client.snapshot.pendingRequestCount, 0)
    }

    func assertRuntimeEpoch(
        _ expected: UInt64,
        registry: NativeDecompilerRuntimeRegistry
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if await registry.processRuntimeSnapshotForTesting().epoch == expected {
                return
            }
            await Task.yield()
        }
        let finalSnapshot = await registry.processRuntimeSnapshotForTesting()
        XCTAssertEqual(
            finalSnapshot.epoch,
            expected,
            "the current signed XPC lifecycle event must replace the app runtime epoch"
        )
    }

    func assertNewProcessInstance(
        _ session: NativeDecompilerLiveControlSession,
        differsFrom old: NativeDecompilerLiveProcessIdentity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNotEqual(
            session.processIdentity.processInstanceID,
            old.processInstanceID,
            "relaunch must mint a new process-global instance identity",
            file: file,
            line: line
        )
        XCTAssertNotEqual(
            session.processIdentity.kernel,
            old.kernel,
            "relaunch must have a distinct kernel PID/start identity",
            file: file,
            line: line
        )
    }

    func makeClient(
        watchdog: Duration = .seconds(15),
        cooperativeGrace: Duration = .milliseconds(250)
    ) -> NativeDecompilerXPCClient {
        NativeDecompilerXPCClient(
            configuration: .init(
                defaultWatchdog: watchdog,
                cooperativeGrace: cooperativeGrace
            )
        )
    }

    func startRequest(
        client: NativeDecompilerXPCClient,
        requestID: UUID,
        elapsedTimeBudget: Duration = .seconds(10)
    ) async -> NativeDecompilerLiveAsyncRequest {
        let request = NativeDecompilerLiveAsyncRequest()
        await request.start(
            client: client,
            requestID: requestID,
            envelope: Self.makeRequest(
                requestID: requestID
            ),
            elapsedTimeBudget: elapsedTimeBudget
        )
        return request
    }

    struct AuthoredSnapshotFixture {
        let snapshot: WorkspaceSnapshot
        let slot: ImageSlot
        let functionID: UUID
        let callerBytes: Data
        let calleeBytes: Data
    }

    static func makeAuthoredSnapshotFixture() throws -> AuthoredSnapshotFixture {
        let slot = ImageSlot(rawValue: 7), functionID = UUID()
        func assemble(_ instructions: [String], at start: UInt64) throws -> Data {
            var bytes = Data()
            for (index, instruction) in instructions.enumerated() {
                let address = start + UInt64(index * 4)
                switch ARM64Assembler().assemble(instruction, at: address) {
                case let .success(encoded):
                    XCTAssertEqual(encoded.count, 4)
                    let decoded = ARM64Decoder().decode(Data(encoded), baseAddress: address, maxInstructionCount: 1)
                    XCTAssertEqual(decoded.count, 1)
                    bytes.append(contentsOf: encoded)
                case let .failure(diagnostic):
                    throw NSError(domain: "NativeAuthoredContextFixture", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Cannot assemble \(instruction): \(diagnostic)"])
                }
            }
            return bytes
        }
        let caller = try assemble([
            "sub sp, sp, #16", "str x30, [sp, #8]", "mov x0, #0x2000", "ldr w1, [x0]",
            "bl 0x1100", "ldr x30, [sp, #8]", "add sp, sp, #16", "ret",
        ], at: 0x1000)
        let callee = try assemble(["ldr w0, [x0]", "add w0, w0, w1", "ret"], at: 0x1100)
        let nop = try assemble(["nop"], at: 0x1020)
        var bytes = caller
        while bytes.count < 0x100 { bytes.append(nop) }
        bytes.append(callee)
        for _ in 0..<16 { bytes.append(nop) }
        let textCount = bytes.count
        // Keep one consistent preferred base (VM - file offset == 0x1000) across segments.
        while bytes.count < 0x1000 { bytes.append(0) }
        let constFileOffset = bytes.count
        bytes.append(contentsOf: [7, 0, 0, 0])
        let artifact = try MachOSliceArtifactIdentity(uuid: UUID(), rawCPUType: MachOConstants.cpuTypeARM64,
            rawCPUSubtype: 0, selectedSliceSHA256: AnalysisFingerprintBuilder.sha256Hex(bytes),
            selectedSliceByteCount: UInt64(bytes.count))
        let segments: [MachOPreferredSegmentLayout.Record] = [
            .init(name: "__TEXT", preferredVMStart: 0x1000, preferredVMSize: UInt64(textCount),
                sliceRelativeFileOffset: 0, fileSize: UInt64(textCount), initialProtections: 5),
            .init(name: "__CONST", preferredVMStart: 0x2000, preferredVMSize: 4,
                sliceRelativeFileOffset: UInt64(constFileOffset), fileSize: 4, initialProtections: 1),
        ]
        let layout = try MachOPreferredSegmentLayout(records: segments, selectedSliceByteCount: UInt64(bytes.count))
        let binary = BinaryImage(id: UUID(), name: "assembled-authored-context", path: "/fixture/not-reopened",
            kind: "Mach-O 64-bit", architecture: "arm64", artifactIdentity: artifact,
            preferredSegmentLayout: layout, artifactIntegrityState: .verified, slot: slot)
        let attestations = try segments.map { segment in
            let lower = Int(segment.sliceRelativeFileOffset), upper = Int(segment.sliceRelativeFileOffset + segment.fileSize)
            return try IdentityEffectiveByteRangeAttestation(artifactIdentity: artifact, segmentName: segment.name,
                startAddress: segment.preferredVMStart, endAddressExclusive: segment.preferredVMStart + segment.fileSize,
                sliceRelativeFileOffset: segment.sliceRelativeFileOffset, byteCount: segment.fileSize,
                initialProtections: segment.initialProtections,
                rawBytesSHA256: AnalysisFingerprintBuilder.sha256Hex(bytes.subdata(in: lower..<upper)))
        }
        // ImageAnalysis stores listing rows, not raw decoder output: project each decoded
        // instruction exactly as AnalysisEngine does (DecodedInstruction -> InstructionRow).
        let decodedInstructions: [DecodedInstruction] =
            ARM64Decoder().decode(caller, baseAddress: 0x1000, maxInstructionCount: 8)
            + ARM64Decoder().decode(callee, baseAddress: 0x1100, maxInstructionCount: 3)
        let instructionRows: [InstructionRow] = decodedInstructions.map { decoded in
            InstructionRow(address: decoded.address, bytes: decoded.byteText, mnemonic: decoded.mnemonic,
                operands: decoded.operands, hasBreakpoint: false, comment: decoded.comment)
        }
        let functions: [FunctionSummary] = [
            FunctionSummary(id: functionID, name: "_fixture_caller", startAddress: 0x1000, endAddress: 0x1020, confidence: 1),
            FunctionSummary(id: UUID(), name: "_fixture_callee", startAddress: 0x1100, endAddress: 0x110c, confidence: 1),
        ]
        let symbols: [SymbolSummary] = [
            SymbolSummary(id: UUID(), name: "_fixture_callee", address: 0x1100, kind: "function", libraryName: nil,
                rawLinkageName: "_fixture_callee"),
            SymbolSummary(id: UUID(), name: "_fixture_table", address: 0x2000, kind: "data", libraryName: nil,
                rawLinkageName: "_fixture_table"),
        ]
        let xrefs: [XRef] = [
            XRef(id: UUID(), from: 0x1010, to: 0x1100, kind: XRefKind.call),
            XRef(id: UUID(), from: 0x100c, to: 0x2000, kind: XRefKind.data),
        ]
        var analysis = ImageAnalysis(functions: functions, symbols: symbols, instructions: instructionRows,
            xrefs: xrefs, identityEffectiveByteRanges: attestations, imageBytes: bytes)
        analysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(binary: binary, analysis: analysis)
        let sibling = BinaryImage(id: UUID(), name: "sibling", path: "/fixture/sibling-not-reopened",
            kind: binary.kind, architecture: binary.architecture, artifactIdentity: artifact,
            preferredSegmentLayout: layout, artifactIntegrityState: .verified, slot: .primary)
        var siblingAnalysis: ImageAnalysis = analysis
        siblingAnalysis.symbols = [SymbolSummary(id: UUID(), name: "sibling_callee", address: 0x1100,
            kind: "function", libraryName: nil, rawLinkageName: "sibling_callee")]
        siblingAnalysis.analysisInputFingerprint = try AnalysisFingerprintBuilder.fingerprint(binary: sibling, analysis: siblingAnalysis)
        var snapshot = WorkspaceSnapshot(binaries: [sibling, binary], analysisBySlot: [.primary: siblingAnalysis, slot: analysis])
        snapshot.typeDefinitions = [
            TypeDefinition(kind: .struct, name: "Scalar", fields: [FieldDef(name: "value", type: "int32_t")]),
        ]
        let authoredSignature = FunctionSignatureOverride(returnType: "int32_t",
            parameterList: .authoritative([
                ArgOverride(rowToken: "table", name: "table", type: "const Scalar *", provenance: .user),
                ArgOverride(rowToken: "observed", name: "observed", type: "int32_t", provenance: .user),
            ]), variadicState: .fixed, noReturnState: .returns)
        let siblingSignature = FunctionSignatureOverride(returnType: "uint64_t")
        let overrides: [ImageAddress: AddressOverride] = [
            ImageAddress(slot: slot, address: 0x1100): AddressOverride(customName: "authored_signed_callee",
                signature: authoredSignature),
            ImageAddress(slot: slot, address: 0x2000): AddressOverride(customName: "authored_table", appliedTypeName: "Scalar"),
            ImageAddress(slot: .primary, address: 0x1100): AddressOverride(customName: "sibling_callee",
                signature: siblingSignature),
            ImageAddress(slot: .primary, address: 0x2000): AddressOverride(customName: "sibling_table", appliedTypeName: "Scalar"),
        ]
        snapshot.addressOverrides = overrides
        return .init(snapshot: snapshot, slot: slot, functionID: functionID, callerBytes: caller, calleeBytes: callee)
    }

    static func makeRequest(requestID: UUID) -> NativeDecompilerWireRequestEnvelope {
        makeRequest(
            requestID: requestID,
            functionID: "function.live-xpc.return-forty-two",
            functionName: "_returnFortyTwo",
            functionBytes: Data([
                0x40, 0x05, 0x80, 0x52,
                0xc0, 0x03, 0x5f, 0xd6,
            ]),
            additionalSymbols: []
        )
    }

    static func makeTruncatingTokenRequest(
        requestID: UUID
    ) -> NativeDecompilerWireRequestEnvelope {
        let entryAddress: UInt64 = 0x1000
        let calleeAddress: UInt64 = 0x1_100
        let functionName = "_" + String(repeating: "f", count: 507)
        let calleeName = "_" + String(repeating: "p", count: 68)
            + String(repeating: "t", count: 430)
        var functionBytes = Data([0x00, 0x04, 0x00, 0x11])
        for callIndex in 0..<57 {
            let instructionAddress = entryAddress + 4 + UInt64(callIndex * 4)
            let displacement = Int64(calleeAddress) - Int64(instructionAddress)
            let immediate = UInt32(truncatingIfNeeded: displacement >> 2) & 0x03ff_ffff
            appendLittleEndian(0x9400_0000 | immediate, to: &functionBytes)
        }
        appendLittleEndian(0xd65f_03c0, to: &functionBytes)
        return makeRequest(
            requestID: requestID,
            functionID: "function.live-xpc.truncated-provider-tokens",
            functionName: functionName,
            functionBytes: functionBytes,
            authoredInputs: NativeDecompilerWireAuthoredInputs(
                schemaVersion: 1,
                names: [
                    .init(
                        address: .init(entryAddress),
                        subjectKind: .function,
                        name: functionName
                    ),
                    .init(
                        address: .init(calleeAddress),
                        subjectKind: .function,
                        name: calleeName
                    ),
                ],
                signatures: [],
                appliedTypes: [],
                typeDefinitions: []
            ),
            additionalSymbols: [
                .init(
                    imageID: "image.live-xpc",
                    address: .init(calleeAddress),
                    name: calleeName,
                    kind: .function
                ),
            ]
        )
    }

    static func makeRequest(
        requestID: UUID,
        functionID: String,
        functionName: String,
        functionBytes: Data,
        authoredInputs: NativeDecompilerWireAuthoredInputs = .empty,
        additionalSymbols: [NativeDecompilerWireSymbolRecord]
    ) -> NativeDecompilerWireRequestEnvelope {
        let image = NativeDecompilerWireImageIdentity(
            imageID: "image.live-xpc",
            uuid: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!,
            preferredLoadAddress: .init(0x1000)
        )
        let function = NativeDecompilerWireFunctionIdentity(
            functionID: functionID,
            name: functionName,
            entryAddress: .init(0x1000),
            endAddressExclusive: .init(0x1000 + UInt64(functionBytes.count))
        )
        var effectiveBytes = functionBytes
        let nop = Data([0x1f, 0x20, 0x03, 0xd5])
        while effectiveBytes.count < functionBytes.count + 64 { effectiveBytes.append(nop) }

        let target = try! NativeDecompilerSealedTargetProfile.normalizedTarget(
            rawCPUType: 0x0100_000c,
            rawCPUSubtype: 0,
            selectedSliceSHA256: String(repeating: "4", count: 64),
            selectedSliceByteCount: UInt64(effectiveBytes.count)
        )
        let memoryRegions = [
            NativeDecompilerWireMemoryRegion(
                name: "__text",
                startAddress: .init(0x1000),
                permissions: .readExecute,
                rawBytes: Data(repeating: 0, count: effectiveBytes.count),
                effectiveBytes: effectiveBytes,
                appliedPatchIDs: ["patch000001"]
            ),
        ]
        let symbols = [
            NativeDecompilerWireSymbolRecord(
                imageID: image.imageID,
                address: function.entryAddress,
                name: function.name,
                kind: .function
            ),
        ] + additionalSymbols
        let profiledBudgets = NativeDecompilerProductBudgetProfile.v1
        let requestSHA256 = try! NativeDecompilerWireCanonicalRequest.sha256(
            schemaVersion: NativeDecompilerWireRequestEnvelope.currentSchemaVersion,
            operation: .decompile,
            target: target,
            image: image,
            function: function,
            memoryRegions: memoryRegions,
            symbols: symbols,
            authoredInputs: authoredInputs,
            budgets: profiledBudgets
        )

        let body = NativeDecompilerWireRequest(
            requestID: requestID,
            requestSHA256: requestSHA256,
            target: target,
            image: image,
            function: function,
            memoryRegions: memoryRegions,
            symbols: symbols,
            authoredInputs: authoredInputs,
            budgets: .init(
                profileID: profiledBudgets.profileID,
                maxCodeBytes: profiledBudgets.maxCodeBytes,
                maxInstructions: profiledBudgets.maxInstructions,
                maxOperations: profiledBudgets.maxOperations,
                maxOutputBytes: profiledBudgets.maxOutputBytes,
                maxWallTimeMilliseconds: profiledBudgets.maxWallTimeMilliseconds
            )
        )
        return .init(requestID: requestID, body: body)
    }

    static func appendLittleEndian(_ word: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: word))
        data.append(UInt8(truncatingIfNeeded: word >> 8))
        data.append(UInt8(truncatingIfNeeded: word >> 16))
        data.append(UInt8(truncatingIfNeeded: word >> 24))
    }

    func assertRealSuccess(
        _ reply: NativeDecompilerWireReplyEnvelope,
        requestID: UUID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(reply.requestID, requestID, file: file, line: line)
        XCTAssertEqual(reply.outcome, .success, file: file, line: line)
        XCTAssertNil(reply.failure, file: file, line: line)
        guard let success = reply.success else {
            return XCTFail("real native request returned no success payload", file: file, line: line)
        }
        XCTAssertTrue(success.availability.available, file: file, line: line)
        XCTAssertEqual(
            success.result.function.functionID,
            "function.live-xpc.return-forty-two",
            file: file,
            line: line
        )
        let instructionBytes = success.result.instructions.reduce(into: Data()) {
            $0.append($1.bytes)
        }
        XCTAssertEqual(
            instructionBytes,
            Data([0x40, 0x05, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6]),
            "published instruction bytes must be the caller-owned effective bytes",
            file: file,
            line: line
        )
    }

    func assertWireFailure(
        _ reply: NativeDecompilerWireReplyEnvelope,
        requestID: UUID,
        code: NativeDecompilerWireFailureCode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(reply.requestID, requestID, file: file, line: line)
        XCTAssertEqual(reply.outcome, .failure, file: file, line: line)
        XCTAssertNil(reply.success, file: file, line: line)
        XCTAssertEqual(reply.failure?.code, code, file: file, line: line)
        XCTAssertNil(reply.failure?.detail, file: file, line: line)
    }

    func assertFailure(
        _ expected: NativeDecompilerXPCClientFailure,
        from request: NativeDecompilerLiveAsyncRequest,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let reply = try await request.value()
            XCTFail("expected \(expected.rawValue), received \(reply.outcome)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? NativeDecompilerXPCClientFailure, expected, file: file, line: line)
        }
    }
}

private actor NativeDecompilerLiveAsyncRequest {
    private typealias Outcome = Result<
        NativeDecompilerWireReplyEnvelope,
        NativeDecompilerXPCClientFailure
    >

    private var task: Task<Void, Never>?
    private var outcome: Outcome?
    private var waiters: [CheckedContinuation<Outcome, Never>] = []

    func start(
        client: NativeDecompilerXPCClient,
        requestID: UUID,
        envelope: NativeDecompilerWireRequestEnvelope,
        elapsedTimeBudget: Duration
    ) {
        precondition(task == nil, "live request task may only be installed once")
        task = Task { [weak self, client, requestID, envelope, elapsedTimeBudget] in
            let result: Outcome
            do {
                let dispatchRequest = try NativeDecompilerPreencodedDispatchRequest(
                    projection: .init(request: envelope.body),
                    requestID: requestID
                )
                let reply = try await client.decompile(
                    request: dispatchRequest,
                    elapsedTimeBudget: elapsedTimeBudget
                )
                result = .success(reply)
            } catch let failure as NativeDecompilerXPCClientFailure {
                result = .failure(failure)
            } catch {
                result = .failure(.connectionUnavailable)
            }
            await self?.finish(result)
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func finish(_ result: Outcome) {
        guard outcome == nil else { return }
        outcome = result
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(returning: result) }
    }

    func value() async throws -> NativeDecompilerWireReplyEnvelope {
        let result: Outcome
        if let outcome {
            result = outcome
        } else {
            result = await withCheckedContinuation { waiters.append($0) }
        }
        return try result.get()
    }
}

private struct NativeDecompilerLiveSignedProduct {
    static let appIdentifier = "org.macscope.app"
    static let serviceIdentifier = "org.macscope.app.NativeDecompiler"
    static let serviceExecutableName = "NativeDecompilerXPCService"

    let appURL: URL
    let serviceBundleURL: URL
    let serviceExecutableURL: URL

    static func resolveFromTestHost() throws -> Self {
        let appURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        guard appURL.pathExtension == "app",
              Bundle.main.bundleIdentifier == appIdentifier
        else { throw NativeDecompilerLiveXPCTestError.invalidTestHost }

        let serviceURL = appURL.appendingPathComponent(
            "Contents/XPCServices/NativeDecompilerXPCService.xpc",
            isDirectory: true
        ).resolvingSymlinksInPath().standardizedFileURL
        guard serviceURL.path.hasPrefix(appURL.path + "/"),
              let serviceBundle = Bundle(url: serviceURL),
              serviceBundle.bundleIdentifier == serviceIdentifier,
              let executableURL = serviceBundle.executableURL?
                .resolvingSymlinksInPath().standardizedFileURL,
              executableURL.lastPathComponent == serviceExecutableName,
              executableURL.path.hasPrefix(serviceURL.path + "/")
        else { throw NativeDecompilerLiveXPCTestError.invalidEmbeddedService }

        return .init(
            appURL: appURL,
            serviceBundleURL: serviceURL,
            serviceExecutableURL: executableURL
        )
    }
}

private struct NativeDecompilerLiveSigningIdentity: Equatable {
    let identifier: String
    let teamIdentifier: String
    let signatureFlags: UInt32
    let runtimeVersion: UInt32
    let cdHash: Data
    let leafCertificateCommonName: String
    let bundlePath: String
}

private final class NativeDecompilerLiveCodeAuthority {
    private static let expectedTeamIdentifier = "TEAM000000"
    private static let expectedLeafCommonName =
        "Apple Development: MacScope Developer (CERT000000)"
    private static let runtimeSignatureFlag: UInt32 = 0x0001_0000
    private static let adHocSignatureFlag: UInt32 = 0x0000_0002
    private static let considerExpirationFlag: UInt32 = 0x8000_0000
    private static let noNetworkAccessFlag: UInt32 = 0x2000_0000

    let product: NativeDecompilerLiveSignedProduct
    let designatedRequirement: SecRequirement
    let designatedRequirementData: Data
    let designatedRequirementText: String
    let staticIdentity: NativeDecompilerLiveSigningIdentity

    init(product: NativeDecompilerLiveSignedProduct) throws {
        self.product = product
        let staticCode = try Self.makeStaticCode(at: product.serviceBundleURL)
        try Self.validateStatic(staticCode, requirement: nil)

        let requirement = try Self.copyDesignatedRequirement(from: staticCode)
        let requirementData = try Self.copyData(from: requirement)
        let requirementText = try Self.copyString(from: requirement)
        let identity = try Self.identity(
            of: staticCode,
            expectedBundlePath: product.serviceBundleURL.path
        )
        try Self.requireApprovedIdentity(identity)

        designatedRequirement = requirement
        designatedRequirementData = requirementData
        designatedRequirementText = requirementText
        staticIdentity = identity
    }

    func authenticateDynamicProcess(
        _ kernel: NativeDecompilerLiveKernelIdentity
    ) throws {
        guard kernel.pid > 1,
              kernel.uid == geteuid(),
              kernel.executablePath == product.serviceExecutableURL.path
        else { throw NativeDecompilerLiveXPCTestError.processIdentityMismatch }

        var dynamicCode: SecCode?
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: kernel.pid),
        ] as CFDictionary
        let lookupStatus = SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &dynamicCode
        )
        guard lookupStatus == errSecSuccess, let dynamicCode else {
            throw NativeDecompilerLiveXPCTestError.securityFailure(lookupStatus)
        }

        let dynamicFlags = SecCSFlags(
            rawValue: Self.considerExpirationFlag | Self.noNetworkAccessFlag
        )
        let dynamicStatus = SecCodeCheckValidityWithErrors(
            dynamicCode,
            dynamicFlags,
            designatedRequirement,
            nil
        )
        guard dynamicStatus == errSecSuccess else {
            throw NativeDecompilerLiveXPCTestError.securityFailure(dynamicStatus)
        }

        var dynamicStaticCode: SecStaticCode?
        let staticStatus = SecCodeCopyStaticCode(
            dynamicCode,
            SecCSFlags(),
            &dynamicStaticCode
        )
        guard staticStatus == errSecSuccess, let dynamicStaticCode else {
            throw NativeDecompilerLiveXPCTestError.securityFailure(staticStatus)
        }
        try Self.validateStatic(dynamicStaticCode, requirement: designatedRequirement)

        let liveRequirement = try Self.copyDesignatedRequirement(from: dynamicStaticCode)
        guard try Self.copyData(from: liveRequirement) == designatedRequirementData else {
            throw NativeDecompilerLiveXPCTestError.signingIdentityMismatch
        }
        let liveIdentity = try Self.identity(
            of: dynamicStaticCode,
            expectedBundlePath: product.serviceBundleURL.path
        )
        try Self.requireApprovedIdentity(liveIdentity)
        guard liveIdentity == staticIdentity else {
            throw NativeDecompilerLiveXPCTestError.signingIdentityMismatch
        }
    }

    private static func makeStaticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code)
        guard status == errSecSuccess, let code else {
            throw NativeDecompilerLiveXPCTestError.securityFailure(status)
        }
        return code
    }

    private static func validateStatic(
        _ code: SecStaticCode,
        requirement: SecRequirement?
    ) throws {
        let flags = SecCSFlags(
            rawValue:
                UInt32(kSecCSCheckAllArchitectures)
                | UInt32(kSecCSCheckNestedCode)
                | UInt32(kSecCSStrictValidate)
                | UInt32(kSecCSRestrictSymlinks)
                | UInt32(kSecCSRestrictSidebandData)
                | considerExpirationFlag
                | noNetworkAccessFlag
        )
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil)
        guard status == errSecSuccess else {
            throw NativeDecompilerLiveXPCTestError.securityFailure(status)
        }
    }

    private static func copyDesignatedRequirement(
        from code: SecStaticCode
    ) throws -> SecRequirement {
        var value: SecRequirement?
        let status = SecCodeCopyDesignatedRequirement(code, SecCSFlags(), &value)
        guard status == errSecSuccess, let value else {
            throw NativeDecompilerLiveXPCTestError.securityFailure(status)
        }
        return value
    }

    private static func copyData(from requirement: SecRequirement) throws -> Data {
        var value: CFData?
        let status = SecRequirementCopyData(requirement, SecCSFlags(), &value)
        guard status == errSecSuccess, let value else {
            throw NativeDecompilerLiveXPCTestError.securityFailure(status)
        }
        return value as Data
    }

    private static func copyString(from requirement: SecRequirement) throws -> String {
        var value: CFString?
        let status = SecRequirementCopyString(requirement, SecCSFlags(), &value)
        guard status == errSecSuccess, let value else {
            throw NativeDecompilerLiveXPCTestError.securityFailure(status)
        }
        return value as String
    }

    private static func identity(
        of code: SecStaticCode,
        expectedBundlePath: String
    ) throws -> NativeDecompilerLiveSigningIdentity {
        var information: CFDictionary?
        let status = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)),
            &information
        )
        guard status == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              let teamIdentifier = values[kSecCodeInfoTeamIdentifier as String] as? String,
              let signatureFlags = (values[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value,
              let runtimeVersion = (values[kSecCodeInfoRuntimeVersion as String] as? NSNumber)?
                .uint32Value,
              let cdHash = values[kSecCodeInfoUnique as String] as? Data,
              let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first
        else { throw NativeDecompilerLiveXPCTestError.signingIdentityMismatch }

        var commonName: CFString?
        let commonNameStatus = SecCertificateCopyCommonName(leaf, &commonName)
        guard commonNameStatus == errSecSuccess, let commonName else {
            throw NativeDecompilerLiveXPCTestError.securityFailure(commonNameStatus)
        }

        var pathValue: CFURL?
        let pathStatus = SecCodeCopyPath(code, SecCSFlags(), &pathValue)
        guard pathStatus == errSecSuccess, let pathValue else {
            throw NativeDecompilerLiveXPCTestError.securityFailure(pathStatus)
        }
        var bundleURL = (pathValue as URL).resolvingSymlinksInPath().standardizedFileURL
        while bundleURL.path != "/", bundleURL.pathExtension != "xpc" {
            bundleURL.deleteLastPathComponent()
        }
        let bundlePath = bundleURL.path
        guard bundlePath == expectedBundlePath else {
            throw NativeDecompilerLiveXPCTestError.signingIdentityMismatch
        }

        return .init(
            identifier: identifier,
            teamIdentifier: teamIdentifier,
            signatureFlags: signatureFlags,
            runtimeVersion: runtimeVersion,
            cdHash: cdHash,
            leafCertificateCommonName: commonName as String,
            bundlePath: bundlePath
        )
    }

    private static func requireApprovedIdentity(
        _ identity: NativeDecompilerLiveSigningIdentity
    ) throws {
        guard identity.identifier == NativeDecompilerLiveSignedProduct.serviceIdentifier,
              identity.teamIdentifier == expectedTeamIdentifier,
              identity.leafCertificateCommonName == expectedLeafCommonName,
              identity.runtimeVersion > 0,
              identity.signatureFlags & runtimeSignatureFlag != 0,
              identity.signatureFlags & adHocSignatureFlag == 0,
              !identity.cdHash.isEmpty
        else { throw NativeDecompilerLiveXPCTestError.signingIdentityMismatch }
    }
}

private struct NativeDecompilerLiveKernelIdentity: Equatable {
    let pid: Int32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
    let uid: uid_t
    let executablePath: String
}

private enum NativeDecompilerLiveProcessObserver {
    private static let pathBufferSize = 4 * Int(MAXPATHLEN)

    static func observe(pid: Int32) -> NativeDecompilerLiveKernelIdentity? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize) == expectedSize,
              info.pbi_pid == UInt32(pid)
        else { return nil }

        var path = [CChar](repeating: 0, count: pathBufferSize)
        let pathLength = path.withUnsafeMutableBytes { buffer in
            proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        guard pathLength > 0, Int(pathLength) < path.count else { return nil }
        path[Int(pathLength)] = 0
        let pathBytes = path.prefix(Int(pathLength)).map { UInt8(bitPattern: $0) }
        let executablePath = URL(fileURLWithPath: String(decoding: pathBytes, as: UTF8.self))
            .resolvingSymlinksInPath().standardizedFileURL.path

        return .init(
            pid: pid,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec,
            uid: info.pbi_uid,
            executablePath: executablePath
        )
    }

    static func doubleObservation(
        pid: Int32,
        authority: NativeDecompilerLiveCodeAuthority
    ) throws -> NativeDecompilerLiveKernelIdentity {
        guard let before = observe(pid: pid) else {
            throw NativeDecompilerLiveXPCTestError.processUnavailable
        }
        try authority.authenticateDynamicProcess(before)
        guard let after = observe(pid: pid), before == after else {
            throw NativeDecompilerLiveXPCTestError.processIdentityMismatch
        }
        return after
    }

    static func waitUntilOriginalProcessExited(
        _ identity: NativeDecompilerLiveKernelIdentity,
        timeout: Duration = .seconds(3)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            guard let observed = observe(pid: identity.pid), observed == identity else { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NativeDecompilerLiveXPCTestError.processDidNotExit
    }

    static func waitUntilOriginalProcessExitedSynchronously(
        _ identity: NativeDecompilerLiveKernelIdentity,
        timeout: Duration = .seconds(3)
    ) throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            guard let observed = observe(pid: identity.pid), observed == identity else { return }
            Darwin.usleep(10_000)
        }
        throw NativeDecompilerLiveXPCTestError.processDidNotExit
    }
}

private struct NativeDecompilerLiveProcessIdentity: Equatable {
    let sessionID: UUID
    let processInstanceID: UUID
    let kernel: NativeDecompilerLiveKernelIdentity
}

private final class NativeDecompilerLiveControlSession: @unchecked Sendable {
    private let authority: NativeDecompilerLiveCodeAuthority
    private let connection: NSXPCConnection
    private let receipt: NativeDecompilerLiveXPCTestReceipt
    let processIdentity: NativeDecompilerLiveProcessIdentity
    private var terminated = false

    private init(
        authority: NativeDecompilerLiveCodeAuthority,
        connection: NSXPCConnection,
        receipt: NativeDecompilerLiveXPCTestReceipt,
        processIdentity: NativeDecompilerLiveProcessIdentity
    ) {
        self.authority = authority
        self.connection = connection
        self.receipt = receipt
        self.processIdentity = processIdentity
    }

    static func open(
        authority: NativeDecompilerLiveCodeAuthority
    ) async throws -> NativeDecompilerLiveControlSession {
        let sessionID = UUID()
        let connection = NSXPCConnection(
            serviceName: NativeDecompilerFoundationXPCConnection.serviceName
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: NativeDecompilerLiveXPCTestProtocol.self
        )
        connection.setCodeSigningRequirement(authority.designatedRequirementText)
        connection.resume()

        do {
            let receipt = try await invoke(connection, timeout: .seconds(20)) { proxy, reply in
                proxy.openLiveTestSession(sessionID: sessionID as NSUUID, withReply: reply)
            }
            guard let receipt,
                  receipt.sessionID as UUID == sessionID,
                  receipt.processInstanceID as UUID != UUID.zero,
                  receipt.processID > 1,
                  connection.processIdentifier == receipt.processID,
                  connection.effectiveUserIdentifier == geteuid()
            else { throw NativeDecompilerLiveXPCTestError.receiptMismatch }

            let kernel = try NativeDecompilerLiveProcessObserver.doubleObservation(
                pid: receipt.processID,
                authority: authority
            )
            guard kernel.uid == connection.effectiveUserIdentifier else {
                throw NativeDecompilerLiveXPCTestError.processIdentityMismatch
            }
            let identity = NativeDecompilerLiveProcessIdentity(
                sessionID: sessionID,
                processInstanceID: receipt.processInstanceID as UUID,
                kernel: kernel
            )
            return .init(
                authority: authority,
                connection: connection,
                receipt: receipt,
                processIdentity: identity
            )
        } catch {
            connection.invalidate()
            throw error
        }
    }

    static func proveWrongServiceRequirementRejected() async throws {
        let connection = NSXPCConnection(
            serviceName: NativeDecompilerFoundationXPCConnection.serviceName
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: NativeDecompilerLiveXPCTestProtocol.self
        )
        connection.setCodeSigningRequirement(
            "identifier \"org.macscope.app.NativeDecompiler.invalid\" and anchor apple generic"
        )
        connection.resume()
        defer { connection.invalidate() }

        try await withCheckedThrowingContinuation { continuation in
            let once = NativeDecompilerLiveOneShot<Void>(continuation)
            let timeout = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timeout.schedule(deadline: .now() + .seconds(20))
            timeout.setEventHandler {
                once.resume(.failure(NativeDecompilerLiveXPCTestError.controlReplyTimedOut))
            }
            timeout.resume()

            do {
                let remote = try proxy(connection) { error in
                    timeout.cancel()
                    let cocoaError = error as NSError
                    guard cocoaError.domain == NSCocoaErrorDomain,
                          cocoaError.code == NSXPCConnectionCodeSigningRequirementFailure
                    else {
                        return once.resume(
                            .failure(
                                NativeDecompilerLiveXPCTestError.unexpectedAdmissionFailure(
                                    domain: cocoaError.domain,
                                    code: cocoaError.code
                                )
                            )
                        )
                    }
                    once.resume(.success(()))
                }
                let forgedReceipt = NativeDecompilerLiveXPCTestReceipt(
                    sessionID: UUID() as NSUUID,
                    processInstanceID: UUID() as NSUUID,
                    processID: Int32(ProcessInfo.processInfo.processIdentifier)
                )
                remote.pingLiveTestSession(receipt: forgedReceipt) { _ in
                    timeout.cancel()
                    once.resume(
                        .failure(NativeDecompilerLiveXPCTestError.wrongRequirementWasAdmitted)
                    )
                }
            } catch {
                timeout.cancel()
                once.resume(.failure(error))
            }
        }
    }

    func configure(
        requestID: UUID,
        mode: NativeDecompilerLiveXPCTestHoldMode,
        timeout: DispatchTimeInterval = .seconds(5)
    ) async throws {
        let accepted: Bool? = try await Self.invoke(connection, timeout: timeout) { proxy, reply in
            proxy.configureLiveTestRequest(
                receipt: receipt,
                requestID: requestID as NSUUID,
                holdMode: mode.rawValue,
                withReply: reply
            )
        }
        guard accepted == true else { throw NativeDecompilerLiveXPCTestError.controlRejected }
    }

    func waitUntilEntered(requestID: UUID) async throws {
        let entered: NativeDecompilerLiveXPCTestReceipt? = try await Self.invoke(connection) {
            proxy, reply in
            proxy.waitUntilLiveTestRequestEntered(
                receipt: receipt,
                requestID: requestID as NSUUID,
                withReply: reply
            )
        }
        try validate(entered)
    }

    func waitUntilEvent(
        requestID: UUID,
        event: NativeDecompilerLiveXPCTestEvent
    ) async throws {
        let observed: NativeDecompilerLiveXPCTestReceipt? = try await Self.invoke(connection) {
            proxy, reply in
            proxy.waitUntilLiveTestRequestEvent(
                receipt: receipt,
                requestID: requestID as NSUUID,
                event: event.rawValue,
                withReply: reply
            )
        }
        try validate(observed)
    }

    func decompileRaw(requestID: UUID, payload: Data) async throws -> Data {
        try await Self.invoke(connection) { proxy, reply in
            proxy.decompile(
                requestID: requestID as NSUUID,
                payload: payload as NSData
            ) { reply($0 as Data) }
        }
    }

    func releaseManual(requestID: UUID) async throws {
        let released: Bool? = try await Self.invoke(connection) { proxy, reply in
            proxy.releaseLiveTestRequest(
                receipt: receipt,
                requestID: requestID as NSUUID,
                withReply: reply
            )
        }
        guard released == true else { throw NativeDecompilerLiveXPCTestError.controlRejected }
    }

    func pingAndReauthenticate() async throws {
        let ping: NativeDecompilerLiveXPCTestReceipt? = try await Self.invoke(connection) {
            proxy, reply in
            proxy.pingLiveTestSession(receipt: receipt, withReply: reply)
        }
        try validate(ping)
        let kernel = try NativeDecompilerLiveProcessObserver.doubleObservation(
            pid: processIdentity.kernel.pid,
            authority: authority
        )
        guard kernel == processIdentity.kernel,
              connection.processIdentifier == kernel.pid,
              connection.effectiveUserIdentifier == kernel.uid
        else { throw NativeDecompilerLiveXPCTestError.processIdentityMismatch }
    }

    func terminateUsingAuthenticatedSelfSIGKILL() async throws {
        try await pingAndReauthenticate()
        let proxy = try Self.proxy(connection, errorHandler: { _ in })
        proxy.selfSIGKILLLiveTestService(receipt: receipt)
        try await NativeDecompilerLiveProcessObserver.waitUntilOriginalProcessExited(
            processIdentity.kernel
        )
        terminated = true
    }

    func waitUntilAutomaticallyTerminated(timeout: Duration) async throws {
        try await NativeDecompilerLiveProcessObserver.waitUntilOriginalProcessExited(
            processIdentity.kernel,
            timeout: timeout
        )
        terminated = true
    }

    func invalidateAfterTermination() {
        connection.invalidate()
    }

    func cleanupExactAuthenticatedProcessIfNeeded() {
        defer { connection.invalidate() }
        guard !terminated,
              let before = NativeDecompilerLiveProcessObserver.observe(
                  pid: processIdentity.kernel.pid
              ),
              before == processIdentity.kernel
        else { return }
        do {
            try authority.authenticateDynamicProcess(before)
            guard let after = NativeDecompilerLiveProcessObserver.observe(pid: before.pid),
                  after == before,
                  after.uid == geteuid(),
                  after.executablePath == authority.product.serviceExecutableURL.path
            else { throw NativeDecompilerLiveXPCTestError.processIdentityMismatch }
            guard connection.processIdentifier == after.pid,
                  connection.effectiveUserIdentifier == after.uid
            else { throw NativeDecompilerLiveXPCTestError.processIdentityMismatch }
            let remote = try Self.proxy(connection, errorHandler: { _ in })
            remote.selfSIGKILLLiveTestService(receipt: receipt)
            try NativeDecompilerLiveProcessObserver.waitUntilOriginalProcessExitedSynchronously(
                after
            )
            terminated = true
        } catch {
            XCTFail("refused unsafe live-XPC cleanup signal: \(error)")
        }
    }

    private func validate(_ candidate: NativeDecompilerLiveXPCTestReceipt?) throws {
        guard let candidate,
              candidate.sessionID == receipt.sessionID,
              candidate.processInstanceID == receipt.processInstanceID,
              candidate.processID == receipt.processID
        else { throw NativeDecompilerLiveXPCTestError.receiptMismatch }
    }

    private static func invoke<Value: Sendable>(
        _ connection: NSXPCConnection,
        timeout timeoutInterval: DispatchTimeInterval = .seconds(5),
        _ body: (NativeDecompilerLiveXPCTestProtocol, @escaping (Value) -> Void) -> Void
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let once = NativeDecompilerLiveOneShot<Value>(continuation)
            let timeout = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timeout.schedule(deadline: .now() + timeoutInterval)
            timeout.setEventHandler {
                once.resume(.failure(NativeDecompilerLiveXPCTestError.controlReplyTimedOut))
            }
            timeout.resume()
            do {
                let remote = try proxy(connection) { error in
                    timeout.cancel()
                    once.resume(.failure(error))
                }
                body(remote) { value in
                    timeout.cancel()
                    once.resume(.success(value))
                }
            } catch {
                timeout.cancel()
                once.resume(.failure(error))
            }
        }
    }

    private static func proxy(
        _ connection: NSXPCConnection,
        errorHandler: @escaping (Error) -> Void
    ) throws -> NativeDecompilerLiveXPCTestProtocol {
        guard let remote = connection.remoteObjectProxyWithErrorHandler(errorHandler)
            as? NativeDecompilerLiveXPCTestProtocol
        else { throw NativeDecompilerLiveXPCTestError.missingControlProxy }
        return remote
    }
}

private final class NativeDecompilerLiveOneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: sending Result<Value, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Value, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

private enum NativeDecompilerLiveXPCTestError: Error {
    case invalidTestHost
    case invalidEmbeddedService
    case securityFailure(OSStatus)
    case signingIdentityMismatch
    case processUnavailable
    case processIdentityMismatch
    case processDidNotExit
    case receiptMismatch
    case requestIdentityMismatch
    case controlRejected
    case controlReplyTimedOut
    case missingControlProxy
    case wrongRequirementWasAdmitted
    case unexpectedAdmissionFailure(domain: String, code: Int)
}

private extension UUID {
    static let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}
#endif
