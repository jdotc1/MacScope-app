import Foundation
import XCTest
@testable import MacScope

final class DebuggerCLITranscriptDecoderTests: XCTestCase {
    private static let token = String(repeating: "a", count: 64)

    func testMarkersRequireUnpredictableCanonicalTokenAndCommandIsByteBounded() throws {
        let markers = try LLDBCLIExchangeMarkers(token: Self.token)

        XCTAssertEqual(
            markers.requestBeginLine,
            "__MACSCOPE_LLDB_REQUEST_BEGIN_\(Self.token)__"
        )
        XCTAssertEqual(
            markers.statusBeginLine,
            "__MACSCOPE_LLDB_STATUS_BEGIN_\(Self.token)__"
        )
        XCTAssertEqual(
            markers.statusResultPrefix,
            "__MACSCOPE_LLDB_STATUS_RESULT_\(Self.token)_"
        )
        XCTAssertEqual(
            markers.statusEndLine,
            "__MACSCOPE_LLDB_STATUS_END_\(Self.token)__"
        )
        XCTAssertEqual(
            markers.requestEndLine,
            "__MACSCOPE_LLDB_REQUEST_END_\(Self.token)__"
        )

        XCTAssertThrowsError(try LLDBCLIExchangeMarkers(token: "short"))
        XCTAssertThrowsError(
            try LLDBCLIExchangeMarkers(token: String(repeating: "A", count: 64))
        )
        XCTAssertNoThrow(
            try LLDBCLITranscriptDecoder.validateRenderedCommand(
                String(repeating: "x", count: LLDBCLITranscriptDecoder.maximumCommandBytes)
            )
        )
        XCTAssertThrowsError(
            try LLDBCLITranscriptDecoder.validateRenderedCommand(
                String(repeating: "x", count: LLDBCLITranscriptDecoder.maximumCommandBytes + 1)
            )
        )
        XCTAssertThrowsError(
            try LLDBCLITranscriptDecoder.validateRenderedCommand("process status\nquit")
        )
    }

    func testRenderedCommandRejectsEveryC0AndDELControlByte() {
        let controlBytes = Array(UInt8(0x00)...UInt8(0x1f)) + [UInt8(0x7f)]

        for byte in controlBytes {
            let scalar = UnicodeScalar(Int(byte))!
            let command = "process status\(Character(scalar))"
            XCTAssertThrowsError(
                try LLDBCLITranscriptDecoder.validateRenderedCommand(command),
                "Control byte 0x\(String(format: "%02x", byte)) must be rejected."
            )
        }
    }

    func testCoalescedExactMarkerPairReturnsOnlyFramedTranscriptAndObservedPID() throws {
        let markers = try LLDBCLIExchangeMarkers(token: Self.token)
        var decoder = LLDBCLITranscriptDecoder(
            markers: markers,
            observedPIDRequirement: .required
        )
        let bytes = Data(
            "lldb preamble\n\(markers.requestBeginLine)\nframe #0: main\n\(markers.statusBeginLine)\n\(statusResultLine(markers: markers, status: "Process 42 stopped"))\n\(markers.statusEndLine)\n\(markers.requestEndLine)\n(lldb) ".utf8
        )

        let result = try XCTUnwrap(try decoder.append(bytes))

        XCTAssertEqual(result.transcript, "frame #0: main")
        XCTAssertEqual(result.authoritativeStatusTranscript, "Process 42 stopped")
        XCTAssertEqual(result.observedProcessID, 42)
        XCTAssertEqual(result.observedProcessState, .stopped(processID: 42))
        XCTAssertEqual(result.exchangeByteCount, bytes.count)
        XCTAssertEqual(result.exchangeSHA256.count, 64)
    }

    func testFragmentedMarkersAndUTF8PayloadCompleteIncrementally() throws {
        let markers = try LLDBCLIExchangeMarkers(token: Self.token)
        var decoder = LLDBCLITranscriptDecoder(
            markers: markers,
            observedPIDRequirement: .required
        )
        let exchange = Data(
            "\(markers.requestBeginLine)\nreason: café\n\(markers.statusBeginLine)\n\(statusResultLine(markers: markers, status: "Process 77 running"))\n\(markers.statusEndLine)\n\(markers.requestEndLine)\n".utf8
        )

        for byte in exchange.dropLast() {
            XCTAssertNil(try decoder.append(Data([byte])))
        }
        XCTAssertNotNil(try decoder.append(Data(exchange.suffix(1))))

        let result = try decoder.finish()
        XCTAssertEqual(result.transcript, "reason: café")
        XCTAssertEqual(result.authoritativeStatusTranscript, "Process 77 running")
        XCTAssertEqual(result.observedProcessID, 77)
        XCTAssertEqual(result.observedProcessState, .running(processID: 77))
    }

