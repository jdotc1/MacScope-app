import CryptoKit
import XCTest
@testable import MacScope

final class PersistentLLDBDetachProgramTests: XCTestCase {
    func testStaticDetachUsesNonKillingExactRetainedProcessAPI() throws {
        let program = PersistentLLDBDetachProgram()
        let request = try makeRequest()
        let command = try program.command(for: request)
        let commands = program.installChunkCommands + [program.installFinalizeCommand, command]

        XCTAssertTrue(PersistentLLDBDetachProgram.source.contains("Detach(False)"))
        XCTAssertTrue(PersistentLLDBDetachProgram.source.contains("GetUniqueID"))
        XCTAssertTrue(PersistentLLDBDetachProgram.source.contains("message_truncated"))
        XCTAssertTrue(PersistentLLDBDetachProgram.source.contains("message_utf8_bytes"))
        XCTAssertFalse(PersistentLLDBDetachProgram.source.contains("process detach"))
        XCTAssertFalse(PersistentLLDBDetachProgram.source.contains("Kill"))
        XCTAssertFalse(PersistentLLDBDetachProgram.source.contains("kill("))
        XCTAssertFalse(PersistentLLDBDetachProgram.source.contains("signal"))
        XCTAssertFalse(PersistentLLDBDetachProgram.source.contains("Attach"))
        XCTAssertFalse(PersistentLLDBDetachProgram.source.contains("remote"))
        XCTAssertFalse(PersistentLLDBDetachProgram.source.contains("wait"))
        XCTAssertFalse(PersistentLLDBDetachProgram.source.contains("name"))
        XCTAssertFalse(program.installChunkCommands.isEmpty)
        for command in commands {
            XCTAssertLessThanOrEqual(
                try program.completeEncodedWireByteCount(for: command),
                LLDBCLITranscriptDecoder.maximumCommandBytes
            )
        }
    }

    func testReceiptCodecRequiresExactPIDUniqueIDAndAcknowledgement() throws {
        let request = try makeRequest()
        let receipt = try PersistentLLDBDetachReceiptCodec().decode(
            detachReceiptBytes(for: request),
            expected: request
        )

        XCTAssertEqual(receipt.observedProcessID, request.expectedProcessID)
        XCTAssertEqual(receipt.lldbProcessUniqueID, request.expectedLLDBProcessUniqueID)
        XCTAssertTrue(receipt.acknowledged)
        XCTAssertTrue(receipt.resumeOnDetach)
        XCTAssertTrue(receipt.error.succeeded)
        XCTAssertFalse(receipt.error.messageTruncated)
        XCTAssertEqual(receipt.errorMessageOriginalUTF8ByteCount, 0)
    }

    func testRequestRequiresExactAttachedAuthorityAndDerivesPID() throws {
        let identity = makeIdentity()
        let attached = DebuggerSessionTargetAuthority(origin: .attached(identity))
        let request = try makeRequest(authority: attached)

        XCTAssertEqual(request.authority, attached)
        XCTAssertEqual(request.identity, identity)
        XCTAssertEqual(request.expectedProcessID, identity.processID)

        let launched = DebuggerSessionTargetAuthority(
            origin: .launched(DebuggerLaunchTargetAuthority(identity: identity))
        )
        XCTAssertThrowsError(try makeRequest(authority: launched)) { error in
            XCTAssertEqual(error as? PersistentLLDBDetachProgramError, .invalidAuthority)
        }
        XCTAssertThrowsError(
            try makeRequest(
                authority: DebuggerSessionTargetAuthority(origin: .attached(makeIdentity(processID: 1)))
            )
        ) { error in
            XCTAssertEqual(error as? PersistentLLDBDetachProgramError, .invalidAuthority)
        }
    }

    func testReceiptCodecRejectsWrongUniqueIDNegativeAcknowledgementAndReplay() throws {
        let request = try makeRequest()
        let cases = [
            detachReceiptBytes(for: request, uniqueID: request.expectedLLDBProcessUniqueID + 1),
            detachReceiptBytes(for: request, acknowledged: false),
            detachReceiptBytes(for: request, requestSequence: request.requestSequence + 1),
            detachReceiptBytes(for: request, identityDigest: String(repeating: "0", count: 64)),
        ]
        for bytes in cases {
            XCTAssertThrowsError(
                try PersistentLLDBDetachReceiptCodec().decode(bytes, expected: request)
            )
        }
    }

