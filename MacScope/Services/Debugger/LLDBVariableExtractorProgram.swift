import CryptoKit
import Foundation

enum LLDBVariableExtractorProgramError: Error, Equatable, Sendable {
    case invalidToken
    case invalidProcessID
    case invalidStopID
    case invalidThreadID
    case invalidProgramCounter
    case invalidPathComponent
    case invalidPathShape
    case sourceTooLarge
    case tooManyInstallChunks
}

/// Fixed Python installed once into the retained LLDB interpreter. Runtime commands contain only
/// prevalidated integers and a canonical 256-bit token; variable names and values never enter a
/// command string and no human-oriented LLDB command output is parsed.
struct LLDBVariableExtractorProgram: Sendable {
    static let maximumSourceBytes = 16 * 1_024
    static let installChunkCharacterCount = 512
    static let maximumInstallChunkCount = 43

    static let current: LLDBVariableExtractorProgram = {
        do { return try LLDBVariableExtractorProgram(source: extractorSource) }
        catch { preconditionFailure("Invalid frozen LLDB variable extractor: \(error)") }
    }()

    let source: String
    let sourceByteCount: Int
    let sourceSHA256: Data
    let sourceSHA256Hex: String
    let installChunkCommands: [String]
    let installFinalizeCommand: String
    let installedProofCommand: String

    init(source: String) throws {
        let bytes = Data(source.utf8)
        guard !bytes.isEmpty, bytes.count <= Self.maximumSourceBytes else {
            throw LLDBVariableExtractorProgramError.sourceTooLarge
        }
        let digest = Data(SHA256.hash(data: bytes))
        let digestHex = Self.hex(digest)
        let chunks = stride(from: 0, to: bytes.base64EncodedString().utf8.count, by: Self.installChunkCharacterCount).map {
            String(bytes.base64EncodedString().dropFirst($0).prefix(Self.installChunkCharacterCount))
        }
        guard !chunks.isEmpty, chunks.count <= Self.maximumInstallChunkCount else {
            throw LLDBVariableExtractorProgramError.tooManyInstallChunks
        }
        sourceByteCount = bytes.count
        sourceSHA256 = digest
        sourceSHA256Hex = digestHex
        self.source = source
        installChunkCommands = chunks.enumerated().map { index, chunk in
            let initial = "{'n':0,'c':\(chunks.count),'b':\(bytes.count),'h':'\(digestHex)','p':[]}"
            return "script import builtins;d=builtins.__dict__;k='\(Self.installBufferKey)';i=\(index);s=\(index == 0 ? initial : "d.get(k)");assert isinstance(s,dict) and s.get('n')==i and s.get('c')==\(chunks.count) and s.get('b')==\(bytes.count) and s.get('h')=='\(digestHex)' and isinstance(s.get('p'),list);s['p'].append('\(chunk)');s['n']+=1;d[k]=s"
        }
        installFinalizeCommand = Self.encodedScriptCommand("""
        import base64,builtins,hashlib
        d=builtins.__dict__;k='\(Self.installBufferKey)'
        try:
            s=d.get(k);assert isinstance(s,dict) and s.get('n')==\(chunks.count) and s.get('c')==\(chunks.count) and s.get('b')==\(bytes.count) and s.get('h')=='\(digestHex)'
            x=base64.b64decode(''.join(s['p']),validate=True);assert len(x)==\(bytes.count) and hashlib.sha256(x).hexdigest()=='\(digestHex)'
            n={};exec(compile(x,'<macscope-variables>','exec'),n,n);assert callable(n.get('extract')) and callable(n.get('extract_children'))
            n['__source_sha256__']='\(digestHex)';d['\(Self.programKey)']=n
            print('MACSCOPE_LLDB_VARIABLE_INSTALL_V1 {"ok":true,"schema":1,"sha256":"\(digestHex)"}')
        finally:
            d.pop(k,None)
        """)
        installedProofCommand = Self.encodedScriptCommand("""
        import builtins
        n=builtins.__dict__.get('\(Self.programKey)')
        if not isinstance(n,dict) or n.get('__source_sha256__')!='\(digestHex)' or not callable(n.get('extract')) or not callable(n.get('extract_children')):
            raise RuntimeError('variable extractor proof failed')
        print('MACSCOPE_LLDB_VARIABLE_INSTALL_V1 {"ok":true,"schema":1,"sha256":"\(digestHex)"}')
        """)
    }

