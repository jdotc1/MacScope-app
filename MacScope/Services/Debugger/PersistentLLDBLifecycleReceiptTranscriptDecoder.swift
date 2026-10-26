import Foundation

enum PersistentLLDBLifecycleReceiptTranscriptDecoderError: Error, Equatable, Sendable {
    case responseCorrelationMismatch
    case semanticCommandFailed
    case invalidFraming
    case receiptTooLarge
    case invalidBase64
}

/// Decodes only the final, individually correlated lifecycle-helper response.
///
/// Helper installation and request staging use separate physical exchanges. This seam accepts
/// exactly one final semantic-command transcript and never searches a joined transcript for a
/// plausible sentinel. Canonical receipt validation remains owned by the operation-specific codec.
struct PersistentLLDBLifecycleReceiptTranscriptDecoder: Sendable {
    func decodeAttachReceipt(
        from response: PersistentLLDBCLIResponse,
        expected request: PersistentLLDBAttachProgramRequest
    ) throws -> PersistentLLDBAttachReceipt {
        let bytes = try canonicalReceiptBytes(
            from: response,
            expectedRequestID: DebuggerRequestID(
                epoch: request.sessionEpoch,
                sequence: request.requestSequence
            ),
            expectedAdapterGeneration: request.adapterGeneration,
            sentinel: PersistentLLDBAttachProgram.receiptSentinel,
            maximumReceiptBytes: PersistentLLDBAttachReceiptCodec.maximumReceiptBytes
        )
        return try PersistentLLDBAttachReceiptCodec().decode(bytes, expected: request)
    }

    func decodeDetachReceipt(
        from response: PersistentLLDBCLIResponse,
        expected request: PersistentLLDBDetachProgramRequest
    ) throws -> PersistentLLDBDetachReceipt {
        let bytes = try canonicalReceiptBytes(
            from: response,
            expectedRequestID: DebuggerRequestID(
                epoch: request.sessionEpoch,
                sequence: request.requestSequence
            ),
            expectedAdapterGeneration: request.adapterGeneration,
            sentinel: PersistentLLDBDetachProgram.receiptSentinel,
            maximumReceiptBytes: PersistentLLDBDetachReceiptCodec.maximumReceiptBytes
        )
        return try PersistentLLDBDetachReceiptCodec().decode(bytes, expected: request)
    }

    private func canonicalReceiptBytes(
        from response: PersistentLLDBCLIResponse,
        expectedRequestID: DebuggerRequestID,
        expectedAdapterGeneration: UInt64,
        sentinel: String,
        maximumReceiptBytes: Int
    ) throws -> Data {
        guard response.requestID == expectedRequestID,
              response.generation == expectedAdapterGeneration else {
            throw PersistentLLDBLifecycleReceiptTranscriptDecoderError
                .responseCorrelationMismatch
        }

        let transcript = response.transcript
        guard transcript.semanticCommandsSucceeded,
              transcript.firstFailedSemanticCommandIndex == nil else {
            throw PersistentLLDBLifecycleReceiptTranscriptDecoderError.semanticCommandFailed
        }
        guard transcript.semanticCommandTranscripts.count == 1,
              transcript.semanticCommandResultLineByteCounts.count == 1,
              transcript.exchangeByteCount >= 0,
              transcript.exchangeByteCount <= LLDBCLITranscriptDecoder.maximumExchangeBytes else {
            throw PersistentLLDBLifecycleReceiptTranscriptDecoderError.invalidFraming
        }

        let semantic = transcript.semanticCommandTranscripts[0]
        let semanticBytes = Data(semantic.utf8)
        guard transcript.semanticCommandResultLineByteCounts[0] >= semanticBytes.count,
              transcript.semanticCommandResultLineByteCounts[0]
                <= LLDBCLITranscriptDecoder.maximumExchangeBytes,
              semantic.hasPrefix(sentinel),
              semantic.hasSuffix("\n"),
              semantic.utf8.filter({ $0 == 0x0a }).count == 1,
              !semantic.utf8.contains(0x0d) else {
            throw PersistentLLDBLifecycleReceiptTranscriptDecoderError.invalidFraming
        }

        let encodedStart = semantic.index(semantic.startIndex, offsetBy: sentinel.count)
        let encodedEnd = semantic.index(before: semantic.endIndex)
        guard encodedStart < encodedEnd else {
            throw PersistentLLDBLifecycleReceiptTranscriptDecoderError.invalidFraming
        }
        let encoded = String(semantic[encodedStart..<encodedEnd])
        let maximumEncodedBytes = ((maximumReceiptBytes + 2) / 3) * 4
        guard encoded.utf8.count <= maximumEncodedBytes else {
            throw PersistentLLDBLifecycleReceiptTranscriptDecoderError.receiptTooLarge
        }
        guard let receiptBytes = Data(base64Encoded: encoded),
              receiptBytes.base64EncodedString() == encoded else {
            throw PersistentLLDBLifecycleReceiptTranscriptDecoderError.invalidBase64
        }
        guard !receiptBytes.isEmpty,
              receiptBytes.count <= maximumReceiptBytes else {
            throw PersistentLLDBLifecycleReceiptTranscriptDecoderError.receiptTooLarge
        }
        return receiptBytes
    }
}