    /// Captured from the production thread-2 / sleep(600) sequence on 2026-10-13.
    /// The selected thread was __semwait_signal before Continue; interrupt stopped thread 1.
    /// PID, TID, addresses and the secret marker token are normalized fixture identities.
    func testCapturedInterruptAfterSelectingSleepingThreadAndAmbiguousVariants() throws {
        let markers = try LLDBCLIExchangeMarkers(token: Self.token)
        let status = """
        Process 303 stopped
        * thread #1: tid = 0x123, stop reason = signal SIGSTOP
              frame #0: 0x0000000191831af4 libsystem_kernel.dylib`__ulock_wait + 8
        libsystem_kernel.dylib`__ulock_wait:
        ->  0x191831af4 <+8>:  b.lo   0x191831b14               ; <+40>
            0x191831af8 <+12>: pacibsp
            0x191831afc <+16>: stp    x29, x30, [sp, #-0x10]!
            0x191831b00 <+20>: mov    x29, sp

        """
        func exchange(_ status: String) -> Data {
            Data([
                markers.requestBeginLine,
                "\(markers.commandResultPrefix)0___", // successful SBProcess.Stop: empty output
                markers.commandsSucceededLine,
                markers.statusBeginLine,
                statusResultLine(markers: markers, status: status),
                markers.statusEndLine,
                markers.requestEndLine,
                "",
            ].joined(separator: "\n").utf8)
        }
        func decoder() -> LLDBCLITranscriptDecoder {
            LLDBCLITranscriptDecoder(
                markers: markers,
                observedPIDRequirement: .required,
                requiresSemanticCommandStatus: true,
                expectedSemanticCommandCount: 1
            )
        }
        var valid = decoder()
        let result = try XCTUnwrap(try valid.append(exchange(status)))
        XCTAssertEqual(result.observedProcessState, .stopped(processID: 303))
        XCTAssertEqual(result.authoritativeStatusTranscript, status)
        XCTAssertEqual(result.semanticCommandTranscripts, [""])

        for (suffix, code) in [
            ("Process 303 running\n", LLDBCLITranscriptDiagnosticCode.ambiguousObservedProcessState),
            ("Process 304 stopped\n", .ambiguousObservedPID),
        ] {
            var ambiguous = decoder()
            assertFailure(code) { _ = try ambiguous.append(exchange(status + suffix)) }
        }
    }

    func testObservedStatusAcceptsActualLLDBIsRunningForms() throws {
        let markers = try LLDBCLIExchangeMarkers(token: Self.token)
        let statusLines = [
            "Process 77 is running",
            "Process #77 is running.",
            "process 77 IS RUNNING",
        ]

        for status in statusLines {
            var decoder = LLDBCLITranscriptDecoder(
                markers: markers,
                observedPIDRequirement: .required
            )
            let exchange = Data(
                    "\(markers.requestBeginLine)\n"
                    .appending("\(markers.statusBeginLine)\n")
                    .appending("\(statusResultLine(markers: markers, status: status))\n")
                    .appending("\(markers.statusEndLine)\n")
                    .appending("\(markers.requestEndLine)\n")
                    .utf8
            )

            let result = try XCTUnwrap(try decoder.append(exchange))
            XCTAssertEqual(result.observedProcessID, 77, status)
            XCTAssertEqual(result.observedProcessState, .running(processID: 77), status)
        }
    }

    func testLargeExchangeCanArriveOneByteAtATimeWithoutLosingCursorState() throws {
        let markers = try LLDBCLIExchangeMarkers(token: Self.token)
        var decoder = LLDBCLITranscriptDecoder(
            markers: markers,
            observedPIDRequirement: .required
        )
        let console = String(repeating: "0123456789abcdef", count: 1_024)
        let exchange = Data(
            "\(markers.requestBeginLine)\n\(console)\n\(markers.statusBeginLine)\n\(statusResultLine(markers: markers, status: "Process 88 stopped"))\n\(markers.statusEndLine)\n\(markers.requestEndLine)\n".utf8
        )
        var completed: LLDBCLITranscriptResult?

        for byte in exchange {
            if let result = try decoder.append(Data([byte])) {
                completed = result
            }
        }

        let result = try XCTUnwrap(completed)
        XCTAssertEqual(result.transcript, console)
        XCTAssertEqual(result.observedProcessState, .stopped(processID: 88))
    }

