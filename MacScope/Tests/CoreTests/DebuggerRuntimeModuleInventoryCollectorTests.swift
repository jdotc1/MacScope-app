import CryptoKit
import XCTest
@testable import MacScope

final class DebuggerRuntimeModuleInventoryCollectorTests: XCTestCase {
    func testStaticExtractorHasFrozenDigestBoundedChunksAndBoundedCompleteWires() throws {
        let program = LLDBRuntimeModuleExtractorProgram.current

        XCTAssertGreaterThan(program.sourceByteCount, 0)
        XCTAssertEqual(program.sourceByteCount, LLDBRuntimeModuleExtractorProgram.expectedSourceByteCount)
        XCTAssertEqual(program.sourceSHA256Hex, LLDBRuntimeModuleExtractorProgram.expectedSourceSHA256Hex)
        XCTAssertLessThanOrEqual(program.sourceByteCount, 16 * 1_024)
        XCTAssertEqual(program.sourceSHA256.count, 32)
        XCTAssertEqual(Data(SHA256.hash(data: Data(program.source.utf8))), program.sourceSHA256)
        XCTAssertLessThanOrEqual(program.installChunkCommands.count, 43)
        XCTAssertTrue(program.installChunks.allSatisfy { !$0.isEmpty && $0.utf8.count <= 512 })
        XCTAssertEqual(program.installChunks.joined(), Data(program.source.utf8).base64EncodedString())
        XCTAssertEqual(Data(base64Encoded: program.installChunks.joined()), Data(program.source.utf8),
            "Wire budgeting must preserve every frozen extractor byte")

        let commands = program.installChunkCommands
            + [program.installFinalizeCommand, program.installedProofCommand]
            + [try program.pageCommand(token: token, cursor: 0)]
            + [try program.cleanupCommand(token: token)]
        let markers = try LLDBCLIExchangeMarkers(token: String(repeating: "f", count: 64))
        for command in commands {
            let completeWireByteCount = PersistentLLDBCLIAdapter.encodedWirePayload(
                semanticCommands: [command],
                markers: markers
            ).count
            XCTAssertLessThanOrEqual(
                try program.completeEncodedWireByteCount(for: command),
                4 * 1_024,
                "semantic=\(command.utf8.count), complete=\(completeWireByteCount)"
            )
            XCTAssertFalse(command.contains("/Users/"))
            XCTAssertFalse(command.contains("target modules"))
        }
    }

    func testInvocationGrammarAcceptsOnlyCanonicalTokenAndCursor() throws {
        let program = LLDBRuntimeModuleExtractorProgram.current
        XCTAssertThrowsError(try program.pageCommand(token: Data(repeating: 0, count: 31), cursor: 0))
        XCTAssertThrowsError(try program.pageCommand(tokenHex: String(repeating: "A", count: 64), cursor: 0))
        XCTAssertThrowsError(try program.pageCommand(tokenHex: String(repeating: "0", count: 63), cursor: 0))
        XCTAssertThrowsError(try program.pageCommand(token: token, cursor: 4_097))

        let page = try program.pageCommand(token: token, cursor: 4_096)
        let cleanup = try program.cleanupCommand(token: token)
        XCTAssertFalse(page.contains("/tmp"))
        XCTAssertFalse(cleanup.contains("/tmp"))
    }

    func testWireBudgetedInstallPreservesFrozenDigestAndEntrypointProof() throws {
        let program = LLDBRuntimeModuleExtractorProgram.current
        let commands = program.installChunkCommands
            + [program.installFinalizeCommand, program.installedProofCommand]
        let script = "import sys,types;sys.modules['lldb']=types.ModuleType('lldb')\n"
            + commands.map { String($0.dropFirst("script ".count)) }.joined(separator: "\n")
        let receipt = "MACSCOPE_LLDB_MODULE_INSTALL_V1 {\"ok\":true,\"schema\":1,\"sha256\":\""
            + program.sourceSHA256Hex + "\"}\n"
        XCTAssertEqual(try runPython(script), receipt + receipt)
        for command in commands {
            XCTAssertLessThanOrEqual(try program.completeEncodedWireByteCount(for: command), 4 * 1_024)
        }
    }

