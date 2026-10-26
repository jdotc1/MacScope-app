import CryptoKit
import Foundation

enum PersistentLLDBAttachProgramError: Error, Equatable, Sendable {
    case invalidAuthority
    case invalidCorrelation
    case sourceTooLarge
    case encodedWireTooLarge
    case contradictoryReceipt
}

struct PersistentLLDBStructuredErrorReceipt: Hashable, Sendable {
    let code: UInt64
    let kind: UInt64
    let message: String
    let messageTruncated: Bool

    init(
        code: UInt64,
        kind: UInt64,
        message: String,
        messageTruncated: Bool = false
    ) {
        self.code = code
        self.kind = kind
        self.message = message
        self.messageTruncated = messageTruncated
    }

    var succeeded: Bool {
        code == 0 && kind == 0 && message.isEmpty && !messageTruncated
    }
}

enum PersistentLLDBAttachObservedState: String, Hashable, Sendable {
    case stopped
}

enum PersistentLLDBAttachStopReasonKind: String, Hashable, Sendable {
    case trace
    case breakpoint
    case watchpoint
    case signal
    case exception
    case exec
    case planComplete = "plan_complete"
    case threadExiting = "thread_exiting"
    case instrumentation
    case processorTrace = "processor_trace"
    case fork
    case vfork
    case vforkDone = "vfork_done"
}

struct PersistentLLDBAttachStopReason: Hashable, Sendable {
    let kind: PersistentLLDBAttachStopReasonKind
    let data: [UInt64]
}

struct PersistentLLDBAttachProgramRequest: Hashable, Sendable {
    let sessionEpoch: DebuggerSessionEpoch
    let requestSequence: UInt64
    let adapterGeneration: UInt64
    let authority: DebuggerSessionTargetAuthority
    let correlationToken: Data
    let identity: DebuggerLocalProcessIdentity

    init(
        sessionEpoch: DebuggerSessionEpoch,
        requestSequence: UInt64,
        adapterGeneration: UInt64,
        authority: DebuggerSessionTargetAuthority,
        correlationToken: Data
    ) throws {
        guard requestSequence > 0, adapterGeneration > 0, correlationToken.count == 32,
              case .attached(let identity) = authority.origin,
              identity.processID > 1,
              identity.processID == authority.processID,
              identity.identityDigest == authority.identityDigest else {
            throw PersistentLLDBAttachProgramError.invalidAuthority
        }
        self.sessionEpoch = sessionEpoch
        self.requestSequence = requestSequence
        self.adapterGeneration = adapterGeneration
        self.authority = authority
        self.correlationToken = correlationToken
        self.identity = identity
    }
}

struct PersistentLLDBAttachReceipt: Hashable, Sendable {
    let observedProcessID: Int32
    let lldbProcessUniqueID: UInt64
    let state: PersistentLLDBAttachObservedState
    let stopID: UInt32
    let selectedThreadID: UInt64
    let stopReason: PersistentLLDBAttachStopReason
    let targetPath: String
    let targetUUID: UUID?
    let error: PersistentLLDBStructuredErrorReceipt
    let canonicalPayloadSHA256: Data
}

struct PersistentLLDBAttachReceiptCodec: Sendable {
    static let maximumReceiptBytes = 16 * 1_024
    static let maximumErrorMessageBytes = 1_024
    static let maximumStopReasonDataCount = 16

