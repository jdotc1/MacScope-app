import CryptoKit
import Darwin
import Foundation
import XCTest

/// External WS-15 call-argument ABI proof. The Python driver compiles and executes
/// a real arm64 fixture, independently decodes caller instructions and callee entry
/// captures, and binds every retained artifact to its exact SHA-256 digest.
final class CallArgumentABIOracleTests: XCTestCase {
    func testActiveCompilerOracleProducesClosedHashBoundEvidence() throws {
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-call-argument-oracle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }

        let result = try runOracle([
            "--artifact-dir", artifactDirectory.path,
            "--json",
        ])
        XCTAssertEqual(result.status, 0, result.stderr)

        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        )
        XCTAssertEqual(Set(root.keys), [
            "schema", "toolchain", "artifacts", "proofs", "cases",
            "x8_negative_control", "artifact_directory", "build_bindings",
        ])
        XCTAssertEqual(root["schema"] as? String, "call-argument-oracle-v2")
        XCTAssertEqual(
            URL(fileURLWithPath: try XCTUnwrap(root["artifact_directory"] as? String))
                .resolvingSymlinksInPath(),
            artifactDirectory.resolvingSymlinksInPath()
        )

        let toolchain = try XCTUnwrap(root["toolchain"] as? [String: Any])
        XCTAssertEqual(Set(toolchain.keys), [
            "developer_dir", "clang", "clang_size", "clang_sha256",
            "clang_version", "decoder", "decoder_size", "decoder_sha256",
            "decoder_version", "sdk", "sdk_version", "sdk_settings_path",
            "sdk_settings_size", "sdk_settings_sha256", "target",
            "host_architecture",
        ])
        let developerDirectory = URL(fileURLWithPath: try XCTUnwrap(
            toolchain["developer_dir"] as? String
        )).resolvingSymlinksInPath()
        XCTAssertEqual(developerDirectory.lastPathComponent, "Developer")
        XCTAssertEqual(
            developerDirectory.deletingLastPathComponent().lastPathComponent,
            "Contents"
        )
        for key in ["clang", "decoder", "sdk"] {
            let path = URL(fileURLWithPath: try XCTUnwrap(toolchain[key] as? String))
                .resolvingSymlinksInPath()
            XCTAssertTrue(
                path.path.hasPrefix(developerDirectory.path + "/"),
                "\(key) escaped the frozen active developer directory"
            )
        }
        for prefix in ["clang", "decoder"] {
            let path = URL(fileURLWithPath: try XCTUnwrap(
                toolchain[prefix] as? String
            ))
            let expectedSize = try XCTUnwrap(toolchain["\(prefix)_size"] as? Int)
            let expectedDigest = try XCTUnwrap(
                toolchain["\(prefix)_sha256"] as? String
            )
            let bytes = try Data(contentsOf: path)
            XCTAssertEqual(bytes.count, expectedSize, "\(prefix) size identity drifted")
            XCTAssertEqual(
                sha256Hex(bytes), expectedDigest,
                "\(prefix) content identity drifted"
            )
        }
        let sdkSettings = URL(fileURLWithPath: try XCTUnwrap(
            toolchain["sdk_settings_path"] as? String
        ))
        XCTAssertEqual(
            sdkSettings.resolvingSymlinksInPath(),
            URL(fileURLWithPath: try XCTUnwrap(toolchain["sdk"] as? String))
                .appendingPathComponent("SDKSettings.json")
                .resolvingSymlinksInPath()
        )
        let sdkSettingsBytes = try Data(contentsOf: sdkSettings)
        XCTAssertEqual(
            sdkSettingsBytes.count,
            try XCTUnwrap(toolchain["sdk_settings_size"] as? Int)
        )
        XCTAssertEqual(
            sha256Hex(sdkSettingsBytes),
            try XCTUnwrap(toolchain["sdk_settings_sha256"] as? String)
        )
        XCTAssertEqual(toolchain["target"] as? String, "arm64-apple-macos26.4")
        XCTAssertEqual(toolchain["host_architecture"] as? String, "arm64")

        let proofs = try XCTUnwrap(root["proofs"] as? [String: Any])
        XCTAssertEqual(Set(proofs.keys), [
            "decoded_call_sites", "entry_state_capture", "runtime_sentinels",
            "artifact_hashes_verified",
        ])
        for key in proofs.keys {
            XCTAssertEqual(proofs[key] as? Bool, true, "missing proof: \(key)")
        }

        let artifacts = try XCTUnwrap(root["artifacts"] as? [String: Any])
        XCTAssertEqual(Set(artifacts.keys), [
            "fixture_source", "entry_capture_source", "fixture_object",
            "entry_capture_object", "executable", "runtime_image",
        ])
        for key in artifacts.keys {
            let artifact = try XCTUnwrap(artifacts[key] as? [String: Any])
            XCTAssertEqual(Set(artifact.keys), ["path", "size", "sha256"])
            let path = try XCTUnwrap(artifact["path"] as? String)
            let size = try XCTUnwrap(artifact["size"] as? Int)
            let digest = try XCTUnwrap(artifact["sha256"] as? String)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path), path)
            XCTAssertGreaterThan(size, 0)
            XCTAssertNotNil(digest.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
            ))
            let artifactURL = URL(fileURLWithPath: path)
            XCTAssertEqual(
                artifactURL.deletingLastPathComponent().resolvingSymlinksInPath(),
                artifactDirectory.resolvingSymlinksInPath(),
                "oracle retained \(key) outside its fresh artifact snapshot"
            )
            let sizeBefore = try artifactSize(at: artifactURL)
            let bytes = try Data(contentsOf: artifactURL)
            let sizeAfter = try artifactSize(at: artifactURL)
            XCTAssertEqual(sizeBefore, size, "reported size drifted for \(key)")
            XCTAssertEqual(sizeAfter, size, "artifact changed while reading \(key)")
            XCTAssertEqual(bytes.count, size, "read size drifted for \(key)")
            XCTAssertEqual(sha256Hex(bytes), digest, "reported digest drifted for \(key)")
        }

        let expectedBindings: [String: [String]] = [
            "fixture_compile_inputs": ["fixture_source"],
            "entry_compile_inputs": ["entry_capture_source"],
            "executable_link_inputs": ["fixture_object", "entry_capture_object"],
            "runtime_image_link_inputs": ["fixture_object", "entry_capture_object"],
            "fixture_object_decode_inputs": ["fixture_object"],
            "entry_object_decode_inputs": ["entry_capture_object"],
            "executable_decode_inputs": ["executable"],
            "runtime_inputs": ["runtime_image"],
        ]
        let buildBindings = try XCTUnwrap(root["build_bindings"] as? [String: Any])
        XCTAssertEqual(Set(buildBindings.keys), Set(expectedBindings.keys))
        for (stage, expectedArtifacts) in expectedBindings {
            let records = try XCTUnwrap(buildBindings[stage] as? [[String: Any]])
            XCTAssertEqual(records.count, expectedArtifacts.count, stage)
            for (record, artifactName) in zip(records, expectedArtifacts) {
                XCTAssertEqual(Set(record.keys), ["artifact", "path", "size", "sha256"])
                XCTAssertEqual(record["artifact"] as? String, artifactName, stage)
                let artifact = try XCTUnwrap(artifacts[artifactName] as? [String: Any])
                XCTAssertEqual(record["path"] as? String, artifact["path"] as? String, stage)
                XCTAssertEqual(record["size"] as? Int, artifact["size"] as? Int, stage)
                XCTAssertEqual(record["sha256"] as? String, artifact["sha256"] as? String, stage)
            }
        }

        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        XCTAssertEqual(Set(cases.compactMap { $0["name"] as? String }), [
            "fixed_direct", "fixed_indirect",
            "variadic_direct", "variadic_indirect",
        ])
        XCTAssertEqual(Set(cases.compactMap { $0["convention"] as? String }), [
            "darwin-c-fixed", "darwin-c-variadic",
        ])

        let fixedDirect = try XCTUnwrap(cases.first { $0["name"] as? String == "fixed_direct" })
        XCTAssertEqual(fixedDirect["dispatch"] as? String, "direct")
        let fixedArguments = try XCTUnwrap(fixedDirect["arguments"] as? [[String: Any]])
        XCTAssertEqual(
            fixedArguments.compactMap { locationKind($0) },
            ["gpr", "simd", "gpr"]
        )

        let variadicDirect = try XCTUnwrap(
            cases.first { $0["name"] as? String == "variadic_direct" }
        )
        let variadicArguments = try XCTUnwrap(
            variadicDirect["arguments"] as? [[String: Any]]
        )
        let anonymous = variadicArguments.filter {
            $0["role"] as? String == "anonymous-variadic"
        }
        XCTAssertEqual(anonymous.compactMap { locationKind($0) }, [
            "call-stack", "call-stack", "call-stack",
        ])
        XCTAssertEqual(anonymous.compactMap { $0["tail_ordinal"] as? Int }, [0, 1, 2])
        XCTAssertEqual(anonymous.compactMap { locationOffset($0) }, [0, 8, 16])

        let negative = try XCTUnwrap(root["x8_negative_control"] as? [String: Any])
        XCTAssertEqual(Set(negative.keys), [
            "observed_as_control", "ordinary_argument_location", "case_names",
        ])
        XCTAssertEqual(negative["observed_as_control"] as? Bool, true)
        XCTAssertEqual(negative["ordinary_argument_location"] as? Bool, false)
        XCTAssertEqual(negative["case_names"] as? [String], [
            "fixed_indirect", "variadic_indirect",
        ])
    }

    func testOracleSelfTestExercisesEveryFalsePassGuard() throws {
        let result = try runOracle(["--self-test"])
        XCTAssertEqual(result.status, 0, result.stderr)
        let output = String(decoding: result.stdout, as: UTF8.self)
        for gate in [
            "boolean integer", "wrong location", "stale artifact hash",
            "zero positive cases", "convention separation", "duplicate evidence",
            "compacted gap", "unsupported schema", "missing proof",
            "path swap", "lookalike call", "post-call setup", "duplicate call",
            "developer dir mismatch", "process isolation",
            "inner timeout group cleanup", "missing or swapped products",
            "Mach-O roles", "ordered binding drift", "wrong decode role",
            "wrong runtime role", "post-proof mutation",
            "pre-open swap", "tool content identities", "live helper mutation",
            "claimed tool executable swap", "shared toolchain metadata churn",
        ] {
            XCTAssertTrue(output.contains(gate), "self-test did not exercise \(gate)")
        }

        // ★ Insight: pinning only a success phrase lets deleted negative-control
        // tests false-pass. The exact total and per-class counts make omissions
        // visible while still allowing individual test names to evolve.
        XCTAssertTrue(output.contains(
            "self-test inventory: 41 tests; "
                + "ArtifactBindingTests=6; ClaimedToolExecutionTests=1; "
                + "ClosedOracleValidationTests=26; LiveProductionHelperTests=1; "
                + "OtoolParsingTests=4; ProcessIsolationTests=2; "
                + "ToolchainCoherenceTests=1"
        ))
    }

    func testRunnerRejectsDescendantThatOutlivesOracleLeader() throws {
        XCTAssertThrowsError(try runOracle(["--self-test-leaked-descendant"])) { error in
            guard
                let processError = error as? CallArgumentProcessError,
                case let .unexpectedDescendant(groupID) = processError
            else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertGreaterThan(groupID, 1)
        }
    }

    private func runOracle(_ arguments: [String]) throws -> CallArgumentProcessResult {
        let stagedOracleRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-call-argument-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: stagedOracleRoot,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: stagedOracleRoot) }

        let bundle = Bundle(for: CallArgumentABIOracleTests.self)
        let bundledScript = try XCTUnwrap(
            bundle.url(forResource: "call_argument_oracle", withExtension: "py")
        )
        let bundledFixtures = try XCTUnwrap(
            bundle.url(forResource: "call-arguments", withExtension: nil)
        )
        let stagedScript = stagedOracleRoot.appendingPathComponent("call_argument_oracle.py")
        let stagedFixtureParent = stagedOracleRoot.appendingPathComponent("fixtures")
        try FileManager.default.createDirectory(
            at: stagedFixtureParent,
            withIntermediateDirectories: false
        )
        try FileManager.default.copyItem(at: bundledScript, to: stagedScript)
        try FileManager.default.copyItem(
            at: bundledFixtures,
            to: stagedFixtureParent.appendingPathComponent("call-arguments")
        )

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [stagedScript.path] + arguments
        process.currentDirectoryURL = stagedOracleRoot
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let processGroupID = process.processIdentifier
        stdout.fileHandleForWriting.closeFile()
        stderr.fileHandleForWriting.closeFile()

        let stdoutDrain = CallArgumentPipeDrain(stdout.fileHandleForReading)
        let stderrDrain = CallArgumentPipeDrain(stderr.fileHandleForReading)
        let observedIsolatedGroup = waitForIsolatedProcessGroup(
            process,
            groupID: processGroupID,
            until: Date().addingTimeInterval(2)
        )
        let executionDeadline = Date().addingTimeInterval(120)
        let leaderExitedBeforeDeadline = waitForExit(process, until: executionDeadline)
        var cleanupError: CallArgumentProcessError?
        var unexpectedDescendant = false

        if !observedIsolatedGroup {
            do {
                try terminateExactLeader(process)
            } catch let error as CallArgumentProcessError {
                cleanupError = error
            }
        } else if !leaderExitedBeforeDeadline {
            do {
                try terminateProcessGroup(groupID: processGroupID, leader: process)
            } catch let error as CallArgumentProcessError {
                cleanupError = error
            }
        }

        // A leader exit is never enough. Audit the exact PGID observed above on
        // every normal and timeout path before accepting output or closing drains.
        if observedIsolatedGroup, !process.isRunning {
            let memberRemainedAfterLeaderExit = !isProcessGroupGone(processGroupID)
            unexpectedDescendant = leaderExitedBeforeDeadline && memberRemainedAfterLeaderExit
            if memberRemainedAfterLeaderExit {
                do {
                    try terminateProcessGroup(groupID: processGroupID, leader: process)
                } catch let error as CallArgumentProcessError {
                    cleanupError = cleanupError ?? error
                }
            }
        }

        let drainDeadline = Date().addingTimeInterval(5)
        var stdoutData = stdoutDrain.finish(
            timeout: max(0, drainDeadline.timeIntervalSinceNow)
        )
        var stderrData = stderrDrain.finish(
            timeout: max(0, drainDeadline.timeIntervalSinceNow)
        )
        if stdoutData == nil || stderrData == nil {
            if observedIsolatedGroup && !isProcessGroupGone(processGroupID) {
                unexpectedDescendant = leaderExitedBeforeDeadline
                do {
                    try terminateProcessGroup(groupID: processGroupID, leader: process)
                } catch let error as CallArgumentProcessError {
                    cleanupError = cleanupError ?? error
                }
            }
            stdoutData = stdoutData ?? stdoutDrain.cancelAndFinish(timeout: 2)
            stderrData = stderrData ?? stderrDrain.cancelAndFinish(timeout: 2)
        }

        // Re-audit after joining drains as a final guard against a descendant
        // that closed its inherited pipes but remained alive in the group.
        if observedIsolatedGroup, !isProcessGroupGone(processGroupID) {
            unexpectedDescendant = leaderExitedBeforeDeadline
            do {
                try terminateProcessGroup(groupID: processGroupID, leader: process)
            } catch let error as CallArgumentProcessError {
                cleanupError = cleanupError ?? error
            }
        }

        if let cleanupError {
            throw cleanupError
        }
        guard observedIsolatedGroup else {
            throw CallArgumentProcessError.processGroupNotIsolated
        }
        if unexpectedDescendant {
            throw CallArgumentProcessError.unexpectedDescendant(groupID: processGroupID)
        }
        guard leaderExitedBeforeDeadline else {
            throw CallArgumentProcessError.timedOut(
                stderr: String(decoding: stderrData ?? Data(), as: UTF8.self)
            )
        }
        guard let stdoutData, let stderrData else {
            throw CallArgumentProcessError.pipeDrainTimedOut
        }
        return CallArgumentProcessResult(
            status: process.terminationStatus,
            stdout: stdoutData,
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    private func waitForIsolatedProcessGroup(
        _ process: Process,
        groupID: pid_t,
        until deadline: Date
    ) -> Bool {
        while process.isRunning, Date() < deadline {
            errno = 0
            if Darwin.getpgid(process.processIdentifier) == groupID {
                return true
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return false
    }

    private func terminateExactLeader(_ process: Process) throws {
        guard process.processIdentifier > 1 else {
            throw CallArgumentProcessError.processGroupNotIsolated
        }
        if process.isRunning {
            errno = 0
            if Darwin.kill(process.processIdentifier, SIGTERM) != 0, errno != ESRCH {
                throw CallArgumentProcessError.processGroupSignalFailed(
                    signal: SIGTERM,
                    errno: errno
                )
            }
        }
        if !waitForExit(process, until: Date().addingTimeInterval(2)), process.isRunning {
            errno = 0
            if Darwin.kill(process.processIdentifier, SIGKILL) != 0, errno != ESRCH {
                throw CallArgumentProcessError.processGroupSignalFailed(
                    signal: SIGKILL,
                    errno: errno
                )
            }
            _ = waitForExit(process, until: Date().addingTimeInterval(3))
        }
        if process.isRunning {
            throw CallArgumentProcessError.processGroupDidNotExit
        }
    }

    private func terminateProcessGroup(groupID: pid_t, leader: Process) throws {
        guard groupID > 1 else {
            throw CallArgumentProcessError.processGroupNotIsolated
        }
        if !isProcessGroupGone(groupID) {
            errno = 0
            if Darwin.kill(-groupID, SIGTERM) != 0, errno != ESRCH {
                throw CallArgumentProcessError.processGroupSignalFailed(
                    signal: SIGTERM,
                    errno: errno
                )
            }
        }
        let termDeadline = Date().addingTimeInterval(2)
        while !isProcessGroupGone(groupID), Date() < termDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if !isProcessGroupGone(groupID) {
            errno = 0
            if Darwin.kill(-groupID, SIGKILL) != 0, errno != ESRCH {
                throw CallArgumentProcessError.processGroupSignalFailed(
                    signal: SIGKILL,
                    errno: errno
                )
            }
        }
        let killDeadline = Date().addingTimeInterval(3)
        while !isProcessGroupGone(groupID), Date() < killDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        _ = waitForExit(leader, until: killDeadline)
        guard isProcessGroupGone(groupID) else {
            throw CallArgumentProcessError.processGroupDidNotExit
        }
    }

    private func isProcessGroupGone(_ groupID: pid_t) -> Bool {
        errno = 0
        if Darwin.kill(-groupID, 0) == 0 {
            return false
        }
        return errno == ESRCH
    }

    private func waitForExit(_ process: Process, until deadline: Date) -> Bool {
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return !process.isRunning
    }

    private func artifactSize(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.size] as? NSNumber).intValue
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func locationKind(_ argument: [String: Any]) -> String? {
        (argument["location"] as? [String: Any])?["kind"] as? String
    }

    private func locationOffset(_ argument: [String: Any]) -> Int? {
        (argument["location"] as? [String: Any])?["byte_offset"] as? Int
    }
}

private struct CallArgumentProcessResult {
    var status: Int32
    var stdout: Data
    var stderr: String
}

private final class CallArgumentPipeDrain: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private let handle: FileHandle
    private var captured = Data()

    init(_ handle: FileHandle) {
        self.handle = handle
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let data = handle.readDataToEndOfFile()
            lock.lock()
            captured = data
            lock.unlock()
            group.leave()
        }
    }

    func finish(timeout: TimeInterval) -> Data? {
        guard group.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func cancelAndFinish(timeout: TimeInterval) -> Data? {
        try? handle.close()
        return finish(timeout: timeout)
    }
}

private enum CallArgumentProcessError: Error, CustomStringConvertible {
    case timedOut(stderr: String)
    case pipeDrainTimedOut
    case processGroupNotIsolated
    case processGroupSignalFailed(signal: Int32, errno: Int32)
    case processGroupDidNotExit
    case unexpectedDescendant(groupID: pid_t)

    var description: String {
        switch self {
        case let .timedOut(stderr):
            return "call-argument oracle exceeded 120 seconds; stderr: \(stderr)"
        case .pipeDrainTimedOut:
            return "call-argument oracle output pipes did not close within 5 seconds"
        case .processGroupNotIsolated:
            return "call-argument oracle did not become its own process-group leader"
        case let .processGroupSignalFailed(signal, errorNumber):
            return "call-argument oracle process-group signal \(signal) failed with errno \(errorNumber)"
        case .processGroupDidNotExit:
            return "call-argument oracle process group remained alive after SIGKILL"
        case let .unexpectedDescendant(groupID):
            return "call-argument oracle descendant outlived leader in process group \(groupID)"
        }
    }
}
