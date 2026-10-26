import CryptoKit
import Foundation

enum PersistentLLDBDetachProgramError: Error, Equatable, Sendable {
    case invalidAuthority
    case encodedWireTooLarge
    case contradictoryReceipt
}

struct PersistentLLDBDetachProgramRequest: Hashable, Sendable {
    let sessionEpoch: DebuggerSessionEpoch
    let requestSequence: UInt64
    let adapterGeneration: UInt64
    let authority: DebuggerSessionTargetAuthority
    let identity: DebuggerLocalProcessIdentity
    let expectedLLDBProcessUniqueID: UInt64
    let correlationToken: Data

    var expectedProcessID: Int32 { authority.processID }

    init(
        sessionEpoch: DebuggerSessionEpoch,
        requestSequence: UInt64,
        adapterGeneration: UInt64,
        authority: DebuggerSessionTargetAuthority,
        expectedLLDBProcessUniqueID: UInt64,
        correlationToken: Data
    ) throws {
        guard requestSequence > 0,
              adapterGeneration > 0,
              expectedLLDBProcessUniqueID > 0,
              correlationToken.count == 32,
              case .attached(let identity) = authority.origin,
              identity.processID > 1,
              identity.processID == authority.processID,
              identity.identityDigest == authority.identityDigest else {
            throw PersistentLLDBDetachProgramError.invalidAuthority
        }
        self.sessionEpoch = sessionEpoch
        self.requestSequence = requestSequence
        self.adapterGeneration = adapterGeneration
        self.authority = authority
        self.identity = identity
        self.expectedLLDBProcessUniqueID = expectedLLDBProcessUniqueID
        self.correlationToken = correlationToken
    }
}

struct PersistentLLDBDetachReceipt: Hashable, Sendable {
    let observedProcessID: Int32
    let lldbProcessUniqueID: UInt64
    let acknowledged: Bool
    let resumeOnDetach: Bool
    let error: PersistentLLDBStructuredErrorReceipt
    let errorMessageOriginalUTF8ByteCount: UInt64
    let canonicalPayloadSHA256: Data
}

struct PersistentLLDBDetachReceiptCodec: Sendable {
    static let maximumReceiptBytes = 8 * 1_024
    static let maximumErrorMessageBytes = 1_024

    func decode(
        _ bytes: Data,
        expected request: PersistentLLDBDetachProgramRequest
    ) throws -> PersistentLLDBDetachReceipt {
        guard !bytes.isEmpty, bytes.count <= Self.maximumReceiptBytes else { throw failure }
        let value = try Phase2StrictJSONParser().parse(
            bytes,
            limits: Phase2StrictJSONLimits(
                maximumBytes: Self.maximumReceiptBytes,
                maximumDepth: 5,
                maximumTokens: 96,
                maximumMembersAndElements: 24
            )
        )
        guard value.canonicalJSONBytes() == bytes,
              let root = value.objectValue,
              Set(root.keys) == ["payload", "payload_sha256", "schema"],
              unsigned(root["schema"]) == 1,
              let payloadValue = root["payload"],
              let payload = payloadValue.objectValue,
              Set(payload.keys) == [
                "acknowledged", "adapter_generation", "correlation_token", "error",
                "identity_digest", "lldb_unique_id", "observed_pid", "request_sequence",
                "resume_on_detach", "schema", "session_epoch",
              ],
              unsigned(payload["schema"]) == 1 else { throw failure }

        let canonicalPayload = payloadValue.canonicalJSONBytes()
        let digest = Data(SHA256.hash(data: canonicalPayload))
        guard fixedHex(root["payload_sha256"], byteCount: 32) == digest,
              fixedHex(payload["correlation_token"], byteCount: 32)
                == request.correlationToken,
              payload["session_epoch"]?.stringValue
                == request.sessionEpoch.rawValue.uuidString.lowercased(),
              unsigned(payload["request_sequence"]) == request.requestSequence,
              unsigned(payload["adapter_generation"]) == request.adapterGeneration,
              payload["identity_digest"]?.stringValue
                == request.authority.identityDigest.lowercaseHex,
              signedPositiveInt32(payload["observed_pid"]) == request.expectedProcessID,
              unsigned(payload["lldb_unique_id"]) == request.expectedLLDBProcessUniqueID,
              payload["acknowledged"]?.boolValue == true,
              payload["resume_on_detach"]?.boolValue == true,
              let decodedError = structuredError(payload["error"]),
              decodedError.receipt.succeeded else {
            throw failure
        }
        return PersistentLLDBDetachReceipt(
            observedProcessID: request.expectedProcessID,
            lldbProcessUniqueID: request.expectedLLDBProcessUniqueID,
            acknowledged: true,
            resumeOnDetach: true,
            error: decodedError.receipt,
            errorMessageOriginalUTF8ByteCount: decodedError.originalUTF8ByteCount,
            canonicalPayloadSHA256: digest
        )
    }

