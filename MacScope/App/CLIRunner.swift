import Darwin
import Foundation

enum CLIRunnerError: LocalizedError, Equatable {
    case scriptTooLarge
    case outputTooLarge
    case commandDeadlineExceeded
    case scriptIdentityChanged

    var errorDescription: String? {
        switch self {
        case .scriptTooLarge: "The script exceeds the headless input limit."
        case .outputTooLarge: "The script result exceeds the headless output limit."
        case .commandDeadlineExceeded: "A script command exceeded the headless deadline."
        case .scriptIdentityChanged: "The canonical script changed while it was read."
        }
    }
}

/// Headless batch automation: `MacScope --run-script <script.json> <binary>` loads the
/// binary, runs the JSON script (an array of `{command, arguments}` steps) through the
/// scripting command surface, prints the results as JSON to stdout, and exits. The CLI
/// counterpart to the interactive MCP server — same command surface, one-shot instead
/// of a stdio session.
enum CLIRunner {
    struct Limits {
        static let production = Limits(
            maximumScriptBytes: 1 * 1_024 * 1_024,
            maximumOutputBytes: 64 * 1_024 * 1_024,
            maximumCommandDurationNanoseconds: 30 * 1_000_000_000
        )

        let maximumScriptBytes: Int
        let maximumOutputBytes: Int
        let maximumCommandDurationNanoseconds: UInt64

        init(
            maximumScriptBytes: Int,
            maximumOutputBytes: Int,
            maximumCommandDurationNanoseconds: UInt64
        ) {
            precondition(maximumScriptBytes > 0)
            precondition(maximumOutputBytes > 0)
            precondition(maximumCommandDurationNanoseconds > 0)
            self.maximumScriptBytes = maximumScriptBytes
            self.maximumOutputBytes = maximumOutputBytes
            self.maximumCommandDurationNanoseconds = maximumCommandDurationNanoseconds
        }
    }

    /// Parses `--run-script <scriptPath> <binaryPath>` — but ONLY when the flag occupies
    /// the mode slot (the first argument after the program name), so the two path values
    /// can never be confused with another launch mode's flags (and vice versa). The two
    /// paths immediately follow the flag. nil if absent or incomplete.
    static func request(from arguments: [String]) -> (script: URL, binary: URL)? {
        guard arguments.dropFirst().first == "--run-script",
              arguments.count == 4,
              let script = MCPLauncher.canonicalURL(forPath: arguments[2]),
              let binary = MCPLauncher.canonicalURL(forPath: arguments[3]) else { return nil }
        return (script, binary)
    }