    func childSnapshotCommand(
        token: Data,
        expectedProcessID: Int32,
        expectedStopID: UInt32,
        threadID: UInt64,
        frameIndex: UInt32,
        programCounter: UInt64,
        pathComponents: [String]
    ) throws -> String {
        guard token.count == 32 else { throw LLDBVariableExtractorProgramError.invalidToken }
        guard expectedProcessID > 0 else { throw LLDBVariableExtractorProgramError.invalidProcessID }
        guard expectedStopID > 0 else { throw LLDBVariableExtractorProgramError.invalidStopID }
        guard threadID > 0 else { throw LLDBVariableExtractorProgramError.invalidThreadID }
        guard programCounter > 0 else { throw LLDBVariableExtractorProgramError.invalidProgramCounter }
        guard pathComponents.count >= 3,
              pathComponents.count <= DebuggerVariablePathToken.maximumComponentCount,
              pathComponents.count % 2 == 1 else {
            throw LLDBVariableExtractorProgramError.invalidPathShape
        }
        guard pathComponents.allSatisfy(DebuggerVariablePathToken.isValidComponent) else {
            throw LLDBVariableExtractorProgramError.invalidPathComponent
        }
        let tokenHex = Self.hex(token)
        let pathLiteral = String(data: try JSONEncoder().encode(pathComponents), encoding: .utf8)!
        return Self.encodedScriptCommand("""
        import builtins
        n=builtins.__dict__.get('\(Self.programKey)')
        if not isinstance(n,dict) or not callable(n.get('extract_children')):
            raise RuntimeError('variable extractor unavailable')
        n['extract_children']('\(tokenHex)',\(expectedProcessID),\(expectedStopID),\(threadID),\(frameIndex),\(programCounter),\(pathLiteral))
        """)
    }

    func snapshotCommand(
        token: Data,
        expectedProcessID: Int32,
        expectedStopID: UInt32,
        threadID: UInt64,
        frameIndex: UInt32,
        programCounter: UInt64
    ) throws -> String {
        guard token.count == 32 else { throw LLDBVariableExtractorProgramError.invalidToken }
        guard expectedProcessID > 0 else { throw LLDBVariableExtractorProgramError.invalidProcessID }
        guard expectedStopID > 0 else { throw LLDBVariableExtractorProgramError.invalidStopID }
        guard threadID > 0 else { throw LLDBVariableExtractorProgramError.invalidThreadID }
        guard programCounter > 0 else { throw LLDBVariableExtractorProgramError.invalidProgramCounter }
        let tokenHex = Self.hex(token)
        return Self.encodedScriptCommand("""
        import builtins
        n=builtins.__dict__.get('\(Self.programKey)')
        if not isinstance(n,dict) or not callable(n.get('extract')):
            raise RuntimeError('variable extractor unavailable')
        n['extract']('\(tokenHex)',\(expectedProcessID),\(expectedStopID),\(threadID),\(frameIndex),\(programCounter))
        """)
    }

    private static let installBufferKey = "__macscope_lldb_variable_install_v1"
    private static let programKey = "__macscope_lldb_variable_extractor_v1"

