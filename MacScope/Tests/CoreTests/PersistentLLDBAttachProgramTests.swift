import CryptoKit
import XCTest
@testable import MacScope

final class PersistentLLDBAttachProgramTests: XCTestCase {
    func testGeneratedFinalizeAndRequestScriptsResolveAllSwiftValues() throws {
        let program = try PersistentLLDBAttachProgram(source: PersistentLLDBAttachProgram.source)
        let request = try makeRequest(path: "/tmp/fixture")
        let finalize = try decodedScript(from: program.installFinalizeCommand)
        let requestScript = try decodedScript(
            from: XCTUnwrap(try program.requestCommands(for: request).last)
        )

        XCTAssertTrue(finalize.contains("__macscope_exact_attach_install_v1"))
        XCTAssertTrue(finalize.contains("__macscope_exact_attach_program_v1"))
        let sourceDigest = program.sourceSHA256.map { String(format: "%02x", $0) }.joined()
        let correlationToken = request.correlationToken.map { String(format: "%02x", $0) }.joined()
        XCTAssertTrue(finalize.contains(sourceDigest))
        XCTAssertTrue(requestScript.contains("__macscope_exact_attach_program_v1"))
        XCTAssertTrue(requestScript.contains(correlationToken))
        XCTAssertTrue(requestScript.contains(request.sessionEpoch.rawValue.uuidString.lowercased()))
        XCTAssertTrue(requestScript.contains(String(request.requestSequence)))
        XCTAssertTrue(requestScript.contains(String(request.adapterGeneration)))
        XCTAssertTrue(requestScript.contains(String(request.authority.processID)))
        XCTAssertFalse(finalize.contains("(Self."))
        XCTAssertFalse(requestScript.contains("(Self."))
        XCTAssertFalse(requestScript.contains("(request."))
        XCTAssertFalse(requestScript.contains("(token)"))
    }

    func testMaximumAcceptedIdentityPathProducesOnlyBoundedStaticWires() throws {
        let program = try PersistentLLDBAttachProgram(source: PersistentLLDBAttachProgram.source)
        // `DebuggerLocalProcessIdentity` currently relies on NSString.standardizingPath,
        // whose effective canonical-path ceiling on macOS is MAXPATHLEN (1,024 bytes).
        let maximumCanonicalPath = "/" + String(repeating: "a", count: 1_023)
        XCTAssertEqual(maximumCanonicalPath.utf8.count, 1_024)
        let request = try makeRequest(path: maximumCanonicalPath)

        let commands = program.installChunkCommands
            + [program.installFinalizeCommand]
            + (try program.requestCommands(for: request))

        XCTAssertFalse(commands.isEmpty)
        for command in commands {
            XCTAssertLessThanOrEqual(
                try program.completeEncodedWireByteCount(for: command),
                LLDBCLITranscriptDecoder.maximumCommandBytes
            )
        }
    }

    func testStaticAttachSourceUsesExactPIDSBAPIAndNoProhibitedSurface() throws {
        let source = PersistentLLDBAttachProgram.source

        XCTAssertTrue(source.contains("AttachToProcessWithID"))
        XCTAssertTrue(source.contains("CreateTarget"))
        XCTAssertTrue(source.contains("GetUniqueID"))
        XCTAssertTrue(source.contains("GetStopID"))
        XCTAssertTrue(source.contains("GetStopReason"))
        XCTAssertTrue(source.contains("GetStopReasonDataCount"))
        XCTAssertTrue(source.contains("GetStopReasonDataAtIndex"))
        XCTAssertTrue(source.contains("message_truncated"))
        XCTAssertTrue(source.contains("[:1024].decode('utf-8','ignore').encode()"))
        XCTAssertFalse(source.contains("AttachToProcessWithName"))
        XCTAssertFalse(source.contains("SetWaitForLaunch"))
        XCTAssertFalse(source.contains("SBAttachInfo"))
        XCTAssertFalse(source.contains("gdb-remote"))
        XCTAssertFalse(source.contains("task_for_pid"))
        XCTAssertFalse(source.contains("process attach"))
        XCTAssertFalse(source.contains("kill("))
    }

