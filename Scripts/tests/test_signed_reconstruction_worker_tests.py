from __future__ import annotations

import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

from Scripts.reconstruction import native_live_preparation_receipt as preparation
from Scripts.qualification import generated_project_evidence
from Scripts.qualification.restore_build_source import _generated_project_identity
from Scripts.tests.test_generated_project_evidence import make_project_evidence_fixture


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "Scripts/reconstruction/run_signed_reconstruction_worker_tests.sh"
AI_GATE = (
    ROOT
    / "MacScope/Tests/CoreTests/Phase2LiveAIAgentXPCProductionGateTests.swift"
)
NATIVE_GATE = ROOT / "MacScope/Tests/CoreTests/NativeDecompilerLiveXPCTests.swift"
WORKER_RECEIPT_TESTS = (
    ROOT / "MacScope/Tests/CoreTests/AIAgentXPCWorkerProcessReceiptTests.swift"
)
AI_SELECTOR = (
    "CoreTests/Phase2LiveAIAgentXPCProductionGateTests/"
    "testSignedWorkerCompletesReconstructionRoundThenFinalSynthesisExactlyOnce"
)
R2_AI_SELECTOR = (
    "CoreTests/Phase2LiveAIAgentXPCProductionGateTests/"
    "testSignedR2WorkerDispatchesReadableObjectiveAndEvidenceThenAcceptsExactSemantics"
)


def method_body(source: str, method: str) -> str:
    start = source.index(f"    func {method}(")
    try:
        end = source.index("\n    func ", start + 1)
    except ValueError:
        end = len(source)
    return source[start:end]


def test_results(
    result: str = "Passed", *, skipped: bool = False, selector: str = AI_SELECTOR
) -> dict[str, object]:
    method = selector.rsplit("/", 1)[1]
    children: list[dict[str, object]] = [
        {
            "nodeType": "Test Case Run",
            "name": f"{method}()",
            "result": result,
            "children": [],
        }
    ]
    if skipped:
        children.append(
            {
                "nodeType": "Skip Message",
                "name": "unexpected skip",
                "children": [],
            }
        )
    return {
        "testNodes": [
            {
                "nodeType": "Test Plan",
                "name": "MacScopeApp",
                "children": [
                    {
                        "nodeType": "Unit test bundle",
                        "name": "CoreTests",
                        "children": [
                            {
                                "nodeType": "Test Suite",
                                "name": "Phase2LiveAIAgentXPCProductionGateTests",
                                "children": [
                                    {
                                        "nodeType": "Test Case",
                                        "name": f"{method}()",
                                        "nodeIdentifier": selector,
                                        "result": result,
                                        "children": children,
                                    }
                                ],
                            }
                        ],
                    }
                ],
            }
        ]
    }


class SignedWorkerPreparationBindingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        project_spec = b"name: MacScope\n"
        project = make_project_evidence_fixture(
            self.root, "1" * 40, "2" * 40, project_spec
        )
        retained_project = generated_project_evidence.capture(
            self.root, _generated_project_identity(project, require_complete=True)
        )
        self.products = self.root / "DerivedData/Build/Products"
        self.app = self.products / "Debug/MacScope.app"
        self.app_executable = self.app / "Contents/MacOS/MacScope"
        self.worker_executable = (
            self.app
            / "Contents/XPCServices/AIAgentWorkerXPCService.xpc/Contents/MacOS/AIAgentWorkerXPCService"
        )
        self.native_executable = (
            self.app
            / "Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents/MacOS/NativeDecompilerXPCService"
        )
        self.core_tests = self.app / "Contents/PlugIns/CoreTests.xctest"
        self.core_executable = self.core_tests / "Contents/MacOS/CoreTests"
        self.core_signature = self.core_tests / "Contents/_CodeSignature/CodeResources"
        for executable, payload in (
            (self.app_executable, b"app"),
            (self.worker_executable, b"worker"),
            (self.native_executable, b"native"),
            (self.core_executable, b"tests"),
        ):
            executable.parent.mkdir(parents=True, exist_ok=True)
            executable.write_bytes(payload)
            executable.chmod(0o755)
        self.core_signature.parent.mkdir(parents=True, exist_ok=True)
        self.core_signature.write_bytes(b"signed-coretests-v1")

        self.xctestrun = self.products / "MacScopeApp.xctestrun"
        self.xctestrun.parent.mkdir(parents=True, exist_ok=True)
        self.xctestrun.write_bytes(
            plistlib.dumps(
                {
                    "__xctestrun_metadata__": {
                        "ContainerInfo": {"SchemeName": "MacScopeApp"}
                    },
                    "CoreTests": {
                        "BlueprintName": "CoreTests",
                        "DependentProductPaths": [
                            "__TESTROOT__/Debug/MacScope.app",
                            "__TESTROOT__/Debug/MacScope.app/Contents/PlugIns/CoreTests.xctest",
                        ],
                        "IsAppHostedTestBundle": True,
                        "TestHostBundleIdentifier": "org.macscope.app",
                        "TestHostPath": "__TESTROOT__/Debug/MacScope.app",
                        "TestBundlePath": "__TESTHOST__/Contents/PlugIns/CoreTests.xctest",
                    },
                },
                fmt=plistlib.FMT_BINARY,
                sort_keys=True,
            )
        )
        self.candidate = self.root / "candidate.json"
        self.candidate.write_text("{}", encoding="utf-8")
        self.receipt = preparation.parse_document(
            {
                "schema_version": preparation.SCHEMA_VERSION,
                "receipt_kind": preparation.RECEIPT_KIND,
                "source": {
                    "repository": "gitfox-local:MacScope",
                    "branch_label": "feature/signed-worker-receipt-test",
                    "commit": "1" * 40,
                    "tree": "2" * 40,
                    "dirty": False,
                    "project_yml_sha256": hashlib.sha256(project_spec).hexdigest(),
                    "generated_project_sha256": preparation.file_sha256(retained_project),
                },
                "toolchain": {
                    "developer_dir": "/Applications/Xcode-beta.app/Contents/Developer",
                    "xcodebuild_sha256": "5" * 64,
                    "xcode_version": "27.0",
                    "xcode_build": "27A5252f",
                    "swiftc_sha256": "6" * 64,
                    "swift_version": "Apple Swift version 6.4",
                    "sdk_path": "/Applications/Xcode-beta.app/SDKs/MacOSX.sdk",
                    "sdk_settings_sha256": "7" * 64,
                    "sdk_version": "27.0",
                    "sdk_build": "26A5419a",
                },
                "build": {
                    "scheme": preparation.SCHEME,
                    "configuration": preparation.CONFIGURATION,
                    "destination": preparation.DESTINATION,
                    "live_test_condition": preparation.LIVE_TEST_CONDITION,
                    "preparation_mode": preparation.NATIVE_LIVE_PREPARATION_MODE,
                },
                "artifacts": {
                    "xctestrun": {
                        "path": str(self.xctestrun),
                        "sha256": preparation.file_sha256(self.xctestrun),
                    },
                    "app": {
                        "path": str(self.app),
                        "closed_tree_sha256": preparation.closed_tree_sha256(self.app),
                        "executable_sha256": preparation.file_sha256(self.app_executable),
                    },
                    "native_decompiler": {
                        "path": str(self.native_executable),
                        "sha256": preparation.file_sha256(self.native_executable),
                    },
                    "core_tests": {
                        "path": str(self.core_tests),
                        "closed_tree_sha256": preparation.closed_tree_sha256(
                            self.core_tests
                        ),
                        "executable_sha256": preparation.file_sha256(
                            self.core_executable
                        ),
                    },
                },
            }
        )

        # Admit the unmodified products first: mutations below must fail at
        # product identity, not because generated-project evidence is absent.
        self.assertEqual(
            preparation.validate_prepared_artifacts(
                self.receipt, self.xctestrun, self.app
            ),
            preparation.canonical_sha256(self.receipt),
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def assert_prepared_artifact_drift_is_rejected(self) -> None:
        with self.assertRaisesRegex(
            preparation.PreparationReceiptError,
            "prepared product identity differs",
        ):
            preparation.validate_prepared(
                self.receipt,
                self.xctestrun,
                self.app,
                self.candidate,
            )

    def test_stale_xctestrun_and_resigned_coretests_fail_the_existing_receipt(
        self,
    ) -> None:
        self.assertEqual(self.app.parent.parent, self.xctestrun.parent)
        original_xctestrun = self.xctestrun.read_bytes()
        document = plistlib.loads(original_xctestrun)
        self.assertEqual(
            document["__xctestrun_metadata__"]["ContainerInfo"]["SchemeName"],
            "MacScopeApp",
        )
        self.assertEqual(document["CoreTests"]["BlueprintName"], "CoreTests")
        document["CoreTests"]["TestTimeoutsEnabled"] = True
        self.xctestrun.write_bytes(
            plistlib.dumps(document, fmt=plistlib.FMT_BINARY, sort_keys=True)
        )
        self.assert_prepared_artifact_drift_is_rejected()
        self.xctestrun.write_bytes(original_xctestrun)

        original_signature = self.core_signature.read_bytes()
        self.core_signature.write_bytes(b"signed-coretests-v2")
        self.assert_prepared_artifact_drift_is_rejected()
        self.core_signature.write_bytes(original_signature)

    def test_embedded_worker_and_native_mutation_fail_the_existing_receipt(self) -> None:
        for executable in (self.worker_executable, self.native_executable):
            with self.subTest(executable=executable.name):
                original = executable.read_bytes()
                executable.write_bytes(original + b"-tampered")
                executable.chmod(0o755)
                self.assert_prepared_artifact_drift_is_rejected()
                executable.write_bytes(original)
                executable.chmod(0o755)


class SignedReconstructionWorkerTests(unittest.TestCase):
    def run_verifier(
        self, document: dict[str, object], selector: str | None = None
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "tests.json"
            path.write_text(json.dumps(document), encoding="utf-8")
            arguments = [str(RUNNER), "--verify-test-results-json", str(path)]
            if selector is not None:
                arguments.extend(["--test-selector", selector])
            return subprocess.run(
                arguments,
                text=True,
                capture_output=True,
                check=False,
            )

    def test_runner_is_signing_aware_bounded_and_reuses_sealed_products(self) -> None:
        script = RUNNER.read_text(encoding="utf-8")
        self.assertTrue(RUNNER.stat().st_mode & 0o111)
        self.assertIn(f"readonly DEFAULT_TEST_SELECTOR='{AI_SELECTOR}'", script)
        self.assertIn(f"readonly R2_TEST_SELECTOR='{R2_AI_SELECTOR}'", script)
        self.assertIn('readonly TEST_SELECTOR=$test_selector', script)
        self.assertIn("xcodebuild test-without-building", script)
        self.assertIn('--candidate-identity ABSOLUTE_PATH', script)
        self.assertIn('--candidate-identity "$candidate_identity"', script)
        self.assertIn('--product ai-agent-worker', script)
        self.assertIn('-xctestrun "$xctestrun"', script)
        self.assertIn('--app-bundle "$candidate_app"', script)
        self.assertIn('--xcode-test-host-entitlements', script)
        self.assertIn("AIAgentWorkerXPCService.xpc", script)
        self.assertIn('--artifact-root ABSOLUTE_PATH', script)
        self.assertIn('MACSCOPE_SIGNED_RECONSTRUCTION_TEST_RESULTS=', script)
        self.assertIn('MACSCOPE_SIGNED_RECONSTRUCTION_EXECUTABLE=', script)
        self.assertIn('MACSCOPE_SIGNED_RECONSTRUCTION_EXECUTION_REPORT=', script)
        self.assertIn('write_execution_report.py', script)
        for forwarding in (
            '--qualification-run-id "$qualification_run_id"',
            '--qualification-run-nonce "$qualification_run_nonce"',
            '--predecessor-observations-sha256 "$predecessor_observations_sha256"',
        ):
            self.assertEqual(script.count(forwarding), 1)
        self.assertNotIn("MACSCOPE_QUALIFICATION_RUN", script)
        self.assertIn('native_live_preparation_receipt.py', script)
        self.assertIn('--preparation-receipt ABSOLUTE_PATH', script)
        validation_lines = [
            line
            for line in script.splitlines()
            if line.startswith('/usr/bin/python3 -B "$preparation_validator"')
        ]
        self.assertEqual(
            validation_lines,
            ['/usr/bin/python3 -B "$preparation_validator" validate \\'],
        )
        self.assertIn('--receipt "$preparation_receipt"', script)
        self.assertIn('--candidate-app "$candidate_app"', script)
        self.assertNotIn('validate-xctestrun', script)
        self.assertIn('--xctestrun "$xctestrun"', script)
        self.assertIn("-test-timeouts-enabled YES", script)
        self.assertIn("-parallel-testing-enabled NO", script)
        self.assertNotIn("MACSCOPE_SLEIGH_MATERIALIZATION_ROOT", script)
        self.assertNotIn("MACSCOPE_GHOSTTY_SOURCE_DIR", script)
        self.assertNotIn("xcodegen generate", script)
        self.assertNotIn("MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION", script)
        self.assertNotIn("MACSCOPE_SIGNED_RECONSTRUCTION_PROCESS_IDENTIFIER", script)
        receipt_validation = script.index(validation_lines[0])
        output_creation = script.index('/bin/mkdir "$artifact_root"')
        first_xcode_execution = script.index("xcodebuild test-without-building")
        self.assertLess(receipt_validation, output_creation)
        self.assertLess(receipt_validation, first_xcode_execution)
        self.assertNotIn(
            "__TESTROOT__/Debug/MacScope.app/Contents/MacOS/MacScope",
            script,
        )
        self.assertNotIn("__TESTROOT__/Debug/CoreTests.xctest", script)

    def test_runner_requires_orchestrator_execution_report_authority(self) -> None:
        result = subprocess.run(
            [
                str(RUNNER),
                "--candidate-identity", "/tmp/candidate.json",
                "--preparation-receipt", "/tmp/preparation.json",
                "--xctestrun", "/tmp/tests.xctestrun",
                "--candidate-app", "/tmp/MacScope.app",
                "--result-bundle-path", "/tmp/results.xcresult",
                "--artifact-root", "/tmp/artifacts",
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("--qualification-run-id is required", result.stderr)

    def test_exact_signed_selectors_bind_the_existing_production_seams(self) -> None:
        ai_source = AI_GATE.read_text(encoding="utf-8")
        ai_body = method_body(
            ai_source,
            "testSignedWorkerCompletesReconstructionRoundThenFinalSynthesisExactlyOnce",
        )
        for required in (
            "ReconstructionXPCInferenceProvider(transport: transport)",
            "Phase2AIWorkerProductionProtocol.reconstructionR1",
            "transport.prepareWorkerProcessReceipt()",
            "provider.runRound(",
            "provider.runFinalSynthesis(",
            "summary.requestCount, 2",
            "summary.hasTools, [true, false]",
            "transport.revalidateWorkerProcessReceipt(",
            "Phase2LiveAIAgentWorkerProcessAuthority",
            ".resolveFromTestHost()",
            "workerProcessAuthority.observe(",
            "XCTAssertEqual(finalWorkerProcess, initialWorkerProcess)",
        ):
            self.assertIn(required, ai_body)

        for required in (
            "let observer = Phase2QualificationLibprocProcessObserver()",
            "beforeProcess.hasSameIdentity(as: afterProcess)",
            "proc_pidpath(processIdentifier",
            "SecCodeCopyGuestWithAttributes(",
            "SecCodeCheckValidityWithErrors(",
            "SecCodeCopyStaticCode(",
            "kSecCodeInfoUnique",
            "observation.executableIdentity == expectedExecutableIdentity",
            "receipt.protocolManifestDigest == expectedProtocolManifestDigest",
            '"Contents/XPCServices/AIAgentWorkerXPCService.xpc"',
        ):
            self.assertIn(required, ai_source)

        receipt_tests = WORKER_RECEIPT_TESTS.read_text(encoding="utf-8")
        mutation_body = method_body(
            receipt_tests,
            "testLiveBindingRejectsAlternateExecutableWithAcceptedProtocolAndSigner",
        )
        for required in (
            "XCTAssertEqual(receipt.protocolManifestDigest, manifestDigest)",
            "XCTAssertTrue(alternateExecutable.signingRequirementAccepted)",
            '"/private/tmp/AcceptedSigner/AIAgentWorkerXPCService.xpc/Contents/"',
            "XCTAssertFalse(",
            "accepted-protocol, accepted-signer worker cannot substitute another executable",
        ):
            self.assertIn(required, mutation_body)

        native_source = NATIVE_GATE.read_text(encoding="utf-8")
        native_body = method_body(
            native_source,
            "testSignedServiceReturnsMalformedFailureAndHonorsCooperativeCancellation",
        )
        self.assertIn("NativeDecompilerLiveSignedProduct.resolveFromTestHost()", native_body)
        self.assertIn("proveMalformedRawDataReturnsWireFailure(session: session)", native_body)
        self.assertIn("proveCooperativeCancellation(session: session)", native_body)

    def test_result_verifier_accepts_only_the_exact_executed_pass(self) -> None:
        passed = self.run_verifier(test_results())
        self.assertEqual(passed.returncode, 0, passed.stderr)
        self.assertIn("verified exact executed test", passed.stdout)

        failed = self.run_verifier(test_results("Failed"))
        self.assertEqual(failed.returncode, 1)
        self.assertIn("not exclusively passed", failed.stderr)

        skipped = self.run_verifier(test_results(skipped=True))
        self.assertEqual(skipped.returncode, 1)
        self.assertIn("recorded a skip message", skipped.stderr)

    def test_r2_selector_verifies_only_its_exact_executed_result(self) -> None:
        passed = self.run_verifier(test_results(selector=R2_AI_SELECTOR), R2_AI_SELECTOR)
        self.assertEqual(passed.returncode, 0, passed.stderr)
        self.assertIn(R2_AI_SELECTOR, passed.stdout)
        for result in ["Failed", "Skipped"]:
            with self.subTest(result=result):
                rejected = self.run_verifier(test_results(result, selector=R2_AI_SELECTOR), R2_AI_SELECTOR)
                self.assertEqual(rejected.returncode, 1)
        skipped = self.run_verifier(test_results(skipped=True, selector=R2_AI_SELECTOR), R2_AI_SELECTOR)
        self.assertEqual(skipped.returncode, 1)
        self.assertIn("recorded a skip message", skipped.stderr)
        wrong_generation = self.run_verifier(test_results(), R2_AI_SELECTOR)
        self.assertEqual(wrong_generation.returncode, 1)
        self.assertIn("found 0", wrong_generation.stderr)
        default_r1 = self.run_verifier(test_results(selector=R2_AI_SELECTOR))
        self.assertEqual(default_r1.returncode, 1)
        self.assertIn("found 0", default_r1.stderr)

    def test_selector_allowlist_rejects_suite_wildcard_and_unrelated_test(self) -> None:
        for selector in [AI_SELECTOR.rsplit("/", 1)[0], AI_SELECTOR + "*", "CoreTests/Other/testFoo", ""]:
            with self.subTest(selector=selector):
                rejected = self.run_verifier(test_results(), selector)
                self.assertEqual(rejected.returncode, 2)
                self.assertIn("allowlisted exact", rejected.stderr)
        missing = subprocess.run([str(RUNNER), "--test-selector"], text=True, capture_output=True)
        self.assertEqual(missing.returncode, 2)
        self.assertIn("--test-selector requires a value", missing.stderr)


if __name__ == "__main__":
    unittest.main()