    func testCollectorRejectsNoncontiguousReservationBeforeExecution() async throws {
        let parent = context(sequence: 10)
        var internals = internalContexts(parent: parent)
        internals[3] = context(sequence: 99)
        let executor = ScriptedCollectorExecutor(responses: [])
        let collector = DebuggerRuntimeModuleInventoryCollector(clock: FixedCollectorClock(now: 1))

        await XCTAssertThrowsErrorAsync {
            _ = try await collector.collect(
                plan: .init(
                    parentContext: parent,
                    internalContexts: internals,
                    adapterGeneration: 1,
                    expectedProcessID: processID,
                    token: token
                ),
                executor: executor
            )
        } verify: { error in
            XCTAssertEqual((error as? DebuggerRuntimeModuleInventoryCollectorFailure)?.code, .invalidReservation)
        }
        let requestCount = await executor.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testCollectorRejectsWrongParentOperationBeforeExecution() async throws {
        let parent = context(sequence: 10, operation: .refreshSnapshot)
        let executor = ScriptedCollectorExecutor(responses: [])
        let collector = DebuggerRuntimeModuleInventoryCollector(clock: FixedCollectorClock(now: 1))

        await XCTAssertThrowsErrorAsync {
            _ = try await collector.collect(
                plan: .init(
                    parentContext: parent,
                    internalContexts: internalContexts(parent: parent),
                    adapterGeneration: 1,
                    expectedProcessID: processID,
                    token: token
                ),
                executor: executor
            )
        } verify: { error in
            XCTAssertEqual((error as? DebuggerRuntimeModuleInventoryCollectorFailure)?.code, .invalidReservation)
        }
        let requestCount = await executor.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testFirstGenerationInstallsCollectsOneAtomicPageAndCleansUp() async throws {
        let program = LLDBRuntimeModuleExtractorProgram.current
        let parent = context(sequence: 20)
        let responses = installResponses(program: program, parent: parent, generation: 7)
            + [response(sequence: parent.id.sequence + UInt64(program.installChunkCommands.count) + 2,
                        generation: 7, semantic: emptyPage)]
            + [response(sequence: parent.id.sequence + 112, generation: 7, semantic: cleanupReceipt)]
        let executor = ScriptedCollectorExecutor(responses: responses)
        let collector = DebuggerRuntimeModuleInventoryCollector(clock: FixedCollectorClock(now: 100))

        let collection = try await collector.collect(
            plan: .init(
                parentContext: parent,
                internalContexts: internalContexts(parent: parent),
                adapterGeneration: 7,
                expectedProcessID: processID,
                token: token
            ),
            executor: executor
        )

        XCTAssertEqual(collection.observedProcessID, processID)
        XCTAssertEqual(collection.observedStopID, 9)
        XCTAssertEqual(collection.modules.count, 0)
        XCTAssertEqual(collection.canonicalSnapshotByteCount, 2)
        let requests = await executor.requests
        XCTAssertEqual(requests.count, program.installChunkCommands.count + 3)
        XCTAssertEqual(requests.last?.context.id.sequence, parent.id.sequence + 112)
        XCTAssertEqual(Set(requests.map(\.context.id.sequence)).count, requests.count)
    }

    func testInstalledGenerationUsesProofInsteadOfReinstalling() async throws {
        let program = LLDBRuntimeModuleExtractorProgram.current
        let collector = DebuggerRuntimeModuleInventoryCollector(clock: FixedCollectorClock(now: 100))
        let firstParent = context(sequence: 100)
        let firstResponses = installResponses(program: program, parent: firstParent, generation: 4)
            + [response(sequence: firstParent.id.sequence + UInt64(program.installChunkCommands.count) + 2,
                        generation: 4, semantic: emptyPage)]
            + [response(sequence: firstParent.id.sequence + 112, generation: 4, semantic: cleanupReceipt)]
        _ = try await collector.collect(
            plan: .init(parentContext: firstParent, internalContexts: internalContexts(parent: firstParent),
                        adapterGeneration: 4, expectedProcessID: processID, token: token),
            executor: ScriptedCollectorExecutor(responses: firstResponses)
        )

        let secondParent = context(sequence: 300)
        let executor = ScriptedCollectorExecutor(responses: [
            response(sequence: 301, generation: 4, semantic: installReceipt),
            response(sequence: 302, generation: 4, semantic: emptyPage),
            response(sequence: 412, generation: 4, semantic: cleanupReceipt),
        ])
        _ = try await collector.collect(
            plan: .init(parentContext: secondParent, internalContexts: internalContexts(parent: secondParent),
                        adapterGeneration: 4, expectedProcessID: processID, token: token),
            executor: executor
        )

        let requests = await executor.requests
        let commands = requests.map { $0.semanticCommands[0] }
        XCTAssertEqual(commands.count, 3)
        XCTAssertEqual(commands.first, program.installedProofCommand)
    }

    func testFailedInstalledProofClearsCacheAndNextRefreshReinstalls() async throws {
        let program = LLDBRuntimeModuleExtractorProgram.current
        let collector = DebuggerRuntimeModuleInventoryCollector(clock: FixedCollectorClock(now: 100))
        let firstParent = context(sequence: 100)
        let firstResponses = installResponses(program: program, parent: firstParent, generation: 4)
            + [response(sequence: firstParent.id.sequence + UInt64(program.installChunkCommands.count) + 2,
                        generation: 4, semantic: emptyPage)]
            + [response(sequence: firstParent.id.sequence + 112, generation: 4, semantic: cleanupReceipt)]
        _ = try await collector.collect(
            plan: .init(parentContext: firstParent, internalContexts: internalContexts(parent: firstParent),
                        adapterGeneration: 4, expectedProcessID: processID, token: token),
            executor: ScriptedCollectorExecutor(responses: firstResponses)
        )

        let failedProofParent = context(sequence: 300)
        await XCTAssertThrowsErrorAsync {
            _ = try await collector.collect(
                plan: .init(
                    parentContext: failedProofParent,
                    internalContexts: internalContexts(parent: failedProofParent),
                    adapterGeneration: 4,
                    expectedProcessID: processID,
                    token: token
                ),
                executor: ScriptedCollectorExecutor(responses: [
                    response(sequence: 301, generation: 4, semantic: "unexpected\n"),
                    response(sequence: 412, generation: 4, semantic: cleanupReceipt),
                ])
            )
        } verify: { error in
            XCTAssertEqual(
                (error as? DebuggerRuntimeModuleInventoryCollectorFailure)?.code,
                .installNotProven
            )
        }
        let generationAfterFailedProof = await collector.installedAdapterGeneration
        XCTAssertNil(generationAfterFailedProof)

        let retryParent = context(sequence: 500)
        let retryExecutor = ScriptedCollectorExecutor(
            responses: installResponses(program: program, parent: retryParent, generation: 4)
                + [response(sequence: retryParent.id.sequence + UInt64(program.installChunkCommands.count) + 2,
                            generation: 4, semantic: emptyPage)]
                + [response(sequence: retryParent.id.sequence + 112, generation: 4, semantic: cleanupReceipt)]
        )
        _ = try await collector.collect(
            plan: .init(parentContext: retryParent, internalContexts: internalContexts(parent: retryParent),
                        adapterGeneration: 4, expectedProcessID: processID, token: token),
            executor: retryExecutor
        )
        let retryRequests = await retryExecutor.requests
        let retryCommands = retryRequests.map { $0.semanticCommands[0] }
        XCTAssertEqual(retryCommands.first, program.installChunkCommands.first)
        XCTAssertNotEqual(retryCommands.first, program.installedProofCommand)
    }

    func testSemanticPageFailureStillRunsReservedCleanupAndPublishesNothing() async throws {
        let program = LLDBRuntimeModuleExtractorProgram.current
        let parent = context(sequence: 500)
        let malformedPage = "MACSCOPE_LLDB_MODULE_PAGE_V1 {\"ok\":true}\n"
        let responses = installResponses(program: program, parent: parent, generation: 9)
            + [response(sequence: parent.id.sequence + UInt64(program.installChunkCommands.count) + 2,
                        generation: 9, semantic: malformedPage)]
            + [response(sequence: parent.id.sequence + 112, generation: 9, semantic: cleanupReceipt)]
        let executor = ScriptedCollectorExecutor(responses: responses)
        let collector = DebuggerRuntimeModuleInventoryCollector(clock: FixedCollectorClock(now: 100))

        await XCTAssertThrowsErrorAsync {
            _ = try await collector.collect(
                plan: .init(parentContext: parent, internalContexts: internalContexts(parent: parent),
                            adapterGeneration: 9, expectedProcessID: processID, token: token),
                executor: executor
            )
        } verify: { error in
            XCTAssertEqual((error as? LLDBRuntimeModuleInventoryFailure)?.code, .invalidSchema)
        }
        let requests = await executor.requests
        XCTAssertEqual(requests.last?.context.id.sequence, parent.id.sequence + 112)
    }

    func testCleanupMismatchIsGenerationFatalAndClearsInstalledFact() async throws {
        let program = LLDBRuntimeModuleExtractorProgram.current
        let parent = context(sequence: 700)
        let responses = installResponses(program: program, parent: parent, generation: 3)
            + [response(sequence: parent.id.sequence + UInt64(program.installChunkCommands.count) + 2,
                        generation: 3, semantic: emptyPage)]
            + [response(sequence: parent.id.sequence + 112, generation: 3,
                        semantic: cleanupReceipt.replacingOccurrences(of: "true", with: "false"))]
        let collector = DebuggerRuntimeModuleInventoryCollector(clock: FixedCollectorClock(now: 100))

        await XCTAssertThrowsErrorAsync {
            _ = try await collector.collect(
                plan: .init(parentContext: parent, internalContexts: internalContexts(parent: parent),
                            adapterGeneration: 3, expectedProcessID: processID, token: token),
                executor: ScriptedCollectorExecutor(responses: responses)
            )
        } verify: { error in
            let failure = error as? DebuggerRuntimeModuleInventoryCollectorFailure
            XCTAssertEqual(failure?.code, .cleanupNotProven)
            XCTAssertEqual(failure?.requiresAdapterInvalidation, true)
        }
        let installedGeneration = await collector.installedAdapterGeneration
        XCTAssertNil(installedGeneration)
    }

    func testPreFinalizeSemanticFailureUsesStaticReservedCleanup() async throws {
        let program = LLDBRuntimeModuleExtractorProgram.current
        let parent = context(sequence: 900)
        let responses = [
            response(sequence: 901, generation: 12, semantic: "unexpected\n"),
            response(sequence: 1_012, generation: 12, semantic: cleanupReceipt),
        ]
        let executor = ScriptedCollectorExecutor(responses: responses)
        let collector = DebuggerRuntimeModuleInventoryCollector(clock: FixedCollectorClock(now: 100))

        await XCTAssertThrowsErrorAsync {
            _ = try await collector.collect(
                plan: .init(parentContext: parent, internalContexts: internalContexts(parent: parent),
                            adapterGeneration: 12, expectedProcessID: processID, token: token),
                executor: executor
            )
        } verify: { error in
            XCTAssertEqual((error as? DebuggerRuntimeModuleInventoryCollectorFailure)?.code, .installNotProven)
        }
        let requests = await executor.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.last?.semanticCommands, [try! program.cleanupCommand(token: token)])
        XCTAssertEqual(requests.last?.context.id.sequence, 1_012)
    }

    func testCancellationAfterFinalizeBeforePageZeroRunsDetachedStaticCleanup() async throws {
        let program = LLDBRuntimeModuleExtractorProgram.current
        let parent = context(sequence: 1_100)
        let responses = installResponses(program: program, parent: parent, generation: 13)
            + [response(sequence: 1_212, generation: 13, semantic: cleanupReceipt)]
        let executor = CancellationAfterResponsesCollectorExecutor(
            responses: responses,
            cancelAfterResponseCount: program.installChunkCommands.count + 1
        )
        let collector = DebuggerRuntimeModuleInventoryCollector(clock: FixedCollectorClock(now: 100))
        let plan = DebuggerRuntimeModuleInventoryCollectionPlan(
            parentContext: parent,
            internalContexts: internalContexts(parent: parent),
            adapterGeneration: 13,
            expectedProcessID: processID,
            token: token
        )
        let task = Task {
            try await collector.collect(plan: plan, executor: executor)
        }
        await executor.setTaskToCancel(task)

        await XCTAssertThrowsErrorAsync {
            _ = try await task.value
        } verify: { error in
            XCTAssertEqual(
                (error as? DebuggerRuntimeModuleInventoryCollectorFailure)?.code,
                .cancelledBetweenExchanges
            )
        }
        let requests = await executor.requests
        XCTAssertEqual(requests.count, program.installChunkCommands.count + 2)
        XCTAssertEqual(requests.last?.context.id.sequence, 1_212)
    }

    func testCancellationAfterLastChunkBeforeFinalizeSkipsFinalizeAndRunsCleanup() async throws {
        let program = LLDBRuntimeModuleExtractorProgram.current
        let parent = context(sequence: 1_300)
        var responses = program.installChunkCommands.indices.map { index in
            response(sequence: 1_301 + UInt64(index), generation: 14, semantic: "")
        }
        responses.append(response(sequence: 1_412, generation: 14, semantic: cleanupReceipt))
        let executor = CancellationAfterResponsesCollectorExecutor(
            responses: responses,
            cancelAfterResponseCount: program.installChunkCommands.count
        )
        let collector = DebuggerRuntimeModuleInventoryCollector(clock: FixedCollectorClock(now: 100))
        let plan = DebuggerRuntimeModuleInventoryCollectionPlan(
            parentContext: parent,
            internalContexts: internalContexts(parent: parent),
            adapterGeneration: 14,
            expectedProcessID: processID,
            token: token
        )
        let task = Task {
            try await collector.collect(plan: plan, executor: executor)
        }
        await executor.setTaskToCancel(task)

        await XCTAssertThrowsErrorAsync {
            _ = try await task.value
        } verify: { error in
            XCTAssertEqual(
                (error as? DebuggerRuntimeModuleInventoryCollectorFailure)?.code,
                .cancelledBetweenExchanges
            )
        }
        let requests = await executor.requests
        XCTAssertEqual(requests.count, program.installChunkCommands.count + 1)
        XCTAssertFalse(requests.contains { $0.semanticCommands == [program.installFinalizeCommand] })
        XCTAssertEqual(requests.last?.context.id.sequence, 1_412)
    }

    func testFrozenIncrementalCapacityAccountingAcceptsBoundaryAndRejectsOneByteOver() {
        XCTAssertTrue(LLDBRuntimeModuleExtractorProgram.incrementalCapacityFits(
            canonicalSnapshotByteCount: 8 * 1_024 * 1_024,
            logicalDecodedRecordByteCount: 8 * 1_024 * 1_024
        ))
        XCTAssertFalse(LLDBRuntimeModuleExtractorProgram.incrementalCapacityFits(
            canonicalSnapshotByteCount: 8 * 1_024 * 1_024 + 1,
            logicalDecodedRecordByteCount: 8 * 1_024 * 1_024
        ))
        XCTAssertFalse(LLDBRuntimeModuleExtractorProgram.incrementalCapacityFits(
            canonicalSnapshotByteCount: 8 * 1_024 * 1_024,
            logicalDecodedRecordByteCount: 8 * 1_024 * 1_024 + 1
        ))
        let source = LLDBRuntimeModuleExtractorProgram.current.source
        XCTAssertTrue(source.contains("prospective_snapshot_bytes"))
        XCTAssertTrue(source.contains("prospective_logical_bytes"))
        XCTAssertFalse(source.contains("records = [_record_module"))
    }

    func testStaticCleanupClearsPartialInstallAndMatchingSnapshotWithoutInstalledEntrypoint() throws {
        let program = LLDBRuntimeModuleExtractorProgram.current
        let cleanup = try decodedPythonScript(from: program.cleanupCommand(token: token))
        let partialOnly = """
        import builtins
        builtins.__dict__['__macscope_lldb_module_install_v1']={'parts':['partial']}
        \(cleanup)
        assert '__macscope_lldb_module_install_v1' not in builtins.__dict__
        """
        XCTAssertEqual(try runPython(partialOnly), cleanupReceipt)

        let matchingSnapshot = """
        import builtins
        builtins.__dict__['__macscope_lldb_module_install_v1']={'parts':['partial']}
        builtins.__dict__['__macscope_lldb_module_extractor_v1']={'_SNAPSHOT':{'token':'\(tokenHex)'}}
        \(cleanup)
        assert '__macscope_lldb_module_install_v1' not in builtins.__dict__
        assert builtins.__dict__['__macscope_lldb_module_extractor_v1']['_SNAPSHOT'] is None
        """
        XCTAssertEqual(try runPython(matchingSnapshot), cleanupReceipt)
    }

    func testPage64ExhaustionUsesExactCapacityRecordOracle() throws {
        let source64 = Data(LLDBRuntimeModuleExtractorProgram.current.source.utf8).base64EncodedString()
        let oracle = """
        import base64,sys,types
        lldb=types.ModuleType('lldb');lldb.eStateStopped=5
        class Process:
            def GetProcessID(self): return \(processID)
            def GetState(self): return 5
            def GetStopID(self): return 9
        class Target:
            def GetProcess(self): return Process()
        class Debugger:
            def GetSelectedTarget(self): return Target()
        lldb.debugger=Debugger();lldb.LLDB_INVALID_ADDRESS=(1<<64)-1;sys.modules['lldb']=lldb
        exec(compile(base64.b64decode('\(source64)').decode('utf-8'),'<extractor>','exec'),globals(),globals())
        _SNAPSHOT={'token':'\(tokenHex)','digest':'0'*64,'pid':\(processID),'stop_id':9,'count':2,'next':1,'pages':64,'records':[]}
        page('\(tokenHex)',1)
        """
        XCTAssertEqual(
            try runPython(oracle),
            "MACSCOPE_LLDB_MODULE_PAGE_V1 {\"code\":\"capacity\",\"ok\":false,\"schema\":1,\"token\":\"\(tokenHex)\"}\n"
        )
    }

    func testSnapshotEnumerationStopsAtModule4097WithoutOverconsumingLazyIterable() throws {
        let source64 = Data(LLDBRuntimeModuleExtractorProgram.current.source.utf8).base64EncodedString()
        let oracle = """
        import base64,sys,types
        lldb=types.ModuleType('lldb');lldb.eStateStopped=5
        class Process:
            def GetProcessID(self): return \(processID)
            def GetState(self): return 5
            def GetStopID(self): return 9
        class BoundedModules:
            def __init__(self): self.count=0
            def __iter__(self): return self
            def __next__(self):
                self.count+=1
                if self.count>4097: raise RuntimeError('module iterable overconsumed')
                return object()
        modules=BoundedModules()
        class Target:
            def GetProcess(self): return Process()
        target=Target();target.modules=modules
        class Debugger:
            def GetSelectedTarget(self): return target
        lldb.debugger=Debugger();lldb.LLDB_INVALID_ADDRESS=(1<<64)-1;sys.modules['lldb']=lldb
        exec(compile(base64.b64decode('\(source64)').decode('utf-8'),'<extractor>','exec'),globals(),globals())
        _record_module=lambda module,target,index: ([index,None,'','arm64',[]],70)
        _build_snapshot('\(tokenHex)')
        print(modules.count,_SNAPSHOT.get('capacity'))
        """
        XCTAssertEqual(try runPython(oracle), "4097 True\n")
    }

    private let processID: Int32 = 321
    private let token = Data(repeating: 0xab, count: 32)

    private var tokenHex: String { token.map { String(format: "%02x", $0) }.joined() }
    private var installReceipt: String {
        "MACSCOPE_LLDB_MODULE_INSTALL_V1 {\"ok\":true,\"schema\":1,\"sha256\":\"\(LLDBRuntimeModuleExtractorProgram.current.sourceSHA256Hex)\"}\n"
    }
    private var cleanupReceipt: String {
        "MACSCOPE_LLDB_MODULE_CLEANUP_V1 {\"ok\":true,\"schema\":1,\"token\":\"\(tokenHex)\"}\n"
    }
    private var emptyPage: String {
        let digest = Data(SHA256.hash(data: Data("[]".utf8))).map { String(format: "%02x", $0) }.joined()
        return "MACSCOPE_LLDB_MODULE_PAGE_V1 {\"digest\":\"\(digest)\",\"end\":0,\"final\":true,\"module_count\":0,\"modules\":[],\"observed_pid\":\(processID),\"observed_state\":\"stopped\",\"observed_stop_id\":9,\"ok\":true,\"schema\":1,\"start\":0,\"token\":\"\(tokenHex)\"}\n"
    }

    private func context(
        sequence: UInt64,
        operation: DebuggerOperation = .refreshRuntimeModules
    ) -> DebuggerRequestContext {
        let epoch = DebuggerSessionEpoch(rawValue: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!)
        let session = DebuggerSessionCoordinate(epoch: epoch, lifecycleRevision: .init(rawValue: 4))
        return DebuggerRequestContext(
            id: DebuggerRequestID(epoch: epoch, sequence: sequence),
            operation: operation,
            expectedSession: session,
            requiredStop: DebuggerStopCoordinate(session: session, stopRevision: .init(rawValue: 2))
        )
    }

    private func internalContexts(parent: DebuggerRequestContext) -> [DebuggerRequestContext] {
        (1...112).map { offset in
            DebuggerRequestContext(
                id: DebuggerRequestID(epoch: parent.id.epoch, sequence: parent.id.sequence + UInt64(offset)),
                operation: parent.operation,
                expectedSession: parent.expectedSession,
                requiredStop: parent.requiredStop
            )
        }
    }

    private func installResponses(
        program: LLDBRuntimeModuleExtractorProgram,
        parent: DebuggerRequestContext,
        generation: UInt64
    ) -> [PersistentLLDBCLIResponse] {
        var responses: [PersistentLLDBCLIResponse] = []
        for index in program.installChunkCommands.indices {
            responses.append(response(sequence: parent.id.sequence + UInt64(index) + 1,
                                      generation: generation, semantic: ""))
        }
        responses.append(response(sequence: parent.id.sequence + UInt64(program.installChunkCommands.count) + 1,
                                  generation: generation, semantic: installReceipt))
        return responses
    }

    private func response(sequence: UInt64, generation: UInt64, semantic: String) -> PersistentLLDBCLIResponse {
        let request = context(sequence: sequence)
        return PersistentLLDBCLIResponse(
            requestID: request.id,
            generation: generation,
            transcript: LLDBCLITranscriptResult(
                transcript: semantic,
                authoritativeStatusTranscript: "Process \(processID) stopped",
                observedProcessID: processID,
                observedProcessState: .stopped(processID: processID),
                exchangeByteCount: semantic.utf8.count + 256,
                exchangeSHA256: String(repeating: "0", count: 64),
                semanticCommandsSucceeded: true,
                firstFailedSemanticCommandIndex: nil,
                semanticCommandTranscripts: [semantic],
                semanticCommandResultLineByteCounts: [
                    wrappedResultLineByteCount(forPayloadByteCount: semantic.utf8.count),
                ]
            )
        )
    }

    private func wrappedResultLineByteCount(forPayloadByteCount count: Int) -> Int {
        let base64Count = ((count + 2) / 3) * 4
        return 31 + LLDBCLIExchangeMarkers.tokenCharacterCount + "_0_".utf8.count
            + base64Count + "__\n".utf8.count
    }

    private func decodedPythonScript(from command: String) throws -> String {
        let prefix = "script exec("
        guard command.hasPrefix(prefix), command.hasSuffix(")") else {
            throw DebuggerRuntimeModuleInventoryCollectorFailure(code: .invalidProgram)
        }
        let start = command.index(command.startIndex, offsetBy: prefix.count)
        let end = command.index(before: command.endIndex)
        return try JSONDecoder().decode(String.self, from: Data(command[start..<end].utf8))
    }

    private func runPython(_ script: String) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let stdoutDrain = CoreTestPipeDrain(output)
        let stderrDrain = CoreTestPipeDrain(error)
        process.waitUntilExit()
        let stdout = stdoutDrain.data()
        let stderr = stderrDrain.data()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "DebuggerRuntimeModuleInventoryCollectorTests.Python",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: stderr, as: UTF8.self)]
            )
        }
        return String(decoding: stdout, as: UTF8.self)
    }
}

