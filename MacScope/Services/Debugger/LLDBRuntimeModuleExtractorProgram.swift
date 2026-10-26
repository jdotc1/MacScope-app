import CryptoKit
import Foundation

enum LLDBRuntimeModuleExtractorProgramError: Error, Equatable, Sendable {
    case invalidToken
    case invalidCursor
    case sourceTooLarge
    case tooManyInstallChunks
    case encodedWireTooLarge
}

/// Fixed, app-authored Python extractor installed into one retained LLDB interpreter generation.
/// Runtime commands interpolate only a validated 256-bit token and a bounded decimal cursor.
struct LLDBRuntimeModuleExtractorProgram: Sendable {
    static let maximumSourceBytes = 16 * 1_024
    static let installChunkCharacterCount = 512
    static let maximumInstallChunkCount = 43
    static let maximumEncodedWireBytes = 4 * 1_024
    static let maximumCursor = 4_096
    static let maximumSnapshotBytes = 8 * 1_024 * 1_024
    static let maximumLogicalDecodedRecordBytes = 8 * 1_024 * 1_024
    static let expectedSourceByteCount = 8_951
    static let expectedSourceSHA256Hex = "105f4a5945e24d7d1be3d8000894ef2920532c7c5727c2bd7c1a5b9e03a8fad0"

    static let installSentinel = "MACSCOPE_LLDB_MODULE_INSTALL_V1 "
    static let cleanupSentinel = "MACSCOPE_LLDB_MODULE_CLEANUP_V1 "

    static let current: LLDBRuntimeModuleExtractorProgram = {
        do {
            let program = try LLDBRuntimeModuleExtractorProgram(source: extractorSource)
            precondition(
                program.sourceByteCount == expectedSourceByteCount
                    && program.sourceSHA256Hex == expectedSourceSHA256Hex,
                "The frozen LLDB runtime-module extractor bytes changed without updating its contract."
            )
            return program
        } catch {
            preconditionFailure("The frozen LLDB runtime-module extractor is invalid: \(error)")
        }
    }()

    let source: String
    let sourceByteCount: Int
    let sourceSHA256: Data
    let sourceSHA256Hex: String
    let installChunks: [String]
    let installChunkCommands: [String]
    let installFinalizeCommand: String
    let installedProofCommand: String

    init(source: String) throws {
        let sourceBytes = Data(source.utf8)
        guard !sourceBytes.isEmpty, sourceBytes.count <= Self.maximumSourceBytes else {
            throw LLDBRuntimeModuleExtractorProgramError.sourceTooLarge
        }
        let digest = Data(SHA256.hash(data: sourceBytes))
        let digestHex = Self.hex(digest)
        let encoded = sourceBytes.base64EncodedString()
        let markers = try LLDBCLIExchangeMarkers(
            token: String(repeating: "f", count: LLDBCLIExchangeMarkers.tokenCharacterCount)
        )
        var chunks: [String] = []
        var commands: [String] = []
        // Budget the actual lossless transport, including JSON/Base64 expansion,
        // correlation markers and the larger first-install command. Preserve all
        // source bytes and the frozen exchange reservation; never truncate a wire.
        for size in stride(from: Self.installChunkCharacterCount, through: 4, by: -4) {
            let candidate = stride(from: 0, to: encoded.utf8.count, by: size).map {
                String(encoded.dropFirst($0).prefix(size))
            }
            guard candidate.count <= Self.maximumInstallChunkCount else {
                throw LLDBRuntimeModuleExtractorProgramError.tooManyInstallChunks
            }
            let candidateCommands = candidate.enumerated().map { index, chunk in
                Self.installChunkCommand(index: index, count: candidate.count,
                    sourceByteCount: sourceBytes.count, digestHex: digestHex, chunk: chunk)
            }
            if candidateCommands.allSatisfy({
                PersistentLLDBCLIAdapter.encodedWirePayload(semanticCommands: [$0], markers: markers).count
                    <= Self.maximumEncodedWireBytes
            }) {
                chunks = candidate
                commands = candidateCommands
                break
            }
        }
        guard !chunks.isEmpty else { throw LLDBRuntimeModuleExtractorProgramError.encodedWireTooLarge }

        self.source = source
        self.sourceByteCount = sourceBytes.count
        self.sourceSHA256 = digest
        self.sourceSHA256Hex = digestHex
        self.installChunks = chunks
        self.installChunkCommands = commands
        self.installFinalizeCommand = Self.encodedScriptCommand(Self.finalizeScript(
            chunkCount: chunks.count,
            sourceByteCount: sourceBytes.count,
            digestHex: digestHex
        ))
        self.installedProofCommand = Self.encodedScriptCommand(Self.proofScript(digestHex: digestHex))
    }