    private var failure: PersistentLLDBDetachProgramError { .contradictoryReceipt }

    private struct DecodedError {
        let receipt: PersistentLLDBStructuredErrorReceipt
        let wasTruncated: Bool
        let originalUTF8ByteCount: UInt64
    }

    private func structuredError(
        _ value: Phase2ProductionJSONValue?
    ) -> DecodedError? {
        guard let object = value?.objectValue,
              Set(object.keys) == [
                "code", "kind", "message_b64", "message_truncated", "message_utf8_bytes",
              ],
              let code = unsigned(object["code"]),
              let kind = unsigned(object["kind"]),
              let encodedMessage = object["message_b64"]?.stringValue,
              let messageData = Data(base64Encoded: encodedMessage),
              messageData.count <= Self.maximumErrorMessageBytes,
              messageData.base64EncodedString() == encodedMessage,
              let message = String(data: messageData, encoding: .utf8),
              let wasTruncated = object["message_truncated"]?.boolValue,
              let originalUTF8ByteCount = unsigned(object["message_utf8_bytes"]) else { return nil }
        if wasTruncated {
            guard originalUTF8ByteCount > UInt64(Self.maximumErrorMessageBytes),
                  messageData.count >= Self.maximumErrorMessageBytes - 3 else { return nil }
        } else {
            guard originalUTF8ByteCount == UInt64(messageData.count) else { return nil }
        }
        return DecodedError(
            receipt: PersistentLLDBStructuredErrorReceipt(
                code: code,
                kind: kind,
                message: message,
                messageTruncated: wasTruncated
            ),
            wasTruncated: wasTruncated,
            originalUTF8ByteCount: originalUTF8ByteCount
        )
    }

    private func signedPositiveInt32(_ value: Phase2ProductionJSONValue?) -> Int32? {
        guard let number = unsigned(value),
              let result = Int32(exactly: number), result > 0 else { return nil }
        return result
    }

    private func unsigned(_ value: Phase2ProductionJSONValue?) -> UInt64? {
        guard case .number(let text) = value,
              !text.isEmpty,
              text == "0" || !text.hasPrefix("0"),
              text.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return UInt64(text)
    }

    private func fixedHex(_ value: Phase2ProductionJSONValue?, byteCount: Int) -> Data? {
        guard let text = value?.stringValue,
              text.utf8.count == byteCount * 2,
              text.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            return nil
        }
        var bytes = Data(capacity: byteCount)
        var index = text.startIndex
        for _ in 0..<byteCount {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}

/// One app-authored non-killing detach request against the exact process retained by LLDB.
/// No caller-authored command, process name, remote endpoint, or target-selection input is used.
struct PersistentLLDBDetachProgram: Sendable {
    static let maximumSourceBytes = 16 * 1_024
    static let installChunkCharacterCount = 512
    static let maximumEncodedWireBytes = 4 * 1_024
    static let receiptSentinel = "MACSCOPE_LLDB_DETACH_V1 "

    let sourceSHA256: Data
    let installChunkCommands: [String]
    let installFinalizeCommand: String

    init() {
        let bytes = Data(Self.source.utf8)
        precondition(!bytes.isEmpty && bytes.count <= Self.maximumSourceBytes)
        sourceSHA256 = Data(SHA256.hash(data: bytes))
        let encoded = bytes.base64EncodedString()
        let chunks = stride(from: 0, to: encoded.utf8.count, by: Self.installChunkCharacterCount)
            .map { String(encoded.dropFirst($0).prefix(Self.installChunkCharacterCount)) }
        installChunkCommands = chunks.enumerated().map { index, chunk in
            Self.installChunkCommand(index: index, count: chunks.count, chunk: chunk)
        }
        installFinalizeCommand = Self.encodedScriptCommand("""
        import base64,builtins,hashlib
        d=builtins.__dict__;s=d.get('\(Self.installKey)');x=base64.b64decode(''.join(s['p']),validate=True)
        assert s['n']==s['c'] and hashlib.sha256(x).hexdigest()=='\(Self.hex(sourceSHA256))'
        n={'__builtins__':__builtins__};exec(compile(x.decode('utf-8'),'<macscope-exact-detach>','exec'),n,n)
        assert callable(n.get('d'));d['\(Self.programKey)']=n;d.pop('\(Self.installKey)',None)
        """)
    }