    func testForeignAndEmbeddedMarkerFamilyTextFailClosed() throws {
        let markers = try LLDBCLIExchangeMarkers(token: Self.token)
        let foreign = try LLDBCLIExchangeMarkers(token: String(repeating: "b", count: 64))
        let cases = [
            "\(foreign.requestBeginLine)\ntext\n\(markers.requestEndLine)\n",
            "prefix \(markers.requestBeginLine) suffix\ntext\n\(markers.requestEndLine)\n",
            "\(markers.requestBeginLine)\nscript print(\"\(markers.statusBeginLine)\")\n"
        ]

        for exchange in cases {
            var decoder = LLDBCLITranscriptDecoder(markers: markers)
            assertFailure(.ambiguousMarker) {
                _ = try decoder.append(Data(exchange.utf8))
                _ = try decoder.finish()
            }
        }
    }

    func testDuplicateNestedAndReversedMarkersFailClosed() throws {
        let markers = try LLDBCLIExchangeMarkers(token: Self.token)
        let cases = [
            "\(markers.requestBeginLine)\n\(markers.requestBeginLine)\n\(markers.statusBeginLine)\n\(markers.statusEndLine)\n\(markers.requestEndLine)\n",
            "\(markers.requestBeginLine)\n\(markers.statusBeginLine)\n\(markers.statusBeginLine)\n\(markers.statusEndLine)\n\(markers.requestEndLine)\n",
            "\(markers.requestBeginLine)\n\(markers.statusEndLine)\n\(markers.statusBeginLine)\n\(markers.requestEndLine)\n",
            "\(markers.requestBeginLine)\n\(markers.statusBeginLine)\n\(markers.requestEndLine)\n\(markers.statusEndLine)\n",
            "\(markers.requestEndLine)\n\(markers.requestBeginLine)\n",
            "\(markers.requestBeginLine)\n\(markers.statusBeginLine)\n\(statusResultLine(markers: markers, status: ""))\n\(markers.statusEndLine)\n\(markers.requestEndLine)\n\(markers.requestEndLine)\n"
        ]

        for exchange in cases {
            var decoder = LLDBCLITranscriptDecoder(markers: markers)
            assertFailure(.markerOrderViolation) {
                _ = try decoder.append(Data(exchange.utf8))
                _ = try decoder.finish()
            }
        }
    }

    func testFinishRejectsMissingBeginOrEndMarker() throws {
        let markers = try LLDBCLIExchangeMarkers(token: Self.token)

        var missingBegin = LLDBCLITranscriptDecoder(markers: markers)
        _ = try missingBegin.append(Data("ordinary output\n".utf8))
        assertFailure(.missingRequestBeginMarker) {
            _ = try missingBegin.finish()
        }

        var missingEnd = LLDBCLITranscriptDecoder(markers: markers)
        _ = try missingEnd.append(
            Data(
                "\(markers.requestBeginLine)\nordinary output\n\(markers.statusBeginLine)\n\(statusResultLine(markers: markers, status: "no process"))\n\(markers.statusEndLine)\n".utf8
            )
        )
        assertFailure(.missingRequestEndMarker) {
            _ = try missingEnd.finish()
        }
    }

    func testMissingStatusMarkersFailClosed() throws {
        let markers = try LLDBCLIExchangeMarkers(token: Self.token)

        var missingBegin = LLDBCLITranscriptDecoder(markers: markers)
        assertFailure(.missingStatusBeginMarker) {
            _ = try missingBegin.append(
                Data("\(markers.requestBeginLine)\noutput\n\(markers.requestEndLine)\n".utf8)
            )
            _ = try missingBegin.finish()
        }

        var missingEnd = LLDBCLITranscriptDecoder(markers: markers)
        _ = try missingEnd.append(
            Data(
                "\(markers.requestBeginLine)\noutput\n\(markers.statusBeginLine)\n\(statusResultLine(markers: markers, status: "no process"))\n".utf8
            )
        )
        assertFailure(.missingStatusEndMarker) {
            _ = try missingEnd.finish()
        }
    }

