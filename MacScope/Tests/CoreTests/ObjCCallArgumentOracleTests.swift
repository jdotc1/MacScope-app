import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import XCTest

/// External WS-15 Objective-C call-argument ABI proof. The independent Python
/// driver compiles, links, runs, and disassembles an arm64 Objective-C fixture.
/// Its placements are fixture evidence, not authoritative runtime method ABI.
final class ObjCCallArgumentOracleTests: XCTestCase {
    func testActiveCompilerOracleProducesClosedHashBoundEvidence() throws {
        let artifactDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-objc-call-argument-oracle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: artifactDirectory) }

        let result = try runOracle([
            "--artifact-dir", artifactDirectory.path,
            "--json",
        ])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(result.cleanedResidualGroup)
        XCTAssertFalse(result.escalatedToSIGKILL)

        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
        )
        XCTAssertEqual(Set(root.keys), [
            "schema", "toolchain", "artifacts", "proofs", "cases",
            "policy_boundaries", "build_bindings", "artifact_directory",
        ])
        XCTAssertEqual(root["schema"] as? String, "objc-call-argument-oracle-v1")
        let claimedArtifactDirectory = URL(fileURLWithPath: try XCTUnwrap(
            nonemptyString(root["artifact_directory"])
        )).resolvingSymlinksInPath().standardizedFileURL
        XCTAssertEqual(
            claimedArtifactDirectory.path,
            artifactDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        )

        let toolchain = try XCTUnwrap(root["toolchain"] as? [String: Any])
        XCTAssertEqual(Set(toolchain.keys), [
            "developer_dir", "xcode_version", "clang", "clang_version", "sdk",
            "sdk_version", "target", "host_architecture", "object_file_description",
            "executable_file_description", "decoder", "decoder_version",
            "decoder_sha256", "clang_sha256", "sdk_settings_path",
            "sdk_settings_sha256",
        ])
        for key in toolchain.keys {
            XCTAssertNotNil(nonemptyString(toolchain[key]), "invalid toolchain field: \(key)")
        }
        XCTAssertEqual(toolchain["target"] as? String, "arm64-apple-macos26.4")
        XCTAssertEqual(toolchain["host_architecture"] as? String, "arm64")
        XCTAssertTrue(
            try XCTUnwrap(toolchain["xcode_version"] as? String).hasPrefix("Xcode 27.")
        )
        XCTAssertTrue(
            try XCTUnwrap(toolchain["clang_version"] as? String)
                .contains("Apple clang version 21.")
        )
        XCTAssertTrue(
            try XCTUnwrap(toolchain["decoder_version"] as? String)
                .hasPrefix("Apple LLVM version 21.")
        )
        XCTAssertNotNil(
            try XCTUnwrap(toolchain["decoder_sha256"] as? String).range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
            )
        )
        for key in ["clang_sha256", "sdk_settings_sha256"] {
            XCTAssertNotNil(
                try XCTUnwrap(toolchain[key] as? String).range(
                    of: "^[0-9a-f]{64}$",
                    options: .regularExpression
                )
            )
        }
        try validateToolchainPaths(toolchain)

        let proofs = try XCTUnwrap(root["proofs"] as? [String: Any])
        XCTAssertEqual(Set(proofs.keys), [
            "canonical_objc_msgsend_direct", "canonical_receiver_x0",
            "canonical_selector_x1", "canonical_object_carriers_observed",
            "normal_selector_stub_lowering", "normal_object_carriers_observed",
            "mixed_simd_and_object_observed", "mixed_requires_abstention",
            "runtime_sentinels", "artifact_hashes_verified",
        ])
        for key in proofs.keys {
            XCTAssertEqual(proofs[key] as? Bool, true, "missing proof: \(key)")
        }

        let artifacts = try XCTUnwrap(root["artifacts"] as? [String: Any])
        try validateArtifacts(artifacts, inside: artifactDirectory)
        let buildBindings = try XCTUnwrap(root["build_bindings"] as? [String: Any])
        try validateBuildBindings(buildBindings, artifacts: artifacts)

        let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
        try validateCases(cases)

        let boundaries = try XCTUnwrap(root["policy_boundaries"] as? [String: Any])
        XCTAssertEqual(Set(boundaries.keys), [
            "typed_canonical_does_not_certify_stub",
            "selector_arity_does_not_certify_bank",
            "fixture_placement_does_not_authorize_runtime_recovery",
            "mixed_bank_must_abstain",
        ])
        for key in boundaries.keys {
            XCTAssertEqual(boundaries[key] as? Bool, true, "missing boundary: \(key)")
        }
    }

    func testOracleSelfTestExercisesEveryFalsePassGuard() throws {
        let result = try runOracle(["--self-test"])
        XCTAssertEqual(result.status, 0, result.stderr)
        let output = String(decoding: result.stdout, as: UTF8.self)
        XCTAssertTrue(
            output.contains("objc-call-argument-oracle self-test: 44 tests passed"),
            "Objective-C oracle self-test inventory drifted"
        )
        for gate in [
            "missing proof", "wrong register", "missing SIMD",
            "stale artifact hash", "unsupported schema", "malformed selector",
            "classification separation", "selector arity is not bank proof",
            "lookalike target", "non-move overwrite", "post-dispatch prefix",
            "helper call", "conditional skip", "base writeback", "SIMD lane write",
            "executable slice binding", "case order",
            "fixture placement is not runtime method ABI", "normal stub abstention",
            "exact abstention policy",
            "same-size source mutation", "same-size object mutation",
            "same-size executable mutation", "artifact path escape",
            "fresh artifact directory", "artifact alias", "decoder provenance",
            "developer dir mismatch", "claimed artifact directory",
            "absolute tool selectors",
            "full-byte rebuild proof", "closed artifact entries",
            "clang content identity", "SDK content identity",
            "selected minor SDK provenance",
            "descriptor-pinned tool execution",
            "sandbox descriptor-copy execution",
        ] {
            XCTAssertTrue(output.contains(gate), "self-test did not exercise \(gate)")
        }
    }

    func testRunnerKillsResidualDescendantProcessGroup() throws {
        let result = try runOracle(
            ["--process-test-mode", "residual"],
            executionTimeout: 3,
            terminationGrace: 0.15,
            allowResidualDescendantsForTest: true
        )
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.cleanedResidualGroup)
        XCTAssertTrue(result.escalatedToSIGKILL)
    }

    func testRunnerEscalatesTimedOutProcessGroupAndConfirmsCleanup() throws {
        let readiness = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscope-objc-oracle-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: readiness) }
        XCTAssertThrowsError(
            try runOracle(
                ["--process-test-mode", "hang"],
                executionTimeout: 0.15,
                terminationGrace: 0.15,
                processReadyFile: readiness
            )
        ) { error in
            guard case let ObjCCallArgumentProcessError.timedOut(_, escalated) = error else {
                return XCTFail("unexpected process error: \(error)")
            }
            XCTAssertTrue(escalated)
        }
    }

    func testInnerChildTimeoutTerminatesEntireIsolatedGroup() throws {
        let result = try runOracle(["--process-test-mode", "inner-timeout"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("inner timeout probe exceeded"))
        XCTAssertFalse(result.cleanedResidualGroup)
    }

    private var repositoryRoot: URL {
        TestSourceRoot.fileURL(#filePath)
            .deletingLastPathComponent() // CoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // MacScope
            .deletingLastPathComponent() // repository root
    }

    private func validateArtifacts(
        _ artifacts: [String: Any],
        inside requestedDirectory: URL
    ) throws {
        let expectedNames = [
            "fixture_source": "objc_call_arguments.m",
            "fixture_object": "objc_call_arguments.o",
            "executable": "objc_call_argument_fixture",
            "object_disassembly": "objc_call_arguments.object.txt",
            "executable_disassembly": "objc_call_arguments.executable.txt",
        ]
        XCTAssertEqual(Set(artifacts.keys), Set(expectedNames.keys))

        let canonicalDirectory = requestedDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: canonicalDirectory.path)),
            Set(expectedNames.values)
        )
        var artifactIdentities = Set<String>()
        for key in expectedNames.keys.sorted() {
            let artifact = try XCTUnwrap(artifacts[key] as? [String: Any])
            XCTAssertEqual(Set(artifact.keys), ["path", "size", "sha256"])
            let declaredPath = try XCTUnwrap(nonemptyString(artifact["path"]))
            let declaredSize = try XCTUnwrap(strictInteger(artifact["size"]))
            let declaredDigest = try XCTUnwrap(nonemptyString(artifact["sha256"]))
            XCTAssertGreaterThan(declaredSize, 0)
            XCTAssertNotNil(declaredDigest.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
            ))

            let declaredArtifact = URL(fileURLWithPath: declaredPath).standardizedFileURL
            let canonicalArtifact = declaredArtifact
                .resolvingSymlinksInPath()
                .standardizedFileURL
            XCTAssertEqual(
                declaredArtifact.path,
                canonicalArtifact.path,
                "artifact path is not canonical or is a symlink: \(key)"
            )
            XCTAssertEqual(
                canonicalArtifact.deletingLastPathComponent().path,
                canonicalDirectory.path,
                "artifact escaped requested directory: \(key)"
            )
            XCTAssertEqual(
                canonicalArtifact.lastPathComponent,
                expectedNames[key],
                "artifact name is not frozen: \(key)"
            )

            var isDirectory = ObjCBool(false)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: canonicalArtifact.path,
                    isDirectory: &isDirectory
                ),
                canonicalArtifact.path
            )
            XCTAssertFalse(isDirectory.boolValue)
            let attributes = try FileManager.default.attributesOfItem(
                atPath: canonicalArtifact.path
            )
            let actualSize = try XCTUnwrap((attributes[.size] as? NSNumber)?.intValue)
            XCTAssertEqual(actualSize, declaredSize, "artifact size mismatch: \(key)")
            let device = try XCTUnwrap(attributes[.systemNumber] as? NSNumber)
            let inode = try XCTUnwrap(attributes[.systemFileNumber] as? NSNumber)
            XCTAssertTrue(
                artifactIdentities.insert("\(device.uint64Value):\(inode.uint64Value)").inserted,
                "artifact aliases another artifact: \(key)"
            )

            let bytes = try Data(contentsOf: canonicalArtifact, options: .mappedIfSafe)
            let actualDigest = SHA256.hash(data: bytes)
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(actualDigest, declaredDigest, "artifact hash mismatch: \(key)")
        }
    }

    private func validateToolchainPaths(_ toolchain: [String: Any]) throws {
        let declaredDeveloper = URL(fileURLWithPath: try XCTUnwrap(
            nonemptyString(toolchain["developer_dir"])
        ))
        let developer = declaredDeveloper.resolvingSymlinksInPath().standardizedFileURL
        XCTAssertEqual(declaredDeveloper.standardizedFileURL.path, developer.path)
        var developerIsDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: developer.path,
            isDirectory: &developerIsDirectory
        ))
        XCTAssertTrue(developerIsDirectory.boolValue)

        for key in ["clang", "decoder", "sdk"] {
            let declared = URL(fileURLWithPath: try XCTUnwrap(
                nonemptyString(toolchain[key])
            ))
            let canonical = declared.resolvingSymlinksInPath().standardizedFileURL
            XCTAssertEqual(declared.standardizedFileURL.path, canonical.path)
            XCTAssertTrue(
                canonical.path.hasPrefix(developer.path + "/"),
                "\(key) escaped the effective developer directory"
            )
            var isDirectory = ObjCBool(false)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: canonical.path,
                isDirectory: &isDirectory
            ))
            XCTAssertEqual(isDirectory.boolValue, key == "sdk")
            if key == "decoder" {
                let bytes = try Data(contentsOf: canonical, options: .mappedIfSafe)
                let digest = SHA256.hash(data: bytes)
                    .map { String(format: "%02x", $0) }
                    .joined()
                XCTAssertEqual(digest, toolchain["decoder_sha256"] as? String)
            }
            if key == "clang" {
                let bytes = try Data(contentsOf: canonical, options: .mappedIfSafe)
                let digest = SHA256.hash(data: bytes)
                    .map { String(format: "%02x", $0) }
                    .joined()
                XCTAssertEqual(digest, toolchain["clang_sha256"] as? String)
            }
        }

        let sdk = URL(fileURLWithPath: try XCTUnwrap(nonemptyString(toolchain["sdk"])))
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let settings = URL(fileURLWithPath: try XCTUnwrap(
            nonemptyString(toolchain["sdk_settings_path"])
        )).resolvingSymlinksInPath().standardizedFileURL
        XCTAssertEqual(settings.path, sdk.appendingPathComponent("SDKSettings.json").path)
        let settingsBytes = try Data(contentsOf: settings, options: .mappedIfSafe)
        let settingsDigest = SHA256.hash(data: settingsBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(settingsDigest, toolchain["sdk_settings_sha256"] as? String)
    }

    private func validateBuildBindings(
        _ bindings: [String: Any],
        artifacts: [String: Any]
    ) throws {
        let expected = [
            "compile_inputs": ["fixture_source"],
            "link_inputs": ["fixture_object"],
            "object_decode_inputs": ["fixture_object"],
            "executable_decode_inputs": ["executable"],
            "runtime_inputs": ["executable"],
        ]
        XCTAssertEqual(Set(bindings.keys), Set(expected.keys))
        for stage in expected.keys.sorted() {
            let records = try XCTUnwrap(bindings[stage] as? [[String: Any]])
            let artifactNames = try XCTUnwrap(expected[stage])
            XCTAssertEqual(records.count, artifactNames.count)
            for (index, artifactName) in artifactNames.enumerated() {
                let binding = records[index]
                XCTAssertEqual(Set(binding.keys), ["artifact", "path", "size", "sha256"])
                XCTAssertEqual(binding["artifact"] as? String, artifactName)
                let artifact = try XCTUnwrap(artifacts[artifactName] as? [String: Any])
                XCTAssertEqual(binding["path"] as? String, artifact["path"] as? String)
                XCTAssertEqual(
                    strictInteger(binding["size"]),
                    strictInteger(artifact["size"])
                )
                XCTAssertEqual(binding["sha256"] as? String, artifact["sha256"] as? String)
            }
        }
    }

    private func validateCases(_ cases: [[String: Any]]) throws {
        let expectedOrder = [
            "canonical_zero", "canonical_one", "canonical_two",
            "normal_zero", "normal_one", "normal_two", "normal_mixed",
        ]
        XCTAssertEqual(cases.compactMap { $0["name"] as? String }, expectedOrder)
        XCTAssertEqual(cases.count, expectedOrder.count)

        let expectedLocations = [
            "canonical_zero": ["x0", "x1"],
            "canonical_one": ["x0", "x1", "x2"],
            "canonical_two": ["x0", "x1", "x2", "x3"],
            "normal_zero": ["x0"],
            "normal_one": ["x0", "x2"],
            "normal_two": ["x0", "x2", "x3"],
            "normal_mixed": ["x0", "d0", "x2"],
        ]
        let expectedSelectors = [
            "canonical_zero": "zero",
            "canonical_one": "one:",
            "canonical_two": "first:second:",
            "normal_zero": "zero",
            "normal_one": "one:",
            "normal_two": "first:second:",
            "normal_mixed": "mixed:object:",
        ]
        let expectedTargets = [
            "canonical_zero": "_objc_msgSend",
            "canonical_one": "_objc_msgSend",
            "canonical_two": "_objc_msgSend",
            "normal_zero": "_objc_msgSend$zero",
            "normal_one": "_objc_msgSend$one:",
            "normal_two": "_objc_msgSend$first:second:",
            "normal_mixed": "_objc_msgSend$mixed:object:",
        ]
        let caseKeys: Set<String> = [
            "name", "classification", "selector", "selector_colon_count", "dispatch",
            "target", "selector_transport", "must_abstain", "arguments",
            "decoded_instructions", "function_symbol", "function_start_address",
            "function_end_address", "function_slice_sha256",
        ]
        let argumentKeys: Set<String> = [
            "role", "source_position", "tail_ordinal", "type_class", "location",
            "input_origin",
        ]

        var priorFunctionEnd = -1
        for (index, oracleCase) in cases.enumerated() {
            XCTAssertEqual(Set(oracleCase.keys), caseKeys)
            let name = try XCTUnwrap(nonemptyString(oracleCase["name"]))
            XCTAssertEqual(name, expectedOrder[index])
            let canonical = name.hasPrefix("canonical_")
            XCTAssertEqual(
                oracleCase["classification"] as? String,
                canonical ? "canonical-objc-msgsend" : "normal-objc-stub-lowering"
            )
            XCTAssertEqual(oracleCase["dispatch"] as? String, "direct")
            XCTAssertEqual(oracleCase["target"] as? String, expectedTargets[name])
            XCTAssertEqual(
                oracleCase["selector_transport"] as? String,
                canonical ? "explicit-x1" : "selector-specific-stub"
            )
            let expectedAbstention = [false, true, true, true, true, true, true]
            XCTAssertEqual(
                oracleCase["must_abstain"] as? Bool,
                expectedAbstention[index]
            )

            let selector = try XCTUnwrap(nonemptyString(oracleCase["selector"]))
            XCTAssertEqual(selector, expectedSelectors[name])
            XCTAssertEqual(
                strictInteger(oracleCase["selector_colon_count"]),
                selector.filter { $0 == ":" }.count
            )

            let symbol = try XCTUnwrap(nonemptyString(oracleCase["function_symbol"]))
            XCTAssertEqual(symbol, "_ws15_\(name)")
            let functionStart = try XCTUnwrap(
                strictInteger(oracleCase["function_start_address"])
            )
            let functionEnd = try XCTUnwrap(
                strictInteger(oracleCase["function_end_address"])
            )
            XCTAssertGreaterThan(functionStart, 0)
            XCTAssertGreaterThan(functionEnd, functionStart)
            XCTAssertGreaterThanOrEqual(functionStart, priorFunctionEnd)
            priorFunctionEnd = functionEnd

            let instructions = try XCTUnwrap(
                oracleCase["decoded_instructions"] as? [Any]
            )
            XCTAssertFalse(instructions.isEmpty)
            XCTAssertTrue(instructions.allSatisfy { nonemptyString($0) != nil })
            XCTAssertEqual(functionEnd - functionStart, instructions.count * 4)
            let sliceDigest = try XCTUnwrap(
                nonemptyString(oracleCase["function_slice_sha256"])
            )
            XCTAssertNotNil(sliceDigest.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
            ))

            let arguments = try XCTUnwrap(oracleCase["arguments"] as? [[String: Any]])
            for argument in arguments {
                XCTAssertEqual(Set(argument.keys), argumentKeys)
                XCTAssertNotNil(nonemptyString(argument["role"]))
                XCTAssertNotNil(nonemptyString(argument["type_class"]))
                XCTAssertNotNil(nonemptyString(argument["location"]))
                XCTAssertNotNil(nonemptyString(argument["input_origin"]))
                XCTAssertGreaterThanOrEqual(
                    try XCTUnwrap(strictInteger(argument["source_position"])),
                    0
                )
                if !(argument["tail_ordinal"] is NSNull) {
                    XCTAssertGreaterThanOrEqual(
                        try XCTUnwrap(strictInteger(argument["tail_ordinal"])),
                        0
                    )
                }
            }
            XCTAssertEqual(
                arguments.compactMap { $0["location"] as? String },
                expectedLocations[name]
            )
        }
    }

    private func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        guard string.unicodeScalars.allSatisfy({ scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }) else { return nil }
        return string
    }

    private func strictInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let encoding = String(cString: number.objCType)
        guard encoding != "f", encoding != "d" else { return nil }
        return number.intValue
    }

    private func runOracle(
        _ arguments: [String],
        executionTimeout: TimeInterval = 120,
        terminationGrace: TimeInterval = 2,
        allowResidualDescendantsForTest: Bool = false,
        processReadyFile: URL? = nil
    ) throws -> ObjCOracleProcessResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        var processArguments = [
            repositoryRoot
                .appendingPathComponent("Scripts/decompiler-oracles/objc_call_argument_oracle.py")
                .path,
            "--isolated-process-group",
        ] + arguments
        if let processReadyFile {
            processArguments += ["--process-test-ready-file", processReadyFile.path]
        }
        process.arguments = processArguments
        process.currentDirectoryURL = repositoryRoot
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        stdout.fileHandleForWriting.closeFile()
        stderr.fileHandleForWriting.closeFile()
        let stdoutDrain = ObjCCallArgumentPipeDrain(stdout.fileHandleForReading)
        let stderrDrain = ObjCCallArgumentPipeDrain(stderr.fileHandleForReading)

        guard let processGroup = waitForIsolatedProcessGroup(
            process,
            until: Date().addingTimeInterval(2)
        ) else {
            terminateExactProcess(process)
            _ = stdoutDrain.unblockAndFinish(timeout: 2)
            _ = stderrDrain.unblockAndFinish(timeout: 2)
            throw ObjCCallArgumentProcessError.isolationFailed
        }
        if let processReadyFile,
           !waitForProcessReadiness(
                processReadyFile,
                process: process,
                until: Date().addingTimeInterval(2)
           ) {
            _ = cleanProcessGroup(processGroup, terminationGrace: 0.15)
            _ = stdoutDrain.unblockAndFinish(timeout: 2)
            _ = stderrDrain.unblockAndFinish(timeout: 2)
            throw ObjCCallArgumentProcessError.readinessFailed
        }

        let exitedBeforeDeadline = waitForExit(
            process,
            until: Date().addingTimeInterval(executionTimeout)
        )
        let hadResidualGroup = processGroupExists(processGroup)
        var cleanup = ObjCCallArgumentGroupCleanup(
            performed: false,
            escalatedToSIGKILL: false,
            groupIsGone: !hadResidualGroup
        )
        if !exitedBeforeDeadline || hadResidualGroup {
            cleanup = cleanProcessGroup(
                processGroup,
                terminationGrace: terminationGrace
            )
        }
        _ = waitForExit(process, until: Date().addingTimeInterval(3))

        let stdoutData = stdoutDrain.finish(timeout: 5)
            ?? stdoutDrain.unblockAndFinish(timeout: 2)
        let stderrData = stderrDrain.finish(timeout: 5)
            ?? stderrDrain.unblockAndFinish(timeout: 2)
        guard cleanup.groupIsGone else {
            throw ObjCCallArgumentProcessError.groupCleanupFailed(processGroup)
        }
        guard let stdoutData, let stderrData else {
            throw ObjCCallArgumentProcessError.pipeDrainTimedOut
        }
        if !exitedBeforeDeadline {
            throw ObjCCallArgumentProcessError.timedOut(
                stderr: String(decoding: stderrData, as: UTF8.self),
                escalatedToSIGKILL: cleanup.escalatedToSIGKILL
            )
        }
        if hadResidualGroup, !allowResidualDescendantsForTest {
            throw ObjCCallArgumentProcessError.unexpectedResidualProcessGroup(
                processGroup
            )
        }
        guard !process.isRunning else {
            throw ObjCCallArgumentProcessError.groupCleanupFailed(processGroup)
        }
        return ObjCOracleProcessResult(
            status: process.terminationStatus,
            stdout: stdoutData,
            stderr: String(decoding: stderrData, as: UTF8.self),
            cleanedResidualGroup: cleanup.performed,
            escalatedToSIGKILL: cleanup.escalatedToSIGKILL
        )
    }

    private func waitForIsolatedProcessGroup(
        _ process: Process,
        until deadline: Date
    ) -> pid_t? {
        let processID = process.processIdentifier
        while Date() < deadline {
            let group = Darwin.getpgid(processID)
            if group == processID, group != Darwin.getpgrp() {
                return group
            }
            if !process.isRunning { return nil }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return nil
    }

    private func waitForProcessReadiness(
        _ readinessFile: URL,
        process: Process,
        until deadline: Date
    ) -> Bool {
        while Date() < deadline {
            if (try? Data(contentsOf: readinessFile)) == Data("ready\n".utf8) {
                return true
            }
            if !process.isRunning { return false }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return (try? Data(contentsOf: readinessFile)) == Data("ready\n".utf8)
    }

    private func cleanProcessGroup(
        _ processGroup: pid_t,
        terminationGrace: TimeInterval
    ) -> ObjCCallArgumentGroupCleanup {
        guard processGroup > 1, processGroup != Darwin.getpgrp() else {
            return ObjCCallArgumentGroupCleanup(
                performed: false,
                escalatedToSIGKILL: false,
                groupIsGone: false
            )
        }
        guard processGroupExists(processGroup) else {
            return ObjCCallArgumentGroupCleanup(
                performed: false,
                escalatedToSIGKILL: false,
                groupIsGone: true
            )
        }

        _ = Darwin.kill(-processGroup, SIGTERM)
        if waitForProcessGroupToDisappear(
            processGroup,
            until: Date().addingTimeInterval(terminationGrace)
        ) {
            return ObjCCallArgumentGroupCleanup(
                performed: true,
                escalatedToSIGKILL: false,
                groupIsGone: true
            )
        }

        _ = Darwin.kill(-processGroup, SIGKILL)
        let gone = waitForProcessGroupToDisappear(
            processGroup,
            until: Date().addingTimeInterval(3)
        )
        return ObjCCallArgumentGroupCleanup(
            performed: true,
            escalatedToSIGKILL: true,
            groupIsGone: gone
        )
    }

    private func processGroupExists(_ processGroup: pid_t) -> Bool {
        errno = 0
        if Darwin.kill(-processGroup, 0) == 0 { return true }
        return errno == EPERM
    }

    private func waitForProcessGroupToDisappear(
        _ processGroup: pid_t,
        until deadline: Date
    ) -> Bool {
        while Date() < deadline {
            if !processGroupExists(processGroup) { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !processGroupExists(processGroup)
    }

    private func terminateExactProcess(_ process: Process) {
        guard process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGTERM)
        if !waitForExit(process, until: Date().addingTimeInterval(0.5)) {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            _ = waitForExit(process, until: Date().addingTimeInterval(2))
        }
    }

    private func waitForExit(_ process: Process, until deadline: Date) -> Bool {
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !process.isRunning
    }
}

private struct ObjCOracleProcessResult {
    var status: Int32
    var stdout: Data
    var stderr: String
    var cleanedResidualGroup: Bool
    var escalatedToSIGKILL: Bool
}

private struct ObjCCallArgumentGroupCleanup {
    var performed: Bool
    var escalatedToSIGKILL: Bool
    var groupIsGone: Bool
}

private final class ObjCCallArgumentPipeDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var captured = Data()

    init(_ handle: FileHandle) {
        self.handle = handle
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { group.leave() }
            let data = handle.readDataToEndOfFile()
            lock.lock()
            captured = data
            lock.unlock()
        }
    }

    func finish(timeout: TimeInterval) -> Data? {
        guard group.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func unblockAndFinish(timeout: TimeInterval) -> Data? {
        try? handle.close()
        return finish(timeout: timeout)
    }
}

private enum ObjCCallArgumentProcessError: Error, CustomStringConvertible {
    case isolationFailed
    case readinessFailed
    case timedOut(stderr: String, escalatedToSIGKILL: Bool)
    case groupCleanupFailed(pid_t)
    case unexpectedResidualProcessGroup(pid_t)
    case pipeDrainTimedOut

    var description: String {
        switch self {
        case .isolationFailed:
            return "Objective-C oracle did not enter a dedicated process group"
        case .readinessFailed:
            return "Objective-C oracle test probe did not publish readiness"
        case let .timedOut(stderr, escalated):
            return "Objective-C oracle timed out (SIGKILL escalation: \(escalated)); stderr: \(stderr)"
        case let .groupCleanupFailed(processGroup):
            return "Objective-C oracle process group \(processGroup) survived cleanup"
        case let .unexpectedResidualProcessGroup(processGroup):
            return "Objective-C oracle process group \(processGroup) left unexpected descendants"
        case .pipeDrainTimedOut:
            return "Objective-C oracle output pipes did not close after process-group cleanup"
        }
    }
}