    func pageCommand(token: Data, cursor: UInt32) throws -> String {
        guard token.count == 32 else { throw LLDBRuntimeModuleExtractorProgramError.invalidToken }
        return try pageCommand(tokenHex: Self.hex(token), cursor: cursor)
    }

    func pageCommand(tokenHex: String, cursor: UInt32) throws -> String {
        guard Self.isCanonicalToken(tokenHex) else {
            throw LLDBRuntimeModuleExtractorProgramError.invalidToken
        }
        guard cursor <= UInt32(Self.maximumCursor) else {
            throw LLDBRuntimeModuleExtractorProgramError.invalidCursor
        }
        return Self.encodedScriptCommand("""
        import builtins
        namespace = builtins.__dict__.get('\(Self.programKey)')
        if not isinstance(namespace, dict) or not callable(namespace.get('page')):
            raise RuntimeError('runtime module extractor unavailable')
        namespace['page']('\(tokenHex)', \(cursor))
        """)
    }

    func cleanupCommand(token: Data) throws -> String {
        guard token.count == 32 else { throw LLDBRuntimeModuleExtractorProgramError.invalidToken }
        return try cleanupCommand(tokenHex: Self.hex(token))
    }

    func cleanupCommand(tokenHex: String) throws -> String {
        guard Self.isCanonicalToken(tokenHex) else {
            throw LLDBRuntimeModuleExtractorProgramError.invalidToken
        }
        return Self.encodedScriptCommand(Self.cleanupScript(tokenHex: tokenHex))
    }

    static func incrementalCapacityFits(
        canonicalSnapshotByteCount: Int,
        logicalDecodedRecordByteCount: Int
    ) -> Bool {
        (0...maximumSnapshotBytes).contains(canonicalSnapshotByteCount)
            && (0...maximumLogicalDecodedRecordBytes).contains(logicalDecodedRecordByteCount)
    }

    private static func cleanupScript(tokenHex: String) -> String {
        """
        import builtins
        d=builtins.__dict__;n=d.get('\(programKey)');s=n.get('_SNAPSHOT') if isinstance(n,dict) else None
        if s is not None and (not isinstance(s,dict) or s.get('token')!='\(tokenHex)'):
            raise RuntimeError('runtime module cleanup token mismatch')
        if isinstance(s,dict):
            n['_SNAPSHOT']=None
        d.pop('\(installBufferKey)',None)
        r=n.get('_SNAPSHOT') if isinstance(n,dict) else None
        if '\(installBufferKey)' in d or (isinstance(r,dict) and r.get('token')=='\(tokenHex)'):
            raise RuntimeError('runtime module cleanup not proven')
        print('MACSCOPE_LLDB_MODULE_CLEANUP_V1 {"ok":true,"schema":1,"token":"\(tokenHex)"}')
        """
    }

    func completeEncodedWireByteCount(for command: String) throws -> Int {
        let markers = try LLDBCLIExchangeMarkers(
            token: String(repeating: "f", count: LLDBCLIExchangeMarkers.tokenCharacterCount)
        )
        let count = PersistentLLDBCLIAdapter.encodedWirePayload(
            semanticCommands: [command],
            markers: markers
        ).count
        guard count <= Self.maximumEncodedWireBytes else {
            throw LLDBRuntimeModuleExtractorProgramError.encodedWireTooLarge
        }
        return count
    }

    private static let installBufferKey = "__macscope_lldb_module_install_v1"
    private static let programKey = "__macscope_lldb_module_extractor_v1"

