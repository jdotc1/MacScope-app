import Darwin
import Foundation
import XCTest
@testable import MacScope

/// MCP attach to an open window (DP09 contract): endpoint ownership, the mutual-proof handshake,
/// grant pinning to window + document generation, capability policy in listing and dispatch,
/// one independent undo group per agent request, the revocation fence, heavy reads leaving the
/// MainActor free, and the real socket path end to end.
@MainActor
final class MCPAttachTests: XCTestCase {
    private static let code = Data([
        0xfd, 0x7b, 0xbf, 0xa9, // stp x29, x30, [sp, #-16]!
        0x00, 0x00, 0x80, 0xd2, // mov x0, #0
        0xfd, 0x7b, 0xc1, 0xa8, // ldp x29, x30, [sp], #16
        0xc0, 0x03, 0x5f, 0xd6, // ret
    ])

    private func makeStore() throws -> WorkspaceStore {
        let url = try TinyMachO.make(code: Self.code).write()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try MCPLauncher.makeStore(binaryURL: url)
    }

    private func entryAddress(_ store: WorkspaceStore) throws -> String {
        let function = try XCTUnwrap(store.snapshot.functions.first)
        return "0x" + String(function.startAddress, radix: 16)
    }

    /// A short private directory (Darwin socket paths are limited to 104 bytes).
    private func makeDirectory() -> URL {
        let directory = URL(fileURLWithPath: "/tmp/msa-\(UUID().uuidString.prefix(8))", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func name(at address: String, _ store: WorkspaceStore) throws -> String {
        "\(try WorkspaceScriptingAPI(store: store).execute("name-at", arguments: .object(["address": .string(address)])))"
    }

    // MARK: - Parsing and handshake

    func testRelayArgumentsAndProofs() {
        XCTAssertEqual(MCPAttachRelay.requestedWindow(from: ["app", "--mcp-attach"]), .some(nil))
        XCTAssertEqual(MCPAttachRelay.requestedWindow(from: ["app", "--mcp-attach", "--window", "ls"]), .some("ls"))
        XCTAssertNil(MCPAttachRelay.requestedWindow(from: ["app", "--mcp-attach", "--window"]))
        XCTAssertNil(MCPAttachRelay.requestedWindow(from: ["app", "--other", "--mcp-attach"]))

        let token = Data(repeating: 7, count: 32)
        let proof = MCPAttachHandshake.proof(token: token, role: "server", first: "aa", second: "bb")
        XCTAssertTrue(MCPAttachHandshake.matches(proof, MCPAttachHandshake.proof(token: token, role: "server", first: "aa", second: "bb")))
        XCTAssertFalse(MCPAttachHandshake.matches(proof, MCPAttachHandshake.proof(token: token, role: "client", first: "aa", second: "bb")))
        XCTAssertFalse(MCPAttachHandshake.matches(proof, MCPAttachHandshake.proof(token: Data(repeating: 8, count: 32), role: "server", first: "aa", second: "bb")))
    }

    // MARK: - Endpoint ownership

    func testEndpointHasOneOwnerAndRemovesOnlyWhatItPublished() throws {
        let directory = makeDirectory()
        let first = try MCPAttachSocket.EndpointOwner(directory: directory)
        XCTAssertThrowsError(try MCPAttachSocket.EndpointOwner(directory: directory)) {
            XCTAssertEqual($0 as? MCPAttachSocketError, .endpointOwnedElsewhere)
        }
        var info = stat()
        XCTAssertEqual(lstat(directory.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        XCTAssertEqual(lstat(MCPAttachSocket.tokenURL(in: directory).path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(try MCPAttachSocket.readToken(in: directory), first.token)

        // If the path no longer holds this owner's socket, release leaves it alone.
        let socketPath = MCPAttachSocket.socketURL(in: directory).path
        unlink(socketPath)
        FileManager.default.createFile(atPath: socketPath, contents: Data())
        first.release()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath), "a foreign object is not removed")
        // The lock is free again, but an unexpected object at the socket path is refused, not removed.
        XCTAssertThrowsError(try MCPAttachSocket.EndpointOwner(directory: directory))
        unlink(socketPath)
        let second = try MCPAttachSocket.EndpointOwner(directory: directory)
        second.release()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testUnsafeDirectoryIsRefusedNotRepaired() throws {
        let directory = makeDirectory()
        XCTAssertEqual(mkdir(directory.path, 0o755), 0)
        chmod(directory.path, 0o755)
        XCTAssertThrowsError(try MCPAttachSocket.EndpointOwner(directory: directory))
        var info = stat()
        XCTAssertEqual(lstat(directory.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o755, "left as found")
    }

    // MARK: - Executor policy

    func testExecutorConsentPolicyAndRate() async throws {
        let store = try makeStore()
        var clock: UInt64 = 0
        let executor = MCPAttachExecutor(store: store, api: { WorkspaceScriptingAPI(store: $0) }, now: { clock })
        do { _ = try await executor.execute("info", .object([:])); XCTFail("ran before consent") }
        catch {
            XCTAssertEqual(error as? MCPAttachExecutor.Failure, .consentPending)
            XCTAssertFalse(error.localizedDescription.contains(store.workspaceName), "no workspace details before consent")
        }
        executor.setConsent(.allowed)
        for command in ["save-workspace", "open-workspace", "goto", "make-procedure", "call-argument-audit", "define-types-from-c"] {
            do { _ = try await executor.execute(command, .object([:])); XCTFail(command) }
            catch { XCTAssertEqual(error as? MCPAttachExecutor.Failure, .unavailableWhenAttached, command) }
        }
        clock = 2_000_000_000
        for _ in 0..<MCPAttachExecutor.maximumRequestsPerSecond { _ = try await executor.execute("info", .object([:])) }
        do { _ = try await executor.execute("info", .object([:])); XCTFail("over the per-second limit") }
        catch { XCTAssertEqual(error as? MCPAttachExecutor.Failure, .rateLimited) }

        executor.setConsent(.revoked)
        executor.setConsent(.allowed)
        XCTAssertEqual(executor.consent, .revoked, "revocation is final")
    }

    func testCapabilityPolicyAppliesToListingAndDispatch() async throws {
        let store = try makeStore()
        let server = MCPServer(api: WorkspaceScriptingAPI(store: store), configuration: .attached,
                               asyncCommandExecutor: { _, _ in .null }, allowedCommands: MCPAttachExecutor.attachCommands)
        let list = String(decoding: try XCTUnwrap(server.handleMessage(
            Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))), as: UTF8.self)
        XCTAssertTrue(list.contains("\"rename\""))
        for hidden in ["\"goto\"", "\"save-workspace\"", "\"open-workspace\"", "\"make-procedure\""] {
            XCTAssertFalse(list.contains(hidden), hidden)
        }
        let call = await server.handleMessageAsync(Data(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"goto","arguments":{"address":"0x1"}}}"#.utf8))
        XCTAssertTrue(String(decoding: try XCTUnwrap(call), as: UTF8.self).contains("unavailable"))
    }

    // MARK: - Undo and the commit fence

    func testAgentAndHumanEditsUndoIndependently() async throws {
        let store = try makeStore()
        let address = try entryAddress(store)
        let target = UInt64(address.dropFirst(2), radix: 16)!
        let executor = MCPAttachExecutor(store: store, api: { WorkspaceScriptingAPI(store: $0) })
        executor.setConsent(.allowed)
        _ = try await executor.execute("rename", .object(["address": .string(address), "name": .string("agent_a")]))
        store.setCustomComment(target, in: store.snapshot.primarySlot, comment: "human")
        _ = try await executor.execute("set-tag", .object(["address": .string(address), "tag": .string("agent_b")]))
        XCTAssertEqual(store.undoManager.undoActionName, "Agent: set-tag")
        store.undoManager.undo() // agent B
        XCTAssertTrue(try name(at: address, store).contains("agent_a"), "agent A survives undoing agent B")
        store.undoManager.undo() // the human comment
        XCTAssertEqual(store.undoManager.undoActionName, "Agent: rename")
        store.undoManager.undo() // agent A
        XCTAssertFalse(try name(at: address, store).contains("agent_a"))
    }

    /// DP09-2 N2 and the release check's bare "Undo": on the window's event-grouping UndoManager an
    /// agent edit is one named top-level group and leaves no automatic group open behind it.
    func testAgentEditIsOneNamedTopLevelGroupOnTheWindowManager() async throws {
        let store = try makeStore()
        let host = UndoManager()
        XCTAssertTrue(host.groupsByEvent)
        store.hostUndoManager = host
        let address = try entryAddress(store)
        let executor = MCPAttachExecutor(store: store, api: { WorkspaceScriptingAPI(store: $0) })
        executor.setConsent(.allowed)
        _ = try await executor.execute("rename", .object(["address": .string(address), "name": .string("agent")]))
        XCTAssertEqual(host.groupingLevel, 0, "no automatic group is left open")
        XCTAssertTrue(host.groupsByEvent, "event grouping is restored")
        XCTAssertEqual(host.undoMenuItemTitle, "Undo Agent: rename", "the Edit menu names the agent edit")
        host.undo()
        XCTAssertFalse(try name(at: address, store).contains("agent"))
    }

    /// DP09-2 N2: while a host group is open (a human edit in progress), the agent waits and then
    /// commits in its own group, so each undoes on its own.
    func testAgentEditWaitsForAnOpenHostGroup() async throws {
        let store = try makeStore()
        let host = UndoManager()
        store.hostUndoManager = host
        let address = try entryAddress(store)
        let target = UInt64(address.dropFirst(2), radix: 16)!
        let executor = MCPAttachExecutor(store: store, api: { WorkspaceScriptingAPI(store: $0) })
        executor.setConsent(.allowed)

        host.groupsByEvent = false // the test owns the human's group explicitly
        host.beginUndoGrouping()
        store.setCustomComment(target, in: store.snapshot.primarySlot, comment: "human")
        let agent = Task { try await executor.execute("rename", .object(["address": .string(address), "name": .string("agent")])) }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(host.groupingLevel, 1, "the agent has not joined the open group")
        host.setActionName("Comment")
        host.endUndoGrouping()
        host.groupsByEvent = true
        _ = try await agent.value

        XCTAssertEqual(host.undoMenuItemTitle, "Undo Agent: rename")
        host.undo()
        XCTAssertFalse(try name(at: address, store).contains("agent"), "the agent edit undoes on its own")
        let instructions = { "\(try WorkspaceScriptingAPI(store: store).execute("instructions", arguments: .object(["address": .string(address), "count": .int(1)])))" }
        XCTAssertTrue(try instructions().contains("human"), "the human edit survives undoing the agent's")
        XCTAssertEqual(host.undoMenuItemTitle, "Undo Comment")
    }

    func testRevokedGrantCommitsNothing() async throws {
        let store = try makeStore()
        let address = try entryAddress(store)
        let executor = MCPAttachExecutor(store: store, api: { WorkspaceScriptingAPI(store: $0) })
        executor.setConsent(.allowed)
        var granted = true
        executor.authorize = { granted }
        granted = false // window closed / document replaced / disconnected
        do {
            _ = try await executor.execute("rename", .object(["address": .string(address), "name": .string("late")]))
            XCTFail("committed after revocation")
        } catch { XCTAssertEqual(error as? MCPAttachExecutor.Failure, .notAuthorized) }
        XCTAssertFalse(try name(at: address, store).contains("late"))
        XCTAssertFalse(store.undoManager.canUndo)
    }

    /// The decompile runs detached: while it is parked mid-work the MainActor (this test) keeps
    /// running and edits the store; a grant revoked meanwhile suppresses the late result.
    func testDecompileLeavesTheMainActorFreeAndLateResultsAreSuppressed() async throws {
        let store = try makeStore()
        let address = try entryAddress(store)
        let gate = CheckpointGate()
        let executor = MCPAttachExecutor(store: store, api: {
            WorkspaceScriptingAPI(store: $0, snapshotReadCheckpoint: { gate.park() })
        })
        executor.setConsent(.allowed)
        var granted = true
        executor.authorize = { granted }
        let decompile = Task { try await executor.execute("decompile", .object(["address": .string(address)])) }
        try await gate.waitUntilParked()
        store.setCustomComment(UInt64(address.dropFirst(2), radix: 16)!, in: store.snapshot.primarySlot, comment: "user edit")
        granted = false
        gate.release()
        do { _ = try await decompile.value; XCTFail("a read was released after revocation") }
        catch { XCTAssertEqual(error as? MCPAttachExecutor.Failure, .notAuthorized) }
    }

    // MARK: - Coordinator and socket end to end

    /// DP09-2 N1: a grant belongs to one installation of the document. Forking or reopening the
    /// same document (same persisted IDs, new installation) revokes it at once and closes the
    /// connection, so a pending request is cancelled instead of committing to the new installation.
    func testGrantEndsWhenTheDocumentIsReinstalled() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MCPAttachTests-\(UUID().uuidString)"))
        defaults.set(true, forKey: MCPAttachCoordinator.enabledDefaultsKey)
        let coordinator = MCPAttachCoordinator(directory: makeDirectory(), defaults: defaults)
        coordinator.syncWithSetting()
        defer { coordinator.stopListening() }
        let store = try makeStore()
        coordinator.register(store)

        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let peer = pair[1]
        defer { close(peer) }
        coordinator.bind(client: pair[0], window: nil)
        let reply = await Task.detached { MCPAttachSocket.readLine(peer) }.value
        let text = String(decoding: try XCTUnwrap(reply), as: UTF8.self)
        XCTAssertTrue(text.contains("\"ok\":true"), text)
        XCTAssertFalse(text.contains(store.workspaceName), "no workspace label before Allow (N5)")
        let connection = try XCTUnwrap(coordinator.connections(for: store).first)
        coordinator.allow(connection.id)
        XCTAssertEqual(coordinator.connections(for: store).first?.consent, .allowed)

        store.forkWorkspaceIdentity() // a new installation of the same content
        XCTAssertEqual(coordinator.connections(for: store).first?.consent, .revoked, "revoked at once, not at the next check")
        coordinator.allow(connection.id)
        XCTAssertNotEqual(coordinator.connections(for: store).first?.consent, .allowed, "a late Allow can't revive it")
        let closed = await Task.detached { MCPAttachSocket.readLine(peer, limit: 1 << 20) }.value
        XCTAssertNil(closed, "the connection is closed")
    }

    /// DP09-2 N4: every connection holds a slot from accept on; a fifth is closed before any
    /// thread is spent on it, and a stalled handshake is cut at the absolute deadline.
    func testAdmissionBudgetAndHandshakeDeadline() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MCPAttachTests-\(UUID().uuidString)"))
        defaults.set(true, forKey: MCPAttachCoordinator.enabledDefaultsKey)
        let directory = makeDirectory()
        let coordinator = MCPAttachCoordinator(directory: directory, defaults: defaults, handshakeDeadline: .milliseconds(400))
        coordinator.syncWithSetting()
        defer { coordinator.stopListening() }
        let socketURL = MCPAttachSocket.socketURL(in: directory)

        var stalled: [Int32] = []
        defer { stalled.forEach { close($0) } }
        for _ in 0..<MCPAttachCoordinator.maximumConnections { stalled.append(try MCPAttachSocket.connect(to: socketURL)) }
        for _ in 0..<200 where coordinator.slots.count < MCPAttachCoordinator.maximumConnections {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(coordinator.slots.count, MCPAttachCoordinator.maximumConnections, "silent peers hold their slots")
        let extra = try MCPAttachSocket.connect(to: socketURL)
        defer { close(extra) }
        let refused = await Task.detached { MCPAttachSocket.readLine(extra) }.value
        XCTAssertNil(refused, "over budget: closed at accept")

        let first = stalled[0]
        let cut = await Task.detached { MCPAttachSocket.readLine(first) }.value
        XCTAssertNil(cut, "a silent handshake is closed at the deadline")
        for _ in 0..<200 where coordinator.slots.count > 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(coordinator.slots.count, 0, "every slot is returned")
    }

    /// DP09-2 N4: a handshake that completed under an earlier listener (and token) can't bind
    /// after a stop/start.
    func testHandshakeFromAnEarlierListenerNeverBinds() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MCPAttachTests-\(UUID().uuidString)"))
        defaults.set(true, forKey: MCPAttachCoordinator.enabledDefaultsKey)
        let coordinator = MCPAttachCoordinator(directory: makeDirectory(), defaults: defaults)
        coordinator.syncWithSetting()
        defer { coordinator.stopListening() }
        let store = try makeStore()
        coordinator.register(store)
        let earlier = coordinator.listenerEpoch
        coordinator.stopListening()
        coordinator.syncWithSetting()
        XCTAssertNotEqual(coordinator.listenerEpoch, earlier)

        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let peer = pair[1]
        defer { close(peer) }
        coordinator.bind(client: pair[0], window: nil, epoch: earlier, holdsSlot: false)
        let reply = await Task.detached { MCPAttachSocket.readLine(peer) }.value
        XCTAssertTrue(String(decoding: try XCTUnwrap(reply), as: UTF8.self).contains("\"ok\":false"))
        XCTAssertTrue(coordinator.connections.isEmpty)
    }

    /// DP09-2 N7: a start that fails after listening leaves no descriptor and no socket behind,
    /// and the next start succeeds.
    func testFailedStartLeavesNothingBehind() throws {
        let directory = makeDirectory()
        XCTAssertEqual(mkdir(directory.path, 0o700), 0)
        let tokenPath = MCPAttachSocket.tokenURL(in: directory).path
        XCTAssertEqual(mkdir(tokenPath, 0o700), 0) // the token can't be written
        func openDescriptors() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }
        let before = openDescriptors()
        XCTAssertThrowsError(try MCPAttachSocket.EndpointOwner(directory: directory))
        XCTAssertEqual(openDescriptors(), before, "no descriptor leaked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: MCPAttachSocket.socketURL(in: directory).path))
        rmdir(tokenPath)
        let owner = try MCPAttachSocket.EndpointOwner(directory: directory)
        owner.release()
    }

    /// DP09-2 N3: attached list reads get a finite default and a hard cap; instruction ranges are
    /// clamped. N6: `commands` lists exactly the attach tool set.
    func testAttachedReadsAreBoundedAndTheCatalogMatchesPolicy() async throws {
        func limit(_ value: ScriptValue) -> Int64? { value["limit"]?.intValue }
        XCTAssertEqual(limit(MCPAttachExecutor.boundedArguments("functions", .object([:]))), Int64(MCPAttachExecutor.defaultRowLimit))
        XCTAssertEqual(limit(MCPAttachExecutor.boundedArguments("symbols", .object(["limit": .int(1_000_000)]))),
                       Int64(MCPAttachExecutor.maximumRowLimit))
        XCTAssertEqual(limit(MCPAttachExecutor.boundedArguments("strings", .object(["limit": .int(7)]))), 7)
        XCTAssertEqual(MCPAttachExecutor.boundedArguments("instructions", .object(["address": .string("0x1"), "count": .int(1_000_000)]))["count"]?.intValue,
                       Int64(MCPAttachExecutor.maximumInstructionCount))

        let store = try makeStore()
        let executor = MCPAttachExecutor(store: store, api: { WorkspaceScriptingAPI(store: $0) })
        executor.setConsent(.allowed)
        guard case .array(let catalog) = try await executor.execute("commands", .object([:])) else { return XCTFail() }
        let names = Set(catalog.compactMap { $0["name"]?.stringValue })
        XCTAssertFalse(names.isEmpty)
        XCTAssertTrue(names.isSubset(of: MCPAttachExecutor.attachCommands))
        XCTAssertFalse(names.contains("save-workspace"))
        XCTAssertFalse(names.contains("goto"))
    }

    /// DP09-2 N3 follow-up: an attached list read builds its rows off the MainActor. While it is
    /// parked mid-build, the MainActor runs a store edit; the result keeps its usual shape.
    func testListReadsBuildRowsOffTheMainActor() async throws {
        let store = try makeStore()
        let address = try entryAddress(store)
        let gate = CheckpointGate()
        let executor = MCPAttachExecutor(store: store, api: {
            WorkspaceScriptingAPI(store: $0, snapshotReadCheckpoint: { gate.park() })
        })
        executor.setConsent(.allowed)
        let read = Task { try await executor.execute("functions", .object([:])) }
        try await gate.waitUntilParked()
        store.setCustomComment(UInt64(address.dropFirst(2), radix: 16)!, in: store.snapshot.primarySlot, comment: "user edit")
        gate.release()
        let output = try await read.value
        let inline = try WorkspaceScriptingAPI(store: store).execute("functions", arguments: .object(["limit": .int(1_000)]))
        XCTAssertEqual(output, inline, "same rows and shape as the inline registry read")
    }

    func testListReadIsCancelledWithItsRequest() async throws {
        let store = try makeStore()
        let gate = CheckpointGate()
        let executor = MCPAttachExecutor(store: store, api: {
            WorkspaceScriptingAPI(store: $0, snapshotReadCheckpoint: { gate.park() })
        })
        executor.setConsent(.allowed)
        let read = Task { try await executor.execute("functions", .object([:])) }
        try await gate.waitUntilParked()
        read.cancel()
        gate.release()
        do { _ = try await read.value; XCTFail("a cancelled read returned rows") } catch {}
        XCTAssertTrue(gate.sawCancellationAfterRelease)
    }

    func testEveryAdmittedReadHasAnOwnedSnapshotRoute() {
        let reads = Set(WorkspaceScriptingAPI.availableCommands.filter {
            !$0.mutates && MCPAttachExecutor.attachCommands.contains($0.name)
        }.map(\.name))
        // `read-evidence` and `reconstruction-jobs` are admitted (DEF-A06) as
        // non-mutating reads that run inline through `executeAsync`; they have no detached
        // snapshot route by design, so they are listed here explicitly.
        let owned = WorkspaceScriptingAPI.snapshotListCommands
            .union(ScriptingSnapshotRead.allCases.map(\.rawValue)).union(["search"])
            .union(["read-evidence", "reconstruction-jobs"])
        XCTAssertEqual(reads.subtracting(owned), [], "every admitted read must have an owned snapshot route")
    }

    func testStackLocalsCheckpointAllowsMainActorSentinelAndRevocation() async throws {
        try await assertSnapshotReadAllowsSentinelAndRevocation("stack-locals")
    }

    func testStructCandidateCheckpointAllowsMainActorSentinelAndRevocation() async throws {
        try await assertSnapshotReadAllowsSentinelAndRevocation("recover-struct-candidate")
    }

    private static let additionalSnapshotReads = [
        "commands", "info", "xrefs", "callers", "callees", "name-at", "read-bytes", "resolve-symbol",
        "bookmarks", "local-labels", "register-names", "manual-xrefs", "segment-overrides",
    ]

    private func snapshotReadArguments(_ command: String, store: WorkspaceStore, address: String) throws -> ScriptValue {
        let info = try XCTUnwrap(WorkspaceScriptingAPI.availableCommands.first { $0.name == command })
        let values: [String: ScriptValue] = [
            "address": .string(address), "to": .string(address), "parameter": .int(0),
            "name": .string(try XCTUnwrap(store.snapshot.functions.first).name), "count": .int(1),
        ]
        return .object(values.filter { info.arguments.contains($0.key) })
    }

    func testMetadataReadCheckpointsAllowMainActorSentinelAndRevocation() async throws {
        for command in Self.additionalSnapshotReads {
            try await assertSnapshotReadAllowsSentinelAndRevocation(command)
        }
    }

    func testAdditionalSnapshotReadsPreserveInBudgetJSON() async throws {
        let store = try makeStore()
        let address = try entryAddress(store)
        for command in Self.additionalSnapshotReads + ["stack-locals", "recover-struct-candidate"] {
            let arguments = try snapshotReadArguments(command, store: store, address: address)
            let executor = MCPAttachExecutor(store: store, api: { WorkspaceScriptingAPI(store: $0) })
            executor.setConsent(.allowed)
            let expected: ScriptValue
            if command == "commands" {
                let catalog = try WorkspaceScriptingAPI.snapshotListRead(
                    command, arguments: MCPAttachExecutor.boundedArguments(command, arguments),
                    snapshot: store.snapshot, scope: .attached,
                    commandCatalog: WorkspaceScriptingAPI.availableCommands + NavigatorMCPCommands.catalog)
                expected = MCPAttachExecutor.attachCatalog(catalog)
            } else {
                expected = try WorkspaceScriptingAPI(store: store).execute(command, arguments: arguments)
            }
            let actual = try await executor.execute(command, arguments)
            XCTAssertEqual(try actual.jsonData(), try expected.jsonData(), command)
        }
    }

    func testAnalysisReadsRefuseOversizedFunctionsBeforeLift() throws {
        let snapshot = WorkspaceSnapshot(binaries: [], functions: [
            FunctionSummary(id: UUID(), name: "f", startAddress: 0x1000, endAddress: 0x1000 + 2_049 * 4, confidence: 1)
        ], instructions: (0..<2_049).map {
            InstructionRow(address: 0x1000 + UInt64($0 * 4), bytes: "1f 20 03 d5", mnemonic: "nop",
                           operands: "", hasBreakpoint: false, comment: nil)
        }, xrefs: [], hexBytes: Data())
        for command in ["stack-locals", "recover-struct-candidate"] {
            XCTAssertThrowsError(try WorkspaceScriptingAPI.snapshotListRead(command, arguments: .object([
                "function": .string("f"), "parameter": .int(0)
            ]), snapshot: snapshot)) { error in
                guard case ScriptingError.invalidArgument(let reason) = error else {
                    return XCTFail("expected analysis budget refusal, got \(error)")
                }
                XCTAssertTrue(reason.contains("budget"), reason)
            }
        }
    }

    private func assertSnapshotReadAllowsSentinelAndRevocation(_ command: String) async throws {
        let store = try makeStore()
        let address = try entryAddress(store)
        let gate = CheckpointGate()
        let executor = MCPAttachExecutor(store: store, api: {
            WorkspaceScriptingAPI(store: $0, snapshotReadCheckpoint: { gate.park() })
        })
        executor.setConsent(.allowed)
        let arguments = try snapshotReadArguments(command, store: store, address: address)
        let read = Task { try await executor.execute(command, arguments) }
        defer { gate.release() }
        do { try await gate.waitUntilParked() } catch {
            read.cancel()
            _ = try? await read.value
            return XCTFail("\(command) never reached an owned worker checkpoint")
        }
        // Reaching this continuation and editing while the worker is parked is the MainActor sentinel.
        store.setCustomComment(UInt64(address.dropFirst(2), radix: 16)!, in: store.snapshot.primarySlot, comment: "sentinel")
        executor.setConsent(.revoked)
        gate.release()
        do { _ = try await read.value; XCTFail("revoked snapshot read returned a result") } catch {}
        XCTAssertTrue(gate.sawCancellationAfterRelease)
    }

    func testUnresolvedWindowRefusalsAreGeneric() throws {
        let coordinator = MCPAttachCoordinator(directory: makeDirectory(),
                                               defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        guard case .refused(let none) = coordinator.resolveWindow(named: nil) else { return XCTFail() }
        let store = try makeStore()
        coordinator.register(store)
        guard case .refused(let missing) = coordinator.resolveWindow(named: "no-such-window") else { return XCTFail() }
        XCTAssertEqual(none, missing, "no window and an unknown name read the same")
    }

    func testDuplicateWindowNamesAreRefused() throws {
        let coordinator = MCPAttachCoordinator(directory: makeDirectory(),
                                               defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        let a = try makeStore(), b = try makeStore()
        b.workspaceName = a.workspaceName
        coordinator.register(a)
        coordinator.register(b)
        guard case .refused = coordinator.resolveWindow(named: a.workspaceName) else { return XCTFail("ambiguous name accepted") }
        guard case .window = coordinator.resolveWindow(named: nil) else { return XCTFail("no default window") }
    }

    func testSocketAttachConsentEditFenceAndDisconnect() async throws {
        let directory = makeDirectory()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MCPAttachTests-\(UUID().uuidString)"))
        defaults.set(true, forKey: MCPAttachCoordinator.enabledDefaultsKey)
        let gate = CheckpointGate(expectsCancellationAfterRelease: true)
        let coordinator = MCPAttachCoordinator(directory: directory, defaults: defaults) { store in
            // Native dispatch checkpoints run in the request-owned task. The fallback renderer
            // uses a plain thread and its separate cancellation token, not Task.isCancelled.
            MCPAttachExecutor(store: store, api: { WorkspaceScriptingAPI(
                store: $0, snapshotReadCheckpoint: { gate.park() },
                nativeDecompiler: CancelledAttachNativeDecompiler()) })
        }
        coordinator.syncWithSetting()
        XCTAssertTrue(coordinator.isListening)
        defer { coordinator.stopListening() }
        let store = try makeStore()
        let address = try entryAddress(store)
        coordinator.register(store)
        let socketURL = MCPAttachSocket.socketURL(in: directory)

        // An endpoint that can't prove the token is rejected by the relay before anything is sent,
        // and the app binds nothing for a client that can't prove it either.
        let impostor = try MCPAttachSocket.connect(to: socketURL)
        defer { close(impostor) }
        let wrongToken = Data(repeating: 1, count: 32)
        let impostorResult = await Task.detached { try? MCPAttachHandshake.runClient(impostor, token: wrongToken, window: nil) }.value
        XCTAssertNil(impostorResult)
        XCTAssertTrue(coordinator.connections.isEmpty)

        let token = try MCPAttachSocket.readToken(in: directory)
        let client = try MCPAttachSocket.connect(to: socketURL)
        defer { close(client) }
        let name = store.workspaceName
        let workspace = try await Task.detached { try MCPAttachHandshake.runClient(client, token: token, window: name) }.value
        XCTAssertNil(workspace, "no workspace label before Allow (N5)")
        for _ in 0..<200 where coordinator.connections(for: store).isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        let connection = try XCTUnwrap(coordinator.connections(for: store).first)
        XCTAssertEqual(connection.consent, .pending)

        func call(_ id: Int, _ name: String, _ arguments: String) -> Data {
            Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#.utf8)
        }
        let renameArguments = #"{"address":"\#(address)","name":"socket_named"}"#
        let pending = String(decoding: try await Self.exchange(client, call(1, "rename", renameArguments)), as: UTF8.self)
        XCTAssertTrue(pending.contains("Waiting for permission"), pending)
        XCTAssertFalse(pending.contains(name), "no workspace details before consent")

        coordinator.allow(connection.id)
        let renamed = String(decoding: try await Self.exchange(client, call(2, "rename", renameArguments)), as: UTF8.self)
        XCTAssertTrue(renamed.contains("\"isError\":false"), renamed)
        XCTAssertEqual(store.undoManager.undoActionName, "Agent: rename")
        XCTAssertTrue(store.isDirty, "an agent edit dirties the document like a user edit")

        // A decompile parks in its detached checkpoint; Disconnect revokes and cancels it.
        XCTAssertTrue(MCPAttachSocket.writeLine(call(3, "decompile", #"{"address":"\#(address)"}"#), to: client))
        try await gate.waitUntilParked()
        coordinator.disconnect(connection.id)
        coordinator.allow(connection.id) // a late Allow cannot revive it
        XCTAssertNotEqual(coordinator.connections(for: store).first?.consent, .allowed)
        let closed = await Task.detached { MCPAttachSocket.readLine(client, limit: 1 << 20) }.value
        XCTAssertNil(closed, "the app closed the connection")
        gate.release()
        for _ in 0..<200 where !coordinator.connections(for: store).isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(coordinator.connections(for: store).isEmpty)
        try await gate.waitUntilResumed()
        XCTAssertTrue(gate.sawCancellationAfterRelease, "the in-flight decompile was cancelled")
    }

    /// Writes one line and reads one reply line off the MainActor (the app side runs on it).
    private static func exchange(_ descriptor: Int32, _ line: Data) async throws -> Data {
        XCTAssertTrue(MCPAttachSocket.writeLine(line, to: descriptor))
        let reply = await Task.detached { MCPAttachSocket.readLine(descriptor, limit: 1 << 20) }.value
        return try XCTUnwrap(reply)
    }
}

/// Cancellation at the admission checkpoint must prevent the native request from starting.
private struct CancelledAttachNativeDecompiler: ScriptingNativeDecompiling {
    func decompile(_ request: ScriptingNativeDecompileRequest) async -> ScriptingNativeDecompileOutcome {
        XCTFail("a cancelled attached request reached the native decompiler")
        return .unavailable
    }
}

/// Parks the first snapshot-read checkpoint until released; records whether the task was
/// cancelled when it resumed.
private final class CheckpointGate: @unchecked Sendable {
    private let lock = NSLock()
    private let parked = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private let resumed = DispatchSemaphore(value: 0)
    private let expectsCancellationAfterRelease: Bool
    private var hasParked = false
    private(set) var sawCancellationAfterRelease = false

    init(expectsCancellationAfterRelease: Bool = false) {
        self.expectsCancellationAfterRelease = expectsCancellationAfterRelease
    }

    func park() {
        lock.lock()
        let first = !hasParked
        hasParked = true
        lock.unlock()
        guard first else { return }
        defer { resumed.signal() }
        parked.signal()
        XCTAssertEqual(resume.wait(timeout: .now() + 5), .success, "snapshot checkpoint was not released")
        // Socket EOF precedes the request session's asynchronous cancellation. Keep this
        // detached checkpoint alive until cancellation arrives; retirement drains the worker.
        if expectsCancellationAfterRelease {
            for _ in 0..<200 where !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
        }
        if Task.isCancelled {
            lock.lock(); sawCancellationAfterRelease = true; lock.unlock()
        }
    }

    private enum Failure: Error { case checkpointNotReached, checkpointNotResumed }

    func waitUntilParked() async throws {
        let reached = await Task.detached { [self] in self.blockUntilParked() }.value
        guard reached else { throw Failure.checkpointNotReached }
    }

    private func blockUntilParked() -> Bool { parked.wait(timeout: .now() + 5) == .success }

    func waitUntilResumed() async throws {
        let finished = await Task.detached { [self] in self.blockUntilResumed() }.value
        guard finished else { throw Failure.checkpointNotResumed }
    }

    private func blockUntilResumed() -> Bool { resumed.wait(timeout: .now() + 5) == .success }

    func release() { resume.signal() }
}
