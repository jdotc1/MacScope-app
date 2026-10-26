import CryptoKit
import XCTest
@testable import MacScope

final class LLDBLogicalBreakpointProgramTests: XCTestCase {
    func testFrozenStaticHelperDigestChunksAndCompleteWires() throws {
        let program = LLDBLogicalBreakpointProgram.current
        XCTAssertEqual(program.sourceByteCount, LLDBLogicalBreakpointProgram.expectedSourceByteCount)
        XCTAssertEqual(program.sourceSHA256Hex, LLDBLogicalBreakpointProgram.expectedSourceSHA256Hex)
        XCTAssertEqual(program.sourceSHA256, Data(SHA256.hash(data: Data(program.source.utf8))))
        XCTAssertEqual(program.sourceSHA256.count, 32)
        XCTAssertLessThanOrEqual(program.sourceByteCount, LLDBLogicalBreakpointProgram.maximumSourceBytes)
        XCTAssertLessThanOrEqual(
            program.installChunkCommands.count,
            LLDBLogicalBreakpointProgram.maximumInstallChunkCount
        )
        XCTAssertEqual(
            program.installChunks.joined(),
            Data(program.source.utf8).base64EncodedString()
        )
        XCTAssertTrue(program.installFinalizeCommand.contains("__ms_lbp1_callback"))
        XCTAssertTrue(program.installedProofCommand.contains("__ms_lbp1_callback"))
        XCTAssertTrue(program.installFinalizeCommand.contains(
            "v and (not i[2] or z[y] is p[l])"
        ))
        XCTAssertTrue(program.installFinalizeCommand.contains(
            "or not any(i)"
        ))
        XCTAssertTrue(program.installFinalizeCommand.contains(
            "i=(u in sys.modules,w in d,y in z)"
        ))
        XCTAssertTrue(program.installFinalizeCommand.contains("m=o if v else type(sys)(u)"))
        XCTAssertTrue(program.installFinalizeCommand.contains("v or exec(compile("))
        XCTAssertTrue(program.installFinalizeCommand.contains(
            "z[y]=n[l]"
        ))
        XCTAssertTrue(program.installedProofCommand.contains(
            "getattr(__main__,'__ms_lbp1_callback',None) is n.get('logical_callback')"
        ))

        let commands = program.installChunkCommands + [
            program.installFinalizeCommand,
            program.installedProofCommand,
            try program.beginCommand(
                token: token,
                adapterGeneration: 7,
                expectedProcessID: 42,
                expectedStopID: 9,
                pageCount: 1,
                planByteCount: 2,
                planSHA256: digest
            ),
            try program.uploadPageCommand(
                token: token,
                pageIndex: 0,
                pageCount: 1,
                payloadBase64: "e30=",
                payloadSHA256: Data(SHA256.hash(data: Data("{}".utf8)))
            ),
            try program.applyCommand(token: token),
            try program.receiptPageCommand(token: token, cursor: 0),
            try program.drainLogsCommand(
                token: token,
                sessionEpoch: callbackSessionEpoch,
                adapterGeneration: 7,
                expectedProcessID: 42,
                afterSequence: 0
            ),
            try program.cleanupCommand(token: token),
            try program.privateBreakpointCleanupCommand(
                token: token,
                adapterGeneration: 7,
                expectedProcessID: 42,
                backendBreakpointID: 9,
                backendLocationID: 1,
                ownerTagDigest: digest,
                nameSHA256: Data(repeating: 0x33, count: 32),
                runtimeAddress: 0x0000000100003f80
            ),
        ]
        for command in commands {
            XCTAssertLessThanOrEqual(
                try program.completeEncodedWireByteCount(for: command),
                LLDBLogicalBreakpointProgram.maximumEncodedWireBytes
            )
            XCTAssertFalse(command.contains("/Users/"))
            XCTAssertFalse(command.contains("breakpoint delete"))
        }
    }