    func command(for request: PersistentLLDBDetachProgramRequest) throws -> String {
        let script = """
        import builtins
        n=builtins.__dict__.get('\(Self.programKey)')
        if not isinstance(n,dict) or not callable(n.get('d')): raise RuntimeError('exact detach helper unavailable')
        n['d'](
        """ + Self.jsonLiteral(Self.hex(request.correlationToken)) + ","
            + Self.jsonLiteral(request.sessionEpoch.rawValue.uuidString.lowercased()) + ","
            + String(request.requestSequence) + ","
            + String(request.adapterGeneration) + ","
            + String(request.expectedProcessID) + ","
            + String(request.expectedLLDBProcessUniqueID) + ","
            + Self.jsonLiteral(request.authority.identityDigest.lowercaseHex) + ")"
        let command = Self.encodedScriptCommand(script)
        guard try completeEncodedWireByteCount(for: command) <= Self.maximumEncodedWireBytes else {
            throw PersistentLLDBDetachProgramError.encodedWireTooLarge
        }
        return command
    }

    func completeEncodedWireByteCount(for command: String) throws -> Int {
        let markers = try LLDBCLIExchangeMarkers(
            token: String(repeating: "f", count: LLDBCLIExchangeMarkers.tokenCharacterCount)
        )
        let count = PersistentLLDBCLIAdapter.encodedWirePayload(
            semanticCommands: [command], markers: markers
        ).count
        guard count <= Self.maximumEncodedWireBytes else {
            throw PersistentLLDBDetachProgramError.encodedWireTooLarge
        }
        return count
    }

    private static func jsonLiteral(_ string: String) -> String {
        String(data: try! JSONEncoder().encode(string), encoding: .utf8)!
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func installChunkCommand(index: Int, count: Int, chunk: String) -> String {
        let initial = "{'n':0,'c':\(count),'p':[]}"
        return "script import builtins;d=builtins.__dict__;k='\(installKey)';i=\(index);s=\(index == 0 ? initial : "d.get(k)");assert isinstance(s,dict) and s.get('n')==i and s.get('c')==\(count);s['p'].append('\(chunk)');s['n']+=1;d[k]=s"
    }

    private static func encodedScriptCommand(_ script: String) -> String {
        "script exec(" + jsonLiteral(script) + ")"
    }

    private static let installKey = "__macscope_exact_detach_install_v1"
    private static let programKey = "__macscope_exact_detach_program_v1"

    static let source = #"""
import base64 as b,hashlib as h,json,lldb
def d(t,e,s,g,p,u,d):
 x=lldb.debugger.GetSelectedTarget().GetProcess();v=x.IsValid();o=int(x.GetProcessID())if v else 0;i=int(x.GetUniqueID())if v else 0;r=x.Detach(False)if v and o==p and i==u else lldb.SBError();m=(r.GetCString()or'').encode();n=len(m);k=n>1024;m=m[:1024].decode('utf8','ignore').encode();a=v and o==p and i==u and r.Success();z={'acknowledged':a,'adapter_generation':g,'correlation_token':t,'error':{'code':int(r.GetError()),'kind':int(r.GetType()),'message_b64':b.b64encode(m).decode(),'message_truncated':k,'message_utf8_bytes':n},'identity_digest':d,'lldb_unique_id':i,'observed_pid':o,'request_sequence':s,'resume_on_detach':True,'schema':1,'session_epoch':e};f=lambda x:json.dumps(x,sort_keys=True,separators=(',',':')).encode();y={'payload':z,'payload_sha256':h.sha256(f(z)).hexdigest(),'schema':1};print('MACSCOPE_LLDB_DETACH_V1 '+b.b64encode(f(y)).decode())
"""#
}
