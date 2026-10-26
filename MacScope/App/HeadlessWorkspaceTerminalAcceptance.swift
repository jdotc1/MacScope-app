import Foundation
import Darwin

/// Exercises the production store/broker boundary without a renderer or application scene.
/// The caller owns workspace admission, serialization, the heavy-job lock and persistence.
@MainActor
enum HeadlessWorkspaceTerminalAcceptance {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private struct Identity: Equatable {
        let pid: Int32
        let parent: UInt32
        let group: Int32
        let seconds: UInt64
        let microseconds: UInt64
        let path: String

        var evidence: ScriptValue {
            .object([
                "pid": .int(Int64(pid)), "parent": .int(Int64(parent)),
                "group": .int(Int64(group)), "startSeconds": .int(Int64(seconds)),
                "startMicroseconds": .int(Int64(microseconds)), "path": .string(path)
            ])
        }
    }

    static func run(store: WorkspaceStore, artifactRoot: URL) async throws -> ScriptValue {
        // Unique child directory prevents a stale PID file from admitting another process.
        let root = artifactRoot.appendingPathComponent("terminal-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        var observations: [String: ScriptValue] = [:]
        var stage = "launch"
        var admittedLaunch = false
        func record(_ name: String, _ identity: Identity) {
            observations[name] = identity.evidence
        }
        func receipt(_ success: Bool, error: String? = nil) -> ScriptValue {
            let canceled: Bool
            if case .terminal(outcome: .canceled) = store.phase2ShellSession.snapshot?.state {
                canceled = true
            } else {
                canceled = false
            }
            return .object([
                "passed": .bool(success), "stage": .string(stage),
                "actualFinalCanceled": .bool(canceled),
                "artifactRoot": .string(root.path), "processOracles": .object(observations),
                "transcript": .string(transcript(store)),
                "terminalState": .string(String(describing: store.phase2ShellSession.snapshot?.state)),
                "lastStoreError": store.phase2ShellSession.lastError.map(ScriptValue.string) ?? .null,
                "error": error.map(ScriptValue.string) ?? .null,
                "evidenceScope": .string("production store and broker; no visible control or renderer acceptance")
            ])
        }
        do {
            guard !store.phase2ShellSession.isRunning,
                  store.phase2ShellSession.durableRecoveryIdentity == nil else {
                throw Failure(description: "Caller supplied a workspace with live shell authority")
            }
            let plan = store.makePhase2ShellLaunchPlan(
                executablePath: "/bin/sh", arguments: ["-i"], workingDirectoryPath: root.path
            )
            admittedLaunch = true
            await store.launchPhase2ShellSession(plan: plan)
            guard case let .running(_, shellPID) = store.phase2ShellSession.snapshot?.state else {
                throw Failure(description: "Production shell launch did not reach running state")
            }
            stage = "signal-mask"
            try await send("echo $$ > shell.pid; /usr/bin/python3 -c 'import signal,json; print(\"MASK=\"+json.dumps(sorted(int(x) for x in signal.pthread_sigmask(signal.SIG_BLOCK, []))))'", store)
            try await awaitLine("MASK=[]", store)
            let shell = try await awaitIdentity("shell.pid", root: root, store: store, path: "/bin/sh")
            guard shell.pid == shellPID, shell.group == shell.pid else {
                throw Failure(description: "Shell PID file is not the broker-admitted group leader")
            }
            record("shell", shell)

            stage = "direct-interrupt"
            try await send("/bin/sh -c 'echo $$ > direct.pid; exec /bin/sleep 300'", store)
            let direct = try await awaitIdentity("direct.pid", root: root, store: store, path: "/bin/sleep")
            try requireChildGroup(direct, shell: shell)
            record("direct", direct)
            await store.signalPhase2ShellSession(.interrupt)
            try await awaitExit(direct, requireGroupExit: true, store: store)
            try requireUnchanged(shell)
            try await send("printf 'SIGNAL_%s_OK\\n' DIRECT", store)
            try await awaitLine("SIGNAL_DIRECT_OK", store)
            observations["directInterruptExitedGroupAndPreservedShell"] = .bool(true)

            stage = "nested-interrupt"
            try await send("/bin/sh -c 'echo $$ > nested.pid; /bin/sh -c '\"'\"'echo $$ > nested-sleep.pid; exec /bin/sleep 300'\"'\"'; echo NESTED_END'", store)
            let nested = try await awaitIdentity("nested.pid", root: root, store: store, path: "/bin/sh")
            let child = try await awaitIdentity("nested-sleep.pid", root: root, store: store, path: "/bin/sleep")
            try requireChildGroup(nested, shell: shell)
            guard child.parent == UInt32(nested.pid), child.group == nested.group else {
                throw Failure(description: "Nested child is not in the admitted foreground group")
            }
            record("nested", nested)
            record("nestedSleep", child)
            await store.signalPhase2ShellSession(.interrupt)
            try await awaitExit(nested, requireGroupExit: true, store: store)
            try await awaitExit(child, requireGroupExit: false, store: store)
            try requireUnchanged(shell)
            try await send("printf 'SIGNAL_%s_OK\\n' NESTED", store)
            try await awaitLine("SIGNAL_NESTED_OK", store)
            observations["nestedInterruptExitedGroupAndPreservedShell"] = .bool(true)

            stage = "stop"
            try await send("/bin/sh -c 'echo $$ > stop.pid; exec /bin/sleep 300'", store)
            let stop = try await awaitIdentity("stop.pid", root: root, store: store, path: "/bin/sleep")
            try requireChildGroup(stop, shell: shell)
            record("stop", stop)
            // This is the exact production action used by the Stop Shell control.
            await store.cleanupPhase2ShellSession(reason: "userStop")
            try await awaitExit(stop, requireGroupExit: true, store: store)
            try await awaitExit(shell, requireGroupExit: true, store: store)
            guard case .terminal(outcome: .canceled) = store.phase2ShellSession.snapshot?.state,
                  store.phase2ShellSession.durableRecoveryIdentity == nil else {
                throw Failure(description: "Stop did not publish canceled state and clear durable authority")
            }
            observations["stopExitedShellAndForegroundGroup"] = .bool(true)
            stage = "complete"
            let result = receipt(true)
            try result.jsonData(prettyPrinted: true).write(to: root.appendingPathComponent("RESULT.json"), options: .atomic)
            return result
        } catch {
            let failed = receipt(false, error: String(describing: error))
            try? failed.jsonData(prettyPrinted: true).write(to: root.appendingPathComponent("FAILURE-before-cleanup.json"), options: .atomic)
            // Cleanup is store-owned and never signals a PID obtained from a file.
            // Admission failure must not terminate an existing caller-owned session.
            if admittedLaunch {
                await store.cleanupPhase2ShellSession(reason: "headlessAcceptanceFailure")
            }
            try? receipt(false, error: String(describing: error)).jsonData(prettyPrinted: true)
                .write(to: root.appendingPathComponent("RESULT.json"), options: .atomic)
            throw error
        }
    }

    private static func send(_ command: String, _ store: WorkspaceStore) async throws {
        guard await store.writePhase2ShellInput(Array((command + "\n").utf8)) else {
            throw Failure(description: "Production shell rejected input")
        }
    }

    private static func transcript(_ store: WorkspaceStore) -> String {
        let bytes = (store.phase2ShellSession.snapshot?.transcriptEvents ?? []).flatMap { event -> [UInt8] in
            if case let .output(_, bytes) = event.payload { return bytes }
            return []
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func awaitLine(_ line: String, _ store: WorkspaceStore) async throws {
        try await bounded("output line " + line, store: store) {
            transcript(store).replacingOccurrences(of: "\r", with: "")
                .split(separator: "\n", omittingEmptySubsequences: false).contains(Substring(line))
        }
    }

    private static func bounded(_ description: String, store: WorkspaceStore, condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if try condition() { return }
            _ = await store.pollPhase2ShellTranscript(maximumEvents: 64, maximumBytes: 16_384, timeoutMilliseconds: 50)
            try await Task.sleep(for: .milliseconds(50))
        }
        throw Failure(description: "Timed out awaiting " + description)
    }

    private static func awaitIdentity(_ file: String, root: URL, store: WorkspaceStore, path: String) async throws -> Identity {
        var result: Identity?
        try await bounded(file + " process", store: store) {
            guard let text = try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1,
                  let identity = observe(pid), matchesExecutable(identity.path, requested: path) else { return false }
            result = identity
            return true
        }
        guard let result else { throw Failure(description: "Missing process identity") }
        return result
    }

    private static func requireChildGroup(_ child: Identity, shell: Identity) throws {
        try requireUnchanged(shell)
        guard child.parent == UInt32(shell.pid), child.group == child.pid, child.group != shell.group else {
            throw Failure(description: "Process is not a shell-owned foreground group leader")
        }
    }

    private static func requireUnchanged(_ identity: Identity) throws {
        guard observe(identity.pid) == identity else {
            throw Failure(description: "Expected process identity no longer alive: \(identity.pid)")
        }
    }

    private static func awaitExit(_ identity: Identity, requireGroupExit: Bool, store: WorkspaceStore) async throws {
        try await bounded("exit of PID \(identity.pid) and owned group", store: store) {
            guard kill(identity.pid, 0) == -1 && errno == ESRCH else { return false }
            // Signal zero only queries existence; it never delivers a signal.
            guard !requireGroupExit || (kill(-identity.group, 0) == -1 && errno == ESRCH) else { return false }
            return true
        }
    }

    private static func matchesExecutable(_ observed: String, requested: String) -> Bool {
        if observed == canonical(requested) { return true }
        // On the supported macOS 27 host /bin/sh is a dispatcher which executes
        // /bin/bash, not a symlink. Keep the kernel executable binding explicit;
        // PID, start time, parent and process-group authority remain independent.
        return requested == "/bin/sh" && observed == canonical("/bin/bash")
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func observe(_ pid: Int32) -> Identity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        let path = String(decoding: buffer.prefix(Int(count)).prefix { $0 != 0 }
            .map(UInt8.init(bitPattern:)), as: UTF8.self)
        return Identity(pid: pid, parent: info.pbi_ppid, group: getpgid(pid),
                        seconds: UInt64(info.pbi_start_tvsec), microseconds: UInt64(info.pbi_start_tvusec),
                        path: canonical(path))
    }
}