    private func decodedScript(from command: String) throws -> String {
        let prefix = "script exec("
        guard command.hasPrefix(prefix), command.hasSuffix(")") else {
            throw NSError(domain: "PersistentLLDBAttachProgramTests", code: 1)
        }
        let literal = String(command.dropFirst(prefix.count).dropLast())
        return try JSONDecoder().decode(String.self, from: Data(literal.utf8))
    }

    func testReceiptCodecAcceptsOnlyCanonicalDigestProtectedExactAuthority() throws {
        let request = try makeRequest(path: "/tmp/fixture")
        let receiptBytes = attachReceiptBytes(for: request)

        let receipt = try PersistentLLDBAttachReceiptCodec().decode(
            receiptBytes,
            expected: request
        )

        XCTAssertEqual(receipt.observedProcessID, request.authority.processID)
        XCTAssertEqual(receipt.lldbProcessUniqueID, 8_811)
        XCTAssertEqual(receipt.stopID, 19)
        XCTAssertEqual(receipt.selectedThreadID, 44)
        XCTAssertEqual(receipt.stopReason.kind, .signal)
        XCTAssertEqual(receipt.stopReason.data, [5])
        XCTAssertEqual(receipt.state, .stopped)
        XCTAssertEqual(receipt.targetPath, request.identity.canonicalExecutablePath)
        XCTAssertEqual(receipt.targetUUID, request.identity.machOUUID)
        XCTAssertTrue(receipt.error.succeeded)
        XCTAssertFalse(receipt.error.messageTruncated)
    }

    func testRequestRejectsPIDOne() throws {
        XCTAssertThrowsError(try makeRequest(path: "/tmp/fixture", processID: 1))
    }

    func testReceiptRejectsInvalidThreadAndStopReasonEvidence() throws {
        let request = try makeRequest(path: "/tmp/fixture")
        let cases: [Data] = [
            attachReceiptBytes(for: request, selectedThreadID: 0),
            attachReceiptBytes(for: request, includeStopReason: false),
            attachReceiptBytes(for: request, stopReasonKind: "future_reason"),
            attachReceiptBytes(
                for: request,
                stopReasonData: Array(repeating: 1, count: 17)
            ),
            attachReceiptBytes(
                for: request,
                stopReasonDataTruncated: true
            ),
            attachReceiptBytes(for: request, stopReasonData: []),
            attachReceiptBytes(for: request, stopReasonKind: "trace", stopReasonData: [1]),
        ]

        for bytes in cases {
            XCTAssertThrowsError(
                try PersistentLLDBAttachReceiptCodec().decode(bytes, expected: request)
            )
        }
    }

    func testReceiptComparesTargetPathUTF8BytesWithoutUnicodeNormalization() throws {
        let request = try makeRequest(path: "/tmp/caf\u{00e9}")
        let canonicallyEquivalentButByteDifferent = "/tmp/cafe\u{0301}"

        XCTAssertEqual(
            canonicallyEquivalentButByteDifferent,
            request.identity.canonicalExecutablePath
        )
        XCTAssertNotEqual(
            Data(canonicallyEquivalentButByteDifferent.utf8),
            Data(request.identity.canonicalExecutablePath.utf8)
        )
        XCTAssertThrowsError(
            try PersistentLLDBAttachReceiptCodec().decode(
                attachReceiptBytes(
                    for: request,
                    targetPath: canonicallyEquivalentButByteDifferent
                ),
                expected: request
            )
        )
    }

    func testReceiptRequiresBoundedNontruncatedStructuredError() throws {
        let request = try makeRequest(path: "/tmp/fixture")
        let cases: [Data] = [
            attachReceiptBytes(for: request, includeErrorTruncationFlag: false),
            attachReceiptBytes(for: request, errorMessageTruncated: true),
            attachReceiptBytes(
                for: request,
                errorMessage: String(repeating: "e", count: 1_025)
            ),
        ]

        for bytes in cases {
            XCTAssertThrowsError(
                try PersistentLLDBAttachReceiptCodec().decode(bytes, expected: request)
            )
        }
    }