    func decode(
        _ bytes: Data,
        expected request: PersistentLLDBAttachProgramRequest
    ) throws -> PersistentLLDBAttachReceipt {
        guard !bytes.isEmpty, bytes.count <= Self.maximumReceiptBytes else { throw failure }
        let value = try Phase2StrictJSONParser().parse(
            bytes,
            limits: Phase2StrictJSONLimits(
                maximumBytes: Self.maximumReceiptBytes,
                maximumDepth: 6,
                maximumTokens: 192,
                maximumMembersAndElements: 64
            )
        )
        guard value.canonicalJSONBytes() == bytes,
              let root = value.objectValue,
              Set(root.keys) == ["payload", "payload_sha256", "schema"],
              unsigned(root["schema"]) == 1,
              let payloadValue = root["payload"],
              let payload = payloadValue.objectValue,
              Set(payload.keys) == [
                "adapter_generation", "correlation_token", "error", "lldb_unique_id",
                "observed_pid", "request_sequence", "requested_pid", "schema",
                "selected_thread_id", "session_epoch", "state", "stop_id",
                "stop_reason", "target_path_b64", "target_uuid",
              ],
              unsigned(payload["schema"]) == 1 else { throw failure }

        let canonicalPayload = payloadValue.canonicalJSONBytes()
        let digest = Data(SHA256.hash(data: canonicalPayload))
        guard fixedHex(root["payload_sha256"], byteCount: 32) == digest,
              fixedHex(payload["correlation_token"], byteCount: 32) == request.correlationToken,
              payload["session_epoch"]?.stringValue
                == request.sessionEpoch.rawValue.uuidString.lowercased(),
              unsigned(payload["request_sequence"]) == request.requestSequence,
              unsigned(payload["adapter_generation"]) == request.adapterGeneration,
              signedPositiveInt32(payload["requested_pid"]) == request.authority.processID,
              signedPositiveInt32(payload["observed_pid"]) == request.authority.processID,
              let uniqueID = unsigned(payload["lldb_unique_id"]), uniqueID > 0,
              payload["state"]?.stringValue == PersistentLLDBAttachObservedState.stopped.rawValue,
              let stopValue = unsigned(payload["stop_id"]),
              let stopID = UInt32(exactly: stopValue), stopID > 0,
              let selectedThreadID = unsigned(payload["selected_thread_id"]),
              selectedThreadID > 0,
              let stopReason = stopReason(payload["stop_reason"]),
              let targetPathBytes = canonicalBase64Data(
                payload["target_path_b64"],
                maximumBytes: 4_096
              ),
              targetPathBytes == Data(request.identity.canonicalExecutablePath.utf8),
              let targetPath = String(data: targetPathBytes, encoding: .utf8),
              let targetUUID = optionalUUID(payload["target_uuid"]),
              targetUUID == request.identity.machOUUID,
              let error = structuredError(payload["error"]), error.succeeded else {
            throw failure
        }
        return PersistentLLDBAttachReceipt(
            observedProcessID: request.authority.processID,
            lldbProcessUniqueID: uniqueID,
            state: .stopped,
            stopID: stopID,
            selectedThreadID: selectedThreadID,
            stopReason: stopReason,
            targetPath: targetPath,
            targetUUID: targetUUID,
            error: error,
            canonicalPayloadSHA256: digest
        )
    }

    private var failure: PersistentLLDBAttachProgramError { .contradictoryReceipt }

    private func structuredError(
        _ value: Phase2ProductionJSONValue?
    ) -> PersistentLLDBStructuredErrorReceipt? {
        guard let object = value?.objectValue,
              Set(object.keys) == ["code", "kind", "message_b64", "message_truncated"],
              let code = unsigned(object["code"]),
              let kind = unsigned(object["kind"]),
              let messageTruncated = object["message_truncated"]?.boolValue,
              let message = canonicalBase64Text(
                object["message_b64"],
                maximumBytes: Self.maximumErrorMessageBytes
              ) else { return nil }
        return PersistentLLDBStructuredErrorReceipt(
            code: code,
            kind: kind,
            message: message,
            messageTruncated: messageTruncated
        )
    }

    private func stopReason(
        _ value: Phase2ProductionJSONValue?
    ) -> PersistentLLDBAttachStopReason? {
        guard let object = value?.objectValue,
              Set(object.keys) == ["data", "data_truncated", "kind"],
              object["data_truncated"]?.boolValue == false,
              let kindText = object["kind"]?.stringValue,
              let kind = PersistentLLDBAttachStopReasonKind(rawValue: kindText),
              let values = object["data"]?.arrayValue,
              values.count <= Self.maximumStopReasonDataCount else { return nil }
        var data: [UInt64] = []
        data.reserveCapacity(values.count)
        for value in values {
            guard let element = unsigned(value) else { return nil }
            data.append(element)
        }
        guard stopReasonDataIsCoherent(data, for: kind) else { return nil }
        return PersistentLLDBAttachStopReason(kind: kind, data: data)
    }

    private func stopReasonDataIsCoherent(
        _ data: [UInt64],
        for kind: PersistentLLDBAttachStopReasonKind
    ) -> Bool {
        switch kind {
        case .trace, .exec, .planComplete, .threadExiting, .instrumentation,
             .processorTrace, .vforkDone:
            return data.isEmpty
        case .signal:
            return data.count == 1 && data[0] > 0
        case .breakpoint, .watchpoint, .exception, .fork, .vfork:
            return !data.isEmpty
        }
    }

    private func optionalUUID(_ value: Phase2ProductionJSONValue?) -> UUID?? {
        guard let value else { return nil }
        if value == .null { return .some(nil) }
        guard let text = value.stringValue,
              text == text.lowercased(),
              let uuid = UUID(uuidString: text),
              uuid.uuidString.lowercased() == text else { return nil }
        return .some(uuid)
    }