    /// Loads the binary, runs the script, and returns bounded canonical JSON results.
    /// Factored out of `run` so it is testable without exiting the process.
    @MainActor
    static func execute(
        scriptData: Data,
        binaryURL: URL,
        limits: Limits = .production,
        monotonicNow: @escaping @MainActor () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        }
    ) throws -> Data {
        guard scriptData.count <= limits.maximumScriptBytes else {
            throw CLIRunnerError.scriptTooLarge
        }
        let script = try HeadlessJSON.decode(
            scriptData, maximumBytes: limits.maximumScriptBytes
        )
        // Validate every step before loading the binary. A denied filesystem command or
        // malformed late step therefore cannot partially run an earlier mutation.
        let steps = try HeadlessAutomationAuthority.scriptSteps(from: script)
        let boundStore = try MCPLauncher.makeBoundStore(binaryURL: binaryURL)
        let api = WorkspaceScriptingAPI(store: boundStore.store)
        var results: [ScriptValue] = []
        results.reserveCapacity(steps.count)
        var encodedByteCount = 2 // []

        for step in steps {
            try boundStore.validateIdentity()
            let started = monotonicNow()
            let output: ScriptValue
            do {
                output = try HeadlessAutomationAuthority.execute(
                    command: step.command, arguments: step.arguments, api: api,
                    proposingPrincipal: .cli
                )
            } catch {
                try boundStore.validateIdentity()
                throw error
            }
            try boundStore.validateIdentity()
            let finished = monotonicNow()
            let elapsed = finished >= started ? finished - started : UInt64.max
            guard elapsed <= limits.maximumCommandDurationNanoseconds else {
                throw CLIRunnerError.commandDeadlineExceeded
            }
            let encoded = try output.jsonData()
            let separatorBytes = results.isEmpty ? 0 : 1
            let (partial, overflowed) = encodedByteCount.addingReportingOverflow(
                encoded.count + separatorBytes
            )
            guard !overflowed, partial <= limits.maximumOutputBytes else {
                throw CLIRunnerError.outputTooLarge
            }
            encodedByteCount = partial
            results.append(output)
        }
        try boundStore.validateIdentity()
        let data = try ScriptValue.array(results).jsonData()
        guard data.count <= limits.maximumOutputBytes else {
            throw CLIRunnerError.outputTooLarge
        }
        return data
    }

    static func loadScript(
        at scriptURL: URL,
        maximumBytes: Int = Limits.production.maximumScriptBytes
    ) throws -> Data {
        guard maximumBytes >= 0 else { throw CLIRunnerError.scriptTooLarge }
        guard let canonicalURL = MCPLauncher.canonicalURL(forPath: scriptURL.path) else {
            throw CLIRunnerError.scriptIdentityChanged
        }
        var pathBefore = stat()
        guard stat(canonicalURL.path, &pathBefore) == 0,
              pathBefore.st_mode & S_IFMT == S_IFREG,
              pathBefore.st_size >= 0,
              UInt64(pathBefore.st_size) <= UInt64(maximumBytes) else {
            throw pathBefore.st_size > Int64(maximumBytes)
                ? CLIRunnerError.scriptTooLarge
                : CLIRunnerError.scriptIdentityChanged
        }
        let descriptor = open(canonicalURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CLIRunnerError.scriptIdentityChanged }
        defer { close(descriptor) }
        var descriptorBefore = stat()
        guard fstat(descriptor, &descriptorBefore) == 0,
              fileIdentity(descriptorBefore) == fileIdentity(pathBefore) else {
            throw CLIRunnerError.scriptIdentityChanged
        }

        var data = Data()
        data.reserveCapacity(Int(pathBefore.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { storage in
                Darwin.read(descriptor, storage.baseAddress, storage.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw CLIRunnerError.scriptIdentityChanged }
            if count == 0 { break }
            guard data.count <= maximumBytes - count else { throw CLIRunnerError.scriptTooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }

        var descriptorAfter = stat()
        var pathAfter = stat()
        let initialIdentity = fileIdentity(pathBefore)
        guard data.count == Int(pathBefore.st_size),
              fstat(descriptor, &descriptorAfter) == 0,
              stat(canonicalURL.path, &pathAfter) == 0,
              fileIdentity(descriptorAfter) == initialIdentity,
              fileIdentity(pathAfter) == initialIdentity else {
            throw CLIRunnerError.scriptIdentityChanged
        }
        return data
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
    }

    private static func fileIdentity(_ value: stat) -> FileIdentity {
        FileIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            size: Int64(value.st_size),
            modificationSeconds: Int64(value.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec),
            changeSeconds: Int64(value.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(value.st_ctimespec.tv_nsec)
        )
    }

    /// Runs the script file against the binary, prints results, and exits. Called at
    /// program entry (main thread, no SwiftUI run loop) — uses the synchronous core.
    @MainActor
    static func run(scriptURL: URL, binaryURL: URL) -> Never {
        let protocolOutput: FileHandle
        do {
            protocolOutput = try HeadlessProtocolIO.isolateStandardOutput()
        } catch {
            FileHandle.standardError.write(Data("MacScope CLI: \(error.localizedDescription)\n".utf8))
            exit(1)
        }

        let output: Data
        do {
            output = try execute(
                scriptData: loadScript(at: scriptURL),
                binaryURL: binaryURL
            )
        } catch {
            FileHandle.standardError.write(Data("MacScope CLI: \(error.localizedDescription)\n".utf8))
            try? protocolOutput.close()
            exit(1)
        }

        do {
            try HeadlessProtocolIO.writeLine(output, to: protocolOutput)
        } catch {
            try? protocolOutput.close()
            exit(0)
        }
        try? protocolOutput.close()
        exit(0)
    }
}
