import Foundation
import XCTest

#if canImport(MacScope)
@testable import MacScope
#endif

@MainActor
final class DebuggerPersistentCLIAdapterTests: XCTestCase {
    private let epoch = DebuggerSessionEpoch(
        rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    )

    func testInboundNeedleProbeMatchesAcrossChunkBoundariesWithoutFalsePositives() {
        let probe = PersistentLLDBCLIInboundNeedleProbe(needle: Data("abab".utf8))

        probe.observe(Data("xxab".utf8))
        probe.observe(Data("abyyaba".utf8))
        probe.observe(Data("xabab".utf8))

        XCTAssertEqual(
            probe.snapshot,
            PersistentLLDBCLIInboundNeedleProbeSnapshot(
                observedByteCount: 16,
                matchCount: 2
            )
        )
    }

    func testInboundNeedleProbeCountersAreConcurrencySafe() async {
        let probe = PersistentLLDBCLIInboundNeedleProbe(needle: Data("needle".utf8))

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    probe.observe(Data("needle".utf8))
                }
            }
        }

        XCTAssertEqual(
            probe.snapshot,
            PersistentLLDBCLIInboundNeedleProbeSnapshot(
                observedByteCount: 600,
                matchCount: 100
            )
        )
    }

    func testAdapterNeedleProbeObservesActiveTrailingIdleAndInvalidatedBytes() async throws {
        let needle = "__MACSCOPE_NO_RAW_STDOUT_PROBE__"
        let probe = PersistentLLDBCLIInboundNeedleProbe(needle: Data(needle.utf8))
        let fixture = makeFixture(inboundNeedleProbe: probe)
        let first = Task {
            try await fixture.adapter.executeCoordinatorSelected(
                request(adapter: fixture.adapter, sequence: 1, command: "process status")
            )
        }
        let firstWire = try await fixture.channel.waitForWrite(at: 0)
        let firstMarkers = try markers(from: firstWire)
        var activeAndTrailing = framedResponse(
            markers: firstMarkers,
            console: needle,
            status: "Process 42 stopped"
        )
        activeAndTrailing.append(Data(needle.utf8))
        await fixture.channel.feed(activeAndTrailing)
        _ = try await first.value

        await fixture.channel.feed(Data(needle.utf8))
        try await assertEventually { probe.snapshot.matchCount == 3 }

        let second = Task {
            try await fixture.adapter.executeCoordinatorSelected(
                request(adapter: fixture.adapter, sequence: 2, command: "process continue")
            )
        }
        _ = try await fixture.channel.waitForWrite(at: 1)
        second.cancel()
        _ = await adapterFailure(from: second)
        await fixture.channel.feed(Data(needle.utf8))
        try await assertEventually { probe.snapshot.matchCount == 4 }

        XCTAssertEqual(
            probe.snapshot.observedByteCount,
            activeAndTrailing.count + (2 * needle.utf8.count)
        )
    }

    func testSuccessfulExchangeWritesNestedStatusEnvelopeAndReturnsDecodedAuthority() async throws {
        let fixture = makeFixture()
        let task = Task {
            try await fixture.adapter.executeCoordinatorSelected(
                request(adapter: fixture.adapter, sequence: 1, command: "process continue")
            )
        }

        let wire = try await fixture.channel.waitForWrite(at: 0)
        let markers = try markers(from: wire)
        let lines = wireLines(wire)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(try decodedMarker(from: XCTUnwrap(lines.first)), markers.requestBeginLine)
        XCTAssertTrue(lines[1].hasPrefix("script exec(__import__('base64').b64decode("))
        let program = try decodedWireProgram(from: lines[1])
        XCTAssertTrue(program.contains("r=lldb.SBCommandReturnObject()"))
        XCTAssertTrue(program.contains("i.HandleCommand('process status',lldb.SBExecutionContext(lldb.debugger.GetSelectedTarget().process),r)"))
        XCTAssertTrue(program.contains("r.GetOutput()"))
        XCTAssertTrue(program.contains("r.GetError()"))
        XCTAssertTrue(program.contains(markers.statusBeginLine))
        XCTAssertTrue(program.contains(markers.statusResultPrefix))
        XCTAssertTrue(program.contains(markers.statusEndLine))
        XCTAssertTrue(program.contains(markers.requestEndLine))

        await fixture.channel.feed(
            framedResponse(
                markers: markers,
                console: "hostile target says Process 999 exited",
                status: "Process 42 stopped"
            )
        )
        let response = try await task.value

        XCTAssertEqual(response.requestID.sequence, 1)
        XCTAssertEqual(response.generation, 1)
        XCTAssertEqual(response.transcript.transcript, "hostile target says Process 999 exited")
        XCTAssertEqual(response.transcript.authoritativeStatusTranscript, "Process 42 stopped")
        XCTAssertEqual(response.transcript.observedProcessID, 42)
        XCTAssertEqual(response.transcript.observedProcessState, .stopped(processID: 42))
    }

    func testSubmittedWireDoesNotExposeLiteralFramingMarkersToLLDBCommandEcho() async throws {
        let fixture = makeFixture()
        let task = Task {
            try await fixture.adapter.executeCoordinatorSelected(
                request(adapter: fixture.adapter, sequence: 1, command: "version")
            )
        }

        let wire = try await fixture.channel.waitForWrite(at: 0)
        let markers = try markers(from: wire)
        let submittedText = String(decoding: wire, as: UTF8.self)

        XCTAssertFalse(submittedText.contains("__MACSCOPE_LLDB_"))

        await fixture.channel.feed(
            framedResponse(markers: markers, status: "Process 42 stopped")
        )
        _ = try await task.value
    }

    func testSubmittedWireCapturesNestedPythonOutputIntoTrustedTranscript() throws {
        let markers = try LLDBCLIExchangeMarkers(
            token: String(repeating: "a", count: LLDBCLIExchangeMarkers.tokenCharacterCount)
        )
        let wire = PersistentLLDBCLIAdapter.encodedWirePayload(
            semanticCommands: ["script print('trusted receipt')"],
            markers: markers
        )
        let program = try decodedWireProgram(from: XCTUnwrap(wireLines(wire).dropFirst().first))

        XCTAssertTrue(program.contains("def z(q,i):"))
        XCTAssertTrue(program.contains("z(q,i)"))
        XCTAssertTrue(program.contains("if x.startswith('script '):"))
        XCTAssertTrue(program.contains("\n        if x.startswith('script '):"))
        XCTAssertTrue(program.contains("c.redirect_stdout(s)"))
        XCTAssertTrue(program.contains("c.redirect_stderr(s)"))
        XCTAssertTrue(program.contains("else:i.HandleCommand(x,r)"))
        XCTAssertTrue(
            program.contains(
                "t=(r.GetOutput() or '')+s.getvalue()+(r.GetError() or '')"
            )
        )
        XCTAssertFalse(program.contains("result.PutCString"))
        XCTAssertLessThan(
            try XCTUnwrap(program.range(of: "c.redirect_stdout(s)")).lowerBound,
            try XCTUnwrap(program.range(of: "t=(r.GetOutput()")).lowerBound
        )
    }

    func testVariableExtractorInstallationFitsEachPhysicalExchangeIncludingMaximumSource() throws {
        let markers = try LLDBCLIExchangeMarkers(
            token: String(repeating: "a", count: LLDBCLIExchangeMarkers.tokenCharacterCount)
        )
        let maximum = try LLDBVariableExtractorProgram(
            source: String(repeating: "#", count: LLDBVariableExtractorProgram.maximumSourceBytes)
        )
        for program in [LLDBVariableExtractorProgram.current, maximum] {
            let commands = PersistentLLDBProductionController.variableExtractorInstallationCommands(
                program: program
            )
            XCTAssertEqual(commands.count, program.installChunkCommands.count + 2)
            XCTAssertEqual(Array(commands.suffix(2)), [program.installFinalizeCommand, program.installedProofCommand])
            for command in commands {
                let wire = PersistentLLDBCLIAdapter.encodedWirePayload(
                    semanticCommands: [command], markers: markers
                )
                XCTAssertLessThanOrEqual(wire.count, LLDBCLITranscriptDecoder.maximumCommandBytes)
            }
            XCTAssertGreaterThan(
                PersistentLLDBCLIAdapter.encodedWirePayload(
                    semanticCommands: commands, markers: markers
                ).count,
                LLDBCLITranscriptDecoder.maximumCommandBytes
            )
        }
    }

    func testWireEscapesSurrogateBytesInCommandAndStatusOutput() throws {
        let markers = try LLDBCLIExchangeMarkers(
            token: String(repeating: "a", count: LLDBCLIExchangeMarkers.tokenCharacterCount)
        )
        let wire = PersistentLLDBCLIAdapter.encodedWirePayload(
            semanticCommands: ["frame variable"], markers: markers
        )
        let program = try decodedWireProgram(from: XCTUnwrap(wireLines(wire).dropFirst().first))
        let stub = #"""
        import sys,types
        class Result:
            def GetOutput(self):return 'caf\u00e9\udcff'
            def GetError(self):return '\udc80'
            def Succeeded(self):return True
        class Interpreter:
            def HandleCommand(self,x,*a):pass
        sys.modules['lldb']=types.SimpleNamespace(
            SBCommandReturnObject=Result,
            SBExecutionContext=lambda p:None,
            debugger=types.SimpleNamespace(
                GetCommandInterpreter=lambda:Interpreter(),
                GetSelectedTarget=lambda:types.SimpleNamespace(process=None)))
        """#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", stub + "\n" + program]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        let command = try XCTUnwrap(lines.compactMap { markers.commandResult(in: $0) }.first)
        XCTAssertEqual(command.transcript, "café\\udcff\\udc80")
        let status = try XCTUnwrap(lines.compactMap { markers.statusResult(in: $0) }.first)
        XCTAssertEqual(status, "café\\udcff\\udc80")
    }

    func testSubmittedWirePreservesAsyncModeForNativeRunControlCommands() throws {
        let markers = try LLDBCLIExchangeMarkers(
            token: String(repeating: "b", count: LLDBCLIExchangeMarkers.tokenCharacterCount)
        )
        let wire = PersistentLLDBCLIAdapter.encodedWirePayload(
            semanticCommands: [
                "breakpoint set --one-shot true --address 0x1000",
                "process continue",
            ],
            markers: markers
        )
        let program = try decodedWireProgram(from: XCTUnwrap(wireLines(wire).dropFirst().first))

        XCTAssertTrue(program.contains("'process continue':'Continue'"))
        XCTAssertTrue(program.contains("'process interrupt':'Stop'"))
        XCTAssertTrue(program.contains("'process kill':'Kill'"))
        XCTAssertTrue(program.contains("'thread step-over':'StepOver'"))
        XCTAssertTrue(program.contains("'thread step-in':'StepInto'"))
        XCTAssertTrue(program.contains("'thread step-out':'StepOut'"))
        XCTAssertTrue(program.contains("\n        if x in a or x in v:"))
        XCTAssertTrue(program.contains("d=lldb.debugger;e=lldb.SBError()"))
        XCTAssertTrue(program.contains("if not d.GetAsync():e.SetErrorString(x)"))
        XCTAssertTrue(program.contains("elif not p.IsValid():e.SetErrorString(x)"))
        XCTAssertTrue(program.contains("getattr(p,a[x])()"))
        XCTAssertTrue(program.contains("e.Fail()"))
        XCTAssertTrue(program.contains("h.StepOver(lldb.eOnlyDuringStepping,e)"))
        XCTAssertTrue(program.contains("h.StepInto(None,0,e,lldb.eOnlyDuringStepping)"))
        XCTAssertTrue(program.contains("h.StepOut(e)"))
        XCTAssertTrue(program.contains("except Exception as k:"))
        XCTAssertTrue(program.contains("r.SetStatus(lldb.eReturnStatusSuccessFinishNoResult)"))
        XCTAssertTrue(program.contains("else:i.HandleCommand(x,r)"))
        XCTAssertFalse(program.contains("SetAsync(False)"))
        XCTAssertFalse(program.contains("GetStopID"))
        XCTAssertLessThanOrEqual(wire.count, LLDBCLITranscriptDecoder.maximumCommandBytes)
    }

    func testStatusObservationUsesOnlyTheIsolatedNestedStatusCommand() async throws {
        let fixture = makeFixture()
        let context = DebuggerRequestContext(
            id: DebuggerRequestID(epoch: epoch, sequence: 1),
            operation: .pollProcessStatus,
            expectedSession: DebuggerSessionCoordinate(
                epoch: epoch,
                lifecycleRevision: .initial
            )
        )
        let request = try PersistentLLDBCLIRequest(
            context: context,
            semanticCommands: [],
            observedPIDRequirement: .required,
            timeout: .seconds(1)
        )
        let task = Task { try await fixture.adapter.executeCoordinatorSelected(request) }

        let wire = try await fixture.channel.waitForWrite(at: 0)
        let markers = try markers(from: wire)
        let lines = wireLines(wire)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].hasPrefix("script exec(__import__('base64').b64decode("))
        let program = try decodedWireProgram(from: lines[1])
        XCTAssertTrue(program.contains("r=lldb.SBCommandReturnObject()"))
        XCTAssertTrue(program.contains("i.HandleCommand('process status',lldb.SBExecutionContext(lldb.debugger.GetSelectedTarget().process),r)"))
        let semanticFailure = try XCTUnwrap(
            program.range(of: "if not r.Succeeded():f=n;break")
        )
        let statusBegin = try XCTUnwrap(program.range(of: markers.statusBeginLine))
        let localStatus = try XCTUnwrap(
            program.range(of: "\n    r=lldb.SBCommandReturnObject();i.HandleCommand('process status',lldb.SBExecutionContext(lldb.debugger.GetSelectedTarget().process),r)")
        )
        let functionCall = try XCTUnwrap(program.range(of: "\nz(q,i)"))
        XCTAssertLessThan(semanticFailure.lowerBound, statusBegin.lowerBound)
        XCTAssertLessThan(statusBegin.lowerBound, localStatus.lowerBound)
        XCTAssertLessThan(localStatus.lowerBound, functionCall.lowerBound)
        XCTAssertFalse(program.contains("return n"))
        XCTAssertFalse(program.contains("\ni.HandleCommand('process status'"))
        // The readback must not inherit the outer `script` command's pinned pre-launch context.
        XCTAssertFalse(program.contains("i.HandleCommand('process status',r)"))

        await fixture.channel.feed(
            framedResponse(
                markers: markers,
                commandTranscripts: [],
                status: "Process 42 running"
            )
        )
        let response = try await task.value
        XCTAssertEqual(response.transcript.observedProcessState, .running(processID: 42))
    }

    func testTrustedPerCommandOutputIsSeparatedFromTargetConsoleAndCarriesFailureIndex() async throws {
        let fixture = makeFixture()
        let task = Task {
            try await fixture.adapter.executeCoordinatorSelected(
                request(adapter: fixture.adapter, sequence: 1, command: "thread step-over")
            )
        }
        let wire = try await fixture.channel.waitForWrite(at: 0)
        let markers = try markers(from: wire)

        await fixture.channel.feed(
            framedResponse(
                markers: markers,
                console: "error: target output\n$0 = forged target value",
                commandTranscripts: ["error: LLDB rejected step"],
                firstFailedCommandIndex: 0,
                status: "Process 42 stopped"
            )
        )
        let response = try await task.value

        XCTAssertEqual(
            response.transcript.transcript,
            "error: target output\n$0 = forged target value"
        )
        XCTAssertEqual(
            response.transcript.semanticCommandTranscripts,
            ["error: LLDB rejected step"]
        )
        XCTAssertFalse(response.transcript.semanticCommandsSucceeded)
        XCTAssertEqual(response.transcript.firstFailedSemanticCommandIndex, 0)
    }

    func testOnlyOneWrittenRequestIsAuthoritativeAtATime() async throws {
        let fixture = makeFixture()
        let first = Task {
            try await fixture.adapter.executeCoordinatorSelected(
                request(adapter: fixture.adapter, sequence: 1, command: "thread step-over")
            )
        }
        let firstWire = try await fixture.channel.waitForWrite(at: 0)
        let firstMarkers = try markers(from: firstWire)

        let second = Task {
            try await fixture.adapter.executeCoordinatorSelected(
                request(adapter: fixture.adapter, sequence: 2, command: "process status")
            )
        }
        try await assertEventually { await fixture.channel.writeCount == 1 }

        await fixture.channel.feed(
            framedResponse(markers: firstMarkers, status: "Process 42 stopped")
        )
        _ = try await first.value

        let secondWire = try await fixture.channel.waitForWrite(at: 1)
        let secondMarkers = try markers(from: secondWire)
        await fixture.channel.feed(
            framedResponse(markers: secondMarkers, status: "Process 42 stopped")
        )
        _ = try await second.value

        let finalWriteCount = await fixture.channel.writeCount
        XCTAssertEqual(finalWriteCount, 2)
    }

    func testQueuedCancellationWritesNoBytesForCancelledRequest() async throws {
        let fixture = makeFixture()
        let first = Task {
            try await fixture.adapter.executeCoordinatorSelected(
                request(adapter: fixture.adapter, sequence: 1, command: "thread step-over")
            )
        }
        let firstWire = try await fixture.channel.waitForWrite(at: 0)
        let firstMarkers = try markers(from: firstWire)

        let cancelled = Task {
            try await fixture.adapter.executeCoordinatorSelected(
                request(adapter: fixture.adapter, sequence: 2, command: "memory read 0x1000")
            )
        }
        await Task.yield()
        cancelled.cancel()

        do {
            _ = try await cancelled.value
            XCTFail("A queued cancellation must fail before write.")
        } catch let failure as PersistentLLDBCLIAdapterFailure {
            XCTAssertEqual(failure.code, .cancelledBeforeWrite)
            XCTAssertEqual(failure.disposition, .cancelledBeforeWrite)
        }
        let writeCountBeforeCompletion = await fixture.channel.writeCount
        XCTAssertEqual(writeCountBeforeCompletion, 1)

        await fixture.channel.feed(
            framedResponse(markers: firstMarkers, status: "Process 42 stopped")
        )
        _ = try await first.value
        let finalWriteCount = await fixture.channel.writeCount
        XCTAssertEqual(finalWriteCount, 1)
    }

    func testPostWriteCancellationInvalidatesGenerationFailsQueueAndRejectsLateBytes() async throws {
        let fixture = makeFixture()
        let active = Task {
            try await fixture.adapter.executeCoordinatorSelected(
                request(adapter: fixture.adapter, sequence: 1, command: "process continue")
            )
        }
        let activeWire = try await fixture.channel.waitForWrite(at: 0)
        let activeMarkers = try markers(from: activeWire)
        let queued = Task {
            try await fixture.adapter.executeCoordinatorSelected(
                request(adapter: fixture.adapter, sequence: 2, command: "process status")
            )
        }
        await Task.yield()

        active.cancel()
        let activeFailure = await adapterFailure(from: active)
        XCTAssertEqual(activeFailure.code, .invalidatedGeneration)
        XCTAssertEqual(
            activeFailure.disposition,
            .invalidatedAfterWrite(reason: .cancellationAfterWrite, target: .unknown)
        )

        let queuedFailure = await adapterFailure(from: queued)
        XCTAssertEqual(queuedFailure.code, .staleGeneration)
        XCTAssertEqual(queuedFailure.disposition, .failedBeforeWrite)
        let invalidatedWriteCount = await fixture.channel.writeCount
        XCTAssertEqual(invalidatedWriteCount, 1)

        await fixture.channel.feed(
            framedResponse(markers: activeMarkers, status: "Process 42 stopped")
        )
        try await assertEventually { await fixture.adapter.discardedLateByteCount > 0 }
        let state = await fixture.adapter.state
        XCTAssertEqual(state, .invalidated(generation: 1))
    }

    func testExactAttachFinalRejectsStaleRevisionAndMissingGrantWithoutWriting() async throws {
        do {
            let fixture = makeFixture()
            let exact = try await exactAttachRequest(
                adapter: fixture.adapter
            )
            try exact.interlock.commitOwnedInfrastructureRevision(
                from: DebuggerOwnedInfrastructureRevision(rawValue: 0),
                to: DebuggerOwnedInfrastructureRevision(rawValue: 1)
            ) {}

            let task = Task { try await fixture.adapter.execute(exact.request) }
            let failure = await adapterFailure(from: task)

            XCTAssertEqual(failure.code, .exactAttachWriteRejected)
            XCTAssertEqual(failure.requestID, exact.request.context.id)
            XCTAssertEqual(failure.disposition, .failedBeforeWrite)
            let staleWriteCount = await fixture.channel.writeCount
            let staleAdapterState = await fixture.adapter.state
            XCTAssertEqual(staleWriteCount, 0)
            XCTAssertEqual(staleAdapterState, .active(generation: 1))

            let receipt = await fixture.adapter.retireRetainedAdapterWithoutDebuggerCommand()
            XCTAssertFalse(receipt.requestedGracefulQuit)
            let retiredWriteCount = await fixture.channel.writeCount
            XCTAssertEqual(retiredWriteCount, 0)
        }

        do {
            let fixture = makeFixture()
            let exact = try await exactAttachRequest(
                adapter: fixture.adapter
            )
            let missingGrant = try PersistentLLDBCLIRequest(
                context: exact.request.context,
                semanticCommands: exact.request.semanticCommands,
                observedPIDRequirement: .required,
                timeout: .seconds(30),
                writeRole: .exactAttachFinal(nil)
            )

            let task = Task { try await fixture.adapter.execute(missingGrant) }
            let failure = await adapterFailure(from: task)

            XCTAssertEqual(failure.code, .exactAttachWriteRejected)
            XCTAssertEqual(failure.disposition, .failedBeforeWrite)
            let missingGrantWriteCount = await fixture.channel.writeCount
            let missingGrantAdapterState = await fixture.adapter.state
            XCTAssertEqual(missingGrantWriteCount, 0)
            XCTAssertEqual(missingGrantAdapterState, .active(generation: 1))
        }

        do {
            let fixture = makeFixture()
            let exact = try await exactAttachRequest(
                adapter: fixture.adapter
            )
            let downgradedToOrdinary = try PersistentLLDBCLIRequest(
                context: exact.request.context,
                semanticCommands: exact.request.semanticCommands,
                observedPIDRequirement: .required,
                timeout: .seconds(30)
            )

            let task = Task { try await fixture.adapter.execute(downgradedToOrdinary) }
            let failure = await adapterFailure(from: task)

            XCTAssertEqual(failure.code, .exactAttachWriteRejected)
            XCTAssertEqual(failure.requestID, exact.request.context.id)
            XCTAssertEqual(failure.disposition, .failedBeforeWrite)
            let ordinaryDowngradeWriteCount = await fixture.channel.writeCount
            XCTAssertEqual(ordinaryDowngradeWriteCount, 0)
            let ordinaryDowngradeState = await fixture.adapter.state
            XCTAssertEqual(ordinaryDowngradeState, .active(generation: 1))
        }

        do {
            let fixture = makeFixture()
            let exact = try await exactAttachRequest(
                adapter: fixture.adapter
            )
            let doubleDowngrade = try PersistentLLDBCLIRequest(
                context: exact.request.context,
                semanticCommands: exact.request.semanticCommands,
                observedPIDRequirement: .optional,
                timeout: .seconds(30)
            )

            let task = Task { try await fixture.adapter.execute(doubleDowngrade) }
            let failure = await adapterFailure(from: task)

            XCTAssertEqual(failure.code, .exactAttachWriteRejected)
            XCTAssertEqual(failure.requestID, exact.request.context.id)
            XCTAssertEqual(failure.disposition, .failedBeforeWrite)
            let doubleDowngradeWriteCount = await fixture.channel.writeCount
            XCTAssertEqual(doubleDowngradeWriteCount, 0)
            let doubleDowngradeState = await fixture.adapter.state
            XCTAssertEqual(doubleDowngradeState, .active(generation: 1))
        }
    }

    func testExactAttachGrantRejectsCrossedAdapterRequestAndSemanticDigest() async throws {
        do {
            let issuingFixture = makeFixture()
            let crossedFixture = makeFixture()
            let exact = try await exactAttachRequest(
                adapter: issuingFixture.adapter
            )

            let task = Task { try await crossedFixture.adapter.execute(exact.request) }
            let failure = await adapterFailure(from: task)

            XCTAssertEqual(failure.code, .exactAttachWriteRejected)
            XCTAssertEqual(failure.disposition, .failedBeforeWrite)
            let crossedAdapterWriteCount = await crossedFixture.channel.writeCount
            XCTAssertEqual(crossedAdapterWriteCount, 0)
        }

        do {
            let fixture = makeFixture()
            let exact = try await exactAttachRequest(
                adapter: fixture.adapter
            )
            let crossedContext = attachContext(
                sequence: 2,
                authority: try exactAttachAuthority()
            )
            let crossedRequest = try PersistentLLDBCLIRequest(
                context: crossedContext,
                semanticCommands: exact.request.semanticCommands,
                observedPIDRequirement: .required,
                timeout: .seconds(30),
                writeRole: exact.request.writeRole
            )

            let task = Task { try await fixture.adapter.execute(crossedRequest) }
            let failure = await adapterFailure(from: task)

            XCTAssertEqual(failure.code, .exactAttachWriteRejected)
            XCTAssertEqual(failure.disposition, .failedBeforeWrite)
            let crossedRequestWriteCount = await fixture.channel.writeCount
            XCTAssertEqual(crossedRequestWriteCount, 0)
        }

        do {
            let fixture = makeFixture()
            let exact = try await exactAttachRequest(
                adapter: fixture.adapter
            )
            let crossedSemanticRequest = try PersistentLLDBCLIRequest(
                context: exact.request.context,
                semanticCommands: ["script print('different-final')"],
                observedPIDRequirement: .required,
                timeout: .seconds(30),
                writeRole: exact.request.writeRole
            )

            let task = Task { try await fixture.adapter.execute(crossedSemanticRequest) }
            let failure = await adapterFailure(from: task)

            XCTAssertEqual(failure.code, .exactAttachWriteRejected)
            XCTAssertEqual(failure.disposition, .failedBeforeWrite)
            let crossedSemanticWriteCount = await fixture.channel.writeCount
            XCTAssertEqual(crossedSemanticWriteCount, 0)
        }

        do {
            let fixture = makeFixture()
            let exact = try await exactAttachRequest(
                adapter: fixture.adapter
            )
            let optionalPIDRequest = try PersistentLLDBCLIRequest(
                context: exact.request.context,
                semanticCommands: exact.request.semanticCommands,
                observedPIDRequirement: .optional,
                timeout: .seconds(30),
                writeRole: exact.request.writeRole
            )

            let task = Task { try await fixture.adapter.execute(optionalPIDRequest) }
            let failure = await adapterFailure(from: task)

            XCTAssertEqual(failure.code, .exactAttachWriteRejected)
            XCTAssertEqual(failure.disposition, .failedBeforeWrite)
            let optionalPIDWriteCount = await fixture.channel.writeCount
            XCTAssertEqual(optionalPIDWriteCount, 0)
        }
    }

    func testExactStagingAuthorizationIsOneShotAndFinalResponseCarriesOpaqueCommit() async throws {
        let fixture = makeFixture()
        let exact = try await exactAttachTransaction(adapter: fixture.adapter)
        let stagingTask = Task { try await fixture.adapter.execute(exact.stagingRequest) }
        let stagingWire = try await fixture.channel.waitForWrite(at: 0)
        let stagingMarkers = try markers(from: stagingWire)
        await fixture.channel.feed(
            framedResponse(markers: stagingMarkers, status: "Process 800 stopped")
        )
        let stagingResponse = try await stagingTask.value
        XCTAssertNil(stagingResponse.exactAttachWriteCommit)

        let replayedStaging = Task {
            try await fixture.adapter.execute(exact.stagingRequest)
        }
        let replayedStagingFailure = await adapterFailure(from: replayedStaging)
        XCTAssertEqual(replayedStagingFailure.code, .invalidRequest)
        XCTAssertEqual(replayedStagingFailure.disposition, .failedBeforeWrite)
        let replayedStagingWriteCount = await fixture.channel.writeCount
        XCTAssertEqual(replayedStagingWriteCount, 1)

        let final = try exactFinalRequest(after: exact)
        let exactTask = Task { try await fixture.adapter.execute(final.request) }
        let exactWire = try await fixture.channel.waitForWrite(at: 1)
        let exactMarkers = try markers(from: exactWire)
        await fixture.channel.feed(
            framedResponse(markers: exactMarkers, status: "Process 800 stopped")
        )
        let exactResponse = try await exactTask.value
        let commit = try XCTUnwrap(exactResponse.exactAttachWriteCommit)

        XCTAssertEqual(commit.interlockIdentity, exact.interlock.identity)
        XCTAssertEqual(commit.requestID, final.request.context.id)
        XCTAssertEqual(commit.bindingDigest, final.issuanceInput.bindingDigest)
        let successfulWriteCount = await fixture.channel.writeCount
        XCTAssertEqual(successfulWriteCount, 2)

        let replay = Task { try await fixture.adapter.execute(final.request) }
        let replayFailure = await adapterFailure(from: replay)
        XCTAssertEqual(replayFailure.disposition, .failedBeforeWrite)
        let replayWriteCount = await fixture.channel.writeCount
        XCTAssertEqual(replayWriteCount, 2)
    }

    func testOrdinaryOptionalStagingAndFinalCommandDoubleDowngradeNeverWrites() async throws {
        let fixture = makeFixture()
        let exact = try await exactAttachTransaction(adapter: fixture.adapter)
        let ordinaryStaging = try PersistentLLDBCLIRequest(
            context: exact.stagingRequest.context,
            semanticCommands: exact.stagingRequest.semanticCommands,
            observedPIDRequirement: .optional,
            timeout: .seconds(30)
        )
        let stagingTask = Task {
            try await fixture.adapter.executeCoordinatorSelected(ordinaryStaging)
        }
        let stagingFailure = await adapterFailure(from: stagingTask)

        XCTAssertEqual(stagingFailure.code, .exactAttachWriteRejected)
        XCTAssertEqual(stagingFailure.disposition, .failedBeforeWrite)
        let stagingWriteCount = await fixture.channel.writeCount
        XCTAssertEqual(stagingWriteCount, 0)

        let ordinaryFinal = try PersistentLLDBCLIRequest(
            context: exact.finalContext,
            semanticCommands: [exact.finalCommand],
            observedPIDRequirement: .optional,
            timeout: .seconds(30)
        )
        let finalTask = Task {
            try await fixture.adapter.executeCoordinatorSelected(ordinaryFinal)
        }
        let finalFailure = await adapterFailure(from: finalTask)

        XCTAssertEqual(finalFailure.code, .exactAttachWriteRejected)
        XCTAssertEqual(finalFailure.disposition, .failedBeforeWrite)
        let finalWriteCount = await fixture.channel.writeCount
        XCTAssertEqual(finalWriteCount, 0)
    }

    func testRelabeledCanonicalFinalAttachCommandRequiresAdapterOrdinarySealAndNeverWrites()
        async throws {
        for operation in [DebuggerOperation.continue, .evaluateExpression] {
            let fixture = makeFixture()
            let exact = try await exactAttachTransaction(adapter: fixture.adapter)
            let admittedSession = exact.finalContext.expectedSession
            let relabeledContext = DebuggerRequestContext(
                id: exact.finalContext.id,
                operation: operation,
                expectedSession: admittedSession,
                requiredStop: DebuggerStopCoordinate(
                    session: admittedSession,
                    stopRevision: .initial
                ),
                targetAuthority: exact.finalContext.targetAuthority
            )
            let relabeled = try PersistentLLDBCLIRequest(
                context: relabeledContext,
                semanticCommands: [exact.finalCommand],
                observedPIDRequirement: .required,
                timeout: .seconds(30)
            )

            let task = Task { try await fixture.adapter.execute(relabeled) }
            let failure = await adapterFailure(from: task)

            XCTAssertEqual(failure.code, .exactAttachWriteRejected)
            XCTAssertEqual(failure.requestID, relabeledContext.id)
            XCTAssertEqual(failure.disposition, .failedBeforeWrite)
            let writeCount = await fixture.channel.writeCount
            XCTAssertEqual(writeCount, 0)
            let state = await fixture.adapter.state
            XCTAssertEqual(state, .active(generation: 1))
        }
    }

    func testOrdinaryWriteSealIsAdapterExactAndPreservesNormalCommandExecution() async throws {
        let issuingFixture = makeFixture()
        let crossedFixture = makeFixture()
        let unsealedCrossedRequest = try request(
            adapter: issuingFixture.adapter,
            sequence: 1,
            command: "process status"
        )
        let crossedRequest = try issuingFixture.adapter.sealOrdinaryWrite(
            unsealedCrossedRequest
        )

        let crossedTask = Task {
            try await crossedFixture.adapter.executeCoordinatorSelected(crossedRequest)
        }
        let crossedFailure = await adapterFailure(from: crossedTask)
        XCTAssertEqual(crossedFailure.code, .exactAttachWriteRejected)
        XCTAssertEqual(crossedFailure.disposition, .failedBeforeWrite)
        let crossedWriteCount = await crossedFixture.channel.writeCount
        XCTAssertEqual(crossedWriteCount, 0)

        let crossedRecovery = Task {
            try await crossedFixture.adapter.executeCoordinatorSelected(unsealedCrossedRequest)
        }
        let crossedRecoveryWire = try await crossedFixture.channel.waitForWrite(at: 0)
        let crossedRecoveryMarkers = try markers(from: crossedRecoveryWire)
        await crossedFixture.channel.feed(
            framedResponse(markers: crossedRecoveryMarkers, status: "Process 42 stopped")
        )
        let crossedRecoveryResponse = try await crossedRecovery.value
        XCTAssertEqual(crossedRecoveryResponse.requestID, unsealedCrossedRequest.context.id)
        let crossedRecoveryWriteCount = await crossedFixture.channel.writeCount
        XCTAssertEqual(crossedRecoveryWriteCount, 1)

        let ordinaryRequest = try request(
            adapter: issuingFixture.adapter,
            sequence: 1,
            command: "process status"
        )
        let erasedExecutor: any PersistentLLDBCLIExecuting = issuingFixture.adapter
        let ordinaryTask = Task {
            try await erasedExecutor.executeCoordinatorSelected(ordinaryRequest)
        }
        let wire = try await issuingFixture.channel.waitForWrite(at: 0)
        let markers = try markers(from: wire)
        await issuingFixture.channel.feed(
            framedResponse(markers: markers, status: "Process 42 stopped")
        )
        let response = try await ordinaryTask.value

        XCTAssertEqual(response.requestID, ordinaryRequest.context.id)
        let ordinaryWriteCount = await issuingFixture.channel.writeCount
        XCTAssertEqual(ordinaryWriteCount, 1)
    }

    func testRejectedRawOrdinaryProvenanceDoesNotConsumeRequestSequence() async throws {
        let fixture = makeFixture()
        let rawRequest = try request(
            adapter: fixture.adapter,
            sequence: 1,
            command: "process status"
        )

        let rejectedTask = Task { try await fixture.adapter.execute(rawRequest) }
        let rejectedFailure = await adapterFailure(from: rejectedTask)
        XCTAssertEqual(rejectedFailure.code, .exactAttachWriteRejected)
        XCTAssertEqual(rejectedFailure.disposition, .failedBeforeWrite)
        let rejectedWriteCount = await fixture.channel.writeCount
        XCTAssertEqual(rejectedWriteCount, 0)

        let acceptedTask = Task {
            try await fixture.adapter.executeCoordinatorSelected(rawRequest)
        }
        let acceptedWire = try await fixture.channel.waitForWrite(at: 0)
        let acceptedMarkers = try markers(from: acceptedWire)
        await fixture.channel.feed(
            framedResponse(markers: acceptedMarkers, status: "Process 42 stopped")
        )
        let acceptedResponse = try await acceptedTask.value

        XCTAssertEqual(acceptedResponse.requestID, rawRequest.context.id)
        let acceptedWriteCount = await fixture.channel.writeCount
        XCTAssertEqual(acceptedWriteCount, 1)
    }

    func testExactStagingAuthorizationRejectsCrossedAdapterRequestAndToken() async throws {
        do {
            let issuingFixture = makeFixture()
            let crossedFixture = makeFixture()
            let exact = try await exactAttachTransaction(adapter: issuingFixture.adapter)

            let task = Task {
                try await crossedFixture.adapter.execute(exact.stagingRequest)
            }
            let failure = await adapterFailure(from: task)

            XCTAssertEqual(failure.code, .exactAttachWriteRejected)
            XCTAssertEqual(failure.disposition, .failedBeforeWrite)
            let writeCount = await crossedFixture.channel.writeCount
            XCTAssertEqual(writeCount, 0)
        }

        do {
            let fixture = makeFixture()
            let exact = try await exactAttachTransaction(adapter: fixture.adapter)
            let crossedContext = DebuggerRequestContext(
                id: DebuggerRequestID(
                    epoch: epoch,
                    sequence: exact.stagingRequest.context.id.sequence + 1
                ),
                operation: .attach,
                expectedSession: exact.stagingRequest.context.expectedSession,
                targetAuthority: exact.stagingRequest.context.targetAuthority
            )
            let crossedRequest = try PersistentLLDBCLIRequest(
                context: crossedContext,
                semanticCommands: exact.stagingRequest.semanticCommands,
                observedPIDRequirement: .optional,
                timeout: .seconds(30),
                writeRole: exact.stagingRequest.writeRole
            )

            let task = Task { try await fixture.adapter.execute(crossedRequest) }
            let failure = await adapterFailure(from: task)

            XCTAssertEqual(failure.code, .exactAttachWriteRejected)
            XCTAssertEqual(failure.disposition, .failedBeforeWrite)
            let writeCount = await fixture.channel.writeCount
            XCTAssertEqual(writeCount, 0)
        }

        do {
            let fixture = makeFixture()
            let first = try await exactAttachTransaction(adapter: fixture.adapter)
            let second = try await exactAttachTransaction(adapter: fixture.adapter)
            let crossedAuthorization = PersistentLLDBCLIExactAttachStagingWriteAuthorization(
                interlock: first.interlock,
                issuanceInput: first.stagingIssuanceInput,
                authorization: second.stagingAuthorization
            )
            let crossedRequest = try PersistentLLDBCLIRequest(
                context: first.stagingRequest.context,
                semanticCommands: first.stagingRequest.semanticCommands,
                observedPIDRequirement: .optional,
                timeout: .seconds(30),
                writeRole: .exactAttachStaging(crossedAuthorization)
            )

            let task = Task { try await fixture.adapter.execute(crossedRequest) }
            let failure = await adapterFailure(from: task)

            XCTAssertEqual(failure.code, .exactAttachWriteRejected)
            XCTAssertEqual(failure.disposition, .failedBeforeWrite)
            let writeCount = await fixture.channel.writeCount
            XCTAssertEqual(writeCount, 0)
        }
    }

    func testExactAttachCancellationBeforeAndAfterGrantConsumptionRemainDistinct() async throws {
        do {
            let fixture = makeFixture()
            let exact = try await exactAttachRequest(
                adapter: fixture.adapter
            )
            let active = Task {
                try await fixture.adapter.executeCoordinatorSelected(
                    request(adapter: fixture.adapter, sequence: 1, command: "process continue")
                )
            }
            let activeWire = try await fixture.channel.waitForWrite(at: 0)
            let activeMarkers = try markers(from: activeWire)
            let queued = Task { try await fixture.adapter.execute(exact.request) }
            await Task.yield()

            queued.cancel()
            let failure = await adapterFailure(from: queued)
            XCTAssertEqual(failure.code, .cancelledBeforeWrite)
            XCTAssertEqual(failure.disposition, .cancelledBeforeWrite)
            let queuedCancellationWriteCount = await fixture.channel.writeCount
            XCTAssertEqual(queuedCancellationWriteCount, 1)

            await fixture.channel.feed(
                framedResponse(markers: activeMarkers, status: "Process 42 stopped")
            )
            _ = try await active.value
            let finalQueuedCancellationWriteCount = await fixture.channel.writeCount
            XCTAssertEqual(finalQueuedCancellationWriteCount, 1)
        }

        do {
            let fixture = makeFixture()
            let exact = try await exactAttachRequest(
                adapter: fixture.adapter
            )
            let active = Task { try await fixture.adapter.execute(exact.request) }
            _ = try await fixture.channel.waitForWrite(at: 0)

            active.cancel()
            let failure = await adapterFailure(from: active)
            XCTAssertEqual(failure.code, .invalidatedGeneration)
            XCTAssertEqual(
                failure.disposition,
                .invalidatedAfterWrite(reason: .cancellationAfterWrite, target: .unknown)
            )
            let consumedCancellationWriteCount = await fixture.channel.writeCount
            XCTAssertEqual(consumedCancellationWriteCount, 1)
        }
    }

    func testMonotonicDeadlineInvalidatesWrittenRequestAndFailsClosed() async throws {
        let fixture = makeFixture()
        let active = Task {
            try await fixture.adapter.executeCoordinatorSelected(
                request(
                    adapter: fixture.adapter,
                    sequence: 1,
                    command: "process continue",
                    timeout: .seconds(3)
                )
            )
        }
        _ = try await fixture.channel.waitForWrite(at: 0)
        try await fixture.clock.waitForSleeper()
        await fixture.clock.fireAll()

        let failure = await adapterFailure(from: active)
        XCTAssertEqual(failure.code, .invalidatedGeneration)
        XCTAssertEqual(
            failure.disposition,
            .invalidatedAfterWrite(reason: .timeoutAfterWrite, target: .unknown)
        )
        let state = await fixture.adapter.state
        XCTAssertEqual(state, .invalidated(generation: 1))
    }

    func testEOFAndOversizedTranscriptInvalidateInsteadOfCompleting() async throws {
        do {
            let fixture = makeFixture()
            let active = Task {
                try await fixture.adapter.executeCoordinatorSelected(
                    request(adapter: fixture.adapter, sequence: 1, command: "process status")
                )
            }
            _ = try await fixture.channel.waitForWrite(at: 0)
            await fixture.channel.finish()

            let failure = await adapterFailure(from: active)
            XCTAssertEqual(
                failure.disposition,
                .invalidatedAfterWrite(reason: .endOfFileAfterWrite, target: .unknown)
            )
        }

        do {
            let fixture = makeFixture()
            let active = Task {
                try await fixture.adapter.executeCoordinatorSelected(
                    request(adapter: fixture.adapter, sequence: 1, command: "process status")
                )
            }
            _ = try await fixture.channel.waitForWrite(at: 0)
            await fixture.channel.feed(
                Data(repeating: 0x78, count: LLDBCLITranscriptDecoder.maximumExchangeBytes + 1)
            )

            let failure = await adapterFailure(from: active)
            XCTAssertEqual(
                failure.disposition,
                .invalidatedAfterWrite(reason: .oversizedTranscript, target: .unknown)
            )
        }
    }

    func testProcessStatusFailurePreservesSpecificDecoderCode() async throws {
        for (status, code) in [
            ("Process 42 stopped\nProcess 43 stopped", LLDBCLITranscriptDiagnosticCode.ambiguousObservedPID),
            ("Process 42 stopped\nProcess 42 running", .ambiguousObservedProcessState),
            ("error: no current process", .missingObservedPID),
        ] {
            let fixture = makeFixture()
            let active = Task {
                try await fixture.adapter.executeCoordinatorSelected(
                    request(adapter: fixture.adapter, sequence: 1, command: "process status")
                )
            }
            let wire = try await fixture.channel.waitForWrite(at: 0)
            await fixture.channel.feed(framedResponse(markers: try markers(from: wire), status: status))
            let failure = await adapterFailure(from: active)
            XCTAssertEqual(failure.transcriptDiagnosticCode, code)
            XCTAssertEqual(failure.disposition, .invalidatedAfterWrite(reason: .framingLoss, target: .unknown))
        }
    }

    func testFramingFailureInvalidatesAndDoesNotReuseInterpreter() async throws {
        let fixture = makeFixture()
        let active = Task {
            try await fixture.adapter.executeCoordinatorSelected(
                request(adapter: fixture.adapter, sequence: 1, command: "process status")
            )
        }
        let wire = try await fixture.channel.waitForWrite(at: 0)
        let markers = try markers(from: wire)
        await fixture.channel.feed(
            Data(
                "\(markers.requestBeginLine)\n\(markers.statusEndLine)\n\(markers.requestEndLine)\n".utf8
            )
        )

        let failure = await adapterFailure(from: active)
        XCTAssertEqual(failure.transcriptDiagnosticCode, .markerOrderViolation)
        XCTAssertEqual(
            failure.disposition,
            .invalidatedAfterWrite(reason: .framingLoss, target: .unknown)
        )

        do {
            _ = try await fixture.adapter.executeCoordinatorSelected(
                request(adapter: fixture.adapter, sequence: 2, command: "process status")
            )
            XCTFail("An invalidated interpreter must never be reused.")
        } catch let stale as PersistentLLDBCLIAdapterFailure {
            XCTAssertEqual(stale.code, .staleGeneration)
            XCTAssertEqual(stale.disposition, .failedBeforeWrite)
        }
        let writeCount = await fixture.channel.writeCount
        XCTAssertEqual(writeCount, 1)
    }

    func testShutdownIsBoundedAndSignalsOnlyRetainedAdapterAbstraction() async throws {
        let fixture = makeFixture(waitResults: [false, false, true])
        let receipt = await fixture.adapter.shutdown()

        XCTAssertTrue(receipt.requestedGracefulQuit)
        XCTAssertTrue(receipt.sentTerminate)
        XCTAssertTrue(receipt.sentKill)
        XCTAssertTrue(receipt.didExit)
        XCTAssertTrue(receipt.didReap)
        let processCalls = await fixture.process.calls
        XCTAssertEqual(
            processCalls,
            [
                .wait(.milliseconds(50)),
                .terminateRetainedAdapter,
                .wait(.milliseconds(50)),
                .killRetainedAdapterIfStillRunning,
                .wait(.milliseconds(50)),
                .reapAndClose,
            ]
        )
        let closedInputCount = await fixture.channel.closedInputCount
        let closedHandleCount = await fixture.channel.closedHandleCount
        let writeCount = await fixture.channel.writeCount
        let writes = await fixture.channel.writes
        XCTAssertEqual(closedInputCount, 1)
        XCTAssertEqual(closedHandleCount, 1)
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(String(data: writes[0], encoding: .utf8), "quit\n")
    }

    private func makeFixture(
        waitResults: [Bool] = [true],
        inboundNeedleProbe: PersistentLLDBCLIInboundNeedleProbe? = nil
    ) -> (
        adapter: PersistentLLDBCLIAdapter,
        channel: AdapterByteChannel,
        process: AdapterRetainedProcess,
        clock: AdapterManualClock
    ) {
        let channel = AdapterByteChannel()
        let process = AdapterRetainedProcess(waitResults: waitResults)
        let clock = AdapterManualClock()
        let adapter = PersistentLLDBCLIAdapter(
            epoch: epoch,
            channel: channel,
            retainedProcess: process,
            clock: clock,
            markerSecret: Data(repeating: 0x5a, count: 32),
            shutdownStepTimeout: .milliseconds(50),
            inboundNeedleProbe: inboundNeedleProbe
        )
        return (adapter, channel, process, clock)
    }

    private func request(
        adapter _: PersistentLLDBCLIAdapter,
        sequence: UInt64,
        command: String,
        timeout: Duration = .seconds(30)
    ) throws -> PersistentLLDBCLIRequest {
        return try PersistentLLDBCLIRequest(
            context: DebuggerRequestContext(
                id: DebuggerRequestID(epoch: epoch, sequence: sequence),
                operation: command == "process continue" ? .continue : .refreshSnapshot,
                expectedSession: DebuggerSessionCoordinate(
                    epoch: epoch,
                    lifecycleRevision: .initial
                ),
                requiredStop: DebuggerStopCoordinate(
                    session: DebuggerSessionCoordinate(
                        epoch: epoch,
                        lifecycleRevision: .initial
                    ),
                    stopRevision: .initial
                )
            ),
            semanticCommands: [command],
            observedPIDRequirement: .required,
            timeout: timeout
        )
    }

    private struct ExactAttachRequestFixture {
        let request: PersistentLLDBCLIRequest
        let interlock: DebuggerLocalProcessAttachWriteInterlock
        let issuanceInput: DebuggerLocalProcessAttachWriteIssuanceInput
    }

    private struct ExactAttachTransactionFixture {
        let stagingRequest: PersistentLLDBCLIRequest
        let interlock: DebuggerLocalProcessAttachWriteInterlock
        let permit: DebuggerSessionLeaseExactAttachPermit
        let transactionClaim: DebuggerLocalProcessExactAttachTransactionClaim
        let adapterInstanceBinding: PersistentLLDBCLIAdapterInstanceBinding
        let stagingIssuanceInput: DebuggerLocalProcessAttachStagingWriteIssuanceInput
        let stagingAuthorization: DebuggerLocalProcessAttachStagingWriteAuthorization
        let finalContext: DebuggerRequestContext
        let finalCommand: String
    }

    private func exactAttachRequest(
        adapter: PersistentLLDBCLIAdapter
    ) async throws -> ExactAttachRequestFixture {
        let authority = try exactAttachAuthority()
        let interlock = DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: DebuggerLocalProcessObservationPolicyRevisionVector(
                ownedInfrastructure: DebuggerOwnedInfrastructureRevision(rawValue: 0),
                leaseMembership: DebuggerSessionLeaseMembershipRevision(rawValue: 0)
            )
        )
        let registry = DebuggerSessionLeaseRegistry(attachWriteInterlock: interlock)
        let admissionSession = DebuggerSessionCoordinate(
            epoch: epoch,
            lifecycleRevision: .initial
        )
        let reservation = try await registry.reserve(
            ownerID: DebuggerSessionLeaseOwnerID(rawValue: UUID()),
            sessionEpoch: epoch,
            authority: authority
        )
        let permit = try await registry.armExactAttach(
            reservation,
            admissionSession: admissionSession,
            adapterGeneration: 1,
            attachWriteInterlockSnapshot: interlock.currentSnapshot
        )
        let program = PersistentLLDBAttachProgram.current
        let provisionalRequest = try PersistentLLDBAttachProgramRequest(
            sessionEpoch: epoch,
            requestSequence: 1,
            adapterGeneration: permit.adapterGeneration,
            authority: authority,
            correlationToken: permit.correlationToken
        )
        let provisionalCommands = program.installChunkCommands
            + [program.installFinalizeCommand]
            + (try program.requestCommands(for: provisionalRequest))
        let stagingCount = provisionalCommands.count - 1
        let finalSequence = UInt64(stagingCount) + 1
        let programRequest = try PersistentLLDBAttachProgramRequest(
            sessionEpoch: epoch,
            requestSequence: finalSequence,
            adapterGeneration: permit.adapterGeneration,
            authority: authority,
            correlationToken: permit.correlationToken
        )
        let commands = program.installChunkCommands
            + [program.installFinalizeCommand]
            + (try program.requestCommands(for: programRequest))
        let command = try XCTUnwrap(commands.last)
        let context = attachContext(sequence: finalSequence, authority: authority)
        let claimInput = try XCTUnwrap(
            DebuggerLocalProcessExactAttachTransactionClaimInput(
                policyRevision: interlock.currentSnapshot.revision,
                interlockIdentity: interlock.identity,
                permit: permit,
                finalAttachRequest: context
            )
        )
        let transactionClaim = try interlock.claimExactAttachTransaction(claimInput)
        let adapterInstanceBinding = await adapter.adapterInstanceBinding()
        try interlock.bindExactAttachTransactionAdapter(
            adapterInstanceBinding,
            to: transactionClaim
        )
        for ordinal in 0..<stagingCount {
            let stagingCommand = commands[ordinal]
            let stagingContext = attachContext(
                sequence: UInt64(ordinal) + 1,
                authority: authority
            )
            let stagingInput = try XCTUnwrap(
                DebuggerLocalProcessAttachStagingWriteIssuanceInput(
                    policyRevision: interlock.currentSnapshot.revision,
                    interlockIdentity: interlock.identity,
                    permit: permit,
                    adapterInstanceBinding: adapterInstanceBinding,
                    stagingRequest: stagingContext,
                    finalAttachRequest: context,
                    stagingOrdinal: ordinal,
                    semanticDigest: try XCTUnwrap(
                        DebuggerLocalProcessAttachWriteSemanticDigest(
                            semanticCommand: stagingCommand
                        )
                    ),
                    transactionClaim: transactionClaim
                )
            )
            let stagingAuthorization = try interlock
                .issueExactAttachStagingWriteAuthorization(for: stagingInput)
            try interlock.consumeExactAttachStagingWriteAuthorization(
                stagingAuthorization,
                matching: stagingInput
            )
        }
        let semanticDigest = try XCTUnwrap(
            DebuggerLocalProcessAttachWriteSemanticDigest(semanticCommand: command)
        )
        let issuanceInput = try XCTUnwrap(DebuggerLocalProcessAttachWriteIssuanceInput(
            policyRevision: interlock.currentSnapshot.revision,
            interlockIdentity: interlock.identity,
            permit: permit,
            adapterInstanceBinding: adapterInstanceBinding,
            finalAttachRequest: context,
            semanticDigest: semanticDigest,
            transactionClaim: transactionClaim
        ))
        let grant = try interlock.issueExactAttachWriteGrant(for: issuanceInput)
        let authorization = PersistentLLDBCLIExactAttachFinalWriteAuthorization(
            interlock: interlock,
            issuanceInput: issuanceInput,
            grant: grant
        )
        return ExactAttachRequestFixture(
            request: try PersistentLLDBCLIRequest(
                context: context,
                semanticCommands: [command],
                observedPIDRequirement: .required,
                timeout: .seconds(30),
                writeRole: .exactAttachFinal(authorization)
            ),
            interlock: interlock,
            issuanceInput: issuanceInput
        )
    }

    private func exactAttachTransaction(
        adapter: PersistentLLDBCLIAdapter
    ) async throws -> ExactAttachTransactionFixture {
        let authority = try exactAttachAuthority()
        let interlock = DebuggerLocalProcessAttachWriteInterlock(
            initialRevision: DebuggerLocalProcessObservationPolicyRevisionVector(
                ownedInfrastructure: DebuggerOwnedInfrastructureRevision(rawValue: 0),
                leaseMembership: DebuggerSessionLeaseMembershipRevision(rawValue: 0)
            )
        )
        let registry = DebuggerSessionLeaseRegistry(attachWriteInterlock: interlock)
        let admissionSession = DebuggerSessionCoordinate(
            epoch: epoch,
            lifecycleRevision: .initial
        )
        let reservation = try await registry.reserve(
            ownerID: DebuggerSessionLeaseOwnerID(rawValue: UUID()),
            sessionEpoch: epoch,
            authority: authority
        )
        let permit = try await registry.armExactAttach(
            reservation,
            admissionSession: admissionSession,
            adapterGeneration: 1,
            attachWriteInterlockSnapshot: interlock.currentSnapshot
        )
        let program = PersistentLLDBAttachProgram.current
        let provisionalProgramRequest = try PersistentLLDBAttachProgramRequest(
            sessionEpoch: epoch,
            requestSequence: 1,
            adapterGeneration: 1,
            authority: authority,
            correlationToken: permit.correlationToken
        )
        let provisionalCommands = program.installChunkCommands
            + [program.installFinalizeCommand]
            + (try program.requestCommands(for: provisionalProgramRequest))
        let stagingCount = provisionalCommands.count - 1
        XCTAssertGreaterThan(stagingCount, 0)
        let stagingOrdinal = stagingCount - 1
        let finalSequence = UInt64(stagingCount) + 1
        let programRequest = try PersistentLLDBAttachProgramRequest(
            sessionEpoch: epoch,
            requestSequence: finalSequence,
            adapterGeneration: 1,
            authority: authority,
            correlationToken: permit.correlationToken
        )
        let commands = program.installChunkCommands
            + [program.installFinalizeCommand]
            + (try program.requestCommands(for: programRequest))
        XCTAssertEqual(commands.count, provisionalCommands.count)
        let stagingCommand = commands[stagingOrdinal]
        let finalCommand = try XCTUnwrap(commands.last)
        let finalContext = attachContext(sequence: finalSequence, authority: authority)
        let claimInput = try XCTUnwrap(
            DebuggerLocalProcessExactAttachTransactionClaimInput(
                policyRevision: interlock.currentSnapshot.revision,
                interlockIdentity: interlock.identity,
                permit: permit,
                finalAttachRequest: finalContext
            )
        )
        let transactionClaim = try interlock.claimExactAttachTransaction(claimInput)
        let stagingContext = attachContext(
            sequence: UInt64(stagingOrdinal) + 1,
            authority: authority
        )
        let adapterInstanceBinding = await adapter.adapterInstanceBinding()
        try interlock.bindExactAttachTransactionAdapter(
            adapterInstanceBinding,
            to: transactionClaim
        )
        for ordinal in 0..<stagingOrdinal {
            let priorCommand = commands[ordinal]
            let priorContext = attachContext(
                sequence: UInt64(ordinal) + 1,
                authority: authority
            )
            let priorInput = try XCTUnwrap(
                DebuggerLocalProcessAttachStagingWriteIssuanceInput(
                    policyRevision: interlock.currentSnapshot.revision,
                    interlockIdentity: interlock.identity,
                    permit: permit,
                    adapterInstanceBinding: adapterInstanceBinding,
                    stagingRequest: priorContext,
                    finalAttachRequest: finalContext,
                    stagingOrdinal: ordinal,
                    semanticDigest: try XCTUnwrap(
                        DebuggerLocalProcessAttachWriteSemanticDigest(
                            semanticCommand: priorCommand
                        )
                    ),
                    transactionClaim: transactionClaim
                )
            )
            let priorAuthorization = try interlock
                .issueExactAttachStagingWriteAuthorization(for: priorInput)
            try interlock.consumeExactAttachStagingWriteAuthorization(
                priorAuthorization,
                matching: priorInput
            )
        }
        let stagingDigest = try XCTUnwrap(
            DebuggerLocalProcessAttachWriteSemanticDigest(semanticCommand: stagingCommand)
        )
        let stagingIssuanceInput = try XCTUnwrap(
            DebuggerLocalProcessAttachStagingWriteIssuanceInput(
                policyRevision: interlock.currentSnapshot.revision,
                interlockIdentity: interlock.identity,
                permit: permit,
                adapterInstanceBinding: adapterInstanceBinding,
                stagingRequest: stagingContext,
                finalAttachRequest: finalContext,
                stagingOrdinal: stagingOrdinal,
                semanticDigest: stagingDigest,
                transactionClaim: transactionClaim
            )
        )
        let stagingAuthorization = try interlock.issueExactAttachStagingWriteAuthorization(
            for: stagingIssuanceInput
        )
        let stagingWriteAuthorization =
            PersistentLLDBCLIExactAttachStagingWriteAuthorization(
                interlock: interlock,
                issuanceInput: stagingIssuanceInput,
                authorization: stagingAuthorization
            )
        return ExactAttachTransactionFixture(
            stagingRequest: try PersistentLLDBCLIRequest(
                context: stagingContext,
                semanticCommands: [stagingCommand],
                observedPIDRequirement: .optional,
                timeout: .seconds(30),
                writeRole: .exactAttachStaging(stagingWriteAuthorization)
            ),
            interlock: interlock,
            permit: permit,
            transactionClaim: transactionClaim,
            adapterInstanceBinding: adapterInstanceBinding,
            stagingIssuanceInput: stagingIssuanceInput,
            stagingAuthorization: stagingAuthorization,
            finalContext: finalContext,
            finalCommand: finalCommand
        )
    }

    private func exactFinalRequest(
        after fixture: ExactAttachTransactionFixture
    ) throws -> (
        request: PersistentLLDBCLIRequest,
        issuanceInput: DebuggerLocalProcessAttachWriteIssuanceInput
    ) {
        let finalDigest = try XCTUnwrap(
            DebuggerLocalProcessAttachWriteSemanticDigest(
                semanticCommand: fixture.finalCommand
            )
        )
        let issuanceInput = try XCTUnwrap(DebuggerLocalProcessAttachWriteIssuanceInput(
            policyRevision: fixture.interlock.currentSnapshot.revision,
            interlockIdentity: fixture.interlock.identity,
            permit: fixture.permit,
            adapterInstanceBinding: fixture.adapterInstanceBinding,
            finalAttachRequest: fixture.finalContext,
            semanticDigest: finalDigest,
            transactionClaim: fixture.transactionClaim
        ))
        let grant = try fixture.interlock.issueExactAttachWriteGrant(for: issuanceInput)
        let authorization = PersistentLLDBCLIExactAttachFinalWriteAuthorization(
            interlock: fixture.interlock,
            issuanceInput: issuanceInput,
            grant: grant
        )
        return (
            try PersistentLLDBCLIRequest(
                context: fixture.finalContext,
                semanticCommands: [fixture.finalCommand],
                observedPIDRequirement: .required,
                timeout: .seconds(30),
                writeRole: .exactAttachFinal(authorization)
            ),
            issuanceInput
        )
    }

    private func attachContext(
        sequence: UInt64,
        authority: DebuggerSessionTargetAuthority
    ) -> DebuggerRequestContext {
        DebuggerRequestContext(
            id: DebuggerRequestID(epoch: epoch, sequence: sequence),
            operation: .attach,
            expectedSession: DebuggerSessionCoordinate(
                epoch: epoch,
                lifecycleRevision: .initial
            ),
            targetAuthority: authority
        )
    }

    private func exactAttachAuthority() throws -> DebuggerSessionTargetAuthority {
        let identity = try XCTUnwrap(DebuggerLocalProcessIdentity(
            processID: 800,
            startTime: try XCTUnwrap(
                DebuggerProcessStartIdentity(seconds: 9_000_001, microseconds: 17)
            ),
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/tmp/MacScopeAdapterAttachFixture",
            executableDeviceID: 7,
            executableFileID: 7_001,
            executableByteCount: 4_096,
            executableSHA256: String(repeating: "a", count: 64),
            architecture: .arm64,
            machOUUID: UUID(uuidString: "11111111-2222-3333-4444-555555555555"),
            codeIdentity: nil
        ))
        return DebuggerSessionTargetAuthority(origin: .attached(identity))
    }

    private func markers(from wire: Data) throws -> LLDBCLIExchangeMarkers {
        let line = try XCTUnwrap(wireLines(wire).first)
        let marker = try decodedMarker(from: line)
        let prefix = "__MACSCOPE_LLDB_REQUEST_BEGIN_"
        let suffix = "__"
        guard marker.hasPrefix(prefix), marker.hasSuffix(suffix) else {
            throw TestFailure.invalidWire
        }
        let start = marker.index(marker.startIndex, offsetBy: prefix.count)
        let end = marker.index(marker.endIndex, offsetBy: -suffix.count)
        return try LLDBCLIExchangeMarkers(token: String(marker[start..<end]))
    }

    private func decodedMarker(from line: String) throws -> String {
        let prefix = "script print(__import__('base64').b64decode('"
        let suffix = "').decode('ascii'))"
        guard line.hasPrefix(prefix), line.hasSuffix(suffix) else {
            throw TestFailure.invalidWire
        }
        let start = line.index(line.startIndex, offsetBy: prefix.count)
        let end = line.index(line.endIndex, offsetBy: -suffix.count)
        guard let data = Data(base64Encoded: String(line[start..<end])),
              let marker = String(data: data, encoding: .ascii) else {
            throw TestFailure.invalidWire
        }
        return marker
    }

    private func decodedWireProgram(from line: String) throws -> String {
        let prefix = "script exec(__import__('base64').b64decode('"
        let suffix = "').decode('utf-8'))"
        guard line.hasPrefix(prefix), line.hasSuffix(suffix) else {
            throw TestFailure.invalidWire
        }
        let start = line.index(line.startIndex, offsetBy: prefix.count)
        let end = line.index(line.endIndex, offsetBy: -suffix.count)
        guard let data = Data(base64Encoded: String(line[start..<end])),
              let program = String(data: data, encoding: .utf8) else {
            throw TestFailure.invalidWire
        }
        return program
    }

    private func wireLines(_ data: Data) -> [String] {
        String(data: data, encoding: .utf8)?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init) ?? []
    }

    private func framedResponse(
        markers: LLDBCLIExchangeMarkers,
        console: String = "",
        commandTranscripts: [String] = [""],
        firstFailedCommandIndex: Int? = nil,
        status: String
    ) -> Data {
        let resultLines = commandTranscripts.enumerated().map { index, transcript in
            let encoded = Data(transcript.utf8).base64EncodedString()
            return "\(markers.commandResultPrefix)\(index)_\(encoded)__"
        }
        let commandStatusLine = firstFailedCommandIndex.map {
            markers.commandsFailedLine(firstFailedCommandIndex: $0)
        } ?? markers.commandsSucceededLine
        let encodedStatus = Data(status.utf8).base64EncodedString()
        let statusResultLine = "\(markers.statusResultPrefix)\(encodedStatus)__"
        return Data(
            ([markers.requestBeginLine]
                + (console.isEmpty ? [] : [console])
                + resultLines
                + [
                    commandStatusLine,
                    markers.statusBeginLine,
                    statusResultLine,
                    markers.statusEndLine,
                    markers.requestEndLine,
                ])
                .joined(separator: "\n")
                .appending("\n")
                .utf8
        )
    }

    private func adapterFailure(
        from task: Task<PersistentLLDBCLIResponse, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> PersistentLLDBCLIAdapterFailure {
        do {
            _ = try await task.value
            XCTFail("Expected adapter failure.", file: file, line: line)
            return PersistentLLDBCLIAdapterFailure(
                code: .staleGeneration,
                requestID: nil,
                generation: 0,
                disposition: .failedBeforeWrite
            )
        } catch let failure as PersistentLLDBCLIAdapterFailure {
            return failure
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
            return PersistentLLDBCLIAdapterFailure(
                code: .staleGeneration,
                requestID: nil,
                generation: 0,
                disposition: .failedBeforeWrite
            )
        }
    }

    private func assertEventually(
        _ predicate: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<500 {
            if await predicate() { return }
            try await ContinuousClock().sleep(for: .milliseconds(1))
        }
        XCTFail("Condition was not reached.", file: file, line: line)
    }
}

private enum TestFailure: Error {
    case invalidWire
}

private actor AdapterByteChannel: PersistentLLDBCLIByteChannel {
    private(set) var writes: [Data] = []
    private(set) var closedInputCount = 0
    private(set) var closedHandleCount = 0
    private var reads: [Result<Data?, Error>] = []
    private var readWaiters: [CheckedContinuation<Data?, Error>] = []

    var writeCount: Int { writes.count }

    func write(_ data: Data) async throws {
        writes.append(data)
    }

    func nextBytes() async throws -> Data? {
        if !reads.isEmpty {
            return try reads.removeFirst().get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            readWaiters.append(continuation)
        }
    }

    func closeInput() async {
        closedInputCount += 1
    }

    func closeHandles() async {
        closedHandleCount += 1
    }

    func feed(_ data: Data) {
        deliver(.success(data))
    }

    func finish() {
        deliver(.success(nil))
    }

    func waitForWrite(at index: Int) async throws -> Data {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        repeat {
            if writes.indices.contains(index) { return writes[index] }
            try await clock.sleep(for: .milliseconds(1))
        } while clock.now < deadline
        throw TestFailure.invalidWire
    }

    private func deliver(_ result: Result<Data?, Error>) {
        if readWaiters.isEmpty {
            reads.append(result)
        } else {
            readWaiters.removeFirst().resume(with: result)
        }
    }
}

private actor AdapterManualClock: PersistentLLDBCLIClock {
    private var sleepers: [CheckedContinuation<Void, Error>] = []

    func sleep(for duration: Duration) async throws {
        _ = duration
        try await withCheckedThrowingContinuation { continuation in
            sleepers.append(continuation)
        }
    }

    func waitForSleeper() async throws {
        for _ in 0..<500 {
            if !sleepers.isEmpty { return }
            await Task.yield()
        }
        throw TestFailure.invalidWire
    }

    func fireAll() {
        let current = sleepers
        sleepers.removeAll()
        current.forEach { $0.resume() }
    }
}

private actor AdapterRetainedProcess: PersistentLLDBCLIRetainedProcess {
    enum Call: Equatable {
        case wait(Duration)
        case terminateRetainedAdapter
        case killRetainedAdapterIfStillRunning
        case reapAndClose
    }

    private(set) var calls: [Call] = []
    private var waitResults: [Bool]

    init(waitResults: [Bool]) {
        self.waitResults = waitResults
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
        return true
    }
}
