import Foundation

/// Runs only inside the retained LLDB interpreter. Callers use correlated semantic-command
/// output, never inferior stdout, when decoding the final command's response.
enum LLDBWatchpointProgram {
    static let marker = "MACSCOPE_LLDB_WATCHPOINTS_V1 "
    static let maximumResponseBytes = 32 * 1_024

    /// Chunking keeps each command below the persistent transport's 4 KiB wire limit.
    /// Reinstallation preserves the session's ownership ledger.
    static var installCommands: [String] {
        let encoded = Array(Data(source.utf8).base64EncodedString())
        var commands = ["script __ms_wp_source = ''"]
        for offset in stride(from: 0, to: encoded.count, by: 1_024) {
            let chunk = String(encoded[offset..<min(offset + 1_024, encoded.count)])
            commands.append("script __ms_wp_source += '\(chunk)'")
        }
        commands.append("script import base64; exec(compile(base64.b64decode(__ms_wp_source), '<macscope-watchpoints>', 'exec')); del __ms_wp_source")
        return commands
    }

    static func command(
        for request: DebuggerWatchpointRequest,
        processID: Int32,
        stopID: UInt32
    ) throws -> String {
        try request.validate()
        guard processID > 0 else { throw DebuggerWatchpointError.invalidProcess }
        var payload: [String: Any] = ["pid": Int(processID), "stop": Int(stopID)]
        switch request {
        case .upsert(let id, let address, let size, let access, let enabled):
            payload.merge([
                "op": "upsert", "id": id.uuidString, "address": String(address),
                "size": size, "access": access.rawValue, "enabled": enabled,
            ]) { _, new in new }
        case .remove(let id):
            payload["op"] = "remove"
            payload["id"] = id.uuidString
        case .setEnabled(let id, let enabled):
            payload["op"] = "enable"
            payload["id"] = id.uuidString
            payload["enabled"] = enabled
        case .refresh:
            payload["op"] = "refresh"
        }
        let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            .base64EncodedString()
        return "script __ms_wp_run('\(encoded)')"
    }

    static func decode(transcript: String) throws -> DebuggerWatchpointUpdate {
        guard transcript.utf8.count <= maximumResponseBytes else {
            throw DebuggerWatchpointError.invalidResponse
        }
        // One semantic command must yield exactly one bounded record, with no extra output.
        let line = transcript.hasSuffix("\n") ? String(transcript.dropLast()) : transcript
        guard line.hasPrefix(marker), !line.contains("\n"), !line.contains("\r") else {
            throw DebuggerWatchpointError.invalidResponse
        }
        let data = Data(line.dropFirst(marker.count).utf8)
        let update: DebuggerWatchpointUpdate
        do { update = try JSONDecoder().decode(DebuggerWatchpointUpdate.self, from: data) }
        catch { throw DebuggerWatchpointError.invalidResponse }
        guard update.watchpoints.count <= 64,
              Set(update.watchpoints.map(\.id)).count == update.watchpoints.count,
              Set(update.watchpoints.map(\.backendID)).count == update.watchpoints.count,
              update.error.map({ $0.utf8.count <= 2_048 }) ?? true else {
            throw DebuggerWatchpointError.invalidResponse
        }
        for entry in update.watchpoints {
            guard entry.backendID > 0 else { throw DebuggerWatchpointError.invalidResponse }
            do { try DebuggerWatchpointRequest.validate(address: entry.address, size: entry.size) }
            catch { throw DebuggerWatchpointError.invalidResponse }
        }
        return update
    }