    func testReceiptCodecRejectsWrongPIDStopIDGenerationTokenAndNoncanonicalBytes() throws {
        let request = try makeRequest(path: "/tmp/fixture")
        let cases: [Data] = [
            attachReceiptBytes(for: request, observedPID: request.authority.processID + 1),
            attachReceiptBytes(for: request, stopID: 0),
            attachReceiptBytes(for: request, adapterGeneration: request.adapterGeneration + 1),
            attachReceiptBytes(for: request, tokenHex: String(repeating: "f", count: 64)),
            Data((String(data: attachReceiptBytes(for: request), encoding: .utf8)! + "\n").utf8),
        ]

        for bytes in cases {
            XCTAssertThrowsError(
                try PersistentLLDBAttachReceiptCodec().decode(bytes, expected: request)
            )
        }
    }

    private func makeRequest(
        path: String,
        processID: Int32 = 7_777
    ) throws -> PersistentLLDBAttachProgramRequest {
        let identity = try XCTUnwrap(DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: try XCTUnwrap(DebuggerProcessStartIdentity(seconds: 100, microseconds: 9)),
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: path,
            executableDeviceID: 2,
            executableFileID: 3,
            executableByteCount: 4,
            executableSHA256: String(repeating: "a", count: 64),
            architecture: .arm64,
            machOUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            codeIdentity: nil
        ))
        return try PersistentLLDBAttachProgramRequest(
            sessionEpoch: DebuggerSessionEpoch(rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!),
            requestSequence: 12,
            adapterGeneration: 3,
            authority: DebuggerSessionTargetAuthority(origin: .attached(identity)),
            correlationToken: Data(repeating: 0x2a, count: 32)
        )
    }

    private func attachReceiptBytes(
        for request: PersistentLLDBAttachProgramRequest,
        observedPID: Int32? = nil,
        stopID: UInt32 = 19,
        adapterGeneration: UInt64? = nil,
        tokenHex: String? = nil,
        selectedThreadID: UInt64 = 44,
        includeStopReason: Bool = true,
        stopReasonKind: String = "signal",
        stopReasonData: [UInt64] = [5],
        stopReasonDataTruncated: Bool = false,
        targetPath: String? = nil,
        includeErrorTruncationFlag: Bool = true,
        errorMessage: String = "",
        errorMessageTruncated: Bool = false
    ) -> Data {
        var error: [String: Phase2ProductionJSONValue] = [
            "code": .number("0"),
            "kind": .number("0"),
            "message_b64": .string(Data(errorMessage.utf8).base64EncodedString()),
        ]
        if includeErrorTruncationFlag {
            error["message_truncated"] = .bool(errorMessageTruncated)
        }
        var payload: [String: Phase2ProductionJSONValue] = [
            "adapter_generation": .number(String(adapterGeneration ?? request.adapterGeneration)),
            "correlation_token": .string(tokenHex ?? request.correlationToken.map { String(format: "%02x", $0) }.joined()),
            "error": .object(error),
            "lldb_unique_id": .number("8811"),
            "observed_pid": .number(String(observedPID ?? request.authority.processID)),
            "request_sequence": .number(String(request.requestSequence)),
            "requested_pid": .number(String(request.authority.processID)),
            "schema": .number("1"),
            "selected_thread_id": .number(String(selectedThreadID)),
            "session_epoch": .string(request.sessionEpoch.rawValue.uuidString.lowercased()),
            "state": .string("stopped"),
            "stop_id": .number(String(stopID)),
            "target_path_b64": .string(Data((targetPath ?? request.identity.canonicalExecutablePath).utf8).base64EncodedString()),
            "target_uuid": .string(request.identity.machOUUID!.uuidString.lowercased()),
        ]
        if includeStopReason {
            payload["stop_reason"] = .object([
                "data": .array(stopReasonData.map { .number(String($0)) }),
                "data_truncated": .bool(stopReasonDataTruncated),
                "kind": .string(stopReasonKind),
            ])
        }
        let payloadValue = Phase2ProductionJSONValue.object(payload)
        let payloadBytes = payloadValue.canonicalJSONBytes()
        let digest = SHA256.hash(data: payloadBytes).map { String(format: "%02x", $0) }.joined()
        return Phase2ProductionJSONValue.object([
            "payload": payloadValue,
            "payload_sha256": .string(digest),
            "schema": .number("1"),
        ]).canonicalJSONBytes()
    }
}