    func testInvocationGrammarAcceptsOnlyCanonicalBoundedData() throws {
        let program = LLDBLogicalBreakpointProgram.current
        XCTAssertThrowsError(try program.beginCommand(
            token: Data(repeating: 0, count: 31), adapterGeneration: 1,
            expectedProcessID: 1, expectedStopID: 1, pageCount: 1,
            planByteCount: 2, planSHA256: digest
        ))
        XCTAssertThrowsError(try program.beginCommand(
            token: token, adapterGeneration: 0,
            expectedProcessID: 1, expectedStopID: 1, pageCount: 1,
            planByteCount: 2, planSHA256: digest
        ))
        XCTAssertThrowsError(try program.beginCommand(
            token: token, adapterGeneration: 1,
            expectedProcessID: 0, expectedStopID: 1, pageCount: 1,
            planByteCount: 2, planSHA256: digest
        ))
        XCTAssertThrowsError(try program.beginCommand(
            token: token, adapterGeneration: 1,
            expectedProcessID: 1, expectedStopID: 1, pageCount: 0,
            planByteCount: 2, planSHA256: digest
        ))
        XCTAssertThrowsError(try program.uploadPageCommand(
            token: token, pageIndex: 1, pageCount: 1,
            payloadBase64: "e30=", payloadSHA256: digest
        ))
        XCTAssertThrowsError(try program.uploadPageCommand(
            token: token, pageIndex: 0, pageCount: 1,
            payloadBase64: "not base64!", payloadSHA256: digest
        ))
        XCTAssertThrowsError(try program.uploadPageCommand(
            token: token, pageIndex: 0, pageCount: 1,
            payloadBase64: String(repeating: "A", count: 2_052), payloadSHA256: digest
        ))
        XCTAssertThrowsError(try program.receiptPageCommand(
            token: token,
            cursor: LLDBLogicalBreakpointProgram.maximumReceiptBytes + 1
        ))
        XCTAssertThrowsError(try program.privateBreakpointCleanupCommand(
            token: token,
            adapterGeneration: 7,
            expectedProcessID: 42,
            backendBreakpointID: 0,
            backendLocationID: 1,
            ownerTagDigest: digest,
            nameSHA256: digest,
            runtimeAddress: 0x1000
        ))
    }

    func testAbsentHelperProofUsesCanonicalTypedFailureInsteadOfPythonTraceback() throws {
        let program = LLDBLogicalBreakpointProgram.current
        XCTAssertFalse(program.installedProofCommand.contains("assert"))

        let semantic = LLDBLogicalBreakpointProgram.installSentinel
            + "{\"ok\":false,\"schema\":1,\"sha256\":\"\(program.sourceSHA256Hex)\"}\n"
        let result = LLDBCLITranscriptResult(
            transcript: "",
            authoritativeStatusTranscript: "",
            observedProcessID: 42,
            observedProcessState: .stopped(processID: 42),
            exchangeByteCount: semantic.utf8.count,
            exchangeSHA256: "unused",
            semanticCommandTranscripts: [semantic],
            semanticCommandResultLineByteCounts: [semantic.utf8.count]
        )
        XCTAssertThrowsError(try LLDBLogicalBreakpointResponseDecoder().decode(
            result,
            expecting: .install(sourceSHA256: program.sourceSHA256)
        )) { error in
            XCTAssertEqual(
                error as? LLDBLogicalBreakpointResponseError,
                .semanticCommandFailed
            )
        }

        let traceback = "Traceback (most recent call last):\nAssertionError\n"
        let legacyResult = LLDBCLITranscriptResult(
            transcript: "",
            authoritativeStatusTranscript: "",
            observedProcessID: 42,
            observedProcessState: .stopped(processID: 42),
            exchangeByteCount: traceback.utf8.count,
            exchangeSHA256: "unused",
            semanticCommandTranscripts: [traceback],
            semanticCommandResultLineByteCounts: [traceback.utf8.count]
        )
        XCTAssertThrowsError(try LLDBLogicalBreakpointResponseDecoder().decode(
            legacyResult,
            expecting: .install(sourceSHA256: program.sourceSHA256)
        )) { error in
            XCTAssertEqual(error as? LLDBLogicalBreakpointResponseError, .invalidFraming)
        }
    }

