import CryptoKit
import XCTest
@testable import MacScope

final class PersistentLLDBLifecycleReceiptTranscriptDecoderTests: XCTestCase {
    func testDecodesExactSingleAttachReceiptTranscript() throws {
        let request = try makeAttachRequest()
        let receiptBytes = attachReceiptBytes(for: request)
        let response = response(
            for: request,
            semanticTranscripts: [framed(receiptBytes, sentinel: PersistentLLDBAttachProgram.receiptSentinel)]
        )

        let receipt = try PersistentLLDBLifecycleReceiptTranscriptDecoder()
            .decodeAttachReceipt(from: response, expected: request)

        XCTAssertEqual(receipt.observedProcessID, request.authority.processID)
        XCTAssertEqual(receipt.lldbProcessUniqueID, 8_811)
        XCTAssertEqual(receipt.canonicalPayloadSHA256.count, 32)
    }

    func testDecodesExactSingleDetachReceiptTranscript() throws {
        let request = try makeDetachRequest()
        let receiptBytes = detachReceiptBytes(for: request)
        let response = response(
            for: request,
            semanticTranscripts: [framed(receiptBytes, sentinel: PersistentLLDBDetachProgram.receiptSentinel)]
        )

        let receipt = try PersistentLLDBLifecycleReceiptTranscriptDecoder()
            .decodeDetachReceipt(from: response, expected: request)

        XCTAssertEqual(receipt.observedProcessID, request.expectedProcessID)
        XCTAssertEqual(receipt.lldbProcessUniqueID, request.expectedLLDBProcessUniqueID)
        XCTAssertTrue(receipt.acknowledged)
    }

    func testRejectsJoinedOrMultipleSemanticTranscriptsInsteadOfSearchingForSentinel() throws {
        let request = try makeAttachRequest()
        let valid = framed(
            attachReceiptBytes(for: request),
            sentinel: PersistentLLDBAttachProgram.receiptSentinel
        )
        let cases = [
            ["untrusted prefix\n", valid],
            ["untrusted prefix\n" + valid],
            [valid, "untrusted suffix\n"],
        ]

        for semanticTranscripts in cases {
            XCTAssertThrowsError(
                try PersistentLLDBLifecycleReceiptTranscriptDecoder().decodeAttachReceipt(
                    from: response(for: request, semanticTranscripts: semanticTranscripts),
                    expected: request
                )
            ) { error in
                XCTAssertEqual(
                    error as? PersistentLLDBLifecycleReceiptTranscriptDecoderError,
                    .invalidFraming
                )
            }
        }
    }

    func testRejectsWrongSentinelNoncanonicalBase64AndInvalidLineFraming() throws {
        let request = try makeAttachRequest()
        let receiptBytes = attachReceiptBytes(for: request)
        let encoded = receiptBytes.base64EncodedString()
        let cases = [
            "WRONG " + encoded + "\n",
            PersistentLLDBAttachProgram.receiptSentinel + encoded + "=\n",
            PersistentLLDBAttachProgram.receiptSentinel + encoded + "\r\n",
            PersistentLLDBAttachProgram.receiptSentinel + encoded + "\nextra\n",
            PersistentLLDBAttachProgram.receiptSentinel + encoded,
        ]

        for semanticTranscript in cases {
            XCTAssertThrowsError(
                try PersistentLLDBLifecycleReceiptTranscriptDecoder().decodeAttachReceipt(
                    from: response(for: request, semanticTranscripts: [semanticTranscript]),
                    expected: request
                )
            )
        }
    }

    func testRejectsOversizedEncodedReceiptBeforeCodecParsing() throws {
        let request = try makeAttachRequest()
        let oversized = Data(
            repeating: 0x61,
            count: PersistentLLDBAttachReceiptCodec.maximumReceiptBytes + 1
        )
        let transcript = framed(
            oversized,
            sentinel: PersistentLLDBAttachProgram.receiptSentinel
        )

        XCTAssertThrowsError(
            try PersistentLLDBLifecycleReceiptTranscriptDecoder().decodeAttachReceipt(
                from: response(for: request, semanticTranscripts: [transcript]),
                expected: request
            )
        ) { error in
            XCTAssertEqual(
                error as? PersistentLLDBLifecycleReceiptTranscriptDecoderError,
                .receiptTooLarge
            )
        }
    }

    func testRejectsFailedCommandWrongRequestAndWrongGeneration() throws {
        let request = try makeDetachRequest()
        let valid = framed(
            detachReceiptBytes(for: request),
            sentinel: PersistentLLDBDetachProgram.receiptSentinel
        )
        let exact = response(for: request, semanticTranscripts: [valid])
        let cases = [
            PersistentLLDBCLIResponse(
                requestID: exact.requestID,
                generation: exact.generation,
                transcript: transcript(
                    semanticTranscripts: [valid],
                    semanticCommandsSucceeded: false,
                    firstFailedSemanticCommandIndex: 0
                )
            ),
            PersistentLLDBCLIResponse(
                requestID: DebuggerRequestID(
                    epoch: request.sessionEpoch,
                    sequence: request.requestSequence + 1
                ),
                generation: exact.generation,
                transcript: exact.transcript
            ),
            PersistentLLDBCLIResponse(
                requestID: exact.requestID,
                generation: request.adapterGeneration + 1,
                transcript: exact.transcript
            ),
        ]

        for response in cases {
            XCTAssertThrowsError(
                try PersistentLLDBLifecycleReceiptTranscriptDecoder().decodeDetachReceipt(
                    from: response,
                    expected: request
                )
            )
        }
    }