    // SBProcess hardware capacity and SBTarget WatchAddress signatures are documented at
    // https://lldb.llvm.org/python_api/lldb.SBProcess.html and lldb.SBTarget.html.
    static let source = #"""
import base64, json, uuid, lldb
__ms_wp_state = globals().get('__ms_wp_state', {'process': None, 'owned': {}})

def __ms_wp_run(encoded):
    result = {'watchpoints': [], 'error': None}
    owned = None
    target = None
    def fail(message):
        raise RuntimeError(message)
    def observe():
        t = lldb.debugger.GetSelectedTarget()
        p = t.GetProcess()
        if not t.IsValid() or not p.IsValid():
            fail('No valid debugger process.')
        if int(p.GetProcessID()) != request['pid'] or int(p.GetStopID()) != request['stop']:
            fail('Debugger process or stop changed; refresh before editing watchpoints.')
        if p.GetState() != lldb.eStateStopped:
            fail('Watchpoint changes require a stopped process.')
        return t, p
    def signature(w):
        return (int(w.GetWatchAddress()), int(w.GetWatchSize()), bool(w.IsWatchingReads()), bool(w.IsWatchingWrites()))
    def live(record):
        w = target.FindWatchpointByID(record['backendID'])
        return w if w.IsValid() and w == record['handle'] and signature(w) == record['signature'] else None
    def catalog():
        entries = []
        for ident, record in list(owned.items()):
            w = live(record)
            if w is None:
                del owned[ident]
                continue
            address, size, reads, writes = signature(w)
            entries.append({'id': ident, 'address': address, 'size': size,
                            'access': 'rw' if reads and writes else ('read' if reads else 'write'),
                            'isEnabled': bool(w.IsEnabled()), 'backendID': int(w.GetID())})
        return sorted(entries, key=lambda v: v['id'])
    def room():
        error = lldb.SBError()
        capacity = int(process.GetNumSupportedHardwareWatchpoints(error))
        if error.Fail() or capacity <= 0:
            fail('Hardware watchpoint capacity is unavailable or unsupported.')
        count = int(target.GetNumWatchpoints())
        if count > 4096:
            fail('Debugger watchpoint catalog exceeds the inspection limit.')
        used = sum(1 for i in range(count) if target.GetWatchpointAtIndex(i).IsEnabled())
        if used >= capacity:
            fail('Hardware watchpoint limit reached; existing watchpoints were retained.')
    def enable(w, value):
        if value and not w.IsEnabled():
            room()
        observe()
        w.SetEnabled(value)
        if bool(w.IsEnabled()) != value or w.GetError().Fail():
            fail('LLDB could not change watchpoint enabled state.')
    try:
        request = json.loads(base64.b64decode(encoded, validate=True))
        if type(request.get('pid')) is not int or request['pid'] <= 0 or type(request.get('stop')) is not int:
            fail('Invalid process authority.')
        target, process = observe()
        unique = int(process.GetUniqueID())
        if unique <= 0:
            fail('Debugger process identity is unavailable.')
        if __ms_wp_state['process'] != unique:
            __ms_wp_state['process'] = unique
            __ms_wp_state['owned'] = {}
        owned = __ms_wp_state['owned']
        catalog()
        op = request.get('op')
        ident = str(uuid.UUID(request['id'])).upper() if op != 'refresh' else None
        record = owned.get(ident)
        old = live(record) if record else None
        if op == 'upsert':
            address, size, access = int(request['address']), request['size'], request['access']
            enabled = request['enabled']
            if type(size) is not int or size not in (1, 2, 4, 8) or type(enabled) is not bool:
                fail('Invalid watchpoint size or enabled state.')
            if address < 0 or address > (1 << 64) - size or address % size or access not in ('read', 'write', 'rw'):
                fail('Invalid watchpoint range, alignment, or access.')
            desired = (address, size, access in ('read', 'rw'), access in ('write', 'rw'))
            if old is not None and signature(old) == desired:
                enable(old, enabled)
            else:
                if len(owned) >= 64 and old is None:
                    fail('Owned watchpoint limit reached.')
                room()
                # WatchAddress may replace an existing address; refuse overlaps before mutation.
                for index in range(int(target.GetNumWatchpoints())):
                    other = target.GetWatchpointAtIndex(index)
                    start, length, _, _ = signature(other)
                    if address < start + length and start < address + size:
                        fail('Watchpoint overlaps an existing range; remove it explicitly before changing that range.')
                observe()
                error = lldb.SBError()
                new = target.WatchAddress(address, size, desired[2], desired[3], error)
                if error.Fail() or not new.IsValid() or int(new.GetID()) <= 0:
                    fail('LLDB refused the hardware watchpoint: ' + str(error.GetCString() or 'unknown error'))
                new_id = int(new.GetID())
                # Record immediately so a later failure reports all surviving owned watchpoints.
                new_key = ident if old is None else str(uuid.uuid4()).upper()
                owned[new_key] = {'backendID': new_id, 'signature': signature(new), 'handle': new}
                if signature(new) != desired:
                    fail('LLDB created a different watchpoint range or access; inspect the resulting catalog.')
                if not enabled:
                    enable(new, False)
                if old is not None:
                    observe()
                    if not target.DeleteWatchpoint(int(old.GetID())):
                        fail('Replacement created, but original watchpoint deletion failed; both are shown.')
                    if target.FindWatchpointByID(int(old.GetID())).IsValid():
                        fail('Original watchpoint is still present; both are shown.')
                    del owned[ident]
                    owned[ident] = owned.pop(new_key)
        elif op == 'remove':
            if old is None:
                fail('Watchpoint no longer belongs to this debugger session.')
            observe()
            if not target.DeleteWatchpoint(int(old.GetID())) or target.FindWatchpointByID(int(old.GetID())).IsValid():
                fail('LLDB could not remove the watchpoint.')
            del owned[ident]
        elif op == 'enable':
            if old is None or type(request.get('enabled')) is not bool:
                fail('Watchpoint no longer belongs to this debugger session.')
            enable(old, request['enabled'])
        elif op != 'refresh':
            fail('Unknown watchpoint operation.')
    except Exception as error:
        result['error'] = str(error).encode('utf-8')[:2048].decode('utf-8', errors='ignore')
    if owned is not None:
        try:
            result['watchpoints'] = catalog()
        except Exception:
            result['error'] = 'Could not read the resulting watchpoint catalog; refresh required.'
    print('MACSCOPE_LLDB_WATCHPOINTS_V1 ' + json.dumps(result, separators=(',', ':')))
"""#
}
