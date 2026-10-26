import Foundation
import XCTest

@testable import MacScope

@MainActor
final class Phase2QualificationGateApplicationRunnerTests: XCTestCase {
    private let executable = "/tmp/MacScope.app/Contents/MacOS/MacScope"

    func testClosedProfileRequestPreservesModeAndRejectsAliasesDuplicatesAndMixedForms() {
        let mode = Phase2QualificationGateApplicationRunner.authorityProofArgument
        let option = "--phase2-f4c-profile=qwen38-v2-q6k"
        let request = Phase2QualificationGateApplicationRunner.request(
            arguments: [executable, mode, option], environment: [:])
        XCTAssertEqual(request?.mode, .authorityProof)
        XCTAssertEqual(request?.selector, .qwen38V2Q6K)
        XCTAssertEqual(Phase2QualificationGateApplicationRunner.request(
            arguments: [executable, mode], environment: [:])?.selector, .historicalF4C)
        for args in [[mode, option, option], [option, mode], [option],
                     [mode, "--profile", "qwen38-v2-q6k"],
                     [mode, "--phase2-f4c-profile=QWEN38-V2-Q6K"],
                     [mode, "--phase2-f4c-profile=qwen38-v2-q6k "],
                     [mode, "--phase2-f4c-profile=unknown"]] {
            XCTAssertEqual(decision(arguments: [executable] + args), .rejected)
            XCTAssertNil(Phase2QualificationGateApplicationRunner.request(
                arguments: [executable] + args, environment: [:]))
        }
    }

    func testCandidateAuthorityDoesNotInventProviderAdmission() {
        let record = Phase2QualificationGateApplicationRunner.profileTerminalRecord(
            ["schema_version": 1, "status": "authority-verified"],
            selector: .qwen38V2Q6K, admissionState: .unqualified)
        XCTAssertEqual(record["schema_version"] as? Int, 2)
        XCTAssertEqual(record["profile_selector"] as? String, "qwen38-v2-q6k")
        XCTAssertEqual(record["admission_state"] as? String, "unqualified")
        XCTAssertNil(record["provider_build_sha256"])
        let failure = Phase2QualificationGateApplicationRunner.profileTerminalRecord(
            ["status": "failed"], selector: .qwen38V2Q6K,
            admissionState: .failed, includeUnavailableProvider: true)
        XCTAssertTrue(failure["provider_build_sha256"] is NSNull)
        XCTAssertTrue(failure["runtime_closure_sha256"] is NSNull)
        XCTAssertThrowsError(try Phase2QualificationGateApplicationRunner.profileSuccessTerminalRecord(
            [:], selector: .qwen38V2Q6K, admissionState: .canaryPassed, providerAdmission: nil))
    }

    func testCandidateLiveTerminalRejectsHistoricalOrIncompleteOutcome() throws {
        let reportID = try Phase2ModelQualificationReportID(rawValue: "sha256:" + String(repeating: "a", count: 64))
        var outcome: [String: Any] = [
            "report_id": reportID.rawValue, "verdict": "certified",
            "run_id": "01234567-89ab-cdef-0123-456789abcdef",
        ]
        func terminal(_ value: [String: Any]) throws -> [String: Any] {
            try Phase2QualificationGateApplicationRunner.liveSuccessTerminalRecord(
                reportID: reportID, verdict: .certified,
                publishedOutcomeData: JSONSerialization.data(withJSONObject: value),
                selector: .qwen38V2Q6K)
        }
        XCTAssertThrowsError(try terminal(outcome))
        outcome["profile_selector"] = "qwen38-v2-q6k"
        outcome["qualification_definition_sha256"] = Phase2QualificationProfileContract.resolve(.qwen38V2Q6K).definitionIdentity.sha256
        outcome["admission_state"] = "qualified"
        for key in ["provider_build_sha256", "runtime_closure_sha256", "template_authority_sha256",
                    "app_executable_sha256", "worker_executable_sha256"] {
            outcome[key] = String(repeating: "b", count: 64)
        }
        outcome["git_head_commit"] = String(repeating: "c", count: 40)
        XCTAssertEqual(try terminal(outcome)["schema_version"] as? Int, 2)
        for key in ["provider_build_sha256", "runtime_closure_sha256", "template_authority_sha256"] {
            var missing = outcome
            missing[key] = NSNull()
            XCTAssertThrowsError(try terminal(missing))
        }
        outcome["qualification_definition_sha256"] = String(repeating: "d", count: 64)
        XCTAssertThrowsError(try terminal(outcome))
    }