    private static func installChunkCommand(
        index: Int,
        count: Int,
        sourceByteCount: Int,
        digestHex: String,
        chunk: String
    ) -> String {
        let initial = "{'n':0,'c':\(count),'b':\(sourceByteCount),'h':'\(digestHex)','p':[]}"
        return "script import builtins;d=builtins.__dict__;k='\(installBufferKey)';i=\(index);s=\(index == 0 ? initial : "d.get(k)");assert isinstance(s,dict) and s.get('n')==i and s.get('c')==\(count) and s.get('b')==\(sourceByteCount) and s.get('h')=='\(digestHex)' and isinstance(s.get('p'),list);s['p'].append('\(chunk)');s['n']+=1;d[k]=s"
    }

    private static func finalizeScript(
        chunkCount: Int,
        sourceByteCount: Int,
        digestHex: String
    ) -> String {
        """
        import base64,builtins,hashlib
        d=builtins.__dict__;k='\(installBufferKey)';h='\(digestHex)'
        try:
            s=d.get(k);assert isinstance(s,dict) and s.get('n')==\(chunkCount) and s.get('c')==\(chunkCount) and s.get('b')==\(sourceByteCount) and s.get('h')==h and len(s.get('p',[]))==\(chunkCount)
            x=base64.b64decode(''.join(s['p']),validate=True);assert len(x)==\(sourceByteCount) and hashlib.sha256(x).hexdigest()==h
            n={'__builtins__':__builtins__};exec(compile(x.decode('utf-8'),'<macscope-runtime-modules>','exec'),n,n);assert callable(n.get('page')) and callable(n.get('cleanup'))
            n['__source_sha256__']=h;d['\(programKey)']=n
            print('MACSCOPE_LLDB_MODULE_INSTALL_V1 {"ok":true,"schema":1,"sha256":"'+h+'"}')
        finally:
            d.pop(k,None)
        """
    }

    private static func proofScript(digestHex: String) -> String {
        """
        import builtins
        namespace = builtins.__dict__.get('\(programKey)')
        if not isinstance(namespace, dict) or namespace.get('__source_sha256__') != '\(digestHex)' or not callable(namespace.get('page')) or not callable(namespace.get('cleanup')):
            raise RuntimeError('runtime module extractor proof failed')
        print('MACSCOPE_LLDB_MODULE_INSTALL_V1 {"ok":true,"schema":1,"sha256":"\(digestHex)"}')
        """
    }

    private static func encodedScriptCommand(_ script: String) -> String {
        // JSON string escaping is also a valid Python string literal for this ASCII-only static
        // source and avoids a second Base64 expansion inside the adapter's already encoded wire.
        let literal = String(data: try! JSONEncoder().encode(script), encoding: .utf8)!
        return "script exec(\(literal))"
    }