    private func canonicalBase64Text(
        _ value: Phase2ProductionJSONValue?,
        maximumBytes: Int
    ) -> String? {
        guard let data = canonicalBase64Data(value, maximumBytes: maximumBytes),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    private func canonicalBase64Data(
        _ value: Phase2ProductionJSONValue?,
        maximumBytes: Int
    ) -> Data? {
        guard let encoded = value?.stringValue,
              let data = Data(base64Encoded: encoded),
              data.count <= maximumBytes,
              data.base64EncodedString() == encoded else { return nil }
        return data
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

/// Fixed app-authored helper installed into one retained LLDB generation. Executable paths are
/// staged in bounded Base64 chunks and are never interpolated into Python source or LLDB syntax.
struct PersistentLLDBAttachProgram: Sendable {
    static let maximumSourceBytes = 16 * 1_024
    static let installChunkCharacterCount = 512
    static let pathChunkCharacterCount = 384
    static let maximumEncodedWireBytes = 4 * 1_024
    static let receiptSentinel = "MACSCOPE_LLDB_ATTACH_V1 "

    static let current: PersistentLLDBAttachProgram = {
        do { return try PersistentLLDBAttachProgram(source: source) }
        catch { preconditionFailure("Invalid frozen attach program: \(error)") }
    }()

    let source: String
    let sourceSHA256: Data
    let installChunkCommands: [String]
    let installFinalizeCommand: String

    init(source: String) throws {
        let bytes = Data(source.utf8)
        guard !bytes.isEmpty, bytes.count <= Self.maximumSourceBytes else {
            throw PersistentLLDBAttachProgramError.sourceTooLarge
        }
        sourceSHA256 = Data(SHA256.hash(data: bytes))
        self.source = source
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
        n={'__builtins__':__builtins__};exec(compile(x.decode('utf-8'),'<macscope-exact-attach>','exec'),n,n)
        assert callable(n.get('attach'));d['\(Self.programKey)']=n;d.pop('\(Self.installKey)',None)
        """)
    }

    func requestCommands(
        for request: PersistentLLDBAttachProgramRequest
    ) throws -> [String] {
        let path = Data(request.identity.canonicalExecutablePath.utf8)
        let encoded = path.base64EncodedString()
        let chunks = stride(from: 0, to: encoded.utf8.count, by: Self.pathChunkCharacterCount)
            .map { String(encoded.dropFirst($0).prefix(Self.pathChunkCharacterCount)) }
        let token = Self.hex(request.correlationToken)
        let requestKey = Self.requestKeyPrefix + token
        var commands = chunks.enumerated().map { index, chunk in
            let initial = "{'n':0,'c':\(chunks.count),'b':\(path.count),'h':'\(Self.hex(Data(SHA256.hash(data: path))))','p':[]}"
            return "script import builtins;d=builtins.__dict__;k='\(requestKey)';i=\(index);s=\(index == 0 ? initial : "d.get(k)");assert isinstance(s,dict) and s.get('n')==i and s.get('c')==\(chunks.count);s['p'].append('\(chunk)');s['n']+=1;d[k]=s"
        }
        let uuidText = request.identity.machOUUID?.uuidString.lowercased() ?? ""
        commands.append(Self.encodedScriptCommand("""
        import builtins
        n=builtins.__dict__.get('\(Self.programKey)')
        if not isinstance(n,dict) or not callable(n.get('attach')): raise RuntimeError('exact attach helper unavailable')
        n['attach']('\(token)','\(request.sessionEpoch.rawValue.uuidString.lowercased())',\(request.requestSequence),\(request.adapterGeneration),\(request.authority.processID),'\(requestKey)','\(uuidText)')
        """))
        return commands
    }

    func completeEncodedWireByteCount(for command: String) throws -> Int {
        let markers = try LLDBCLIExchangeMarkers(
            token: String(repeating: "f", count: LLDBCLIExchangeMarkers.tokenCharacterCount)
        )
        let count = PersistentLLDBCLIAdapter.encodedWirePayload(
            semanticCommands: [command], markers: markers
        ).count
        guard count <= Self.maximumEncodedWireBytes else {
            throw PersistentLLDBAttachProgramError.encodedWireTooLarge
        }
        return count
    }

    private static func installChunkCommand(index: Int, count: Int, chunk: String) -> String {
        let initial = "{'n':0,'c':\(count),'p':[]}"
        return "script import builtins;d=builtins.__dict__;k='\(installKey)';i=\(index);s=\(index == 0 ? initial : "d.get(k)");assert isinstance(s,dict) and s.get('n')==i and s.get('c')==\(count);s['p'].append('\(chunk)');s['n']+=1;d[k]=s"
    }

    private static func encodedScriptCommand(_ script: String) -> String {
        let literal = String(data: try! JSONEncoder().encode(script), encoding: .utf8)!
        return "script exec(\(literal))"
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static let installKey = "__macscope_exact_attach_install_v1"
    private static let programKey = "__macscope_exact_attach_program_v1"
    private static let requestKeyPrefix = "__macscope_exact_attach_request_v1_"

    static let source = #"""
import base64,builtins,hashlib,json,lldb
def _b(v): return base64.b64encode(v.encode()).decode()
def _error(e):
    m=(e.GetCString() or '').encode();t=len(m)>1024
    m=m[:1024].decode('utf-8','ignore').encode()
    return {'code':int(e.GetError()),'kind':int(e.GetType()),'message_b64':base64.b64encode(m).decode(),'message_truncated':t}
def _reason(t):
    if not t.IsValid(): return {'data':[],'data_truncated':False,'kind':'unknown'}
    names={}
    for a,n in (('eStopReasonTrace','trace'),('eStopReasonBreakpoint','breakpoint'),('eStopReasonWatchpoint','watchpoint'),('eStopReasonSignal','signal'),('eStopReasonException','exception'),('eStopReasonExec','exec'),('eStopReasonPlanComplete','plan_complete'),('eStopReasonThreadExiting','thread_exiting'),('eStopReasonInstrumentation','instrumentation'),('eStopReasonProcessorTrace','processor_trace'),('eStopReasonFork','fork'),('eStopReasonVFork','vfork'),('eStopReasonVForkDone','vfork_done')):
        v=getattr(lldb,a,None)
        if v is not None: names[int(v)]=n
    k=int(t.GetStopReason());c=int(t.GetStopReasonDataCount());o=c>16
    data=[] if o else [int(t.GetStopReasonDataAtIndex(i)) for i in range(c)]
    return {'data':data,'data_truncated':o,'kind':names.get(k,'unknown')}
def _path(spec):
    p=getattr(spec,'fullpath',None)
    if p: return p
    d=spec.GetDirectory() or '';f=spec.GetFilename() or ''
    return (d+'/'+f) if d and f else (d or f)
def _emit(p):
    raw=json.dumps(p,sort_keys=True,separators=(',',':')).encode()
    root={'payload':p,'payload_sha256':hashlib.sha256(raw).hexdigest(),'schema':1}
    print('MACSCOPE_LLDB_ATTACH_V1 '+base64.b64encode(json.dumps(root,sort_keys=True,separators=(',',':')).encode()).decode())
def attach(token,epoch,sequence,generation,requested_pid,request_key,expected_uuid):
    d=builtins.__dict__;s=d.pop(request_key,None)
    if not isinstance(s,dict) or s.get('n')!=s.get('c'): raise RuntimeError('attach path staging unavailable')
    raw=base64.b64decode(''.join(s.get('p',[])),validate=True)
    if len(raw)!=s.get('b') or hashlib.sha256(raw).hexdigest()!=s.get('h'): raise RuntimeError('attach path staging mismatch')
    path=raw.decode('utf-8');target=lldb.debugger.CreateTarget(path);error=lldb.SBError()
    process=target.AttachToProcessWithID(lldb.debugger.GetListener(),requested_pid,error) if target.IsValid() else lldb.SBProcess()
    valid=process.IsValid();observed=int(process.GetProcessID()) if valid else 0
    state=int(process.GetState()) if valid else 0;stop=int(process.GetStopID()) if valid else 0
    thread=process.GetSelectedThread() if valid else lldb.SBThread();thread_id=int(thread.GetThreadID()) if thread.IsValid() else 0
    module=target.GetModuleAtIndex(0) if target.IsValid() and target.GetNumModules()>0 else lldb.SBModule()
    uuid=(module.GetUUIDString() or '').lower() if module.IsValid() else ''
    actual_path=_path(target.GetExecutable()) if target.IsValid() else ''
    payload={'adapter_generation':generation,'correlation_token':token,'error':_error(error),'lldb_unique_id':int(process.GetUniqueID()) if valid else 0,'observed_pid':observed,'request_sequence':sequence,'requested_pid':requested_pid,'schema':1,'selected_thread_id':thread_id,'session_epoch':epoch,'state':'stopped' if state==lldb.eStateStopped else 'other','stop_id':stop,'stop_reason':_reason(thread),'target_path_b64':_b(actual_path),'target_uuid':uuid if uuid else None}
    _emit(payload)
"""#
}
