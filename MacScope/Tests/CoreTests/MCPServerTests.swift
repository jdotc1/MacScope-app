import Darwin
import Foundation
import XCTest
@testable import MacScope

@MainActor
final class MCPServerTests: XCTestCase {
    func testDefaultAsyncSearchHandlerPreservesCompleteResultsAndReadOnlyState() async throws {
        let (_, store) = makeServer()
        let api = WorkspaceScriptingAPI(store: store)
        let server = MCPServer(api: api)
        let before = store.snapshot
        let selection = store.selectedImageAddress
        for (query, mode) in [("mov", "text"), ("^mov\\b", "regex"), ("e0 03 01 aa", "hex")] {
            let arguments = ScriptValue.object(["query": .string(query), "mode": .string(mode)])
            let expected = try api.execute("search", arguments: arguments)
            let responseData = await server.handleMessageAsync(try request("tools/call", params: .object([
                "name": .string("search"), "arguments": arguments])).jsonData())
            let response = try XCTUnwrap(responseData)
            let envelope = try ScriptValue.decode(response)
            XCTAssertNil(envelope["error"])
            XCTAssertEqual(envelope["result"]?["isError"], .bool(false))
            let text = try XCTUnwrap(envelope["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
            let output = try ScriptValue.decode(Data(text.utf8))
            XCTAssertEqual(output["results"], expected["results"])
            XCTAssertEqual(output["total"], expected["total"])
            XCTAssertEqual(output["lowerBound"], expected["total"])
            XCTAssertEqual(output["isTruncated"], .bool(false))
        }
        XCTAssertEqual(store.snapshot.binaries, before.binaries)
        XCTAssertEqual(store.snapshot.instructions, before.instructions)
        XCTAssertEqual(store.snapshot.addressOverrides, before.addressOverrides)
        XCTAssertEqual(store.selectedImageAddress, selection)
    }

    func testDefaultAsyncSearchHandlerReportsTruncatedLowerBound() async throws {
        let (_, store) = makeServer()
        var snapshot = store.snapshot
        snapshot.instructions = (0..<600).map { InstructionRow(address: 0x1000 + UInt64($0 * 4),
            bytes: "00 00 00 00", mnemonic: "mov", operands: "x0, x1", hasBreakpoint: false, comment: nil) }
        store.snapshot = snapshot
        let server = MCPServer(api: WorkspaceScriptingAPI(store: store))
        let responseData = await server.handleMessageAsync(try request("tools/call", params: .object([
            "name": .string("search"), "arguments": .object(["query": .string("mov")])])).jsonData())
        let response = try XCTUnwrap(responseData)
        let envelope = try ScriptValue.decode(response)
        XCTAssertNil(envelope["error"])
        let text = try XCTUnwrap(envelope["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        let output = try ScriptValue.decode(Data(text.utf8))
        XCTAssertEqual(output["total"], .null)
        XCTAssertEqual(output["isTruncated"], .bool(true))
        XCTAssertEqual(output["results"]?.arrayValue?.count, 500)
        XCTAssertGreaterThan(output["lowerBound"]?.intValue ?? 0, 500)
        XCTAssertLessThanOrEqual(output["lowerBound"]?.intValue ?? 0, 600)
    }

    func testDefaultSearchRequestSessionSettlesCompletionOrCancellationWithoutCrossSessionEffect() async throws {
        let (_, store) = makeServer()
        var snapshot = store.snapshot
        let operands = String(repeating: "a", count: 4_000)
        snapshot.instructions = (0..<10_000).map { InstructionRow(address: 0x1000 + UInt64($0 * 4),
            bytes: "00 00 00 00", mnemonic: "mov", operands: operands, hasBreakpoint: false, comment: nil) }
        store.snapshot = snapshot
        let selection = store.selectedImageAddress
        let overrides = store.snapshot.addressOverrides
        var identityChecked = false
        let server = MCPServer(api: WorkspaceScriptingAPI(store: store), validateWorkspaceIdentity: {
            identityChecked = true
        })
        let cancelledOutput = MCPAsyncTestOutput(), otherOutput = MCPAsyncTestOutput()
        let cancelled = server.makeRequestSession(output: { await cancelledOutput.append($0) })
        let other = server.makeRequestSession(output: { await otherOutput.append($0) })
        await cancelled.receive(try request("tools/call", id: .string("same-id"), params: .object([
            "name": .string("search"), "arguments": .object(["query": .string("never-present"), "mode": .string("regex")])])).jsonData())
        // Identity validation proves default handler admission. The scan may finish before
        // this actor resumes; cancellation cannot replace an already-completed terminal.
        while !identityChecked { await Task.yield() }
        let info = try WorkspaceScriptingAPI(store: store).execute("info")
        XCTAssertEqual(info["instructionCount"], .int(10_000))
        await cancelled.receive(try request("notifications/cancelled", id: nil, params: .object([
            "requestId": .string("same-id")])).jsonData())
        await other.receive(try request("tools/call", id: .string("same-id"), params: .object([
            "name": .string("info")])).jsonData())
        let cancelledResponses = try await asyncResponses(cancelledOutput, count: 1)
        let otherResponses = try await asyncResponses(otherOutput, count: 1)
        let settled = try ScriptValue.decode(cancelledResponses[0])
        if let error = settled["error"] {
            XCTAssertEqual(error["code"], .int(-32800))
            XCTAssertNil(settled["result"])
        } else {
            XCTAssertEqual(settled["result"]?["isError"], .bool(false))
            let text = try XCTUnwrap(settled["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
            let output = try ScriptValue.decode(Data(text.utf8))
            XCTAssertEqual(output["results"], .array([]))
            XCTAssertEqual(output["lowerBound"], .int(0))
            let truncated = try XCTUnwrap(output["isTruncated"]?.boolValue)
            XCTAssertEqual(output["total"], truncated ? .null : .int(0))
        }
        XCTAssertNil(try ScriptValue.decode(otherResponses[0])["error"])
        XCTAssertEqual(try ScriptValue.decode(otherResponses[0])["result"]?["isError"], .bool(false))
        await cancelled.finishInput()
        await other.finishInput()
        let count = await cancelledOutput.count
        XCTAssertEqual(count, 1, "Completion and cancellation must settle to exactly one terminal")
        let inFlight = await cancelled.inFlightCount
        XCTAssertEqual(inFlight, 0)
        XCTAssertEqual(store.snapshot.instructions, snapshot.instructions)
        XCTAssertEqual(store.snapshot.addressOverrides, overrides)
        XCTAssertEqual(store.selectedImageAddress, selection)
    }

    func testDefaultAsyncHandlerRetainsMCPPrincipalAndPrecancelledSearchResponse() async throws {
        let (server, store) = makeServer()
        let readData = await server.handleMessageAsync(try request("tools/call", params: .object([
            "name": .string("read-evidence"), "arguments": .object(["operation": .string("workspace.summary")])])).jsonData())
        let read = try ScriptValue.decode(XCTUnwrap(readData))
        let text = try XCTUnwrap(read["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        let evidence = try ScriptValue.decode(Data(text.utf8))
        XCTAssertEqual(evidence["proposingPrincipal"], .string("mcp"))
        XCTAssertEqual(evidence["authorizingPrincipal"], .string("app"))
        let selection = store.selectedImageAddress
        let requestBytes = try request("tools/call", params: .object([
            "name": .string("search"), "arguments": .object(["query": .string("mov")])])).jsonData()
        let operation = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await server.handleMessageAsync(requestBytes)
        }
        let responseData = await operation.value
        let response = try ScriptValue.decode(XCTUnwrap(responseData))
        XCTAssertEqual(response["error"]?["code"], .int(-32800))
        XCTAssertNil(response["result"])
        XCTAssertEqual(store.selectedImageAddress, selection)
    }

    func testDefaultDecompileRequestSessionCancellationStopsDetachedReadWithOneTerminal() async throws {
        let (_, store) = makeServer()
        // Hold after body extraction, before the MacIR build (checkpoint 2).
        let gate = SnapshotReadCheckpointGate(holdAt: 2)
        let server = MCPServer(api: WorkspaceScriptingAPI(store: store,
            snapshotReadCheckpoint: { gate.checkpoint() }))
        let output = MCPAsyncTestOutput()
        let session = server.makeRequestSession(output: { await output.append($0) })
        let selection = store.selectedImageAddress
        await session.receive(try request("tools/call", id: .string("dec"), params: .object([
            "name": .string("decompile"), "arguments": .object(["function": .string("_main")])])).jsonData())
        try await gate.waitUntilHeld()
        // MainActor stays available while the read is held off it.
        XCTAssertEqual(try WorkspaceScriptingAPI(store: store).execute("info")["functionCount"], .int(1))
        await session.receive(try request("notifications/cancelled", id: nil, params: .object([
            "requestId": .string("dec")])).jsonData())
        gate.open()
        let responses = try await asyncResponses(output, count: 1)
        let terminal = try ScriptValue.decode(responses[0])
        XCTAssertEqual(terminal["error"]?["code"], .int(-32800))
        XCTAssertNil(terminal["result"])
        await session.finishInput()
        let count = await output.count
        XCTAssertEqual(count, 1, "A cancelled read cannot publish a second terminal")
        let inFlight = await session.inFlightCount
        XCTAssertEqual(inFlight, 0, "The detached read acknowledged cancellation and retired")
        XCTAssertEqual(gate.checkpointCount, 2, "No MacIR build or print ran after cancellation")
        XCTAssertEqual(store.selectedImageAddress, selection)
    }

    func testDefaultMutationCancelledBeforeCommitHasNoEffectAndUncancelledCommits() async throws {
        let (server, store) = makeServer()
        let api = WorkspaceScriptingAPI(store: store)
        let requestBytes = try request("tools/call", params: .object([
            "name": .string("set-comment"),
            "arguments": .object(["address": .string("0x1000"), "comment": .string("must not commit")]),
        ])).jsonData()
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await server.handleMessageAsync(requestBytes)
        }
        let cancelledData = await cancelled.value
        let cancelledResponse = try ScriptValue.decode(XCTUnwrap(cancelledData))
        XCTAssertEqual(cancelledResponse["error"]?["code"], .int(-32800))
        XCTAssertNil(cancelledResponse["result"])
        let row = try api.execute("instructions", arguments: .object(["address": .string("0x1000"), "count": .int(1)]))
        XCTAssertNil(row.arrayValue?.first?["comment"])

        let committedData = await server.handleMessageAsync(try request("tools/call", params: .object([
            "name": .string("set-comment"),
            "arguments": .object(["address": .string("0x1000"), "comment": .string("committed")]),
        ])).jsonData())
        let committed = try ScriptValue.decode(XCTUnwrap(committedData))
        XCTAssertEqual(committed["result"]?["isError"], .bool(false))
        let after = try api.execute("instructions", arguments: .object(["address": .string("0x1000"), "count": .int(1)]))
        XCTAssertEqual(after.arrayValue?.first?["comment"], .string("committed"))
    }

    func testAsyncSessionCancelsSuspendedReadAndSuppressesItsLateResult() async throws {
        let (_, store) = makeServer()
        let gate = MCPAsyncTestGate()
        let probe = MCPAsyncTestOutput()
        let server = MCPServer(api: WorkspaceScriptingAPI(store: store), asyncCommandExecutor: { _, _ in
            await gate.suspend()
            return .object(["late": .bool(true)])
        })
        let session = server.makeRequestSession(output: { await probe.append($0) })
        await session.receive(Data(#"{"jsonrpc":"2.0","id":"read","method":"tools/call","params":{"name":"info"}}"#.utf8))
        await gate.waitUntilStarted()
        await session.receive(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"read"}}"#.utf8))
        let responses = try await asyncResponses(probe, count: 1)
        XCTAssertEqual(try ScriptValue.decode(responses[0])["error"]?["code"], .int(-32800))
        let observed1 = await session.inFlightCount
        XCTAssertEqual(observed1, 1, "retirement remains bounded until the task returns")
        await gate.release()
        await session.finishInput()
        let observed2 = await probe.count
        XCTAssertEqual(observed2, 1, "late success cannot become a second terminal")
    }

    func testAsyncDeadlineFiresBeforeSuspendedReadCompletes() async throws {
        let (_, store) = makeServer()
        let gate = MCPAsyncTestGate()
        let probe = MCPAsyncTestOutput()
        let server = MCPServer(api: WorkspaceScriptingAPI(store: store), configuration: .init(
            maximumInputBytes: 1_024, maximumOutputBytes: 8_192,
            maximumToolDurationNanoseconds: 20_000_000, maximumRememberedCancellations: 8),
            asyncCommandExecutor: { _, _ in await gate.suspend(); return .null })
        let session = server.makeRequestSession(output: { await probe.append($0) })
        await session.receive(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"info"}}"#.utf8))
        let responses = try await asyncResponses(probe, count: 1)
        XCTAssertEqual(try ScriptValue.decode(responses[0])["error"]?["code"], .int(-32001))
        await gate.release()
        await session.finishInput()
        let observed3 = await probe.count
        XCTAssertEqual(observed3, 1)
    }

    func testAsyncRequestIDsPreserveNullStringAndExactNumericIdentity() async throws {
        let gate = MCPAsyncTestGate()
        let probe = MCPAsyncTestOutput()
        let session = MCPRequestSession(configuration: .production, mutatingCommands: [], execute: { _ in
            await gate.suspend()
            return Data(#"{"jsonrpc":"2.0","id":0,"result":{}}"#.utf8)
        }, output: { await probe.append($0) })
        for id in ["1", "\"1\"", "null"] {
            await session.receive(Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"ping\"}".utf8))
        }
        await session.receive(Data(#"{"jsonrpc":"2.0","id":1.00e0,"method":"ping"}"#.utf8))
        let duplicates = try await asyncResponses(probe, count: 1)
        let duplicate = try Phase2StrictJSONParser().parse(duplicates[0], limits: .providerEnvelope)
        XCTAssertEqual(duplicate.objectValue?["id"], .number("1.00e0"))
        XCTAssertEqual(duplicate.objectValue?["error"]?.objectValue?["code"], .number("-32600"))
        let observed4 = await session.inFlightCount
        XCTAssertEqual(observed4, 3)
        await session.receive(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":null}}"#.utf8))
        let cancelled = try await asyncResponses(probe, count: 2)
        XCTAssertEqual(try ScriptValue.decode(cancelled[1])["id"], .null)
        await gate.release()
        _ = try await asyncResponses(probe, count: 4)
        await session.finishInput()
    }

    func testAsyncInFlightLimitAndEOFRetireOwnedReads() async throws {
        let gate = MCPAsyncTestGate()
        let probe = MCPAsyncTestOutput()
        let session = MCPRequestSession(configuration: .init(maximumInputBytes: 1_024,
            maximumOutputBytes: 8_192, maximumToolDurationNanoseconds: 1_000_000_000,
            maximumRememberedCancellations: 8, maximumInFlightRequests: 1), mutatingCommands: [],
            execute: { _ in await gate.suspend(); return Data(#"{"jsonrpc":"2.0","id":0,"result":{}}"#.utf8) },
            output: { await probe.append($0) })
        await session.receive(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
        await gate.waitUntilStarted()
        await session.receive(Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8))
        let saturated = try await asyncResponses(probe, count: 1)
        XCTAssertEqual(try ScriptValue.decode(saturated[0])["error"]?["code"], .int(-32000))
        await gate.release()
        await session.finishInput()
        let observed5 = await session.inFlightCount
        XCTAssertEqual(observed5, 0)
        await gate.release()
        await session.receive(Data(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#.utf8))
        let observed6 = await probe.count
        XCTAssertEqual(observed6, 2)
    }

    func testEOFWaitsForCommittedMutationTerminalWrite() async throws {
        let (_, store) = makeServer()
        let api = WorkspaceScriptingAPI(store: store)
        let outputGate = MCPAsyncTestGate()
        let probe = MCPAsyncTestOutput()
        let server = MCPServer(api: api)
        let session = server.makeRequestSession(output: { data in
            await outputGate.suspend()
            await probe.append(data)
        })
        await session.receive(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"set-comment","arguments":{"address":"0x1000","comment":"committed before EOF"}}}"#.utf8))
        await outputGate.waitUntilStarted()
        let pending = await session.pendingTerminalWriteCount
        XCTAssertEqual(pending, 1)
        let finished = MCPAsyncTestOutput()
        let eof = Task { await session.finishInput(); await finished.append(Data()) }
        while await session.isAcceptingRequests { await Task.yield() }
        while !(await session.isAwaitingInputDrain), await finished.count == 0 { await Task.yield() }
        let waiting = await session.isAwaitingInputDrain
        XCTAssertTrue(waiting)
        let early = await finished.count
        XCTAssertEqual(early, 0, "EOF must not close the response descriptor while output is suspended")
        await outputGate.release()
        await eof.value
        let responses = await probe.values
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(try ScriptValue.decode(responses[0])["result"]?["isError"], .bool(false))
        let comment = try api.execute("instructions", arguments: .object(["address": .string("0x1000"), "count": .int(1)]))
        XCTAssertEqual(comment.arrayValue?.first?["comment"], .string("committed before EOF"))
    }

    func testEOFRetainsCancelledReadUntilCleanupAcknowledgement() async {
        let execution = MCPAsyncTestGate()
        let probe = MCPAsyncTestOutput()
        let session = MCPRequestSession(configuration: .production, mutatingCommands: [],
            execute: { _ in await execution.suspend(); return nil }, output: { await probe.append($0) })
        await session.receive(Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
        await execution.waitUntilStarted()
        let finished = MCPAsyncTestOutput()
        let eof = Task { await session.finishInput(); await finished.append(Data()) }
        while await session.isAcceptingRequests { await Task.yield() }
        while !(await session.isAwaitingInputDrain), await finished.count == 0 { await Task.yield() }
        let waiting = await session.isAwaitingInputDrain
        XCTAssertTrue(waiting)
        let retained = await session.inFlightCount
        let early = await finished.count
        XCTAssertEqual(retained, 1)
        XCTAssertEqual(early, 0)
        await execution.release() // Explicit owned-resource cleanup acknowledgment.
        await eof.value
        let retired = await session.inFlightCount
        XCTAssertEqual(retired, 0)
    }

    func testOutputFailureStopsAdmissionBeforeQueuedMutationRuns() async {
        let execution = MCPAsyncTestGate()
        let calls = MCPAsyncTestOutput()
        let outputGate = MCPAsyncTestGate()
        let session = MCPRequestSession(configuration: .production, mutatingCommands: ["set-comment"],
            execute: { data in
                await calls.append(data)
                await execution.suspend()
                return Data(#"{"jsonrpc":"2.0","id":0,"result":{}}"#.utf8)
            }, output: { _ in await outputGate.markStarted(); throw HeadlessProtocolIOError.writeFailure })
        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"set-comment"}}"#.utf8)
        await session.receive(request)
        await execution.waitUntilStarted()
        await session.receive(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set-comment"}}"#.utf8))
        await execution.release()
        await outputGate.waitUntilStarted()
        while await session.isAcceptingRequests { await Task.yield() }
        await session.receive(request)
        await session.finishInput()
        let count = await calls.count
        XCTAssertEqual(count, 1)
    }

    func testAsyncCommittedMutationSurvivesCancellationAndQueuedMutationDoesNotRun() async throws {
        let (_, store) = makeServer()
        let api = WorkspaceScriptingAPI(store: store)
        let gate = MCPAsyncTestGate()
        let probe = MCPAsyncTestOutput()
        let server = MCPServer(api: api, asyncCommandExecutor: { command, arguments in
            let committed = try HeadlessAutomationAuthority.execute(command: command,
                arguments: arguments, api: api, proposingPrincipal: .mcp)
            await gate.suspend()
            return committed
        })
        let session = server.makeRequestSession(output: { await probe.append($0) })
        await session.receive(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"set-comment","arguments":{"address":"0x1000","comment":"committed"}}}"#.utf8))
        await gate.waitUntilStarted()
        await session.receive(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"set-comment","arguments":{"address":"0x1000","comment":"must not run"}}}"#.utf8))
        for id in [1, 2] {
            await session.receive(Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\(id)}}".utf8))
        }
        _ = try await asyncResponses(probe, count: 1)
        await gate.release()
        let responses = try await asyncResponses(probe, count: 2)
        let committed = try responses.map(ScriptValue.decode).first { $0["id"] == .int(1) }
        XCTAssertEqual(committed?["result"]?["isError"], .bool(false))
        let comment = try api.execute("instructions", arguments: .object(["address": .string("0x1000"), "count": .int(1)]))
        XCTAssertEqual(comment.arrayValue?.first?["comment"], .string("committed"))
        await session.finishInput()
    }

    func testGotoIsAdvertisedAsWorkspaceMutation() throws {
        let (server, _) = makeServer()
        let tools = server.handle(request("tools/list"))?["result"]?["tools"]?.arrayValue ?? []
        let tool = try XCTUnwrap(tools.first { $0["name"]?.stringValue == "goto" })
        XCTAssertEqual(tool["annotations"]?["readOnlyHint"]?.boolValue, false)
    }

    func testQueuedGotoCancelledBehindRunningMutationNeverNavigates() async throws {
        let (_, store) = makeServer()
        let api = WorkspaceScriptingAPI(store: store)
        let gate = MCPAsyncTestGate()
        let probe = MCPAsyncTestOutput()
        let server = MCPServer(api: api, asyncCommandExecutor: { command, arguments in
            let committed = try HeadlessAutomationAuthority.execute(command: command,
                arguments: arguments, api: api, proposingPrincipal: .mcp)
            await gate.suspend()
            return committed
        })
        let selection = store.selectedImageAddress
        let session = server.makeRequestSession(output: { await probe.append($0) })
        await session.receive(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"set-comment","arguments":{"address":"0x1000","comment":"committed"}}}"#.utf8))
        await gate.waitUntilStarted()
        // goto is a mutation, so it queues behind the running set-comment instead of running now.
        await session.receive(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"goto","arguments":{"query":"0x1004"}}}"#.utf8))
        await session.receive(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}"#.utf8))
        let first = try await asyncResponses(probe, count: 1)
        XCTAssertEqual(try ScriptValue.decode(first[0])["id"], .int(2))
        XCTAssertEqual(try ScriptValue.decode(first[0])["error"]?["code"], .int(-32800))
        await gate.release()
        let responses = try await asyncResponses(probe, count: 2)
        let committed = try responses.map(ScriptValue.decode).first { $0["id"] == .int(1) }
        XCTAssertEqual(committed?["result"]?["isError"], .bool(false))
        await session.finishInput()
        XCTAssertEqual(store.selectedImageAddress, selection, "a cancelled queued goto must not navigate")
    }

    func testCommittedGotoReportsReceiptDespiteLateCancellation() async throws {
        let (_, store) = makeServer()
        let api = WorkspaceScriptingAPI(store: store)
        let gate = MCPAsyncTestGate()
        let probe = MCPAsyncTestOutput()
        let server = MCPServer(api: api, asyncCommandExecutor: { command, arguments in
            let committed = try HeadlessAutomationAuthority.execute(command: command,
                arguments: arguments, api: api, proposingPrincipal: .mcp)
            await gate.suspend()
            return committed
        })
        let session = server.makeRequestSession(output: { await probe.append($0) })
        await session.receive(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"goto","arguments":{"query":"0x1004"}}}"#.utf8))
        await gate.waitUntilStarted()
        await session.receive(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#.utf8))
        await gate.release()
        let responses = try await asyncResponses(probe, count: 1)
        let response = try ScriptValue.decode(responses[0])
        XCTAssertEqual(response["result"]?["isError"], .bool(false), "navigation already happened; report it")
        XCTAssertEqual(store.selectedAddress, 0x1004)
        await session.finishInput()
    }

    func testCancellationReachesOwnedAuditProcessWhileMainActorIsBusy() async throws {
        let (_, store) = makeServer()
        let gate = MCPAsyncTestGate()
        let probe = MCPAsyncTestOutput()
        let server = MCPServer(api: WorkspaceScriptingAPI(store: store), asyncCommandExecutor: { _, _ in
            await gate.markStarted()
            _ = try WorkspaceScriptingAPI.runCallArgumentAuditProcess(
                executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"],
                environment: [:], timeout: 10)
            return .null
        })
        let session = server.makeRequestSession(output: { await probe.append($0) })
        let sender = Task.detached {
            await gate.waitUntilStarted()
            try? await Task.sleep(nanoseconds: 100_000_000)
            await session.receive(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#.utf8))
        }
        let start = DispatchTime.now().uptimeNanoseconds
        await session.receive(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"info"}}"#.utf8))
        let responses = try await asyncResponses(probe, count: 1)
        await sender.value
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - start, 2_000_000_000)
        XCTAssertEqual(try ScriptValue.decode(responses[0])["error"]?["code"], .int(-32800))
        await session.finishInput()
    }

    private func asyncResponses(_ probe: MCPAsyncTestOutput, count: Int) async throws -> [Data] {
        for _ in 0..<200 {
            let values = await probe.values
            if values.count >= count { return values }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for MCP terminal responses")
        throw URLError(.timedOut)
    }

    func testRawHeadlessJSONPreservesIntegralDecimalAndExponentValuesExactly() throws {
        let cases: [(String, Int64)] = [
            ("1.0", 1), ("1e3", 1000), ("1000e-3", 1), ("-0.0e99999999999999999999", 0),
            ("9007199254740993.0", 9_007_199_254_740_993),
            ("9007199254740993e0", 9_007_199_254_740_993),
            ("9223372036854775807.0", Int64.max),
            ("-9223372036854775808.0", Int64.min),
            ("12.000e+0000000000000000000000", 12),
        ]
        for (source, expected) in cases {
            let result = try HeadlessJSON.decode(Data(source.utf8), maximumBytes: 4096)
            XCTAssertEqual(result, .int(expected), source)
        }
    }

    func testFractionalOrOverflowingNumbersNeverBecomeIntegerMutations() throws {
        for source in ["1.9", "1e-1", "1.00000000000000001", "9223372036854775808.0"] {
            let value = try HeadlessJSON.decode(Data(source.utf8), maximumBytes: 4096)
            if case .int = value { XCTFail("Non-Int64 JSON became an integer: \(source)") }
            for (command, key) in [("make-array", "count"), ("make-alignment", "boundary"),
                                   ("rebase-segment", "delta")] {
                var arguments: [String: ScriptValue] = [key: value]
                if command == "rebase-segment" { arguments["section"] = .string("__text") }
                else { arguments["address"] = .string("0x1000") }
                XCTAssertThrowsError(try HeadlessAutomationAuthority.validate(
                    command: command, arguments: .object(arguments)
                ), "\(command): \(source)")
            }
        }
    }

    func testRawTransportAcceptsSchemaIntegralCount() throws {
        let (server, _) = makeServer()
        let json = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"functions","arguments":{"limit":0e3}}}"#
        let response = try XCTUnwrap(server.handleMessage(Data(json.utf8)))
        let value = try ScriptValue.decode(response)
        XCTAssertEqual(value["result"]?["isError"], .bool(false))
    }

    func testRepeatedTypedReadCallsDoNotRetainExternalEvidenceOrDiscardModelEvidence() throws {
        let (server, store) = makeServer()
        guard case .prepared(let modelRead) = store.preparePhase2Read(
            operation: .workspaceSummary, proposingPrincipal: .model
        ) else { return XCTFail("Expected model preparation") }
        let modelExecution = store.executePhase2Read(modelRead)
        let modelEvidence = try XCTUnwrap(modelExecution.acceptedEvidence)
        let retainedCount = store.phase2EvidenceAcceptor.terminalCount

        for call in 0..<128 {
            let response = server.handle(request("tools/call", id: .int(Int64(call)), params: .object([
                "name": .string("read-evidence"),
                "arguments": .object(["operation": .string("workspace.summary")]),
            ])))
            XCTAssertEqual(response?["result"]?["isError"]?.boolValue, false)
            let text = try XCTUnwrap(response?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
            let output = try ScriptValue.decode(Data(text.utf8))
            XCTAssertEqual(output["status"]?.stringValue, "accepted")
            XCTAssertEqual(output["facts"]?["workspaceName"]?.stringValue, "MCP")
            let invocation = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(output["invocationID"]?.stringValue)))
            XCTAssertNil(store.acceptedPhase2Evidence(invocationID: invocation))
            XCTAssertEqual(store.phase2EvidenceAcceptor.terminalCount, retainedCount)
        }
        XCTAssertEqual(store.acceptedPhase2Evidence(invocationID: modelEvidence.invocationID), modelEvidence)
        XCTAssertEqual(store.executePhase2Read(modelRead).disposition, .duplicate)
    }

    func testTypedReadTransportOutputRejectionDoesNotRetainAcceptance() throws {
        let (_, store) = makeServer()
        guard case .prepared(let modelRead) = store.preparePhase2Read(
            operation: .workspaceSummary, proposingPrincipal: .model
        ) else { return XCTFail("Expected model preparation") }
        let modelEvidence = try XCTUnwrap(store.executePhase2Read(modelRead).acceptedEvidence)
        let server = MCPServer(api: WorkspaceScriptingAPI(store: store), configuration: .init(
            maximumInputBytes: 1_024, maximumOutputBytes: 512,
            maximumToolDurationNanoseconds: .max, maximumRememberedCancellations: 8
        ))
        for call in 0..<16 {
            let response = server.handle(request("tools/call", id: .int(Int64(call)), params: .object([
                "name": .string("read-evidence"),
                "arguments": .object(["operation": .string("workspace.summary")]),
            ])))
            XCTAssertEqual(response?["error"]?["code"]?.intValue, -32603)
            XCTAssertEqual(store.phase2EvidenceAcceptor.terminalCount, 1)
        }
        XCTAssertEqual(store.acceptedPhase2Evidence(invocationID: modelEvidence.invocationID), modelEvidence)
    }


    func testTypedReadToolAdvertisesClosedReadOnlyOperations() throws {
        let (server, _) = makeServer()
        let tools = server.handle(request("tools/list"))?["result"]?["tools"]?.arrayValue ?? []
        let tool = try XCTUnwrap(tools.first { $0["name"]?.stringValue == "read-evidence" })
        XCTAssertEqual(tool["annotations"]?["readOnlyHint"]?.boolValue, true)
        XCTAssertEqual(tool["annotations"]?["destructiveHint"]?.boolValue, false)
        XCTAssertEqual(tool["inputSchema"]?["required"]?.arrayValue, [.string("operation")])
        XCTAssertEqual(tool["inputSchema"]?["properties"]?["operation"]?["enum"]?.arrayValue,
                       [.string("workspace.summary"), .string("application.graph.summary"),
                        .string("function.review")])
        XCTAssertEqual(tool["inputSchema"]?["additionalProperties"]?.boolValue, false)
    }

    func testTypedReadCallRecordsMCPProposalAndAppAuthorization() throws {
        let (server, _) = makeServer()
        let response = server.handle(request("tools/call", params: .object([
            "name": .string("read-evidence"),
            "arguments": .object(["operation": .string("workspace.summary")]),
        ])))
        XCTAssertEqual(response?["result"]?["isError"]?.boolValue, false)
        let text = try XCTUnwrap(response?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        let output = try ScriptValue.decode(Data(text.utf8))
        XCTAssertEqual(output["status"]?.stringValue, "accepted")
        XCTAssertEqual(output["proposingPrincipal"]?.stringValue, "mcp")
        XCTAssertEqual(output["authorizingPrincipal"]?.stringValue, "app")
        XCTAssertEqual(output["facts"]?["workspaceName"]?.stringValue, "MCP")
        for fields in [
            ["operation": ScriptValue.string("decompiler.native.result")],
            ["operation": .string("workspace.summary"), "principal": .string("app")],
        ] {
            XCTAssertEqual(server.handle(request("tools/call", params: .object([
                "name": .string("read-evidence"), "arguments": .object(fields),
            ])))?["error"]?["code"]?.intValue, -32602)
        }
    }

    /// F3: `reconstruction-jobs` through the MCP JSON-RPC transport (request bytes in, response
    /// bytes out), not just the scripting function: a durable source job, its lifecycle columns
    /// and the job-not-found argument error.
    func testReconstructionJobsThroughMCPTransportReportsDurableJobAndLifecycle() async throws {
        let databaseFixture = try ReconstructionDatabaseTestFixtures.makeCurrentDatabase()
        let package = try ReconstructionPackageFixture.make(); defer { package.remove() }
        let database = databaseFixture.database, workspaceID = databaseFixture.workspaceUUID
        try database.replaceReconstructionState(workspaceID: workspaceID, state: package.state)
        let project = try XCTUnwrap(package.state.projects.first)
        let occurrence = try XCTUnwrap(package.state.corpusManifests.first?.artifacts.first)
        let initial = try database.commitInitialReconstructionJob(workspaceID: workspaceID,
            mutation: .init(jobID: UUID(), projectID: project.projectID,
                selectedOccurrenceIDs: [occurrence.occurrenceID], objective: "MCP job status transport",
                budget: .init(maxRounds: 2, maxTasks: 20, maxEvidenceRecords: 20, maxEncodedBytes: 1_048_576),
                focus: .artifact(.init(occurrenceID: occurrence.occurrenceID, contentIdentity: occurrence.contentIdentity)),
                sourceProfileID: ReconstructionSourceExecutionTaskContract.profileID))
        let created = try XCTUnwrap(initial.lifecycle.jobs[initial.job.jobID]?.createdAtMilliseconds)

        let (server, store) = makeServer()
        var publication = ReconstructionCommittedCorpus(state: initial.state, attachmentSources: [])
        publication.lifecycle = initial.lifecycle
        store.publishCommittedReconstructionCorpus(publication)
        XCTAssertEqual(store.reconstructionLifecycle, initial.lifecycle)

        let responseData = await server.handleMessageAsync(try request("tools/call", params: .object([
            "name": .string("reconstruction-jobs"),
            "arguments": .object(["job": .string(initial.job.jobID.uuidString)]),
        ])).jsonData())
        let envelope = try ScriptValue.decode(try XCTUnwrap(responseData))
        XCTAssertNil(envelope["error"])
        XCTAssertEqual(envelope["id"]?.intValue, 1)
        XCTAssertEqual(envelope["result"]?["isError"], .bool(false))
        let text = try XCTUnwrap(envelope["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
        let jobs = try XCTUnwrap(try ScriptValue.decode(Data(text.utf8)).arrayValue)
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0]["jobID"]?.stringValue, initial.job.jobID.uuidString)
        XCTAssertEqual(jobs[0]["state"]?.stringValue, "created")
        XCTAssertEqual(jobs[0]["lifecycle"]?["createdAtMilliseconds"]?.stringValue, String(created))
        XCTAssertNil(jobs[0]["lifecycle"]?["finishedAtMilliseconds"])
        XCTAssertNil(jobs[0]["elapsedSource"])
        XCTAssertEqual(jobs[0]["failedTasks"]?.arrayValue?.count, 0)
        // Byte-for-byte the same record the scripting function returns.
        XCTAssertEqual(ScriptValue.array(jobs), try WorkspaceScriptingAPI.reconstructionJobsStatus(
            .object(["job": .string(initial.job.jobID.uuidString)]), state: store.reconstructionState,
            lifecycle: store.reconstructionLifecycle))

        // An unknown job is an argument error through the transport, not an empty success.
        let missing = await server.handleMessageAsync(try request("tools/call", id: .int(2), params: .object([
            "name": .string("reconstruction-jobs"),
            "arguments": .object(["job": .string(UUID().uuidString)]),
        ])).jsonData())
        let missingEnvelope = try ScriptValue.decode(try XCTUnwrap(missing))
        XCTAssertEqual(missingEnvelope["id"]?.intValue, 2)
        XCTAssertTrue(missingEnvelope["error"] != nil || missingEnvelope["result"]?["isError"] == .bool(true),
            "\(missingEnvelope)")
    }

    private func makeServer() -> (MCPServer, WorkspaceStore) {
        let snapshot = WorkspaceSnapshot(
            binaries: [BinaryImage(id: UUID(), name: "test.bin", path: "/tmp/test.bin", kind: "Mach-O executable", architecture: "arm64")],
            functions: [FunctionSummary(id: UUID(), name: "_main", startAddress: 0x1000, endAddress: 0x1008, confidence: 0.9)],
            symbols: [SymbolSummary(id: UUID(), name: "_main", address: 0x1000, kind: "export", libraryName: nil)],
            instructions: [
                InstructionRow(address: 0x1000, bytes: "e0 03 01 aa", mnemonic: "mov", operands: "x0, x1", hasBreakpoint: false, comment: nil),
                InstructionRow(address: 0x1004, bytes: "c0 03 5f d6", mnemonic: "ret", operands: "", hasBreakpoint: false, comment: nil),
            ],
            xrefs: [],
            hexBytes: Data()
        )
        let store = WorkspaceStore(workspaceName: "MCP", snapshot: snapshot, engine: AnalysisEngine())
        return (MCPServer(api: WorkspaceScriptingAPI(store: store)), store)
    }

    private func request(_ method: String, id: ScriptValue? = .int(1), params: ScriptValue? = nil) -> ScriptValue {
        var object: [String: ScriptValue] = ["jsonrpc": .string("2.0"), "method": .string(method)]
        if let id { object["id"] = id }
        if let params { object["params"] = params }
        return .object(object)
    }

    func testInitialize() {
        let (server, _) = makeServer()
        let response = server.handle(request("initialize"))
        XCTAssertEqual(response?["jsonrpc"]?.stringValue, "2.0")
        XCTAssertEqual(response?["id"]?.intValue, 1)
        XCTAssertEqual(response?["result"]?["protocolVersion"]?.stringValue, MCPServer.protocolVersion)
        XCTAssertEqual(response?["result"]?["serverInfo"]?["name"]?.stringValue, "macscope")
        XCTAssertNotNil(response?["result"]?["capabilities"]?["tools"])
    }

    func testToolsListExposesCommandsAsTools() {
        let (server, _) = makeServer()
        let tools = server.handle(request("tools/list"))?["result"]?["tools"]?.arrayValue ?? []
        XCTAssertFalse(tools.isEmpty)
        let rename = tools.first { $0["name"]?.stringValue == "rename" }
        XCTAssertNotNil(rename)
        XCTAssertEqual(rename?["inputSchema"]?["type"]?.stringValue, "object")
        XCTAssertNotNil(rename?["inputSchema"]?["properties"]?["address"])
        XCTAssertTrue(rename?["description"]?.stringValue?.contains("mutates") ?? false)
        XCTAssertTrue(tools.contains { $0["name"]?.stringValue == "functions" })
        XCTAssertFalse(tools.contains { $0["name"]?.stringValue == "save-patched-binary" })
        XCTAssertFalse(tools.contains { $0["name"]?.stringValue == "read-debug-symbols" })
        XCTAssertEqual(rename?["inputSchema"]?["additionalProperties"]?.boolValue, false)
    }

    func testToolSchemasDescribeNumericBooleanAndStructuredArguments() throws {
        let (server, _) = makeServer()
        let tools = server.handle(request("tools/list"))?["result"]?["tools"]?.arrayValue ?? []
        func schema(_ name: String) throws -> ScriptValue {
            try XCTUnwrap(tools.first { $0["name"]?.stringValue == name }?["inputSchema"])
        }

        let functions = try schema("functions")
        XCTAssertEqual(functions["properties"]?["limit"]?["type"], .string("integer"))
        XCTAssertEqual(functions["properties"]?["limit"]?["maximum"], .int(10_000))
        let read = try schema("read-bytes")
        XCTAssertEqual(read["properties"]?["count"]?["maximum"], .int(1_048_576))
        XCTAssertEqual(read["required"], .array([.string("address")]))
        XCTAssertEqual(try schema("make-data")["properties"]?["isData"]?["type"], .string("boolean"))

        let signature = try schema("set-signature")
        XCTAssertEqual(signature["properties"]?["args"]?["type"], .array([.string("array"), .string("null")]))
        XCTAssertEqual(signature["properties"]?["args"]?["items"]?["required"], .array([.string("type")]))
        XCTAssertNil(signature["properties"]?["args"]?["items"]?["additionalProperties"])
        XCTAssertEqual(signature["additionalProperties"], .bool(false))
        XCTAssertEqual(signature["properties"]?["returnType"]?["type"], .array([.string("string"), .string("null")]))
        let defineType = try schema("define-type")
        XCTAssertEqual(defineType["properties"]?["fields"]?["type"], .string("array"))
        XCTAssertNil(defineType["properties"]?["fields"]?["items"]?["additionalProperties"])
        XCTAssertEqual(defineType["additionalProperties"], .bool(false))
        XCTAssertEqual(try schema("decompile")["anyOf"], .array([
            .object(["required": .array([.string("function")])]),
            .object(["required": .array([.string("address")])]),
        ]))
        XCTAssertNotNil(try schema("call-argument-audit")["oneOf"])

        // Correcting schemas must never widen the existing external authority.
        XCTAssertFalse(tools.contains { $0["name"]?.stringValue == "save-patched-binary" })
        XCTAssertFalse(tools.contains { $0["name"]?.stringValue == "read-debug-symbols" })
    }

    func testSchemaNumericLimitMatchesExecutionAndRejectsStringifiedCount() throws {
        let (server, _) = makeServer()
        let response = server.handle(request("tools/call", params: .object([
            "name": .string("functions"), "arguments": .object(["limit": .int(0)]),
        ])))
        XCTAssertEqual(response?["result"]?["isError"], .bool(false))
        XCTAssertEqual(response?["result"]?["content"]?.arrayValue?.first?["text"], .string("[]"))
        let invalid = server.handle(request("tools/call", params: .object([
            "name": .string("functions"), "arguments": .object(["limit": .string("0")]),
        ])))
        XCTAssertEqual(invalid?["error"]?["code"], .int(-32602))
    }

    func testSchemaBooleanFalseAndSignatureNullRetainTheirExistingMeaning() throws {
        let (server, store) = makeServer()
        let result = server.handle(request("tools/call", params: .object([
            "name": .string("make-data"),
            "arguments": .object(["address": .string("0x1000"), "isData": .bool(false)]),
        ])))
        XCTAssertEqual(result?["result"]?["isError"], .bool(false))
        let payload = try ScriptValue.decode(Data(try XCTUnwrap(
            result?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
        ).utf8))
        XCTAssertEqual(payload["isData"], .bool(false))

        let authored = server.handle(request("tools/call", params: .object([
            "name": .string("set-signature"),
            "arguments": .object([
                "address": .string("0x1000"), "returnType": .string("int"),
                "variadicState": .string("fixed"),
                "args": .array([.object(["type": .string("int"), "name": .string("value")])]),
            ]),
        ])))
        XCTAssertEqual(authored?["result"]?["isError"], .bool(false))
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1000)]?.signature?.returnType, "int")
        let cleared = server.handle(request("tools/call", params: .object([
            "name": .string("set-signature"),
            "arguments": .object(["address": .string("0x1000"), "returnType": .null, "args": .null]),
        ])))
        XCTAssertEqual(cleared?["result"]?["isError"], .bool(false))
        let signature = try XCTUnwrap(store.snapshot.addressOverrides[.primary(0x1000)]?.signature)
        XCTAssertNil(signature.returnType)
        XCTAssertEqual(signature.parameterList, .unspecified)
    }

    func testToolsCallReturnsResultContent() {
        let (server, _) = makeServer()
        let response = server.handle(request("tools/call", params: .object(["name": .string("functions")])))
        XCTAssertEqual(response?["result"]?["isError"]?.boolValue, false)
        let text = response?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("_main") ?? false) // the JSON listing includes the function
    }

    func testToolsCallSessionMutatesAndReadsBack() throws {
        let (server, store) = makeServer()
        // Call the rename tool, then read it back via name-at — a full session.
        _ = server.handle(request("tools/call", params: .object([
            "name": .string("rename"),
            "arguments": .object(["address": .string("0x1000"), "name": .string("entry")]),
        ])))
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1000)]?.customName, "entry")