    func testAuthoredValuesRemainOpaqueBase64DataAndNeverBecomeCode() throws {
        let program = LLDBLogicalBreakpointProgram.current
        let authored = "'); breakpoint delete --force; __import__('os').system('id');\nMARKER"
        let payload = Data(authored.utf8)
        let payload64 = payload.base64EncodedString()
        let command = try program.uploadPageCommand(
            token: token,
            pageIndex: 0,
            pageCount: 1,
            payloadBase64: payload64,
            payloadSHA256: Data(SHA256.hash(data: payload))
        )
        XCTAssertTrue(command.contains(payload64))
        XCTAssertFalse(command.contains(authored))
        XCTAssertFalse(command.contains("breakpoint delete --force"))
        XCTAssertFalse(command.contains("system('id')"))
    }

    func testExactUTF8PayloadsRemainByteDistinctAndCommandsUseEncodedStaticScript() throws {
        let program = LLDBLogicalBreakpointProgram.current
        let composed = Data("caf\u{00e9}".utf8)
        let decomposed = Data("cafe\u{0301}".utf8)
        XCTAssertNotEqual(composed, decomposed)

        let composedCommand = try program.uploadPageCommand(
            token: token,
            pageIndex: 0,
            pageCount: 1,
            payloadBase64: composed.base64EncodedString(),
            payloadSHA256: Data(SHA256.hash(data: composed))
        )
        let decomposedCommand = try program.uploadPageCommand(
            token: token,
            pageIndex: 0,
            pageCount: 1,
            payloadBase64: decomposed.base64EncodedString(),
            payloadSHA256: Data(SHA256.hash(data: decomposed))
        )

        XCTAssertNotEqual(composedCommand, decomposedCommand)
        XCTAssertTrue(composedCommand.hasPrefix("script exec(\""))
        XCTAssertTrue(decomposedCommand.hasPrefix("script exec(\""))
        XCTAssertFalse(composedCommand.contains("caf\u{00e9}"))
        XCTAssertFalse(decomposedCommand.contains("cafe\u{0301}"))
    }

    func testMutationAndCapabilityPolicyAdvertisesOnlyLiveProvenSet() {
        XCTAssertEqual(
            LLDBLogicalBreakpointProgram.liveProvenCapabilities,
            [
                .condition,
                .ignoreFirst,
                .actions,
                .targetExpression,
                .continueAfterSuccessfulActions,
            ]
        )
        XCTAssertFalse(LLDBLogicalBreakpointCommandPhase.install.mayWriteTarget)
        XCTAssertFalse(LLDBLogicalBreakpointCommandPhase.begin.mayWriteTarget)
        XCTAssertFalse(LLDBLogicalBreakpointCommandPhase.upload.mayWriteTarget)
        XCTAssertFalse(LLDBLogicalBreakpointCommandPhase.cleanup.mayWriteTarget)
        XCTAssertTrue(LLDBLogicalBreakpointCommandPhase.apply.mayWriteTarget)
        XCTAssertTrue(LLDBLogicalBreakpointCommandPhase.privateCleanup.mayWriteTarget)
    }

