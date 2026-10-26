from __future__ import annotations

import hashlib
import json
import os
import plistlib
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

from Scripts.reconstruction import deterministic_evidence_artifacts as artifacts
from Scripts.reconstruction import native_live_preparation_receipt as preparation
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes, load_canonical_json
from Scripts.reconstruction_gate_f.tests import candidate_mapping
from Scripts.qualification import generated_project_evidence
from Scripts.qualification.restore_build_source import _generated_project_identity
from Scripts.tests.test_generated_project_evidence import make_project_evidence_fixture


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "Scripts/reconstruction/run_deterministic_evidence_tests.sh"
EMITTER = ROOT / "MacScope/Tests/CoreTests/ReconstructionWorkspaceDatabaseTests.swift"


class DeterministicEvidenceArtifactTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.first = self.root / "first"
        self.second = self.root / "second"
        self.first.mkdir()
        self.second.mkdir()
        for relative_path in artifacts.ARTIFACT_PATHS:
            payload = canonical_bytes(
                {
                    "artifact": relative_path,
                    "schema_version": 1,
                }
            )
            (self.first / relative_path).write_bytes(payload)
            (self.second / relative_path).write_bytes(payload)
        self.candidate = self.root / "candidate.json"
        self.candidate.write_bytes(canonical_bytes(candidate_mapping()) + b"\n")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_comparison_is_candidate_bound_closed_and_byte_exact(self) -> None:
        comparison = artifacts.compare_artifact_roots(
            candidate_identity_path=self.candidate,
            first_root=self.first,
            second_root=self.second,
        )

        self.assertEqual(comparison["schema_version"], 1)
        self.assertEqual(
            comparison["command_id"],
            "reconstruction.deterministic-evidence",
        )
        self.assertEqual(comparison["fresh_process_count"], 2)
        self.assertEqual(
            tuple(item["artifact_id"] for item in comparison["artifacts"]),
            artifacts.ARTIFACT_IDS,
        )
        for item in comparison["artifacts"]:
            payload = (self.first / item["relative_path"]).read_bytes()
            self.assertEqual(item["byte_count"], len(payload))
            self.assertEqual(item["sha256"], hashlib.sha256(payload).hexdigest())

    def test_missing_extra_symlink_and_byte_drift_are_rejected(self) -> None:
        missing = self.second / artifacts.ARTIFACT_PATHS[0]
        missing.unlink()
        with self.assertRaisesRegex(artifacts.DeterministicEvidenceError, "artifact-set"):
            artifacts.compare_artifact_roots(
                candidate_identity_path=self.candidate,
                first_root=self.first,
                second_root=self.second,
            )
        missing.write_bytes((self.first / missing.name).read_bytes())

        extra = self.second / "unexpected.json"
        extra.write_text("{}", encoding="utf-8")
        with self.assertRaisesRegex(artifacts.DeterministicEvidenceError, "artifact-set"):
            artifacts.compare_artifact_roots(
                candidate_identity_path=self.candidate,
                first_root=self.first,
                second_root=self.second,
            )
        extra.unlink()

        drift = self.second / artifacts.ARTIFACT_PATHS[1]
        drift.write_bytes(b"drift")
        with self.assertRaisesRegex(artifacts.DeterministicEvidenceError, "byte-mismatch"):
            artifacts.compare_artifact_roots(
                candidate_identity_path=self.candidate,
                first_root=self.first,
                second_root=self.second,
            )
        drift.write_bytes((self.first / drift.name).read_bytes())

        link = self.second / artifacts.ARTIFACT_PATHS[2]
        link.unlink()
        link.symlink_to(self.first / link.name)
        with self.assertRaisesRegex(artifacts.DeterministicEvidenceError, "non-symlink"):
            artifacts.compare_artifact_roots(
                candidate_identity_path=self.candidate,
                first_root=self.first,
                second_root=self.second,
            )

    def test_comparison_report_is_canonical_and_create_only(self) -> None:
        output = self.root / "comparison.json"
        comparison = artifacts.compare_artifact_roots(
            candidate_identity_path=self.candidate,
            first_root=self.first,
            second_root=self.second,
        )

        artifacts.write_create_only(output, comparison)

        self.assertEqual(load_canonical_json(output), comparison)
        self.assertEqual(output.read_bytes(), canonical_bytes(comparison))
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
        with self.assertRaisesRegex(artifacts.DeterministicEvidenceError, "absent"):
            artifacts.write_create_only(output, comparison)

    def test_run_xctestrun_injects_only_the_canonical_artifact_root(self) -> None:
        source = self.root / "source.xctestrun"
        output = self.root / "run.xctestrun"
        artifact_root = self.root / "emitted"
        artifact_root.mkdir()
        original = {
            "CoreTests": {
                "BlueprintName": "CoreTests",
                "EnvironmentVariables": {"TERM": "dumb"},
                "TestHostPath": "__TESTROOT__/Debug/MacScope.app",
                "TestingEnvironmentVariables": {"XCODE_SCHEME_NAME": "MacScopeApp"},
            },
            "__xctestrun_metadata__": {
                "ContainerInfo": {"SchemeName": "MacScopeApp"},
                "FormatVersion": 2,
            },
        }
        source.write_bytes(plistlib.dumps(original, fmt=plistlib.FMT_BINARY, sort_keys=True))

        artifacts.write_run_xctestrun(
            source_path=source,
            output_path=output,
            artifact_root=artifact_root,
        )

        self.assertEqual(plistlib.loads(source.read_bytes()), original)
        derived = plistlib.loads(output.read_bytes())
        environment = derived["CoreTests"]["EnvironmentVariables"]
        self.assertEqual(environment["TERM"], "dumb")
        self.assertEqual(
            environment["MACSCOPE_DETERMINISTIC_EVIDENCE_OUTPUT_ROOT"],
            str(artifact_root),
        )
        self.assertEqual(
            derived["CoreTests"]["TestingEnvironmentVariables"],
            original["CoreTests"]["TestingEnvironmentVariables"],
        )
        self.assertEqual(
            derived["CoreTests"]["TestHostPath"],
            f"{source.parent}/Debug/MacScope.app",
        )
        with self.assertRaisesRegex(artifacts.DeterministicEvidenceError, "absent"):
            artifacts.write_run_xctestrun(
                source_path=source,
                output_path=output,
                artifact_root=artifact_root,
            )

    def test_run_xctestrun_rejects_ambiguous_or_preinjected_coretests(self) -> None:
        artifact_root = self.root / "emitted"
        artifact_root.mkdir()
        for name, document, message in (
            (
                "ambiguous",
                {
                    "CoreTests": {"BlueprintName": "CoreTests", "EnvironmentVariables": {}},
                    "CoreTests-2": {"BlueprintName": "CoreTests", "EnvironmentVariables": {}},
                    "__xctestrun_metadata__": {
                        "ContainerInfo": {"SchemeName": "MacScopeApp"}
                    },
                },
                "exactly one CoreTests",
            ),
            (
                "preinjected",
                {
                    "CoreTests": {
                        "BlueprintName": "CoreTests",
                        "EnvironmentVariables": {
                            "MACSCOPE_DETERMINISTIC_EVIDENCE_OUTPUT_ROOT": "/tmp/other"
                        },
                        "TestingEnvironmentVariables": {},
                    },
                    "__xctestrun_metadata__": {
                        "ContainerInfo": {"SchemeName": "MacScopeApp"}
                    },
                },
                "already carries",
            ),
        ):
            with self.subTest(name=name):
                source = self.root / f"{name}.xctestrun"
                source.write_bytes(plistlib.dumps(document, fmt=plistlib.FMT_BINARY))
                with self.assertRaisesRegex(artifacts.DeterministicEvidenceError, message):
                    artifacts.write_run_xctestrun(
                        source_path=source,
                        output_path=self.root / f"{name}.derived.xctestrun",
                        artifact_root=artifact_root,
                    )