    func testStatusResultIsMandatoryUniqueAndCanonical() throws {
        let markers = try LLDBCLIExchangeMarkers(token: Self.token)

        var missing = LLDBCLITranscriptDecoder(markers: markers)
        assertFailure(.missingStatusResultMarker) {
            _ = try missing.append(
                Data(
                    "\(markers.requestBeginLine)\n\(markers.statusBeginLine)\n"
                        .appending("async stop notice\n")
                        .appending("\(markers.statusEndLine)\n\(markers.requestEndLine)\n")
                        .utf8
                )
            )
        }

        let valid = statusResultLine(markers: markers, status: "Process 42 stopped")
        var duplicate = LLDBCLITranscriptDecoder(markers: markers)
        assertFailure(.invalidStatusResultMarker) {
            _ = try duplicate.append(
                Data(
                    "\(markers.requestBeginLine)\n\(markers.statusBeginLine)\n"
                        .appending("\(valid)\n\(valid)\n")
                        .appending("\(markers.statusEndLine)\n\(markers.requestEndLine)\n")
                        .utf8
                )
            )
        }

        var malformed = LLDBCLITranscriptDecoder(markers: markers)
        assertFailure(.invalidStatusResultMarker) {
            _ = try malformed.append(
                Data(
                    "\(markers.requestBeginLine)\n\(markers.statusBeginLine)\n"
                        .appending("\(markers.statusResultPrefix)not-base64__\n")
                        .appending("\(markers.statusEndLine)\n\(markers.requestEndLine)\n")
                        .utf8
                )
            )
        }
    }

    func testExchangeBoundAcceptsExactLimitAndRejectsOneAdditionalByte() throws {
        let markers = try LLDBCLIExchangeMarkers(token: Self.token)
        let overhead = markers.requestBeginLine.utf8.count
            + markers.statusBeginLine.utf8.count
            + statusResultLine(markers: markers, status: "").utf8.count
            + markers.statusEndLine.utf8.count
            + markers.requestEndLine.utf8.count
            + 6
        let payloadCount = LLDBCLITranscriptDecoder.maximumExchangeBytes - overhead
        let exactExchange =
            "\(markers.requestBeginLine)\n"
            + String(repeating: "x", count: payloadCount)
            + "\n\(markers.statusBeginLine)\n\(statusResultLine(markers: markers, status: ""))\n\(markers.statusEndLine)\n\(markers.requestEndLine)\n"
        XCTAssertEqual(exactExchange.utf8.count, LLDBCLITranscriptDecoder.maximumExchangeBytes)

        var exactDecoder = LLDBCLITranscriptDecoder(markers: markers)
        XCTAssertNotNil(try exactDecoder.append(Data(exactExchange.utf8)))

        var oversizedDecoder = LLDBCLITranscriptDecoder(markers: markers)
        assertFailure(.exchangeTooLarge) {
            _ = try oversizedDecoder.append(
                Data(repeating: 0x78, count: LLDBCLITranscriptDecoder.maximumExchangeBytes + 1)
            )
        }
    }

    func testFailureDiagnosticIsTypedHashBackedAndFourKiBBounded() throws {
        let markers = try LLDBCLIExchangeMarkers(token: Self.token)
        var decoder = LLDBCLITranscriptDecoder(markers: markers)
        let input = Data(
            ("prefix \(markers.requestBeginLine) "
                + String(repeating: "secret", count: 2_000))
                .appending("\n")
                .utf8
        )

        do {
            _ = try decoder.append(input)
            XCTFail("Embedded marker must fail closed.")
        } catch let failure as LLDBCLITranscriptFailure {
            XCTAssertEqual(failure.code, .ambiguousMarker)
            XCTAssertLessThanOrEqual(
                failure.diagnostic.preview.utf8.count,
                LLDBCLITranscriptDecoder.maximumDiagnosticBytes
            )
            XCTAssertEqual(failure.diagnostic.evidenceSHA256.count, 64)
            XCTAssertEqual(failure.diagnostic.evidenceByteCount, input.count)
            XCTAssertFalse(failure.diagnostic.preview.contains("secretsecret"))
        }
    }

    func testRequiredObservedPIDRejectsMissingAndAmbiguousTranscripts() throws {
        let markers = try LLDBCLIExchangeMarkers(token: Self.token)

        var missing = LLDBCLITranscriptDecoder(
            markers: markers,
            observedPIDRequirement: .required
        )
        assertFailure(.missingObservedPID) {
            _ = try missing.append(
                Data(
                    "\(markers.requestBeginLine)\nProcess 999 stopped\n\(markers.statusBeginLine)\n\(statusResultLine(markers: markers, status: "process status unavailable"))\n\(markers.statusEndLine)\n\(markers.requestEndLine)\n".utf8
                )
            )
        }

        var ambiguous = LLDBCLITranscriptDecoder(
            markers: markers,
            observedPIDRequirement: .required
        )
        assertFailure(.ambiguousObservedPID) {
            _ = try ambiguous.append(
                Data(
                    "\(markers.requestBeginLine)\n\(markers.statusBeginLine)\n\(statusResultLine(markers: markers, status: "Process 101 running\nProcess 202 stopped"))\n\(markers.statusEndLine)\n\(markers.requestEndLine)\n".utf8
                )
            )
        }
    }