private struct FixedCollectorClock: DebuggerRuntimeModuleInventoryCollectorClock {
    let now: UInt64
    func uptimeNanoseconds() async -> UInt64 { now }
}

private actor ScriptedCollectorExecutor: PersistentLLDBCLIExecuting {
    private var responses: [PersistentLLDBCLIResponse]
    private(set) var requests: [PersistentLLDBCLIRequest] = []

    init(responses: [PersistentLLDBCLIResponse]) {
        self.responses = responses
    }

    var requestCount: Int { requests.count }

    func execute(_ request: PersistentLLDBCLIRequest) async throws -> PersistentLLDBCLIResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw DebuggerRuntimeModuleInventoryCollectorFailure(code: .exchangeFailed)
        }
        return responses.removeFirst()
    }
}

private actor CancellationAfterResponsesCollectorExecutor: PersistentLLDBCLIExecuting {
    private var responses: [PersistentLLDBCLIResponse]
    private let cancelAfterResponseCount: Int
    private var taskToCancel: Task<DebuggerRuntimeModuleDecodedCollection, Error>?
    private(set) var requests: [PersistentLLDBCLIRequest] = []

    init(responses: [PersistentLLDBCLIResponse], cancelAfterResponseCount: Int) {
        self.responses = responses
        self.cancelAfterResponseCount = cancelAfterResponseCount
    }

    func setTaskToCancel(_ task: Task<DebuggerRuntimeModuleDecodedCollection, Error>) {
        taskToCancel = task
    }

    func execute(_ request: PersistentLLDBCLIRequest) async throws -> PersistentLLDBCLIResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw DebuggerRuntimeModuleInventoryCollectorFailure(code: .exchangeFailed)
        }
        let response = responses.removeFirst()
        if requests.count == cancelAfterResponseCount {
            taskToCancel?.cancel()
        }
        return response
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw.", file: file, line: line)
    } catch {
        verify(error)
    }
}