        let readBack = server.handle(request("tools/call", params: .object([
            "name": .string("name-at"),
            "arguments": .object(["address": .string("0x1000")]),
        ])))
        XCTAssertEqual(readBack?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue, "\"entry\"")
    }

    func testSeparateServerInstancesNeverShareWorkspaceMutations() {
        let (first, firstStore) = makeServer()
        let (second, secondStore) = makeServer()
        _ = first.handle(request("tools/call", params: .object([
            "name": .string("rename"),
            "arguments": .object(["address": .string("0x1000"), "name": .string("first-only")]),
        ])))
        XCTAssertEqual(firstStore.snapshot.addressOverrides[.primary(0x1000)]?.customName, "first-only")
        XCTAssertNil(secondStore.snapshot.addressOverrides[.primary(0x1000)]?.customName)
        let secondName = second.handle(request("tools/call", params: .object([
            "name": .string("name-at"),
            "arguments": .object(["address": .string("0x1000")]),
        ])))
        XCTAssertEqual(secondName?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue, "\"_main\"")
    }

    func testToolErrorIsReportedInBand() {
        let (server, _) = makeServer()
        // An unknown tool / bad argument is an MCP tool error (isError), not a protocol error.
        let response = server.handle(request("tools/call", params: .object(["name": .string("does-not-exist")])))
        XCTAssertEqual(response?["result"]?["isError"]?.boolValue, true)
        XCTAssertNil(response?["error"])
    }

    func testFailedToolCallCarriesTheScriptingErrorDescription() {
        let (server, _) = makeServer()
        // A schema-valid call that fails semantically names the reason instead of a bare
        // "Tool call failed.", so an agent can correct the call.
        let response = server.handle(request("tools/call", params: .object([
            "name": .string("rename"),
            "arguments": .object(["address": .string("not-an-address"), "name": .string("x")]),
        ])))
        XCTAssertEqual(response?["result"]?["isError"]?.boolValue, true)
        let text = response?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertTrue(text.hasPrefix("Tool call failed: "), text)
        XCTAssertGreaterThan(text.count, "Tool call failed: ".count)
    }

    func testCommittedMutationIsNotReportedAsADeadlineFailure() {
        let (_, store) = makeServer()
        var now: UInt64 = 0
        // Every clock read advances a minute, so every call "exceeds" the 30 s deadline.
        let server = MCPServer(api: WorkspaceScriptingAPI(store: store), monotonicNow: {
            now += 60_000_000_000
            return now
        })
        let rename = server.handle(request("tools/call", params: .object([
            "name": .string("rename"),
            "arguments": .object(["address": .string("0x1000"), "name": .string("applied")]),
        ])))
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1000)]?.customName, "applied")
        XCTAssertNil(rename?["error"], "the rename committed; reporting -32001 invites a double apply")
        XCTAssertEqual(rename?["result"]?["isError"]?.boolValue, false)
        // A read that overruns still reports the deadline.
        let read = server.handle(request("tools/call", params: .object(["name": .string("functions")])))
        XCTAssertEqual(read?["error"]?["code"]?.intValue, -32001)
    }

    func testRetainedPatchReportsCommitAndDiagnosticDespiteLateCancellationAndDeadline() throws {
        let bytes = Data([0xb8, 1, 0, 0, 0, 0xc3])
        let text = BinarySection(name: ".text", address: 0x1000, size: 6, fileOffset: 0,
                                 isExecutable: true, fileSize: 6)
        let binary = LoadedBinary(name: "mutation-reporting", path: "/mutation-reporting-fixture",
            isBundle: false, cpuType: MachOConstants.cpuTypeX86_64, fileTypeName: "fixture",
            architectureDisplayName: "x86_64", metadata: .empty, bytes: bytes, sliceOffset: 0,
            sliceSize: 6, sections: [text], executableTextSection: text, entryPointAddress: 0x1000,
            symbols: [], imports: [], indirectSymbols: [], exports: [], stringLiterals: [],
            functionStarts: [0x1000], objcSelectors: [:])
        let engine = AnalysisEngine(loader: MutationReportingFixtureLoader(binary: binary))
        let store = WorkspaceStore(workspaceName: "MCP retained edit",
            snapshot: try engine.analyze(url: URL(fileURLWithPath: binary.path)),
            engine: engine, autosaveScheduler: nil)
        var server: MCPServer?
        defer { server = nil }
        var identityChecks = 0
        var now: UInt64 = 0
        server = MCPServer(api: WorkspaceScriptingAPI(store: store), monotonicNow: {
            now += 60_000_000_000
            return now
        }, validateWorkspaceIdentity: {
            identityChecks += 1
            if identityChecks.isMultiple(of: 2) {
                _ = server?.handle(self.request("notifications/cancelled", id: nil, params: .object([
                    "requestId": .int(41),
                ])))
            }
        })
        for _ in 0..<2 {
            let response = server?.handle(request("tools/call", id: .int(41), params: .object([
                "name": .string("patch-bytes"),
                "arguments": .object(["address": .hex(0x1005), "bytes": .string("90 90")]),
            ])))
            XCTAssertNil(response?["error"], "a retained mutation must survive late cancel/deadline reporting")
            XCTAssertEqual(response?["result"]?["isError"], .bool(false))
            let encoded = try XCTUnwrap(response?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue)
            let output = try ScriptValue.decode(Data(encoded.utf8))
            XCTAssertEqual(output["committed"], .bool(true))
            XCTAssertEqual(output["reanalysisStatus"], .string("failed"))
            XCTAssertTrue(output["reanalysisDiagnostic"]?.stringValue?.contains("unambiguous file-backed mapping") == true)
            XCTAssertEqual(store.snapshot.patches(in: .primary)[0x1005]?.byteText, "90 90")
            XCTAssertTrue(store.isDirty)
        }
    }

    func testProtocolErrors() {
        let (server, _) = makeServer()
        XCTAssertEqual(server.handle(request("nonexistent/method"))?["error"]?["code"]?.intValue, -32601)
        XCTAssertEqual(server.handle(request("tools/call", params: .object([:])))?["error"]?["code"]?.intValue, -32602)
        XCTAssertEqual(server.handle(request("ping"))?["result"], .object([:]))
    }

    func testNotificationsGetNoResponse() {
        let (server, _) = makeServer()
        // No `id` → a notification → no reply.
        XCTAssertNil(server.handle(request("notifications/initialized", id: nil)))
        XCTAssertNil(server.handle(request("initialized", id: nil))) // unknown notification, still no reply
    }

    func testToolCallNotificationExecutesButNeverResponds() {
        let (server, store) = makeServer()
        let notification = request("tools/call", id: nil, params: .object([
            "name": .string("rename"),
            "arguments": .object(["address": .string("0x1000"), "name": .string("notified")]),
        ]))
        XCTAssertNil(server.handle(notification))
        XCTAssertEqual(store.snapshot.addressOverrides[.primary(0x1000)]?.customName, "notified")
    }

    func testHandleLineTransport() {
        let (server, _) = makeServer()
        let line = #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#
        let response = server.handleLine(line)
        XCTAssertTrue(response?.contains("\"id\":7") ?? false)
        // Malformed JSON yields a JSON-RPC parse error.
        XCTAssertTrue(server.handleLine("{not json")?.contains("-32700") ?? false)
        // A blank line yields nothing.
        XCTAssertNil(server.handleLine("   "))
    }

    func testStrictRequestShapesAndDuplicateKeysFailClosed() throws {
        let (server, _) = makeServer()
        XCTAssertEqual(server.handle(.array([]))?["error"]?["code"]?.intValue, -32600)
        XCTAssertEqual(
            server.handle(.object([
                "jsonrpc": .string("2.0"), "id": .bool(true), "method": .string("ping"),
            ]))?["error"]?["code"]?.intValue,
            -32600
        )
        let explicitNull = server.handle(.object([
            "jsonrpc": .string("2.0"), "id": .null, "method": .string("ping"),
        ]))
        XCTAssertEqual(explicitNull?["id"], ScriptValue.null, "an explicit null id is still a request")
        XCTAssertEqual(
            server.handle(request("ping", params: .array([])))?["error"]?["code"]?.intValue,
            -32602
        )
        XCTAssertEqual(
            server.handle(request("tools/call", params: .object([
                "name": .string("info"), "arguments": .array([]),
            ])))?["error"]?["code"]?.intValue,
            -32602
        )
        let duplicate = #"{"jsonrpc":"2.0","id":1,"id":2,"method":"ping"}"#
        let duplicateResponse = try ScriptValue.decode(Data(try XCTUnwrap(
            server.handleLine(duplicate)
        ).utf8))
        XCTAssertEqual(duplicateResponse["error"]?["code"]?.intValue, -32700)
    }

    func testHeadlessAuthorityRejectsFilesystemEscapeAndHostileAmplification() {
        let (server, _) = makeServer()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-authority-escape-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        let denied = server.handle(request("tools/call", params: .object([
            "name": .string("save-patched-binary"),
            "arguments": .object(["path": .string(destination.path)]),
        ])))
        XCTAssertEqual(denied?["result"]?["isError"]?.boolValue, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        let amplified = server.handle(request("tools/call", params: .object([
            "name": .string("read-bytes"),
            "arguments": .object([
                "address": .string("0x1000"), "count": .int(Int64.max),
            ]),
        ])))
        XCTAssertEqual(amplified?["error"]?["code"]?.intValue, -32602)

        let smuggled = server.handle(request("tools/call", params: .object([
            "name": .string("info"),
            "arguments": .object(["path": .string("/etc/passwd")]),
        ])))
        XCTAssertEqual(smuggled?["error"]?["code"]?.intValue, -32602)

        let commands = server.handle(request("tools/call", params: .object([
            "name": .string("commands"),
        ])))?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        XCTAssertFalse(commands.contains("save-patched-binary"))
        XCTAssertFalse(commands.contains("read-debug-symbols"))
    }

    func testCancellationIsBoundedToOneServerSession() {
        let (cancelledServer, _) = makeServer()
        let (otherServer, _) = makeServer()
        let cancellation = request("notifications/cancelled", id: nil, params: .object([
            "requestId": .int(41), "reason": .string("test"),
        ]))
        XCTAssertNil(cancelledServer.handle(cancellation))

        let call = request("tools/call", id: .int(41), params: .object([
            "name": .string("info"),
        ]))
        XCTAssertEqual(cancelledServer.handle(call)?["error"]?["code"]?.intValue, -32800)
        XCTAssertEqual(otherServer.handle(call)?["result"]?["isError"]?.boolValue, false)
        XCTAssertEqual(
            cancelledServer.handle(call)?["result"]?["isError"]?.boolValue,
            false,
            "a cancellation is consumed exactly once"
        )
    }

    func testExpiredToolResultIsNotPublished() {
        let (_, store) = makeServer()
        var ticks: [UInt64] = [100, 111]
        let server = MCPServer(
            api: WorkspaceScriptingAPI(store: store),
            configuration: .init(
                maximumInputBytes: 1_024,
                maximumOutputBytes: 8_192,
                maximumToolDurationNanoseconds: 10,
                maximumRememberedCancellations: 8
            ),
            monotonicNow: { ticks.removeFirst() }
        )
        let response = server.handle(request("tools/call", params: .object([
            "name": .string("info"),
        ])))
        XCTAssertEqual(response?["error"]?["code"]?.intValue, -32001)
        XCTAssertNil(response?["result"], "a late result never becomes authoritative")
    }

    func testBoundedTransportDrainsOneOversizedLineAndKeepsFraming() throws {
        let (_, store) = makeServer()
        let server = MCPServer(
            api: WorkspaceScriptingAPI(store: store),
            configuration: .init(
                maximumInputBytes: 64,
                maximumOutputBytes: 8_192,
                maximumToolDurationNanoseconds: 1_000_000_000,
                maximumRememberedCancellations: 8
            )
        )
        let input = Pipe()
        let output = Pipe()
        let bytes = Data((String(repeating: "x", count: 80)
            + "\n{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"ping\"}\n").utf8)
        try input.fileHandleForWriting.write(contentsOf: bytes)
        try input.fileHandleForWriting.close()
        server.runStdioLoop(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting
        )
        try output.fileHandleForWriting.close()
        let transcript = try XCTUnwrap(try output.fileHandleForReading.readToEnd())
        let lines = String(decoding: transcript, as: UTF8.self)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, "one input line produces at most one response")
        XCTAssertEqual(try ScriptValue.decode(Data(lines[0].utf8))["error"]?["code"]?.intValue, -32700)
        XCTAssertEqual(try ScriptValue.decode(Data(lines[1].utf8))["id"]?.intValue, 9)
    }

    func testOversizedResponseBecomesOneCorrelatedProtocolError() throws {
        let (_, store) = makeServer()
        let server = MCPServer(
            api: WorkspaceScriptingAPI(store: store),
            configuration: .init(
                maximumInputBytes: 1_024,
                maximumOutputBytes: 512,
                maximumToolDurationNanoseconds: 1_000_000_000,
                maximumRememberedCancellations: 8
            )
        )
        let responseData = try XCTUnwrap(server.handleMessage(Data(
            #"{"jsonrpc":"2.0","id":"bounded","method":"tools/list"}"#.utf8
        )))
        XCTAssertLessThanOrEqual(responseData.count, 512)
        let response = try ScriptValue.decode(responseData)
        XCTAssertEqual(response["id"]?.stringValue, "bounded")
        XCTAssertEqual(response["error"]?["code"]?.intValue, -32603)
    }

    func testProtocolDescriptorIsolatesIncidentalOutput() throws {
        var protocolDescriptors: [Int32] = [0, 0]
        var incidentalDescriptors: [Int32] = [0, 0]
        XCTAssertEqual(Darwin.pipe(&protocolDescriptors), 0)
        XCTAssertEqual(Darwin.pipe(&incidentalDescriptors), 0)
        let captured = try HeadlessProtocolIO.isolate(
            outputDescriptor: protocolDescriptors[1],
            replacingWith: incidentalDescriptors[1]
        )
        let incidental = Data("library log with secret\n".utf8)
        _ = incidental.withUnsafeBytes {
            Darwin.write(protocolDescriptors[1], $0.baseAddress, $0.count)
        }
        try HeadlessProtocolIO.writeLine(Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8), to: captured)
        try captured.close()
        close(protocolDescriptors[1])
        close(incidentalDescriptors[1])

        let protocolRead = FileHandle(fileDescriptor: protocolDescriptors[0], closeOnDealloc: true)
        let incidentalRead = FileHandle(fileDescriptor: incidentalDescriptors[0], closeOnDealloc: true)
        let protocolData = try XCTUnwrap(try protocolRead.readToEnd())
        let incidentalData = try XCTUnwrap(try incidentalRead.readToEnd())
        XCTAssertFalse(String(decoding: protocolData, as: UTF8.self).contains("secret"))
        XCTAssertEqual(String(decoding: incidentalData, as: UTF8.self), "library log with secret\n")
        XCTAssertNoThrow(try ScriptValue.decode(Data(protocolData.dropLast())))
    }
}

private struct MutationReportingFixtureLoader: BinaryLoader {
    let binary: LoadedBinary
    func load(at url: URL) throws -> LoadedBinary { binary }
}

private actor MCPAsyncTestOutput {
    private(set) var values: [Data] = []
    var count: Int { values.count }
    func append(_ data: Data) { values.append(data) }
}

private actor MCPAsyncTestGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var blocked: [CheckedContinuation<Void, Never>] = []
    func markStarted() {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    func suspend() async {
        markStarted()
        if !released { await withCheckedContinuation { blocked.append($0) } }
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startWaiters.append($0) } }
    }
    func release() {
        released = true
        let waiters = blocked
        blocked.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