    private static func isCanonicalToken(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// The source is intentionally ordinary Python rather than generated text so its exact bytes,
    /// digest, bounds, and installed entry points remain reviewable and deterministic.
    private static let extractorSource = #"""
import base64
import builtins
import hashlib
import json
import lldb
import uuid as py_uuid

_SNAPSHOT = None
_INSTALL_KEY = "__macscope_lldb_module_install_v1"
_PAGE_SENTINEL = "MACSCOPE_LLDB_MODULE_PAGE_V1 "
_CLEANUP_SENTINEL = "MACSCOPE_LLDB_MODULE_CLEANUP_V1 "
_MAX_U64 = (1 << 64) - 1
_MAX_MODULES = 4096
_MAX_SECTIONS = 128
_MAX_PATH_BYTES = 4096
_MAX_TEXT_BYTES = 256
_MAX_SNAPSHOT_BYTES = 8 * 1024 * 1024
_MAX_LOGICAL_BYTES = 8 * 1024 * 1024
_MAX_RAW_PAGE_BYTES = 128 * 1024
_MAX_WRAPPED_RESULT_BYTES = 192 * 1024
_MAX_PAGES = 64

def _canonical(value):
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True)

def _emit(sentinel, value):
    print(sentinel + _canonical(value))

def _capacity(token):
    _emit(_PAGE_SENTINEL, {"code": "capacity", "ok": False, "schema": 1, "token": token})

def _token_is_valid(token):
    return isinstance(token, str) and len(token) == 64 and all(c in "0123456789abcdef" for c in token)

def _utf8(text, maximum, allow_empty=True):
    if not isinstance(text, str):
        raise RuntimeError("invalid extractor text")
    encoded = text.encode("utf-8")
    if len(encoded) > maximum or (not allow_empty and not encoded) or any(ord(c) < 32 or ord(c) == 127 for c in text):
        raise RuntimeError("extractor text bound exceeded")
    return encoded

def _b64(text, maximum, allow_empty=True):
    return base64.b64encode(_utf8(text, maximum, allow_empty)).decode("ascii")

def _hex(value):
    if not isinstance(value, int) or value < 0 or value > _MAX_U64:
        raise RuntimeError("invalid extractor address")
    return format(value, "016x")

def _path(module):
    spec = module.GetFileSpec()
    try:
        fullpath = spec.fullpath
    except AttributeError:
        fullpath = None
    if isinstance(fullpath, str) and fullpath:
        return fullpath
    directory = spec.GetDirectory() or ""
    filename = spec.GetFilename() or ""
    if directory and filename:
        return directory.rstrip("/") + "/" + filename
    return directory or filename

def _record_module(module, target, ordinal):
    uuid_text = module.GetUUIDString() or None
    if uuid_text is not None:
        uuid_text = str(py_uuid.UUID(uuid_text))
    triple = (module.GetTriple() or "").lower()
    triple_bytes = _utf8(triple, _MAX_TEXT_BYTES, False)
    path_bytes = _utf8(_path(module), _MAX_PATH_BYTES, True)
    path64 = base64.b64encode(path_bytes).decode("ascii")
    logical_bytes = 65 + (16 if uuid_text is not None else 0) + len(path_bytes) + len(triple_bytes)
    sections = []
    count = int(module.GetNumSections())
    for source_index in range(count):
        section = module.GetSectionAtIndex(source_index)
        static_start = int(section.GetFileAddress())
        byte_count = int(section.GetByteSize())
        if static_start == int(lldb.LLDB_INVALID_ADDRESS) or byte_count == 0:
            continue
        if byte_count < 0 or static_start < 0 or static_start > _MAX_U64 or static_start + byte_count - 1 > _MAX_U64:
            raise RuntimeError("invalid extractor static range")
        if len(sections) >= _MAX_SECTIONS:
            raise RuntimeError("extractor section capacity")
        raw_name = section.GetName()
        name_bytes = None if raw_name is None else _utf8(raw_name, _MAX_TEXT_BYTES, False)
        name64 = None if name_bytes is None else base64.b64encode(name_bytes).decode("ascii")
        runtime_start = int(section.GetLoadAddress(target))
        if runtime_start == int(lldb.LLDB_INVALID_ADDRESS):
            runtime_hex = None
        else:
            if runtime_start < 0 or runtime_start > _MAX_U64 or runtime_start + byte_count - 1 > _MAX_U64:
                raise RuntimeError("invalid extractor runtime range")
            runtime_hex = _hex(runtime_start)
        permissions = int(section.GetPermissions())
        if permissions < 0 or permissions > 7:
            raise RuntimeError("invalid extractor permissions")
        sections.append([len(sections), name64, _hex(static_start), runtime_hex, _hex(byte_count), permissions])
        logical_bytes += 27 + (0 if name_bytes is None else 8 + len(name_bytes)) + (0 if runtime_hex is None else 8)
    return [ordinal, uuid_text, path64, triple, sections], logical_bytes

def _observe_process(target):
    process = target.GetProcess()
    pid = int(process.GetProcessID())
    state = int(process.GetState())
    stop_id = int(process.GetStopID())
    if pid <= 0 or pid > 2147483647 or state != int(lldb.eStateStopped) or stop_id < 0 or stop_id > 4294967295:
        raise RuntimeError("runtime module process is not stopped")
    return process, pid, stop_id

def _build_snapshot(token):
    global _SNAPSHOT
    _SNAPSHOT = {"token": token}
    target = lldb.debugger.GetSelectedTarget()
    process, pid, stop_id = _observe_process(target)
    records = []
    snapshot_bytes = 2
    logical_bytes = 81
    for index, module in enumerate(target.modules):
        if index >= _MAX_MODULES:
            _SNAPSHOT["capacity"] = True
            return
        record, record_logical_bytes = _record_module(module, target, index)
        record_bytes = len(_canonical(record).encode("ascii"))
        prospective_snapshot_bytes = snapshot_bytes + record_bytes + (1 if records else 0)
        prospective_logical_bytes = logical_bytes + record_logical_bytes
        if prospective_snapshot_bytes > _MAX_SNAPSHOT_BYTES or prospective_logical_bytes > _MAX_LOGICAL_BYTES:
            _SNAPSHOT["capacity"] = True
            return
        records.append(record)
        snapshot_bytes = prospective_snapshot_bytes
        logical_bytes = prospective_logical_bytes
    canonical = _canonical(records).encode("ascii")
    if len(canonical) != snapshot_bytes:
        raise RuntimeError("runtime module snapshot accounting mismatch")
    _SNAPSHOT.update({
        "records": records,
        "digest": hashlib.sha256(canonical).hexdigest(),
        "pid": pid,
        "stop_id": stop_id,
        "count": len(records),
        "next": 0,
        "pages": 0,
    })

def _wrapped_size(raw_size):
    base64_size = ((raw_size + 2) // 3) * 4
    return len("__MACSCOPE_LLDB_COMMAND_RESULT_") + 64 + len("_0_") + base64_size + len("__\n")

def _page_envelope(snapshot, start, end):
    return {
        "digest": snapshot["digest"],
        "end": end,
        "final": end == snapshot["count"],
        "module_count": snapshot["count"],
        "modules": snapshot["records"][start:end],
        "observed_pid": snapshot["pid"],
        "observed_state": "stopped",
        "observed_stop_id": snapshot["stop_id"],
        "ok": True,
        "schema": 1,
        "start": start,
        "token": snapshot["token"],
    }

def _page_fits(value):
    raw_size = len((_PAGE_SENTINEL + _canonical(value) + "\n").encode("ascii"))
    return raw_size <= _MAX_RAW_PAGE_BYTES and _wrapped_size(raw_size) <= _MAX_WRAPPED_RESULT_BYTES

def page(token, cursor):
    global _SNAPSHOT
    if not _token_is_valid(token) or not isinstance(cursor, int) or cursor < 0 or cursor > _MAX_MODULES:
        raise RuntimeError("invalid runtime module invocation")
    if cursor == 0:
        _build_snapshot(token)
    snapshot = _SNAPSHOT
    if not isinstance(snapshot, dict) or snapshot.get("token") != token:
        raise RuntimeError("runtime module snapshot token mismatch")
    if snapshot.get("capacity"):
        _capacity(token)
        return
    target = lldb.debugger.GetSelectedTarget()
    process, pid, stop_id = _observe_process(target)
    if pid != snapshot["pid"] or stop_id != snapshot["stop_id"] or cursor != snapshot["next"]:
        raise RuntimeError("runtime module snapshot changed")
    if snapshot["pages"] >= _MAX_PAGES:
        _capacity(token)
        return
    count = snapshot["count"]
    if cursor > count:
        raise RuntimeError("runtime module cursor exceeds count")
    if count == 0:
        envelope = _page_envelope(snapshot, 0, 0)
        if not _page_fits(envelope):
            _capacity(token)
            return
        snapshot["pages"] += 1
        _emit(_PAGE_SENTINEL, envelope)
        return
    lower = cursor
    upper = count
    while lower < upper:
        candidate_end = (lower + upper + 1) // 2
        if _page_fits(_page_envelope(snapshot, cursor, candidate_end)):
            lower = candidate_end
        else:
            upper = candidate_end - 1
    end = lower
    if end == cursor:
        _capacity(token)
        return
    envelope = _page_envelope(snapshot, cursor, end)
    snapshot["next"] = end
    snapshot["pages"] += 1
    _emit(_PAGE_SENTINEL, envelope)

def cleanup(token):
    global _SNAPSHOT
    if not _token_is_valid(token) or not isinstance(_SNAPSHOT, dict) or _SNAPSHOT.get("token") != token:
        raise RuntimeError("runtime module cleanup token mismatch")
    _SNAPSHOT = None
    builtins.__dict__.pop(_INSTALL_KEY, None)
    _emit(_CLEANUP_SENTINEL, {"ok": True, "schema": 1, "token": token})
"""#
}