    private func response(
        for request: PersistentLLDBAttachProgramRequest,
        semanticTranscripts: [String]
    ) -> PersistentLLDBCLIResponse {
        PersistentLLDBCLIResponse(
            requestID: DebuggerRequestID(
                epoch: request.sessionEpoch,
                sequence: request.requestSequence
            ),
            generation: request.adapterGeneration,
            transcript: transcript(semanticTranscripts: semanticTranscripts)
        )
    }

    private func response(
        for request: PersistentLLDBDetachProgramRequest,
        semanticTranscripts: [String]
    ) -> PersistentLLDBCLIResponse {
        PersistentLLDBCLIResponse(
            requestID: DebuggerRequestID(
                epoch: request.sessionEpoch,
                sequence: request.requestSequence
            ),
            generation: request.adapterGeneration,
            transcript: transcript(semanticTranscripts: semanticTranscripts)
        )
    }

    private func transcript(
        semanticTranscripts: [String],
        semanticCommandsSucceeded: Bool = true,
        firstFailedSemanticCommandIndex: Int? = nil
    ) -> LLDBCLITranscriptResult {
        LLDBCLITranscriptResult(
            transcript: "",
            authoritativeStatusTranscript: "",
            observedProcessID: nil,
            observedProcessState: nil,
            exchangeByteCount: semanticTranscripts.reduce(0) { $0 + $1.utf8.count },
            exchangeSHA256: String(repeating: "0", count: 64),
            semanticCommandsSucceeded: semanticCommandsSucceeded,
            firstFailedSemanticCommandIndex: firstFailedSemanticCommandIndex,
            semanticCommandTranscripts: semanticTranscripts,
            semanticCommandResultLineByteCounts: semanticTranscripts.map { $0.utf8.count }
        )
    }

    private func framed(_ bytes: Data, sentinel: String) -> String {
        sentinel + bytes.base64EncodedString() + "\n"
    }

    private func makeAttachRequest() throws -> PersistentLLDBAttachProgramRequest {
        let identity = try XCTUnwrap(makeIdentity())
        return try PersistentLLDBAttachProgramRequest(
            sessionEpoch: DebuggerSessionEpoch(
                rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
            ),
            requestSequence: 12,
            adapterGeneration: 3,
            authority: DebuggerSessionTargetAuthority(origin: .attached(identity)),
            correlationToken: Data(repeating: 0x2a, count: 32)
        )
    }

    private func makeDetachRequest() throws -> PersistentLLDBDetachProgramRequest {
        let identity = try XCTUnwrap(makeIdentity())
        return try PersistentLLDBDetachProgramRequest(
            sessionEpoch: DebuggerSessionEpoch(
                rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
            ),
            requestSequence: 13,
            adapterGeneration: 3,
            authority: DebuggerSessionTargetAuthority(origin: .attached(identity)),
            expectedLLDBProcessUniqueID: 8_811,
            correlationToken: Data(repeating: 0x2b, count: 32)
        )
    }

    private func makeIdentity() -> DebuggerLocalProcessIdentity? {
        DebuggerLocalProcessIdentity(
            processID: 7_777,
            startTime: DebuggerProcessStartIdentity(seconds: 9_000_001, microseconds: 17)!,
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/tmp/MacScopeLifecycleFixture",
            executableDeviceID: 7,
            executableFileID: 7_001,
            executableByteCount: 4_096,
            executableSHA256: String(repeating: "a", count: 64),
            architecture: .arm64,
            machOUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            codeIdentity: nil
        )
    }

    private func attachReceiptBytes(
        for request: PersistentLLDBAttachProgramRequest
    ) -> Data {
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
                Data(request.identity.canonicalExecutablePath.utf8).base64EncodedString()
            ),
            "target_uuid": .string(request.identity.machOUUID!.uuidString.lowercased()),
        ])
        return canonicalRoot(payload: payload)
    }

    private func detachReceiptBytes(
        for request: PersistentLLDBDetachProgramRequest
    ) -> Data {
        let payload = Phase2ProductionJSONValue.object([
            "acknowledged": .bool(true),
            "adapter_generation": .number(String(request.adapterGeneration)),
            "correlation_token": .string(hex(request.correlationToken)),
            "error": .object([
                "code": .number("0"),
                "kind": .number("0"),
                "message_b64": .string(""),
                "message_truncated": .bool(false),
                "message_utf8_bytes": .number("0"),
            ]),
            "identity_digest": .string(request.authority.identityDigest.lowercaseHex),
            "lldb_unique_id": .number(String(request.expectedLLDBProcessUniqueID)),
            "observed_pid": .number(String(request.expectedProcessID)),
            "request_sequence": .number(String(request.requestSequence)),
            "resume_on_detach": .bool(true),
            "schema": .number("1"),
            "session_epoch": .string(request.sessionEpoch.rawValue.uuidString.lowercased()),
        ])
        return canonicalRoot(payload: payload)
    }

    private func canonicalRoot(payload: Phase2ProductionJSONValue) -> Data {
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
