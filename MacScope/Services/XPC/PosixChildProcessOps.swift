import Darwin
import MacScopeChildProcessC
import Foundation

/// Live adapter, constructed only by a future granted worker composition, never by the app.
/// All calls are made by one OwnedChildController owner queue. The extra lock fences direct
/// misuse too; callbacks are dispatched on a different serial queue, never synchronously.
final class PosixChildProcessOps: OwnedChildProcessOperations, @unchecked Sendable {
    enum PeerEvent: Sendable {
        case ready(AnalysisWorkerOwnedChildIdentity)
        case returned(AnalysisWorkerOwnedChildIdentity, Data)
        case rejectedBeforeNative(AnalysisWorkerOwnedChildIdentity, String)
        case protocolFailure(AnalysisWorkerOwnedChildIdentity)
        case diagnostics(AnalysisWorkerOwnedChildIdentity, stderrBytes: UInt64, truncated: Bool)
    }
    private final class Child {
        let identity: AnalysisWorkerOwnedChildIdentity
        let input: Int32; let output: Int32; let error: Int32
        var pending = Data(); var stdout = Data(); var stderrTail = Data()
        var handshake = false; var failed = false; var reaped = false; var authority = true
        var finalReply: Data?
        var terminalSeen = false
        var stderrBytes: UInt64 = 0
        init(identity: AnalysisWorkerOwnedChildIdentity, input: Int32, output: Int32, error: Int32) {
            self.identity = identity; self.input = input; self.output = output; self.error = error
        }
        deinit { close(input); close(output); close(error) } // No implicit kill or wait.
    }
    private final class WaitOwnership: @unchecked Sendable {
        let lock = NSLock(); var owner: UUID?
    }
    private static let ownership = WaitOwnership()
    private let token = UUID()
    private let lock = NSLock()
    private let callbackQueue = DispatchQueue(label: "org.macscope.app.owned-child-peer-events")
    private let events: @Sendable (PeerEvent) -> Void
    private let maximumWireBytes: Int
    private var child: Child?

    init(maximumWireBytes: Int, events: @escaping @Sendable (PeerEvent) -> Void) {
        self.maximumWireBytes = maximumWireBytes; self.events = events
    }
    deinit {
        // Unresolved children keep the process-wide owner reservation; destruction is not exit.
        if child == nil { Self.ownership.lock.withLock {
            if Self.ownership.owner == token { Self.ownership.owner = nil }
        } }
    }

    func preservesWaitableChildren() -> Bool {
        lock.withLock {
            var disposition = sigaction()
            guard MacScopeReadSignalDisposition(SIGCHLD, &disposition) == 0,
                  disposition.__sigaction_u.__sa_handler == nil,
                  disposition.sa_flags & SA_NOCLDWAIT == 0 else { return false }
            // Parent code must keep that disposition immutable and use no other waiter.
            return Self.ownership.lock.withLock {
                guard Self.ownership.owner == nil || Self.ownership.owner == token else { return false }
                Self.ownership.owner = token; return true
            }
        }
    }

    static func executablePath(workerBundle: URL, channel: AnalysisWorkerOwnedChildChannel) -> String? {
        guard workerBundle.lastPathComponent == "AnalysisWorkerXPCService.xpc",
              workerBundle.deletingLastPathComponent().lastPathComponent == "XPCServices" else { return nil }
        let bundle = channel == .decompiler
            ? workerBundle.deletingLastPathComponent().appendingPathComponent("NativeDecompilerXPCService.xpc")
            : workerBundle
        let name = channel == .decompiler ? "NativeDecompilerXPCService" : "AnalysisWorkerXPCService"
        return bundle.appendingPathComponent("Contents/MacOS/" + name).path
    }