    func testOrdinaryLaunchIsNotClaimed() {
        XCTAssertEqual(decision(arguments: [executable]), .ordinary)
        XCTAssertEqual(decision(arguments: [executable, "--mcp", "/bin/ls"]), .ordinary)
        XCTAssertEqual(decision(arguments: [executable, "--run-script", "s", "b"]), .ordinary)
    }

    func testAuthorityProofRequiresExactSoleArgumentAndNoLiveOptIn() {
        let argument = Phase2QualificationGateApplicationRunner.authorityProofArgument

        XCTAssertEqual(decision(arguments: [executable, argument]), .authorityProof)
        XCTAssertEqual(
            decision(arguments: [executable, argument], environment: [liveOptInKey: "1"]),
            .rejected
        )
        XCTAssertEqual(
            decision(arguments: [executable, argument], environment: [liveOptInKey: "0"]),
            .rejected
        )
        XCTAssertEqual(decision(arguments: [executable, argument, "extra"]), .rejected)
        XCTAssertEqual(decision(arguments: [executable, "extra", argument]), .rejected)
        XCTAssertEqual(decision(arguments: [executable, argument, argument]), .rejected)
    }

    func testLiveGateRequiresExactSoleArgumentAndExactOptInValue() {
        let argument = Phase2QualificationGateApplicationRunner.liveGateArgument

        XCTAssertEqual(
            decision(arguments: [executable, argument], environment: [liveOptInKey: "1"]),
            .liveGate
        )
        for value in [nil, "", "0", "true", "01", " 1", "1 "] as [String?] {
            var environment: [String: String] = [:]
            environment[liveOptInKey] = value
            XCTAssertEqual(
                decision(arguments: [executable, argument], environment: environment),
                .rejected,
                "unexpectedly accepted opt-in value \(String(describing: value))"
            )
        }
        XCTAssertEqual(
            decision(
                arguments: [executable, argument, "extra"],
                environment: [liveOptInKey: "1"]
            ),
            .rejected
        )
        XCTAssertEqual(
            decision(
                arguments: [executable, Phase2QualificationGateApplicationRunner.authorityProofArgument, argument],
                environment: [liveOptInKey: "1"]
            ),
            .rejected
        )
    }

    func testInstalledCanaryRequiresExactSoleArgumentAndDistinctExactOptIn() {
        let argument = Phase2QualificationGateApplicationRunner.installedCanaryArgument
        let key = Phase2QualificationGateApplicationRunner
            .installedCanaryOptInEnvironmentKey

        XCTAssertEqual(
            decision(arguments: [executable, argument], environment: [key: "1"]),
            .installedCanary
        )
        for value in [nil, "", "0", "true", "01", " 1", "1 "] as [String?] {
            var environment: [String: String] = [:]
            environment[key] = value
            XCTAssertEqual(
                decision(arguments: [executable, argument], environment: environment),
                .rejected
            )
        }
        XCTAssertEqual(
            decision(
                arguments: [executable, argument],
                environment: [key: "1", liveOptInKey: "1"]
            ),
            .rejected
        )
        XCTAssertEqual(
            decision(
                arguments: [executable, argument, "extra"],
                environment: [key: "1"]
            ),
            .rejected
        )
    }