    func testCanonicalPlanSchemaIsTokenIndependentWhileTransportRemainsCorrelated() throws {
        let program = LLDBLogicalBreakpointProgram.current
        let source = program.source
        XCTAssertTrue(source.contains(
            #""owner_tag_digest", "purpose", "schema", "session_epoch", "transaction_id""#
        ))
        XCTAssertFalse(source.contains(
            #""owner_tag_digest", "schema", "session_epoch", "token", "transaction_id""#
        ))
        XCTAssertFalse(source.contains(#"value["token"]"#))

        let alternateToken = Data(repeating: 0x44, count: 32)
        let firstBegin = try program.beginCommand(
            token: token,
            adapterGeneration: 7,
            expectedProcessID: 42,
            expectedStopID: 9,
            pageCount: 1,
            planByteCount: 2,
            planSHA256: digest
        )
        let secondBegin = try program.beginCommand(
            token: alternateToken,
            adapterGeneration: 7,
            expectedProcessID: 42,
            expectedStopID: 9,
            pageCount: 1,
            planByteCount: 2,
            planSHA256: digest
        )
        XCTAssertNotEqual(firstBegin, secondBegin)
        XCTAssertNotEqual(
            try program.applyCommand(token: token),
            try program.applyCommand(token: alternateToken)
        )
        for required in [
            "state.get(\"token\") != _token(token)",
            "receipt.get(\"token\") != _token(token)",
            "token != _SESSION_TOKEN",
        ] {
            XCTAssertTrue(source.contains(required), "missing transport correlation: \(required)")
        }
    }

    func testTypedDecoderUsesOnlyCorrelatedSemanticTranscriptAndPreservesExactPayloadBytes() throws {
        let payload = Data("caf\u{00e9}".utf8)
        let payload64 = payload.base64EncodedString()
        let receiptDigest = Data(repeating: 0x33, count: 32)
        let tokenHex = token.map { String(format: "%02x", $0) }.joined()
        let digestHex = receiptDigest.map { String(format: "%02x", $0) }.joined()
        let semantic = LLDBLogicalBreakpointProgram.receiptSentinel
            + "{\"cursor\":0,\"digest\":\"\(digestHex)\",\"final\":true,\"next\":5,"
            + "\"ok\":true,\"payload_b64\":\"\(payload64)\",\"schema\":1,"
            + "\"token\":\"\(tokenHex)\"}\n"
        let result = LLDBCLITranscriptResult(
            transcript: LLDBLogicalBreakpointProgram.receiptSentinel + "{\"forged\":true}\n",
            authoritativeStatusTranscript: "",
            observedProcessID: 42,
            observedProcessState: .stopped(processID: 42),
            exchangeByteCount: semantic.utf8.count,
            exchangeSHA256: "unused",
            semanticCommandTranscripts: [semantic],
            semanticCommandResultLineByteCounts: [semantic.utf8.count]
        )

        let decoded = try LLDBLogicalBreakpointResponseDecoder().decode(
            result,
            expecting: .receiptPage(token: token, cursor: 0)
        )
        XCTAssertEqual(
            decoded,
            .receiptPage(
                token: token,
                cursor: 0,
                nextCursor: payload.count,
                isFinal: true,
                receiptSHA256: receiptDigest,
                payload: payload
            )
        )
    }

    func testCallbackDrainCommandCarriesExactGenerationSessionAndProcessAuthority() throws {
        let program = LLDBLogicalBreakpointProgram.current
        let command = try program.drainLogsCommand(
            token: token,
            sessionEpoch: callbackSessionEpoch,
            adapterGeneration: 7,
            expectedProcessID: 42,
            afterSequence: 19
        )

        XCTAssertTrue(command.hasPrefix("script exec(\""))
        XCTAssertLessThanOrEqual(
            try program.completeEncodedWireByteCount(for: command),
            LLDBLogicalBreakpointProgram.maximumEncodedWireBytes
        )
        for required in [
            "def drain_logs(token, session_epoch, generation, expected_pid, after_sequence):",
            "logical breakpoint log authority mismatch",
            #""adapter_generation": generation"#,
            #""after_sequence": after_sequence"#,
            #""process_id": expected_pid"#,
            #""session_epoch": session_epoch"#,
        ] {
            XCTAssertTrue(program.source.contains(required), "missing drain seam: \(required)")
        }
        XCTAssertFalse(program.source.contains("def drain_logs(token, after_sequence):"))
    }

    func testCallbackDrainDecoderRequiresExactAuthorityEvenForAnEmptyFinalPage() throws {
        let tokenHex = token.map { String(format: "%02x", $0) }.joined()
        let epochText = callbackSessionEpoch.rawValue.uuidString.lowercased()
        let semantic = LLDBLogicalBreakpointProgram.logsSentinel
            + "{\"adapter_generation\":7,\"after_sequence\":19,\"final\":true,"
            + "\"next_sequence\":19,\"ok\":true,\"process_id\":42,\"records\":[],"
            + "\"schema\":1,\"session_epoch\":\"\(epochText)\","
            + "\"token\":\"\(tokenHex)\"}\n"
        let result = LLDBCLITranscriptResult(
            transcript: "",
            authoritativeStatusTranscript: "",
            observedProcessID: 42,
            observedProcessState: .stopped(processID: 42),
            exchangeByteCount: semantic.utf8.count,
            exchangeSHA256: "unused",
            semanticCommandTranscripts: [semantic],
            semanticCommandResultLineByteCounts: [semantic.utf8.count]
        )
        let expectation = LLDBLogicalBreakpointResponseExpectation.logs(
            token: token,
            sessionEpoch: callbackSessionEpoch,
            adapterGeneration: 7,
            processID: 42,
            afterSequence: 19
        )

        XCTAssertEqual(
            try LLDBLogicalBreakpointResponseDecoder().decode(result, expecting: expectation),
            .logs(
                token: token,
                sessionEpoch: callbackSessionEpoch,
                adapterGeneration: 7,
                processID: 42,
                afterSequence: 19,
                nextSequence: 19,
                isFinal: true,
                canonicalRecords: Data("[]".utf8)
            )
        )
        XCTAssertThrowsError(try LLDBLogicalBreakpointResponseDecoder().decode(
            result,
            expecting: .logs(
                token: token,
                sessionEpoch: callbackSessionEpoch,
                adapterGeneration: 8,
                processID: 42,
                afterSequence: 19
            )
        ))
    }

    func testStaticCallbackUsesOneAbsoluteDeadlineAcrossConditionAndAllActions() {
        let source = LLDBLogicalBreakpointProgram.current.source
        for required in [
            "import time",
            "_MAX_CALLBACK_SECONDS = 1.0",
            "class _CallbackTimeout(Exception):",
            "deadline = time.monotonic() + _MAX_CALLBACK_SECONDS",
            "remaining = int((deadline - time.monotonic()) * 1000000)",
            "options.SetTimeoutInMicroSeconds(min(250000, remaining))",
            #"raise _CallbackTimeout("callback-deadline")"#,
            #"raise _CallbackTimeout("expression-timeout")"#,
        ] {
            XCTAssertTrue(source.contains(required), "missing callback deadline seam: \(required)")
        }
    }

    func testConditionTruthClassifiesLLDBScalarValuesAndRejectsAmbiguousOutput() throws {
        let source = LLDBLogicalBreakpointProgram.current.source
        let callback = try XCTUnwrap(
            source.components(separatedBy: "def logical_callback(").dropFirst().first?
                .components(separatedBy: "\ndef drain_logs(").first
        )
        XCTAssertTrue(callback.contains("if not _condition_truth(condition_value):"))
        let function = try XCTUnwrap(
            source.components(separatedBy: "def _condition_truth(").dropFirst().first?
                .components(separatedBy: "\ndef _append_log(").first
        )
        let functionSource = "def _condition_truth(" + function
        let function64 = Data(functionSource.utf8).base64EncodedString()
        let cases: [(String, Bool?)] = [
            ("0", false),
            ("false", false),
            ("False", false),
            ("0x0000000000000000", false),
            ("1", true),
            ("true", true),
            ("True", true),
            ("-7", true),
            ("0x0000000100000000", true),
            ("nullptr", nil),
            ("(void *) 0x0", nil),
            ("", nil),
        ]
        let cases64 = Data(
            try JSONSerialization.data(
                withJSONObject: cases.map { entry in
                    [entry.0, entry.1.map { NSNumber(value: $0) } ?? NSNull()] as [Any]
                }
            )
        ).base64EncodedString()
        let script = """
        import base64,json
        _MAX_EXPRESSION_BYTES=1024
        exec(base64.b64decode('\(function64)').decode('utf-8'))
        cases=json.loads(base64.b64decode('\(cases64)').decode('utf-8'))
        observed=[]
        for value, expected in cases:
            try:
                observed.append(_condition_truth(value))
            except Exception:
                observed.append(None)
        print(json.dumps(observed, separators=(',', ':')))
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", script]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let stdoutDrain = CoreTestPipeDrain(stdout)
        let stderrDrain = CoreTestPipeDrain(stderr)
        process.waitUntilExit()
        let diagnostic = String(data: stderrDrain.data(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)
        let output = stdoutDrain.data()
        XCTAssertEqual(
            String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            "[false,false,false,false,true,true,true,true,true,null,null,null]"
        )
    }

    func testStaticCallbackDoesNotWriteDirectlyToDebuggerOutput() throws {
        let source = LLDBLogicalBreakpointProgram.current.source
        let callback = try XCTUnwrap(
            source.components(separatedBy: "def logical_callback(").dropFirst().first?
                .components(separatedBy: "\ndef drain_logs(").first
        )
        for forbidden in ["print(", "_emit(", "HandleCommand", "sys.stdout", "sys.stderr"] {
            XCTAssertFalse(callback.contains(forbidden), "callback output escape: \(forbidden)")
        }
    }

    func testCallbackDrainObserverAllowsOnlyCorrelatableRunningStoppedOrExitedProcess() throws {
        let source = LLDBLogicalBreakpointProgram.current.source
        let drain = try XCTUnwrap(
            source.components(separatedBy: "def drain_logs(").dropFirst().first?
                .components(separatedBy: "\ndef cleanup(").first
        )
        for required in [
            "def _observe_drain():",
            "target.IsValid()",
            "process.IsValid()",
            "int(lldb.eStateRunning)",
            "int(lldb.eStateStopped)",
            "int(lldb.eStateExited)",
            "pid not in (0, _SESSION_PID)",
            "_observe_drain()",
        ] {
            XCTAssertTrue(source.contains(required), "missing drain observer seam: \(required)")
        }
        XCTAssertFalse(drain.contains("_observe()"))
    }

    func testTypedDecoderRejectsUncorrelatedMalformedAndNoncanonicalResponses() throws {
        let tokenHex = token.map { String(format: "%02x", $0) }.joined()
        let noncanonical = LLDBLogicalBreakpointProgram.cleanupSentinel
            + "{\"schema\":1,\"ok\":true,\"token\":\"\(tokenHex)\"}\n"
        let failed = LLDBCLITranscriptResult(
            transcript: "",
            authoritativeStatusTranscript: "",
            observedProcessID: 42,
            observedProcessState: .stopped(processID: 42),
            exchangeByteCount: noncanonical.utf8.count,
            exchangeSHA256: "unused",
            semanticCommandsSucceeded: false,
            firstFailedSemanticCommandIndex: 0,
            semanticCommandTranscripts: [noncanonical],
            semanticCommandResultLineByteCounts: [noncanonical.utf8.count]
        )
        XCTAssertThrowsError(try LLDBLogicalBreakpointResponseDecoder().decode(
            failed,
            expecting: .cleanup(token: token)
        ))

        let result = LLDBCLITranscriptResult(
            transcript: "",
            authoritativeStatusTranscript: "",
            observedProcessID: 42,
            observedProcessState: .stopped(processID: 42),
            exchangeByteCount: noncanonical.utf8.count,
            exchangeSHA256: "unused",
            semanticCommandTranscripts: [noncanonical],
            semanticCommandResultLineByteCounts: [noncanonical.utf8.count]
        )
        XCTAssertThrowsError(try LLDBLogicalBreakpointResponseDecoder().decode(
            result,
            expecting: .cleanup(token: token)
        ))
    }

    func testStaticSourceContainsExactSBMutationRollbackCallbackAndBoundedRingSeams() {
        let source = LLDBLogicalBreakpointProgram.current.source
        for required in [
            "BreakpointCreateByAddress", "BreakpointDelete(backend_id)",
            "FindBreakpointByID", "SetEnabled(False)", "_rollback_created",
            #"breakpoint.AddName(metadata["name"])"#,
            "logical_callback", "_CALLBACK_ACTIVE", "_MAX_LOG_RECORDS = 1024",
            #"_CALLBACK_NAME = "__main__.__ms_lbp1_callback""#,
            #"def logical_callback(frame, bp_loc, extra_args, internal_dict):"#,
            #"SetScriptCallbackFunction(_CALLBACK_NAME, lldb.SBStructuredData())"#,
            #"if not callback_error.Success():"#,
            "_MAX_LOG_BYTES = 1024 * 1024", "_MAX_LOG_RECORD_BYTES = 4096",
            "continue_after_successful_actions", "EvaluateExpression",
            "GetStopID", "GetProcessID", "GetUUIDString", "GetLoadAddress",
            "issuance_digest", "owner_tag_digest", "backend_breakpoint_id",
            "backend_location_id", "one_shot", "auto_continue",
            "_CAP_CONDITION = True", "_CAP_ACTIONS = True",
            "_CAP_TARGET_EXPRESSION = True", "_CAP_CONTINUE = True",
            "condition capability unavailable", "action capability unavailable",
            "target expression capability unavailable", "continue capability unavailable",
            "_inventory_matches", "did_write_backend", "pre_state", "_prestate_record",
            "logical breakpoint log authority mismatch", "_LOG_ACK_SEQUENCE",
            "drop_count", "_LogCapacity",
        ] {
            XCTAssertTrue(source.contains(required), "missing static seam: \(required)")
        }
        for forbidden in [
            "HandleCommand", "subprocess", "os.system", "shell=True",
            "breakpoint delete --force", "eval(", "input(", "value[\"plan_digest\"]",
        ] {
            XCTAssertFalse(source.contains(forbidden), "forbidden helper path: \(forbidden)")
        }
    }

    func testPrivateRunToCursorPurposeIsClosedIsolatedOneShotAndLogSilent() throws {
        let program = LLDBLogicalBreakpointProgram.current
        let source = program.source
        for required in [
            #"_PURPOSE_LOGICAL = "logical""#,
            #"_PURPOSE_RUN_TO_CURSOR = "run_to_cursor""#,
            #"value not in (_PURPOSE_LOGICAL, _PURPOSE_RUN_TO_CURSOR)"#,
            #""macscope_logical_g""#,
            #""macscope_private_run_to_cursor_g""#,
            #"(binding_id + policy_digest + issuance_digest).encode("ascii")"#,
            #"run_id.replace("-", "")"#,
            #"breakpoint.SetOneShot(metadata["purpose"] == _PURPOSE_RUN_TO_CURSOR)"#,
            #"location["one_shot"] != (metadata["purpose"] == _PURPOSE_RUN_TO_CURSOR)"#,
            #"if metadata["purpose"] == _PURPOSE_RUN_TO_CURSOR:"#,
            #"def cleanup_private(token, generation, expected_pid, backend_id, location_id, owner_tag, name_digest, runtime_address):"#,
            #"names != [expected_name]"#,
            #"_PRIVATE_LEDGER.pop((backend_id, location_id), None)"#,
            #"target.FindBreakpointByID(backend_id).IsValid()"#,
        ] {
            XCTAssertTrue(source.contains(required), "missing private run-to-cursor seam: \(required)")
        }
        XCTAssertFalse(source.contains("macscope.logical"))
        XCTAssertFalse(source.contains("macscope.private"))

        let command = try program.privateBreakpointCleanupCommand(
            token: token,
            adapterGeneration: 7,
            expectedProcessID: 42,
            backendBreakpointID: 9,
            backendLocationID: 1,
            ownerTagDigest: digest,
            nameSHA256: Data(repeating: 0x33, count: 32),
            runtimeAddress: 0x0000000100003f80
        )
        XCTAssertTrue(command.hasPrefix("script exec(\""))
        XCTAssertFalse(command.contains("breakpoint delete"))
        XCTAssertLessThanOrEqual(
            try program.completeEncodedWireByteCount(for: command),
            LLDBLogicalBreakpointProgram.maximumEncodedWireBytes
        )
    }

    func testPrivateRunToCursorUsesItsFrozenCompactPlanAndReceiptSchema() {
        let source = LLDBLogicalBreakpointProgram.current.source
        for required in [
            #"def _validate_private_plan(value, state):"#,
            #""authority_revision", "binding", "inventory_revision""#,
            #""owner_digest""#,
            #""run_id""#,
            #""workspace_catalog_revision""#,
            #""artifact_uuid", "mapped_byte_count", "mapped_runtime_start""#,
            #""name_owner_digest", "one_shot", "owned_name_b64", "purpose""#,
            #""workspace_binary_id""#,
            #""workspace_owner_revision""#,
            #""workspace_slot""#,
            #"def _publish_private_receipt(state, token, generation, pid, stop_id, metadata, complete):"#,
            #""backend_breakpoint_id": location["backend_breakpoint_id"]"#,
            #""backend_location_id": location["backend_location_id"]"#,
            #""name_owner_digest": metadata["name_owner_digest"]"#,
            #""plan_digest": state["digest"]"#,
            #"_PRIVATE_LEDGER[(backend_id, location_id)] = dict(metadata)"#,
            #"metadata["cleanup_token"] = token"#,
            #"metadata.get("cleanup_token") != token"#,
        ] {
            XCTAssertTrue(source.contains(required), "missing compact private wire: \(required)")
        }
        XCTAssertTrue(source.contains(#"if not breakpoint.AddName("#))
        XCTAssertTrue(source.contains("breakpoint.GetNames(names)"))
        XCTAssertFalse(source.contains("if not breakpoint.GetNames(names)"))
    }

    func testPrivateCleanupDecoderRequiresExactExpectedIdentity() throws {
        let owner = Data(repeating: 0x22, count: 32)
        let name = Data(repeating: 0x33, count: 32)
        let tokenHex = token.map { String(format: "%02x", $0) }.joined()
        let ownerHex = owner.map { String(format: "%02x", $0) }.joined()
        let nameHex = name.map { String(format: "%02x", $0) }.joined()
        let semantic = LLDBLogicalBreakpointProgram.privateCleanupSentinel
            + "{\"backend_breakpoint_id\":9,\"backend_location_id\":1,"
            + "\"name_sha256\":\"\(nameHex)\",\"ok\":true,"
            + "\"owner_tag_digest\":\"\(ownerHex)\","
            + "\"runtime_address\":\"0000000100003f80\",\"schema\":1,"
            + "\"token\":\"\(tokenHex)\",\"was_present\":false}\n"
        let result = LLDBCLITranscriptResult(
            transcript: "",
            authoritativeStatusTranscript: "",
            observedProcessID: 42,
            observedProcessState: .stopped(processID: 42),
            exchangeByteCount: semantic.utf8.count,
            exchangeSHA256: "unused",
            semanticCommandTranscripts: [semantic],
            semanticCommandResultLineByteCounts: [semantic.utf8.count]
        )
        let expectation = LLDBLogicalBreakpointResponseExpectation.privateCleanup(
            token: token,
            backendBreakpointID: 9,
            backendLocationID: 1,
            ownerTagDigest: owner,
            nameSHA256: name,
            runtimeAddress: 0x0000000100003f80
        )
        XCTAssertEqual(
            try LLDBLogicalBreakpointResponseDecoder().decode(result, expecting: expectation),
            .privateCleaned(
                token: token,
                backendBreakpointID: 9,
                backendLocationID: 1,
                ownerTagDigest: owner,
                nameSHA256: name,
                runtimeAddress: 0x0000000100003f80,
                wasPresent: false
            )
        )

        XCTAssertThrowsError(try LLDBLogicalBreakpointResponseDecoder().decode(
            result,
            expecting: .privateCleanup(
                token: token,
                backendBreakpointID: 10,
                backendLocationID: 1,
                ownerTagDigest: owner,
                nameSHA256: name,
                runtimeAddress: 0x0000000100003f80
            )
        ))
    }

    func testFrozenHelperIsValidPythonSyntax() throws {
        let source64 = Data(LLDBLogicalBreakpointProgram.current.source.utf8).base64EncodedString()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-c",
            "import ast,base64;ast.parse(base64.b64decode('" + source64 + "').decode('utf-8'))",
        ]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        let stderrDrain = CoreTestPipeDrain(stderr)
        process.waitUntilExit()
        let diagnostic = String(data: stderrDrain.data(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)
    }

    private let token = Data(repeating: 0x11, count: 32)
    private let digest = Data(repeating: 0x22, count: 32)
    private let callbackSessionEpoch = DebuggerSessionEpoch(
        rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    )
}