    func testRepeatedObservedPIDIsOneFactAndOptionalModeNeverFabricatesPID() throws {
        let markers = try LLDBCLIExchangeMarkers(token: Self.token)
        var repeated = LLDBCLITranscriptDecoder(
            markers: markers,
            observedPIDRequirement: .required
        )
        let repeatedResult = try XCTUnwrap(
            try repeated.append(
                Data(
                    "\(markers.requestBeginLine)\n\(markers.statusBeginLine)\n\(statusResultLine(markers: markers, status: "Process 303 stopped\nProcess 303 stopped"))\n\(markers.statusEndLine)\n\(markers.requestEndLine)\n".utf8
                )
            )
        )
        XCTAssertEqual(repeatedResult.observedProcessID, 303)
        XCTAssertEqual(repeatedResult.observedProcessState, .stopped(processID: 303))

        var optional = LLDBCLITranscriptDecoder(markers: markers)
        let optionalResult = try XCTUnwrap(
            try optional.append(
                Data(
                    "\(markers.requestBeginLine)\nno observed process identity\n\(markers.statusBeginLine)\n\(statusResultLine(markers: markers, status: "no process"))\n\(markers.statusEndLine)\n\(markers.requestEndLine)\n".utf8
                )
            )
        )
        XCTAssertNil(optionalResult.observedProcessID)
    }

    func testOnlyNestedStatusSegmentCanAuthorPIDAndProcessState() throws {
        let markers = try LLDBCLIExchangeMarkers(token: Self.token)
        var decoder = LLDBCLITranscriptDecoder(
            markers: markers,
            observedPIDRequirement: .required
        )
        let result = try XCTUnwrap(
            try decoder.append(
                Data(
                    "\(markers.requestBeginLine)\nProcess 701 stopped\nerror: Process 702 exited\n\(markers.statusBeginLine)\n\(statusResultLine(markers: markers, status: "Process 42 running"))\n\(markers.statusEndLine)\nProcess 703 stopped\n\(markers.requestEndLine)\n".utf8
                )
            )
        )

        XCTAssertEqual(
            result.transcript,
            "Process 701 stopped\nerror: Process 702 exited\nProcess 703 stopped"
        )
        XCTAssertEqual(result.observedProcessID, 42)
        XCTAssertEqual(result.observedProcessState, .running(processID: 42))
    }

    func testOnlyCorrelatedStatusResultAuthorsLifecycleWhileInterleavedLinesRemainConsole() throws {
        let markers = try LLDBCLIExchangeMarkers(token: Self.token)
        let encodedStatus = Data("Process 42 running".utf8).base64EncodedString()
        let statusResult = "__MACSCOPE_LLDB_STATUS_RESULT_\(Self.token)_\(encodedStatus)__"
        var decoder = LLDBCLITranscriptDecoder(
            markers: markers,
            observedPIDRequirement: .required
        )

        let result = try XCTUnwrap(
            try decoder.append(
                Data(
                    "\(markers.requestBeginLine)\n"
                        .appending("before status\n")
                        .appending("\(markers.statusBeginLine)\n")
                        .appending("Process 701 stopped\n")
                        .appending("\(statusResult)\n")
                        .appending("Process 702 exited\n")
                        .appending("\(markers.statusEndLine)\n")
                        .appending("after status\n")
                        .appending("\(markers.requestEndLine)\n")
                        .utf8
                )
            )
        )

        XCTAssertEqual(
            result.transcript,
            "before status\nProcess 701 stopped\nProcess 702 exited\nafter status"
        )
        XCTAssertEqual(result.authoritativeStatusTranscript, "Process 42 running")
        XCTAssertEqual(result.observedProcessID, 42)
        XCTAssertEqual(result.observedProcessState, .running(processID: 42))
    }