    func testUnknownGateShapedArgumentFailsClosed() {
        XCTAssertEqual(
            decision(arguments: [executable, "--phase2-f4c-unknown"]),
            .rejected
        )
        XCTAssertEqual(
            decision(arguments: [executable, "ordinary", "--phase2-f4c-unknown"]),
            .rejected
        )
    }

    func testGateModesRejectDynamicLoaderProxyAndUnexpectedMacScopeEnvironment() {
        let proof = Phase2QualificationGateApplicationRunner.authorityProofArgument
        let live = Phase2QualificationGateApplicationRunner.liveGateArgument
        let unsafeEnvironment: [(String, String)] = [
            ("DYLD_INSERT_LIBRARIES", "/tmp/injected.dylib"),
            ("DYLD_LIBRARY_PATH", "/tmp/lib"),
            ("DYLD_FRAMEWORK_PATH", "/tmp/frameworks"),
            ("HTTP_PROXY", "http://127.0.0.1:8080"),
            ("https_proxy", "http://127.0.0.1:8080"),
            ("ALL_PROXY", "socks5://127.0.0.1:8080"),
            ("NO_PROXY", "127.0.0.1"),
            ("MACSCOPE_UNRELATED_OVERRIDE", "1"),
        ]

        for (key, value) in unsafeEnvironment {
            XCTAssertEqual(
                decision(arguments: [executable, proof], environment: [key: value]),
                .rejected,
                "proof accepted unsafe environment key \(key)"
            )
            XCTAssertEqual(
                decision(
                    arguments: [executable, live],
                    environment: [liveOptInKey: "1", key: value]
                ),
                .rejected,
                "live Gate accepted unsafe environment key \(key)"
            )
        }
    }

    func testGateModesPermitOnlyBenignProcessEnvironmentPlusExactLiveOptIn() {
        let benign = [
            "HOME": "/Users/test",
            "PATH": "/usr/bin:/bin",
            "SHELL": "/bin/zsh",
            "TMPDIR": "/tmp/",
            "USER": "test",
        ]
        XCTAssertEqual(
            decision(
                arguments: [executable, Phase2QualificationGateApplicationRunner.authorityProofArgument],
                environment: benign
            ),
            .authorityProof
        )
        XCTAssertEqual(
            decision(
                arguments: [executable, Phase2QualificationGateApplicationRunner.liveGateArgument],
                environment: benign.merging([liveOptInKey: "1"]) { _, new in new }
            ),
            .liveGate
        )
    }

    func testFailureTerminalRecordDistinguishesAuthorityCaseWithoutRawStatus() {
        let record = Phase2QualificationGateApplicationRunner.failureTerminalRecord(
            for: Phase2QualificationGateBuildAuthorityError.codeInvalid(-67070)
        )
        XCTAssertEqual(Set(record.keys), [
            "authority_error_case", "error_type", "schema_version", "status",
        ])
        XCTAssertEqual(record["authority_error_case"] as? String, "code-invalid")
        XCTAssertEqual(record["schema_version"] as? Int, 1)
        XCTAssertEqual(record["status"] as? String, "failed")
        XCTAssertFalse(String(describing: record).contains("-67070"))

        let generic = Phase2QualificationGateApplicationRunner.failureTerminalRecord(
            for: NSError(domain: "test", code: 7)
        )
        XCTAssertEqual(Set(generic.keys), ["error_type", "schema_version", "status"])
        XCTAssertNil(generic["authority_error_case"])
    }