    func testReceiptCodecRejectsContradictoryErrorTruncationEvidence() throws {
        let request = try makeRequest()
        let cases = [
            detachReceiptBytes(
                for: request,
                errorMessage: Data(),
                messageWasTruncated: true,
                originalMessageUTF8ByteCount: 2_048
            ),
            detachReceiptBytes(
                for: request,
                errorMessage: Data(),
                messageWasTruncated: false,
                originalMessageUTF8ByteCount: 1
            ),
            detachReceiptBytes(
                for: request,
                errorMessage: Data(repeating: 0xff, count: 1),
                messageWasTruncated: false,
                originalMessageUTF8ByteCount: 1
            ),
        ]
        for bytes in cases {
            XCTAssertThrowsError(
                try PersistentLLDBDetachReceiptCodec().decode(bytes, expected: request)
            )
        }
    }

    private func makeRequest(
        authority: DebuggerSessionTargetAuthority? = nil
    ) throws -> PersistentLLDBDetachProgramRequest {
        try PersistentLLDBDetachProgramRequest(
            sessionEpoch: DebuggerSessionEpoch(rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!),
            requestSequence: 13,
            adapterGeneration: 3,
            authority: authority ?? DebuggerSessionTargetAuthority(origin: .attached(makeIdentity())),
            expectedLLDBProcessUniqueID: 8_811,
            correlationToken: Data(repeating: 0x2b, count: 32)
        )
    }

    private func detachReceiptBytes(
        for request: PersistentLLDBDetachProgramRequest,
        uniqueID: UInt64? = nil,
        acknowledged: Bool = true,
        requestSequence: UInt64? = nil,
        identityDigest: String? = nil,
        errorMessage: Data = Data(),
        messageWasTruncated: Bool = false,
        originalMessageUTF8ByteCount: UInt64 = 0
    ) -> Data {
        let payload = Phase2ProductionJSONValue.object([
            "acknowledged": .bool(acknowledged),
            "adapter_generation": .number(String(request.adapterGeneration)),
            "correlation_token": .string(request.correlationToken.map { String(format: "%02x", $0) }.joined()),
            "error": .object([
                "code": .number("0"),
                "kind": .number("0"),
                "message_b64": .string(errorMessage.base64EncodedString()),
                "message_truncated": .bool(messageWasTruncated),
                "message_utf8_bytes": .number(String(originalMessageUTF8ByteCount)),
            ]),
            "identity_digest": .string(
                identityDigest ?? request.authority.identityDigest.lowercaseHex
            ),
            "lldb_unique_id": .number(String(uniqueID ?? request.expectedLLDBProcessUniqueID)),
            "observed_pid": .number(String(request.expectedProcessID)),
            "request_sequence": .number(String(requestSequence ?? request.requestSequence)),
            "resume_on_detach": .bool(true),
            "schema": .number("1"),
            "session_epoch": .string(request.sessionEpoch.rawValue.uuidString.lowercased()),
        ])
        let payloadBytes = payload.canonicalJSONBytes()
        let digest = SHA256.hash(data: payloadBytes).map { String(format: "%02x", $0) }.joined()
        return Phase2ProductionJSONValue.object([
            "payload": payload,
            "payload_sha256": .string(digest),
            "schema": .number("1"),
        ]).canonicalJSONBytes()
    }

    private func makeIdentity(processID: Int32 = 7_777) -> DebuggerLocalProcessIdentity {
        DebuggerLocalProcessIdentity(
            processID: processID,
            startTime: DebuggerProcessStartIdentity(seconds: 9_000_001, microseconds: 17)!,
            realUserID: 501,
            effectiveUserID: 501,
            canonicalExecutablePath: "/tmp/MacScopeDetachFixture",
            executableDeviceID: 7,
            executableFileID: 7_001,
            executableByteCount: 4_096,
            executableSHA256: String(repeating: "a", count: 64),
            architecture: .arm64,
            machOUUID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
            codeIdentity: nil
        )!
    }
}