    /// §4.88b, synthesized from the Tier 2m failure: the first exchange after an asynchronous
    /// breakpoint stop runs while LLDB is still printing the stop block, and LLDB re-prints its
    /// `(lldb) ` prompt (no newline) after each async write. The prompt lands in front of the next
    /// marker line. The exchange must decode, the stop block must stay console text, and only the
    /// correlated status segment may author the process state.
    func testAsyncStopBlockAndRedrawnPromptBeforeMarkersRemainConsoleText() throws {
        let markers = try LLDBCLIExchangeMarkers(token: Self.token)
        let semantic = "thread #2: tid = 0x60d69b\n"
        let encodedSemantic = Data(semantic.utf8).base64EncodedString()
        let stopBlock = [
            "Process 4242 stopped",
            "* thread #4: tid = 0x60d69d, stop reason = breakpoint 1.1",
            "    frame #0: 0x0000000100000548 threads-live-fixture`rendezvous(id=3) at mt.c:13",
            "-> 13  \t__attribute__((noinline)) void rendezvous(int id) {",
            "Target 0: (threads-live-fixture) stopped.",
        ].joined(separator: "\n")
        let exchange = "(lldb) script print(__import__('base64').b64decode('X19N').decode('ascii'))\n"
            + "(lldb) \(markers.requestBeginLine)\n"
            + "(lldb) script exec(__import__('base64').b64decode('aW1w').decode('utf-8'))\n"
            + "\(stopBlock)\n"
            + "(lldb) \(markers.commandResultPrefix)0_\(encodedSemantic)__\n"
            + "(lldb) (lldb) \(markers.commandsSucceededLine)\n"
            + "\(markers.statusBeginLine)\n"
            + "(lldb) \(statusResultLine(markers: markers, status: "Process 4242 stopped"))\n"
            + "\(markers.statusEndLine)\n"
            + "(lldb) \(markers.requestEndLine)\n"
        var decoder = LLDBCLITranscriptDecoder(
            markers: markers,
            observedPIDRequirement: .required,
            requiresSemanticCommandStatus: true,
            expectedSemanticCommandCount: 1
        )

        let result = try XCTUnwrap(try decoder.append(Data(exchange.utf8)))

        XCTAssertEqual(result.semanticCommandTranscripts, [semantic])
        XCTAssertTrue(result.semanticCommandsSucceeded)
        XCTAssertEqual(result.authoritativeStatusTranscript, "Process 4242 stopped")
        XCTAssertEqual(result.observedProcessID, 4242)
        XCTAssertTrue(result.transcript.contains("Target 0: (threads-live-fixture) stopped."))
        XCTAssertFalse(result.transcript.contains("__MACSCOPE_LLDB_"))
    }

    /// Only a redrawn prompt is removed, and only in front of the marker family: anything else
    /// glued to a marker, a foreign token behind a prompt, and prompts on console text keep their
    /// previous handling.
    func testRedrawnPromptRemovalIsLimitedToExactMarkerLines() throws {
        let markers = try LLDBCLIExchangeMarkers(token: Self.token)
        let foreign = try LLDBCLIExchangeMarkers(token: String(repeating: "b", count: 64))
        for exchange in [
            "(lldb) \(foreign.requestBeginLine)\ntext\n\(markers.requestEndLine)\n",
            "(lldb) x \(markers.requestBeginLine)\ntext\n\(markers.requestEndLine)\n",
            "(lldb)\(markers.requestBeginLine)\ntext\n\(markers.requestEndLine)\n",
        ] {
            var decoder = LLDBCLITranscriptDecoder(markers: markers)
            assertFailure(.ambiguousMarker) {
                _ = try decoder.append(Data(exchange.utf8))
                _ = try decoder.finish()
            }
        }
        XCTAssertEqual(
            LLDBCLITranscriptDecoder.removingAsyncPromptPrefix("(lldb) Process 1 stopped"),
            "(lldb) Process 1 stopped"
        )
        XCTAssertEqual(
            LLDBCLITranscriptDecoder.removingAsyncPromptPrefix("(lldb) (lldb) __MACSCOPE_LLDB_X"),
            "__MACSCOPE_LLDB_X"
        )
    }

    private func assertFailure(
        _ expectedCode: LLDBCLITranscriptDiagnosticCode,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            XCTFail("Expected \(expectedCode.rawValue).", file: file, line: line)
        } catch let failure as LLDBCLITranscriptFailure {
            XCTAssertEqual(failure.code, expectedCode, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func statusResultLine(
        markers: LLDBCLIExchangeMarkers,
        status: String
    ) -> String {
        let encoded = Data(status.utf8).base64EncodedString()
        return "\(markers.statusResultPrefix)\(encoded)__"
    }
}
