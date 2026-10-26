import Foundation
import XCTest
@testable import MacScope

/// Thread-header parsing over real Xcode LLDB transcripts (`GoldenFixtures/lldb-thread-list`).
/// Production installs colon-style `thread-format` / `thread-stop-format`
/// (`DebuggerLLDBSealedLaunchPlan`), so the persistent stopped refresh (`thread list`,
/// `thread backtrace`, …) never contains the comma-style header; before this parser accepted
/// `thread #N:` every production stop projected an empty thread list.
@MainActor
final class DebuggerThreadListParserFixtureTests: XCTestCase {
    private static let fixtureDirectory = TestSourceRoot.fileURL(#filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("GoldenFixtures/lldb-thread-list")

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: Self.fixtureDirectory.appendingPathComponent(name), encoding: .utf8)
    }

    func testProductionFormatStoppedRefreshParsesBothThreads() throws {
        let transcript = try fixture("production-format-stopped-refresh.txt")

        let threads = XcodeLLDBCommandLineAdapter.parseThreadSummaries(from: transcript)

        XCTAssertEqual(threads, [
            DebuggerThreadSummary(
                tid: 0x341736,
                index: 1,
                queueName: nil,
                stopReason: .breakpoint(address: 0x0000000100000418),
                isSelected: true,
                topFrameAddress: 0x0000000100000418,
                // `thread backtrace`'s frame #0 wins; arguments are display noise.
                topFrameFunctionName: "parse_header"
            ),
            DebuggerThreadSummary(
                tid: 0x341747,
                index: 2,
                queueName: nil,
                stopReason: nil,
                isSelected: false,
                topFrameAddress: 0x0000000191833308,
                topFrameFunctionName: nil
            )
        ])
    }

    func testNamedThreadFormatCarriesPthreadNamesAndTopFrameFunctions() throws {
        let transcript = try fixture("production-format-named-threads.txt")

        let threads = XcodeLLDBCommandLineAdapter.parseThreadSummaries(from: transcript)

        XCTAssertEqual(threads.map(\.index), [1, 2, 3, 4])
        XCTAssertEqual(threads.map(\.name), [nil, "macscope.worker.1", "macscope.worker.2", "macscope.worker.3"])
        XCTAssertEqual(threads.map(\.topFrameFunctionName),
                       ["__ulock_wait", "__semwait_signal", "__semwait_signal", "rendezvous"],
                       "a non-current thread names its top frame, not just its PC")
        XCTAssertEqual(threads.map(\.isSelected), [false, false, false, true])

        let data = try XCTUnwrap(PersistentLLDBProductionRequestPreparer.makeStoppedData(from: transcript))
        guard case .available(let stopped) = data.threads else { return XCTFail("threads unavailable") }
        XCTAssertEqual(stopped.map(\.name), [nil, "macscope.worker.1", "macscope.worker.2", "macscope.worker.3"])
    }

    func testDebuggeeChosenThreadNamesWithQuotesOrStopReasonTextParseIntact() {
        // Lead note on #487: a debuggee names its own threads, so a name may hold `'` or the
        // text of a stop reason. Neither may truncate the name or invent a stop.
        let transcript = """
          thread #1: tid = 0x11, 0x0000000191831af4 libsystem_kernel.dylib`__ulock_wait, name = 'it's here'
          thread #2: tid = 0x12, 0x0000000191833308 libsystem_kernel.dylib`__semwait_signal, name = 'evil, stop reason = breakpoint 1.1'
        * thread #3: tid = 0x13, 0x0000000100000558 threads`rendezvous, name = 'plain', stop reason = breakpoint 1.1
          thread #4: tid = 0x14, 0x0000000191833308 libsystem_kernel.dylib`__semwait_signal, name = 'w', queue = 'com.example.q'
        """

        let threads = XcodeLLDBCommandLineAdapter.parseThreadSummaries(from: transcript)

        XCTAssertEqual(threads.map(\.name), ["it's here", "evil, stop reason = breakpoint 1.1", "plain", "w"])
        XCTAssertEqual(threads.map { $0.stopReason == nil }, [true, true, false, true],
                       "a stop reason spelled inside a name is not a stop")
        XCTAssertEqual(threads.map(\.queueName), [nil, nil, nil, "com.example.q"])
    }

    func testProductionFormatStoppedRefreshProjectsSelectedThreadWithTID() throws {
        let transcript = try fixture("production-format-stopped-refresh.txt")

        let data = try XCTUnwrap(PersistentLLDBProductionRequestPreparer.makeStoppedData(from: transcript))

        guard case .available(let threads) = data.threads else {
            return XCTFail("threads unavailable")
        }
        XCTAssertEqual(threads.map(\.identifier), [1, 2])
        XCTAssertEqual(threads.map(\.threadID), [0x341736, 0x341747])
        XCTAssertEqual(threads.map(\.isSelected), [true, false])
        XCTAssertEqual(data.selectedThreadID, 1)
        XCTAssertEqual(data.currentProgramCounter, 0x0000000100000418)
    }

    func testDefaultFormatThreadListParsesQueueTopFrameAndSelection() throws {
        let transcript = try fixture("default-format-thread-list.txt")

        let threads = XcodeLLDBCommandLineAdapter.parseThreadSummaries(from: transcript)

        XCTAssertEqual(threads.map(\.tid), [0x3415c5, 0x3415dd])
        XCTAssertEqual(XcodeLLDBCommandLineAdapter.parseThreadList(from: transcript).map(\.tid),
                       [0x3415c5, 0x3415dd])
        XCTAssertNil(XcodeLLDBCommandLineAdapter.parseThreadIdentityDiagnostic(from: transcript))
        XCTAssertEqual(threads.map(\.index), [1, 2])
        XCTAssertEqual(threads.map(\.isSelected), [true, false])
        XCTAssertEqual(threads.map(\.queueName), ["com.apple.main-thread", nil])
        XCTAssertEqual(threads.map(\.topFrameAddress), [0x0000000100000418, 0x0000000191833308])
        XCTAssertEqual(threads.map(\.topFrameFunctionName), ["parse_header", "__semwait_signal"])
    }

    func testSummaryIdentityCarriesTIDAcrossRepeatedHeadersAndProjection() throws {
        let transcript = """
        * thread #1: tid = 0x63, 0x1000 demo`parse_header(x=3)
        * thread #1, queue = 'worker tid = 123'
          frame #0: 0x1000 demo`parse_header(x=3) at demo.c:4
          thread #2: tid = 123, 0x2000
        """
        let summaries = XcodeLLDBCommandLineAdapter.parseThreadSummaries(from: transcript)
        XCTAssertEqual(summaries.map(\.tid), [99, 123])
        XCTAssertEqual(XcodeLLDBCommandLineAdapter.parseThreadList(from: transcript).map(\.tid), [99, 123])
        XCTAssertNil(XcodeLLDBCommandLineAdapter.parseThreadIdentityDiagnostic(from: transcript))
        let identity = try XCTUnwrap(DebuggerThreadIdentity(summary: summaries[0]))
        XCTAssertEqual(identity.tid, 99)
        XCTAssertNotNil(identity.uniqueNameDigest)
        var state = DebuggerReducerState(epoch: DebuggerSessionEpoch(), capabilities: .persistentCLI(attachPolicyReason: "fixture"))
        state.processPhase = .stopped(processID: 42, reason: .userRequested)
        state.stoppedData = try XCTUnwrap(PersistentLLDBProductionRequestPreparer.makeStoppedData(from: transcript))
        let projected = DebuggerTransportSnapshotProjector.project(state)
        XCTAssertEqual(projected.threads.map(\.tid), [99, 123])
        XCTAssertEqual(DebuggerThreadIdentity(summary: projected.threads[0]), identity)
        var invalid = summaries[0]
        invalid.tid = 0
        XCTAssertNil(DebuggerThreadIdentity(summary: invalid))
    }

    func testTIDRequiresCompleteFirstStructuralFieldAndPreservesUnknownTID() throws {
        let transcript = """
        * thread #1: tid = 0X63, queue = 'worker tid = 123'
          thread #2: tid = 123
          thread #3: queue = 'worker tid = 456', tid = 789
          thread #4, tid = 456
          thread #5: name = "tid = 456"
          thread #6: tid = 123garbage, 0x1000
          thread #7: tid = 0x63junk, 0x1000
          thread #8: tid = 0, 0x1000
          thread #9: tid = 18446744073709551616, 0x1000
          thread #10: tid = 0x10000000000000000, 0x1000
          thread #11: tid = 99, 0x1000
          thread #11: queue = 'worker tid = 123'
        """
        let expected: [UInt64?] = [99, 123, nil, nil, nil, nil, nil, nil, nil, nil, 99]
        let summaries = XcodeLLDBCommandLineAdapter.parseThreadSummaries(from: transcript)
        XCTAssertEqual(summaries.map(\.tid), expected)
        XCTAssertEqual(XcodeLLDBCommandLineAdapter.parseThreadList(from: transcript).map(\.tid), expected)
        XCTAssertNil(XcodeLLDBCommandLineAdapter.parseThreadIdentityDiagnostic(from: transcript))
        let data = try XCTUnwrap(PersistentLLDBProductionRequestPreparer.makeStoppedData(from: transcript))
        guard case .available(let threads) = data.threads else { return XCTFail("threads unavailable") }
        XCTAssertEqual(threads.map(\.threadID), expected)
        // Missing TID still uses the existing honest unknown-TID identity contract.
        XCTAssertNil(try XCTUnwrap(DebuggerThreadIdentity(summary: summaries[2])).tid)
    }

    func testConflictingStructuralTIDsFailClosedThroughProductionProjectionWithDiagnostic() throws {
        let transcript = """
        Process 42 stopped
        * thread #1: tid = 0x63, 0x1000
        * thread #1: tid = 100, 0x1000
        * thread #1: tid = 99, queue = 'worker tid = 456'
          thread #2: tid = 200, 0x2000
          frame #0: 0x1000 demo`main
        """
        let summaries = XcodeLLDBCommandLineAdapter.parseThreadSummaries(from: transcript)
        XCTAssertFalse(summaries.contains { $0.index == 1 })
        XCTAssertEqual(summaries.map(\.tid), [200])
        XCTAssertEqual(XcodeLLDBCommandLineAdapter.parseThreadList(from: transcript).map(\.index), [2])
        let diagnostic = try XCTUnwrap(XcodeLLDBCommandLineAdapter.parseThreadIdentityDiagnostic(from: transcript))
        XCTAssertTrue(diagnostic.contains("Conflicting structural TIDs for thread #1"))
        XCTAssertFalse(diagnostic.contains("worker"))
        XCTAssertEqual(XcodeLLDBCommandLineAdapter.parseBatchLaunchTranscript(from: transcript).diagnosticSummary, diagnostic)
        let data = try XCTUnwrap(PersistentLLDBProductionRequestPreparer.makeStoppedData(from: transcript))
        XCTAssertEqual(data.threads, .unavailable)
        XCTAssertNil(data.selectedThreadID)
        XCTAssertEqual(data.threadIdentityDiagnostic, diagnostic)
        var state = DebuggerReducerState(epoch: DebuggerSessionEpoch(), capabilities: .persistentCLI(attachPolicyReason: "fixture"))
        state.processPhase = .stopped(processID: 42, reason: .userRequested)
        state.stoppedData = data
        let projected = DebuggerTransportSnapshotProjector.project(state)
        XCTAssertTrue(projected.threads.isEmpty)
        XCTAssertTrue(projected.threads.compactMap(DebuggerThreadIdentity.init(summary:)).isEmpty)
        XCTAssertEqual(projected.transportDiagnostic?.code, .protocolViolation)
        XCTAssertEqual(projected.transportDiagnostic?.preview, diagnostic)
    }

    func testConflictOnlyRefreshClearsInheritedThreadIdentity() throws {
        let transcript = """
        Process 42 stopped
        * thread #1: tid = 99
        * thread #1: tid = 100
        """
        var previous = DebuggerSessionSnapshot.empty
        previous.processState = .paused(processID: 42, reason: .userRequested)
        previous.threads = XcodeLLDBCommandLineAdapter.parseThreadSummaries(from: "* thread #1: tid = 99")
        let refreshed = XcodeLLDBCommandLineAdapter.makeLiveControlSnapshot(
            previousSnapshot: previous,
            commandDisplay: "thread list",
            response: DebuggerLLDBCommandResponse(command: "thread list", standardOutput: transcript),
            fallbackProcessID: 42,
            fallbackExecutableName: "fixture",
            breakpoints: [],
            successStatus: "Refreshed",
            timeoutStatus: "Timed out"
        )
        XCTAssertTrue(refreshed.threads.isEmpty)
        XCTAssertTrue(try XCTUnwrap(refreshed.lastCommandRun?.diagnosticSummary).contains("Conflicting structural TIDs"))
        let data = try XCTUnwrap(PersistentLLDBProductionRequestPreparer.makeStoppedData(from: transcript))
        XCTAssertEqual(data.threads, .unavailable)
        XCTAssertNotNil(data.threadIdentityDiagnostic)
    }

    func testEquivalentRepeatedStructuralTIDsAndNewStopDoNotConflict() throws {
        let transcript = """
        * thread #1: tid = 0x63, 0x1000
        * thread #1: tid = 99, 0x1000
        """
        XCTAssertEqual(XcodeLLDBCommandLineAdapter.parseThreadSummaries(from: transcript).first?.tid, 99)
        XCTAssertNil(XcodeLLDBCommandLineAdapter.parseThreadIdentityDiagnostic(from: transcript))
        let nextStop = "* thread #1: tid = 100, 0x1000"
        XCTAssertEqual(XcodeLLDBCommandLineAdapter.parseThreadSummaries(from: nextStop).first?.tid, 100)
        XCTAssertNil(XcodeLLDBCommandLineAdapter.parseThreadIdentityDiagnostic(from: nextStop))
    }

    func testFrameDisplayNamesStripNestedArgumentsWithoutDamagingCallOperators() {
        let frames = XcodeLLDBCommandLineAdapter.parseFrameSummaries(from: """
        frame #0: 0x1000 demo`parse_header(x=(3), text="(") + 8 at demo.c:4
        frame #1: 0x2000 demo`Parser::operator()(int) + 4
        frame #2: 0x3000 demo`Parser::operator() + 4
        frame #3: 0x4000 demo`plain + 4
        """)
        XCTAssertEqual(frames.map(\.functionName), ["parse_header", "Parser::operator()", "Parser::operator()", "plain"])
        XCTAssertEqual(frames[0].sourceLocation, "demo.c:4")
    }


    /// Lane AQ (Tier 2k C6): real 4-thread production refresh after selecting a thread that is
    /// not the stop thread. The selection, its TID, the frames, the registers and the current PC
    /// must all describe the selected thread (#1), never the breakpoint thread (#4); otherwise the
    /// variable extractor's exact frame check fails the coordinator.
    func testFourThreadRefreshAfterSelectingNonStopThreadProjectsOneCoherentThread() throws {
        let transcript = try fixture("production-format-four-thread-selected-non-stop-thread.txt")

        let data = try XCTUnwrap(PersistentLLDBProductionRequestPreparer.makeStoppedData(from: transcript))

        guard case .available(let threads) = data.threads,
              case .available(let frames) = data.frames,
              case .available(let registers) = data.registers else {
            return XCTFail("stopped data unavailable")
        }
        XCTAssertNil(data.threadIdentityDiagnostic)
        XCTAssertEqual(threads.map(\.identifier), [1, 2, 3, 4])
        XCTAssertEqual(threads.map(\.threadID), [0x5b7167, 0x5b738a, 0x5b738b, 0x5b738c])
        XCTAssertEqual(threads.map(\.isSelected), [true, false, false, false])
        XCTAssertEqual(threads.map(\.topFrameAddress), [
            0x0000000191831af4, 0x0000000191833308, 0x0000000191833308, 0x0000000100000548,
        ])
        XCTAssertNil(threads[0].stopReason)
        XCTAssertNotNil(threads[3].stopReason, "the breakpoint thread keeps its stop reason")
        XCTAssertEqual(data.selectedThreadID, 1)
        XCTAssertEqual(frames.map(\.identifier), [0, 1, 2, 3])
        XCTAssertEqual(frames.first?.address, 0x0000000191831af4)
        XCTAssertTrue(try XCTUnwrap(frames.first?.functionName).contains("__ulock_wait"))
        XCTAssertEqual(data.selectedFrameID, 0)
        XCTAssertEqual(data.currentProgramCounter, threads[0].topFrameAddress)
        XCTAssertTrue(
            try XCTUnwrap(registers.first(where: { $0.name == "pc" })?.value).contains("191831af4")
        )
    }

}