    private static func encodedScriptCommand(_ script: String) -> String {
        let literal = String(data: try! JSONEncoder().encode(script), encoding: .utf8)!
        return "script exec(\(literal))"
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static let extractorSource = #"""
import json
import lldb

_SENTINEL = "MACSCOPE_LLDB_VARIABLE_SNAPSHOT_V1 "
_MAX_VARIABLES = 256
_MAX_SCOPE_VARIABLES = 128
_MAX_NAME = 256
_MAX_TYPE = 512
_MAX_VALUE = 4096
_MAX_SUMMARY = 4096
_MAX_DIAGNOSTIC = 1024
_MAX_SNAPSHOT = 256 * 1024
_MAX_U32 = (1 << 32) - 1
_MAX_U64 = (1 << 64) - 1

def _text(value, maximum, empty):
    if value is None:
        value = ""
    if not isinstance(value, str) or (not empty and not value):
        raise RuntimeError("invalid SBValue text")
    encoded = value.encode("utf-8")
    if len(encoded) > maximum or any(ord(ch) < 32 or ord(ch) == 127 for ch in value):
        raise RuntimeError("invalid SBValue text")
    return value

def _coordinate(process, expected_pid, expected_stop, thread_id, frame_index, pc):
    if not process.IsValid() or process.GetState() != lldb.eStateStopped:
        raise RuntimeError("process not stopped")
    if process.GetProcessID() != expected_pid or process.GetStopID() != expected_stop:
        raise RuntimeError("process identity changed")
    thread = process.GetThreadByID(thread_id)
    if not thread.IsValid() or thread.GetThreadID() != thread_id:
        raise RuntimeError("thread identity changed")
    frame = thread.GetFrameAtIndex(frame_index)
    if not frame.IsValid() or frame.GetFrameID() != frame_index or frame.GetPC() != pc:
        raise RuntimeError("frame identity changed")
    return thread, frame

def _scope_values(frame, scope):
    if scope == "arguments":
        return "argument", frame.GetVariables(True, False, False, True), 0
    if scope == "locals":
        return "local", frame.GetVariables(False, True, False, True), 1
    if scope == "statics":
        return "static", frame.GetVariables(False, False, True, True), 2
    raise RuntimeError("invalid scope")

def _value_count(values):
    if not values.IsValid():
        return 0
    count = values.GetSize()
    if not isinstance(count, int) or count < 0 or count > _MAX_U32:
        raise RuntimeError("invalid variable count")
    return count

def _index_component(value):
    if not isinstance(value, str) or not value or (len(value) > 1 and value[0] == "0"):
        raise RuntimeError("invalid path index")
    if any(ch not in "0123456789" for ch in value):
        raise RuntimeError("invalid path index")
    parsed = int(value, 10)
    if parsed < 0 or parsed > _MAX_U32:
        raise RuntimeError("invalid path index")
    return parsed

def _snapshot_value(item, scope, ordinal):
    if not item.IsValid() or not item.IsInScope():
        raise RuntimeError("invalid SBValue")
    name = _text(item.GetName(), _MAX_NAME, False)
    type_name = _text(item.GetTypeName(), _MAX_TYPE, False)
    raw_value = item.GetValue()
    raw_summary = item.GetSummary()
    error = item.GetError()
    diagnostic = None
    if error.IsValid() and error.Fail():
        state = "failed"
        diagnostic = _text(error.GetCString(), _MAX_DIAGNOSTIC, False)
        value = None
        summary = None
    elif raw_value is None and raw_summary is None:
        state = "unavailable"
        value = None
        summary = None
    else:
        state = "available"
        value = None if raw_value is None else _text(raw_value, _MAX_VALUE, True)
        summary = None if raw_summary is None else _text(raw_summary, _MAX_SUMMARY, False)
    child_count = item.GetNumChildren()
    if not isinstance(child_count, int) or child_count < 0 or child_count > 65535:
        raise RuntimeError("invalid child count")
    return {
        "child_count": child_count,
        "diagnostic": diagnostic,
        "has_children": child_count > 0,
        "name": name,
        "ordinal": ordinal,
        "scope": scope,
        "state": state,
        "summary": summary,
        "type": type_name,
        "value": value,
    }

def _emit_snapshot(token, expected_pid, expected_stop, thread_id, frame_index, pc, variables, omitted):
    result = {
        "argument_omitted": omitted[0],
        "argument_truncated": omitted[0] > 0,
        "frame_index": frame_index,
        "local_omitted": omitted[1],
        "local_truncated": omitted[1] > 0,
        "observed_pid": expected_pid,
        "observed_state": "stopped",
        "observed_stop_id": expected_stop,
        "ok": True,
        "omitted_count": sum(omitted),
        "pc": pc,
        "schema": 1,
        "static_omitted": omitted[2],
        "static_truncated": omitted[2] > 0,
        "thread_id": thread_id,
        "token": token,
        "truncated": sum(omitted) > 0,
        "variables": variables,
    }
    encoded = json.dumps(result, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
    if len(encoded) > _MAX_SNAPSHOT:
        raise RuntimeError("snapshot capacity")
    print(_SENTINEL + encoded.decode("utf-8"))

def _validate_invocation(token, expected_pid, expected_stop, thread_id, frame_index, pc):
    if not isinstance(token, str) or len(token) != 64 or any(ch not in "0123456789abcdef" for ch in token):
        raise RuntimeError("invalid token")
    integers = (expected_pid, expected_stop, thread_id, frame_index, pc)
    if any(not isinstance(value, int) or value < 0 or value > _MAX_U64 for value in integers):
        raise RuntimeError("invalid coordinate")
    if expected_pid <= 0 or expected_pid > 0x7fffffff or expected_stop <= 0 or expected_stop > _MAX_U32 or thread_id <= 0 or pc <= 0 or frame_index > _MAX_U32:
        raise RuntimeError("invalid coordinate")

def extract_children(token, expected_pid, expected_stop, thread_id, frame_index, pc, path):
    _validate_invocation(token, expected_pid, expected_stop, thread_id, frame_index, pc)
    if not isinstance(path, list) or len(path) < 3 or len(path) > 32 or len(path) % 2 != 1:
        raise RuntimeError("invalid path")
    for component in path:
        _text(component, 256, False)
    debugger = lldb.debugger
    target = debugger.GetSelectedTarget()
    if not target.IsValid():
        raise RuntimeError("target unavailable")
    process = target.GetProcess()
    thread, frame = _coordinate(process, expected_pid, expected_stop, thread_id, frame_index, pc)
    scope, values, omitted_index = _scope_values(frame, path[0])
    value_count = _value_count(values)
    root_index = _index_component(path[1])
    if root_index >= value_count:
        raise RuntimeError("path root unavailable")
    item = values.GetValueAtIndex(root_index)
    if _text(item.GetName(), _MAX_NAME, False) != path[2]:
        raise RuntimeError("path root changed")
    cursor = 3
    while cursor < len(path):
        child_index = _index_component(path[cursor])
        expected_name = path[cursor + 1]
        if child_index >= item.GetNumChildren():
            raise RuntimeError("path child unavailable")
        item = item.GetChildAtIndex(child_index)
        if _text(item.GetName(), _MAX_NAME, False) != expected_name:
            raise RuntimeError("path child changed")
        cursor += 2
    child_count = item.GetNumChildren()
    if not isinstance(child_count, int) or child_count < 0 or child_count > _MAX_U32:
        raise RuntimeError("invalid child count")
    included = min(child_count, _MAX_SCOPE_VARIABLES, _MAX_VARIABLES)
    omitted = [0, 0, 0]
    omitted[omitted_index] = child_count - included
    variables = []
    for index in range(included):
        child = item.GetChildAtIndex(index)
        variables.append(_snapshot_value(child, scope, len(variables)))
    _coordinate(process, expected_pid, expected_stop, thread_id, frame_index, pc)
    _emit_snapshot(token, expected_pid, expected_stop, thread_id, frame_index, pc, variables, omitted)

def extract(token, expected_pid, expected_stop, thread_id, frame_index, pc):
    _validate_invocation(token, expected_pid, expected_stop, thread_id, frame_index, pc)
    debugger = lldb.debugger
    target = debugger.GetSelectedTarget()
    if not target.IsValid():
        raise RuntimeError("target unavailable")
    process = target.GetProcess()
    thread, frame = _coordinate(process, expected_pid, expected_stop, thread_id, frame_index, pc)
    scoped_values = [
        ("argument", frame.GetVariables(True, False, False, True)),
        ("local", frame.GetVariables(False, True, False, True)),
        ("static", frame.GetVariables(False, False, True, True)),
    ]
    buckets = [[], [], []]
    total = 0
    omitted = [0, 0, 0]
    for bucket, (scope, values) in enumerate(scoped_values):
        value_count = _value_count(values)
        included = min(value_count, _MAX_SCOPE_VARIABLES, _MAX_VARIABLES - total)
        omitted[bucket] = value_count - included
        for index in range(included):
            item = values.GetValueAtIndex(index)
            if not item.IsValid() or not item.IsInScope():
                raise RuntimeError("invalid SBValue")
            name = _text(item.GetName(), _MAX_NAME, False)
            type_name = _text(item.GetTypeName(), _MAX_TYPE, False)
            raw_value = item.GetValue()
            raw_summary = item.GetSummary()
            error = item.GetError()
            diagnostic = None
            if error.IsValid() and error.Fail():
                state = "failed"
                diagnostic = _text(error.GetCString(), _MAX_DIAGNOSTIC, False)
                value = None
                summary = None
            elif raw_value is None and raw_summary is None:
                state = "unavailable"
                value = None
                summary = None
            else:
                state = "available"
                value = None if raw_value is None else _text(raw_value, _MAX_VALUE, True)
                summary = None if raw_summary is None else _text(raw_summary, _MAX_SUMMARY, False)
            child_count = item.GetNumChildren()
            if not isinstance(child_count, int) or child_count < 0 or child_count > 65535:
                raise RuntimeError("invalid child count")
            buckets[bucket].append({
                "child_count": child_count,
                "diagnostic": diagnostic,
                "has_children": child_count > 0,
                "name": name,
                "ordinal": len(buckets[bucket]),
                "scope": scope,
                "state": state,
                "summary": summary,
                "type": type_name,
                "value": value,
            })
            total += 1
    _coordinate(process, expected_pid, expected_stop, thread_id, frame_index, pc)
    result = {
        "argument_omitted": omitted[0],
        "argument_truncated": omitted[0] > 0,
        "frame_index": frame_index,
        "local_omitted": omitted[1],
        "local_truncated": omitted[1] > 0,
        "observed_pid": expected_pid,
        "observed_state": "stopped",
        "observed_stop_id": expected_stop,
        "ok": True,
        "omitted_count": sum(omitted),
        "pc": pc,
        "schema": 1,
        "static_omitted": omitted[2],
        "static_truncated": omitted[2] > 0,
        "thread_id": thread_id,
        "token": token,
        "truncated": sum(omitted) > 0,
        "variables": buckets[0] + buckets[1] + buckets[2],
    }
    encoded = json.dumps(result, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
    if len(encoded) > _MAX_SNAPSHOT:
        raise RuntimeError("snapshot capacity")
    _coordinate(process, expected_pid, expected_stop, thread_id, frame_index, pc)
    print(_SENTINEL + encoded.decode("utf-8"))
"""#
}