class DeterministicEvidencePreparationBindingTests(unittest.TestCase):
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
        self.native_executable = (
            self.app
            / "Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents/MacOS/NativeDecompilerXPCService"
        )
        self.core_tests = self.app / "Contents/PlugIns/CoreTests.xctest"
        self.core_executable = self.core_tests / "Contents/MacOS/CoreTests"
        for executable, payload in (
            (self.app_executable, b"app"),
            (self.native_executable, b"native"),
            (self.core_executable, b"tests"),
        ):
            executable.parent.mkdir(parents=True, exist_ok=True)
            executable.write_bytes(payload)
            executable.chmod(0o755)
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
                    "branch_label": "feature/deterministic-receipt-test",
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
                        "closed_tree_sha256": preparation.closed_tree_sha256(self.core_tests),
                        "executable_sha256": preparation.file_sha256(self.core_executable),
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

    def test_stale_xctestrun_and_tampered_coretests_fail_the_existing_receipt(self) -> None:
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
        self.xctestrun.write_bytes(original_xctestrun)

        original_coretests = self.core_executable.read_bytes()
        self.core_executable.write_bytes(original_coretests + b"-tampered")
        self.core_executable.chmod(0o755)
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


class DeterministicEvidenceRunnerContractTests(unittest.TestCase):
    def test_emitter_orders_uuid_maps_before_canonical_encoding(self) -> None:
        source = EMITTER.read_text(encoding="utf-8")

        self.assertIn("private struct EvidenceFrontierArtifact: Encodable", source)
        self.assertIn(
            "ReconstructionCanonicalJSON.encode(EvidenceFrontierArtifact(cut: cut))",
            source,
        )
        self.assertIn(
            "cut.projectedClassificationsByEvidenceID.keys.sorted(by:",
            source,
        )
        self.assertIn("cut.checkpointRevisionsByID.keys.sorted(by:", source)
        self.assertNotIn(
            '("evidence-frontier.json", try ReconstructionCanonicalJSON.encode(cut))',
            source,
        )

    def test_runner_uses_two_fresh_test_processes_and_exact_emitter(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")

        self.assertEqual(source.count("xcodebuild test-without-building"), 2)
        self.assertEqual(
            source.count(
                "CoreTests/ReconstructionDeterministicEvidenceEmitterTests/"
                "testEmitsCanonicalDeterministicEvidenceArtifacts"
            ),
            1,
        )
        self.assertIn('prepare-xctestrun --source "$xctestrun"', source)
        self.assertIn('--preparation-receipt ABSOLUTE_PATH', source)
        validation_lines = [
            line
            for line in source.splitlines()
            if line.startswith('/usr/bin/python3 -B "$preparation_validator"')
        ]
        self.assertEqual(
            validation_lines,
            ['/usr/bin/python3 -B "$preparation_validator" validate \\'],
        )
        self.assertIn('--receipt "$preparation_receipt"', source)
        self.assertIn('--candidate-identity "$candidate_identity"', source)
        self.assertIn('--product native-live-app', source)
        self.assertNotIn('--product app', source)
        self.assertIn('--artifact-root "$first_root"', source)
        self.assertIn('--artifact-root "$second_root"', source)
        self.assertIn('-xctestrun "$first_xctestrun"', source)
        self.assertIn('-xctestrun "$second_xctestrun"', source)
        self.assertNotIn("MACSCOPE_DETERMINISTIC_EVIDENCE_OUTPUT_ROOT=\"$first_root\"", source)
        self.assertIn("deterministic_evidence_artifacts.py", source)
        self.assertIn("write_execution_report.py", source)
        for forwarding in (
            '--qualification-run-id "$qualification_run_id"',
            '--qualification-run-nonce "$qualification_run_nonce"',
            '--predecessor-observations-sha256 "$predecessor_observations_sha256"',
        ):
            self.assertEqual(source.count(forwarding), 1)
        self.assertNotIn("MACSCOPE_QUALIFICATION_RUN", source)
        self.assertNotIn("build-for-testing", source)
        self.assertNotIn("xcodegen", source.lower())
        self.assertNotIn("LM_STUDIO", source)
        receipt_validation = source.index(validation_lines[0])
        first_xcode_execution = source.index("xcodebuild test-without-building")
        output_creation = source.index('/bin/mkdir "$result_bundle_root" "$artifact_root"')
        self.assertLess(receipt_validation, output_creation)
        self.assertLess(receipt_validation, first_xcode_execution)

    def test_runner_requires_orchestrator_execution_report_authority(self) -> None:
        result = subprocess.run(
            [
                str(RUNNER),
                "--candidate-identity", "/tmp/candidate.json",
                "--preparation-receipt", "/tmp/preparation.json",
                "--xctestrun", "/tmp/tests.xctestrun",
                "--candidate-app", "/tmp/MacScope.app",
                "--result-bundle-root", "/tmp/result-bundles",
                "--artifact-root", "/tmp/artifacts",
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("--qualification-run-id is required", result.stderr)

    def test_runner_publishes_every_gate_f_artifact_marker(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        for marker in (
            "MACSCOPE_DETERMINISTIC_EVIDENCE_CHECKPOINT",
            "MACSCOPE_DETERMINISTIC_EVIDENCE_CHECKPOINT_TWO",
            "MACSCOPE_DETERMINISTIC_EVIDENCE_COMPARISON",
            "MACSCOPE_DETERMINISTIC_EVIDENCE_CORPUS",
            "MACSCOPE_DETERMINISTIC_EVIDENCE_CORPUS_TWO",
            "MACSCOPE_DETERMINISTIC_EVIDENCE_EXECUTION_REPORT",
            "MACSCOPE_DETERMINISTIC_EVIDENCE_FRONTIER",
            "MACSCOPE_DETERMINISTIC_EVIDENCE_FRONTIER_TWO",
            "MACSCOPE_DETERMINISTIC_EVIDENCE_RECEIPT",
            "MACSCOPE_DETERMINISTIC_EVIDENCE_RECEIPT_TWO",
            "MACSCOPE_DETERMINISTIC_EVIDENCE_RETRIEVAL_PACKET",
            "MACSCOPE_DETERMINISTIC_EVIDENCE_RETRIEVAL_PACKET_TWO",
            "MACSCOPE_DETERMINISTIC_EVIDENCE_TEST_RESULTS_ONE",
            "MACSCOPE_DETERMINISTIC_EVIDENCE_TEST_RESULTS_TWO",
        ):
            with self.subTest(marker=marker):
                self.assertIn(marker, source)


if __name__ == "__main__":
    unittest.main()