    func testLiveSuccessTerminalRecordBindsRunReportVerdictAndCanonicalArtifactLocation() throws {
        let digest = String(repeating: "a", count: 64)
        let reportID = try Phase2ModelQualificationReportID(rawValue: "sha256:\(digest)")
        let runID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let outcome = try JSONSerialization.data(withJSONObject: [
            "report_id": reportID.rawValue,
            "run_id": runID.uuidString.lowercased(),
            "verdict": Phase2ModelQualificationVerdict.certified.rawValue,
        ])

        let record = try Phase2QualificationGateApplicationRunner.liveSuccessTerminalRecord(
            reportID: reportID,
            verdict: .certified,
            publishedOutcomeData: outcome
        )

        XCTAssertEqual(Set(record.keys), [
            "artifact_location", "report_id", "run_id", "schema_version", "status", "verdict",
        ])
        XCTAssertEqual(record["run_id"] as? String, runID.uuidString.lowercased())
        XCTAssertEqual(record["report_id"] as? String, reportID.rawValue)
        XCTAssertEqual(record["verdict"] as? String, "certified")
        XCTAssertEqual(
            record["artifact_location"] as? String,
            "MacScope/Qualification/F4C/reports/\(digest)/report.json"
        )
        XCTAssertFalse(String(describing: record).contains("/Users/"))
    }

    func testInstalledCanaryTerminalRecordBindsInstalledBuildAndPayloadFreeEvidence() throws {
        let runID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!
        let digest = String(repeating: "a", count: 64)
        let appDigest = String(repeating: "b", count: 64)
        let workerDigest = String(repeating: "c", count: 64)
        let commit = String(repeating: "d", count: 40)

        let record = try Phase2QualificationGateApplicationRunner
            .installedCanarySuccessTerminalRecord(
                runID: runID,
                evidenceDigest: digest,
                gitHeadCommit: commit,
                appExecutableSHA256: appDigest,
                workerExecutableSHA256: workerDigest
            )

        XCTAssertEqual(Set(record.keys), [
            "app_executable_sha256", "canary_evidence_sha256", "evidence_location",
            "git_head_commit", "run_id", "schema_version", "status",
            "worker_executable_sha256",
        ])
        XCTAssertEqual(record["status"] as? String, "canary-completed")
        XCTAssertEqual(record["canary_evidence_sha256"] as? String, digest)
        XCTAssertEqual(record["app_executable_sha256"] as? String, appDigest)
        XCTAssertEqual(record["worker_executable_sha256"] as? String, workerDigest)
        XCTAssertEqual(record["git_head_commit"] as? String, commit)
        XCTAssertEqual(
            record["evidence_location"] as? String,
            "MacScope/Qualification/F4C/"
                + "01234567-89ab-cdef-0123-456789abcdef/canary.json"
        )
        XCTAssertNil(record["verdict"])
        XCTAssertNil(record["report_id"])
    }

    func testLiveFailureTerminalRecordUsesBoundedInconclusiveReasonWithoutHostDetails() {
        let known = Phase2QualificationGateApplicationRunner.liveFailureTerminalRecord(
            for: Phase2QualificationGateComposer.ComposerError.reportUnavailable
        )
        XCTAssertEqual(Set(known.keys), [
            "artifact_location", "reason", "schema_version", "status", "verdict",
        ])
        XCTAssertEqual(known["status"] as? String, "failed")
        XCTAssertEqual(known["verdict"] as? String, "inconclusive")
        XCTAssertEqual(known["reason"] as? String, "report-unavailable")
        XCTAssertEqual(
            known["artifact_location"] as? String,
            "MacScope/Qualification/F4C"
        )

        let unknown = Phase2QualificationGateApplicationRunner.liveFailureTerminalRecord(
            for: NSError(domain: "/Users/private/secret", code: 99)
        )
        XCTAssertEqual(unknown["reason"] as? String, "live-gate-failed")
        XCTAssertFalse(String(describing: unknown).contains("private"))
        XCTAssertFalse(String(describing: unknown).contains("NSError"))
    }

    private var liveOptInKey: String {
        Phase2QualificationGateComposer.liveGateOptInEnvironmentKey
    }

    private func decision(
        arguments: [String],
        environment: [String: String] = [:]
    ) -> Phase2QualificationGateApplicationRunner.LaunchDecision {
        Phase2QualificationGateApplicationRunner.decision(
            arguments: arguments,
            environment: environment
        )
    }

}