    func spawn(_ launch: OwnedChildLaunch) -> OwnedChildSpawnResult {
        lock.withLock {
            guard child == nil, launch.parent.processID == getpid(), maximumWireBytes > 0,
                  maximumWireBytes <= Int(UInt32.max),
                  Self.ownership.lock.withLock({ Self.ownership.owner == token }),
                  let path = Self.executablePath(workerBundle: Bundle.main.bundleURL, channel: launch.key.channel)
            else { return .notCreated(errno: EINVAL) }
            var descriptors: [Int32] = []
            defer { descriptors.forEach { close($0) } }
            do {
                for _ in 0..<3 { descriptors += try Self.makePipe() }
                var actions: posix_spawn_file_actions_t?
                var attrs: posix_spawnattr_t?
                let actionsStatus = posix_spawn_file_actions_init(&actions)
                guard actionsStatus == 0 else { return .notCreated(errno: actionsStatus) }
                defer { posix_spawn_file_actions_destroy(&actions) }
                let attrsStatus = posix_spawnattr_init(&attrs)
                guard attrsStatus == 0 else { return .notCreated(errno: attrsStatus) }
                defer { posix_spawnattr_destroy(&attrs) }
                for (source, destination) in [(descriptors[0], STDIN_FILENO),
                                               (descriptors[3], STDOUT_FILENO), (descriptors[5], STDERR_FILENO)] {
                    let status = posix_spawn_file_actions_adddup2(&actions, source, destination)
                    guard status == 0 else { return .notCreated(errno: status) }
                }
                var mask = sigset_t(); sigemptyset(&mask)
                var defaults = sigset_t(); sigemptyset(&defaults)
                for signal in [SIGINT, SIGTERM, SIGPIPE, SIGCHLD] { sigaddset(&defaults, signal) }
                for status in [posix_spawnattr_setpgroup(&attrs, 0),
                               posix_spawnattr_setsigmask(&attrs, &mask),
                               posix_spawnattr_setsigdefault(&attrs, &defaults),
                               posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP |
                                 POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))] {
                    guard status == 0 else { return .notCreated(errno: status) }
                }
                // Only parent ends are nonblocking; child keeps ordinary blocking stdio.
                for fd in [descriptors[1], descriptors[2], descriptors[4]] {
                    guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw SpawnFailure(errno) }
                }
                guard fcntl(descriptors[1], F_SETNOSIGPIPE, 1) == 0 else { throw SpawnFailure(errno) }
                var pid: pid_t = 0
                let status = Self.withStrings([path, PosixOwnedChildMode.flag, "--channel", launch.key.channel.rawValue]) { argv in
                    Self.withStrings(PosixOwnedChildMode.environment.keys.sorted().map { "\($0)=\(PosixOwnedChildMode.environment[$0] ?? "")" }) { env in
                        posix_spawn(&pid, path, &actions, &attrs, argv, env)
                    }
                }
                guard status == 0 else { return .notCreated(errno: status) }
                let identity = AnalysisWorkerOwnedChildIdentity(parentStartupNonce: launch.parent.startupNonce,
                    spawnNonce: launch.spawnNonce, processID: pid, channel: launch.key.channel,
                    requestID: launch.key.requestID, connectionGeneration: launch.key.connectionGeneration)
                child = Child(identity: identity, input: descriptors[1], output: descriptors[2], error: descriptors[4])
                // Transfer only parent endpoints; deferred close retires all child endpoints.
                descriptors = [descriptors[0], descriptors[3], descriptors[5]]
                return .created(pid: pid)
            } catch let error as SpawnFailure { return .notCreated(errno: error.code) }
            catch { return .notCreated(errno: EIO) }
        }
    }

    func send(_ command: OwnedChildCommand, to identity: AnalysisWorkerOwnedChildIdentity) -> Bool {
        lock.withLock {
            guard let child, child.identity == identity, child.authority, !child.reaped else { return false }
            var wire = Self.wire(identity, kind: "initialize")
            let line: Bool
            switch command {
            case .initialize: line = true
            case .execute(let payload): wire.kind = "execute"; wire.payload = payload; line = false
            case .abort: wire.kind = "abort"; line = false
            case .shutdown: wire.kind = "shutdown"; line = false
            }
            guard let encoded = try? (line ? wire.encoded() + Data([10]) : wire.framed()),
                  encoded.count <= maximumWireBytes, child.pending.count <= maximumWireBytes - encoded.count
            else { return false }
            child.pending.append(encoded)
            return flush(child)
        }
    }
    func signalKill(_ identity: AnalysisWorkerOwnedChildIdentity) -> OwnedChildSignalResult {
        lock.withLock {
            guard let child, child.identity == identity, child.authority, !child.reaped,
                  identity.processID > 1, identity.processID != getpid() else { return .failed(errno: EINVAL) }
            // Never killpg: only this exact positive unreaped child PID, under the wait lock.
            return Darwin.kill(identity.processID, SIGKILL) == 0 ? .sent : .failed(errno: errno)
        }
    }
    func waitNoHang(_ identity: AnalysisWorkerOwnedChildIdentity) -> OwnedChildWaitResult {
        lock.withLock {
            guard let child, child.identity == identity, child.authority, !child.reaped else { return .failed(errno: ECHILD) }
            _ = flush(child); pump(child, budget: 65536)
            var status: Int32 = 0
            let result = Darwin.waitpid(identity.processID, &status, WNOHANG)
            if result == 0 { return .pending }
            if result < 0 {
                if errno == EINTR { return .interrupted }
                let code = errno; child.authority = false
                return .failed(errno: code)
            }
            // SDK sys/wait.h: _WSTATUS=status&0177, stopped=0177, core flag=0200.
            let signal = status & 0x7f
            if signal == 0x7f { return .nonterminal }
            child.reaped = true; child.authority = false
            let termination: AnalysisWorkerOwnedChildTermination = signal == 0
                ? .exited(code: (status >> 8) & 0xff)
                : .signalled(signal: signal, coreDumped: status & 0x80 != 0)
            return .terminal(pid: result, rawStatus: status, termination: termination)
        }
    }
    func finalReplyAfterExit(_ identity: AnalysisWorkerOwnedChildIdentity) -> Data? {
        lock.withLock {
            guard let child, child.identity == identity, child.reaped else { return nil }
            pump(child, budget: maximumWireBytes)
            let reply = child.failed ? nil : child.finalReply
            emit(.diagnostics(identity, stderrBytes: child.stderrBytes, truncated: child.stderrBytes > 65536))
            self.child = nil // Descriptors close only after final bounded drain and receipt.
            return reply
        }
    }

    private func flush(_ child: Child) -> Bool {
        var budget = 65536
        while !child.pending.isEmpty, budget > 0 {
            let count = child.pending.withUnsafeBytes { Darwin.write(child.input, $0.baseAddress, min($0.count, budget)) }
            if count < 0, errno == EINTR || errno == EAGAIN { return true }
            guard count > 0 else { fail(child); return false }
            child.pending.removeFirst(count); budget -= count
        }
        return true
    }
    private func pump(_ child: Child, budget: Int) {
        drain(child.output, budget: budget) { data in
            guard !child.failed, child.stdout.count <= maximumWireBytes - data.count else { fail(child); return }
            child.stdout.append(data); parse(child)
        }
        drain(child.error, budget: budget) { data in
            let total = child.stderrBytes.addingReportingOverflow(UInt64(data.count))
            child.stderrBytes = total.overflow ? UInt64.max : total.partialValue
            child.stderrTail.append(data)
            if child.stderrTail.count > 65536 { child.stderrTail.removeFirst(child.stderrTail.count - 65536) }
        }
    }
    private func drain(_ fd: Int32, budget: Int, consume: (Data) -> Void) {
        var remaining = budget
        var buffer = [UInt8](repeating: 0, count: 8192)
        while remaining > 0 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, min($0.count, remaining)) }
            if count < 0, errno == EINTR { return }
            guard count > 0 else { return }
            consume(Data(buffer.prefix(count))); remaining -= count
        }
    }
    private func parse(_ child: Child) {
        while !child.failed {
            let body: Data
            if !child.handshake {
                guard let newline = child.stdout.firstIndex(of: 10) else {
                    if child.stdout.count >= 1024 { fail(child) }; return
                }
                guard newline < 1024 else { fail(child); return }
                body = Data(child.stdout.prefix(newline)); child.stdout = Data(child.stdout.dropFirst(newline + 1))
            } else {
                guard child.stdout.count >= 4 else { return }
                let count = Int(child.stdout.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                guard count > 0, count <= maximumWireBytes else { fail(child); return }
                guard child.stdout.count - 4 >= count else { return }
                body = child.stdout.subdata(in: 4..<(4 + count)); child.stdout = Data(child.stdout.dropFirst(4 + count))
            }
            guard let wire = try? OwnedChildWire.decode(body, maximum: child.handshake ? maximumWireBytes : 1024),
                  wire.sameIdentity(as: Self.wire(child.identity, kind: wire.kind)) else { fail(child); return }
            if !child.handshake {
                guard wire.kind == "ready", wire.payload == nil, wire.reason == nil else { fail(child); return }
                child.handshake = true; emit(.ready(child.identity))
            } else {
                switch wire.kind {
                case "nativeReturned":
                    guard let payload = wire.payload, wire.reason == nil,
                          !child.terminalSeen else { fail(child); return }
                    child.terminalSeen = true; child.finalReply = payload; emit(.returned(child.identity, payload))
                case "rejectedBeforeNative":
                    guard wire.payload == nil, wire.reason == "unavailable",
                          !child.terminalSeen else { fail(child); return }
                    child.terminalSeen = true
                    emit(.rejectedBeforeNative(child.identity, "unavailable"))
                case "abortAcknowledged":
                    guard wire.payload == nil, wire.reason == nil else { fail(child); return }
                    break // Advisory only, never a terminal reply.
                default: fail(child); return
                }
            }
        }
    }
    private func fail(_ child: Child) {
        guard !child.failed else { return }
        child.failed = true; emit(.protocolFailure(child.identity))
    }
    private func emit(_ event: PeerEvent) { callbackQueue.async { [events] in events(event) } }
    private static func wire(_ identity: AnalysisWorkerOwnedChildIdentity, kind: String) -> OwnedChildWire {
        .init(kind: kind, parentStartupNonce: identity.parentStartupNonce, spawnNonce: identity.spawnNonce,
              processID: identity.processID, channel: identity.channel.rawValue, requestID: identity.requestID,
              connectionGeneration: identity.connectionGeneration)
    }
    private struct SpawnFailure: Error { let code: Int32; init(_ code: Int32) { self.code = code } }
    private static func makePipe() throws -> [Int32] {
        var pair: [Int32] = [0, 0]
        guard pipe(&pair) == 0 else { throw SpawnFailure(errno) }
        defer { pair.forEach { close($0) } }
        var copied: [Int32] = []
        for fd in pair {
            let copy = fcntl(fd, F_DUPFD_CLOEXEC, 4)
            guard copy >= 0 else { let code = errno; copied.forEach { close($0) }; throw SpawnFailure(code) }
            copied.append(copy)
        }
        return copied
    }
    private static func withStrings(_ values: [String], body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32) -> Int32 {
        var strings: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        guard strings.allSatisfy({ $0 != nil }) else { return ENOMEM }
        strings.append(nil)
        return strings.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return EINVAL }
            return body(base)
        }
    }
}
