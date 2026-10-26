import importlib.util
import json
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from Scripts.tests.test_generated_project_evidence import make_project_evidence_fixture
from Scripts.qualification import generated_project_evidence
from Scripts.qualification.restore_build_source import _generated_project_identity


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "Scripts/reconstruction/run_authority_stress_tests.sh"
PREPARATION_HELPER = (
    ROOT / "Scripts/reconstruction/native_live_preparation_receipt.py"
)
QUALIFICATION_RUN_ID = "gate-f-qualification-20260828"
QUALIFICATION_RUN_NONCE = "9" * 64


def load_preparation_helper():
    specification = importlib.util.spec_from_file_location(
        "authority_stress_native_live_preparation_receipt_tests",
        PREPARATION_HELPER,
    )
    if specification is None or specification.loader is None:
        raise AssertionError("could not load native live preparation helper")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class ReconstructionAuthorityStressProductBindingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load_preparation_helper()
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source_repository = self.root / "source-repository"
        (self.source_repository / "MacScope/MacScope.xcodeproj").mkdir(
            parents=True
        )
        (self.source_repository / "MacScope/project.yml").write_text(
            "name: MacScope\n",
            encoding="utf-8",
        )
        (
            self.source_repository
            / "MacScope/MacScope.xcodeproj/project.xcproj"
        ).write_text("// generated\n", encoding="utf-8")
        self._git("init", "-b", "feature/stress-product-binding-test")
        self._git("config", "user.name", "Stress Product Binding Test")
        self._git("config", "user.email", "stress@example.invalid")
        self._git("add", "MacScope/project.yml")
        self._git("commit", "-m", "fixture")
        (
            self.source_repository / ".git/info/exclude"
        ).write_text("MacScope/MacScope.xcodeproj/\n", encoding="utf-8")

        self.products = self.root / "DerivedData/Build/Products"
        self.debug = self.products / "Debug"
        self.app = self.debug / "MacScope.app"
        self.native_bundle = (
            self.app / "Contents/XPCServices/NativeDecompilerXPCService.xpc"
        )
        self.core_tests = self.app / "Contents/PlugIns/CoreTests.xctest"
        self.app_executable = self.app / "Contents/MacOS/MacScope"
        self.native_executable = (
            self.native_bundle / "Contents/MacOS/NativeDecompilerXPCService"
        )
        self.core_executable = self.core_tests / "Contents/MacOS/CoreTests"
        for executable, payload in (
            (self.app_executable, b"app"),
            (self.native_executable, b"native"),
            (self.core_executable, b"tests"),
        ):
            executable.parent.mkdir(parents=True, exist_ok=True)
            executable.write_bytes(payload)
            executable.chmod(0o755)
        self._write_plist(self.app / "Contents/Info.plist", "org.macscope.app")
        self._write_plist(
            self.native_bundle / "Contents/Info.plist",
            "org.macscope.app.NativeDecompiler",
        )

        self.xctestrun = self.products / "MacScopeApp.xctestrun"
        with self.xctestrun.open("wb") as stream:
            plistlib.dump(
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
                        "EnvironmentVariables": {},
                        "IsAppHostedTestBundle": True,
                        "TestBundlePath": (
                            "__TESTHOST__/Contents/PlugIns/CoreTests.xctest"
                        ),
                        "TestHostBundleIdentifier": "org.macscope.app",
                        "TestHostPath": "__TESTROOT__/Debug/MacScope.app",
                        "TestingEnvironmentVariables": {},
                    },
                },
                stream,
                sort_keys=True,
            )

        self.receipt = self.root / "NativeLivePreparation.receipt.json"
        project = make_project_evidence_fixture(
            self.root.resolve(), self._git("rev-parse", "HEAD"),
            self._git("rev-parse", "HEAD^{tree}"),
            (self.source_repository / "MacScope/project.yml").read_bytes(),
        )
        generated_project_evidence.capture(
            self.root.resolve(), _generated_project_identity(project, require_complete=True)
        )
        receipt = self.module.create_document(
            self.source_repository,
            "gitfox-local:MacScope",
            self.xctestrun,
            self.app,
            toolchain={
                "developer_dir": "/Applications/Xcode-beta.app/Contents/Developer",
                "xcodebuild_sha256": "1" * 64,
                "xcode_version": "27.0",
                "xcode_build": "27A5252f",
                "swiftc_sha256": "2" * 64,
                "swift_version": "Apple Swift version 6.4",
                "sdk_path": "/Applications/Xcode-beta.app/SDKs/MacOSX.sdk",
                "sdk_settings_sha256": "3" * 64,
                "sdk_version": "27.0",
                "sdk_build": "26A5419a",
            },
        )
        self.receipt.write_bytes(self.module.canonical_bytes(receipt))
        self.candidate = self._write_candidate(receipt)
        self.predecessor_observations = self.root / "predecessor-observations.json"
        self.predecessor_observations.write_text(
            json.dumps(
                [
                    {
                        "command_id": "xcode.full-coretests",
                        "receipt_id": "receipt-full-coretests",
                        "canonical_sha256": "8" * 64,
                        "qualification_run_id": QUALIFICATION_RUN_ID,
                        "qualification_run_nonce": QUALIFICATION_RUN_NONCE,
                    }
                ],
                sort_keys=True,
                separators=(",", ":"),
            ),
            encoding="utf-8",
        )

        # Copy only the runner's host-side validation closure. Deliberately do
        # not provide run_authority_stress.py: if full receipt validation is
        # weakened, the test fails after exposing the artifact root and before
        # any Xcode invocation can occur.
        self.runner_repository = self.root / "runner-repository"
        reconstruction = self.runner_repository / "Scripts/reconstruction"
        reconstruction.mkdir(parents=True)
        shutil.copy2(RUNNER, reconstruction / RUNNER.name)
        shutil.copy2(
            PREPARATION_HELPER,
            reconstruction / PREPARATION_HELPER.name,
        )
        for helper in (ROOT / "Scripts/reconstruction").glob("*.py"):
            if helper.name != "run_authority_stress.py":
                shutil.copy2(helper, reconstruction / helper.name)
        shutil.copy2(
            ROOT / "Scripts/reconstruction/validate_qualification_product_identity.py",
            reconstruction / "validate_qualification_product_identity.py",
        )
        for helper in (ROOT / "Scripts").glob("*.py"):
            shutil.copy2(helper, self.runner_repository / "Scripts" / helper.name)
        for helper in (ROOT / "Scripts/reconstruction").glob("*.py"):
            if helper.name != "run_authority_stress.py":
                shutil.copy2(helper, reconstruction / helper.name)
        shutil.copytree(
            ROOT / "Scripts/reconstruction_gate_f",
            self.runner_repository / "Scripts/reconstruction_gate_f",
        )
        shutil.copytree(
            ROOT / "Scripts/qualification",
            self.runner_repository / "Scripts/qualification",
        )
        for name in ("check_local_signing_policy.py", "xcode_project_json.py", "generate_release_build_provenance.py"):
            shutil.copy2(ROOT / "Scripts" / name, self.runner_repository / "Scripts" / name)
        # Release provenance imports the shared byte-only golden validator;
        # retain that dependency without providing any native producer runner.
        golden_validator = self.runner_repository / "Scripts/native-decompiler-xpc/native_golden_evidence.py"
        golden_validator.parent.mkdir(parents=True)
        shutil.copy2(ROOT / "Scripts/native-decompiler-xpc/native_golden_evidence.py", golden_validator)
        (self.runner_repository / "Scripts/xcode27_env.sh").write_text(
            "#!/bin/bash\n",
            encoding="utf-8",
        )
        self.result_parent = self.root / "results"
        self.artifact_parent = self.root / "artifacts"
        self.result_parent.mkdir()
        self.artifact_parent.mkdir()
        self.result_bundle = self.result_parent / "Stress.xcresult"
        self.artifact_root = self.artifact_parent / "StressEvidence"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _git(self, *arguments: str) -> str:
        result = subprocess.run(
            ["/usr/bin/git", *arguments],
            cwd=self.source_repository,
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()

    @staticmethod
    def _write_plist(path: Path, identifier: str) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("wb") as stream:
            plistlib.dump({
                "CFBundleIdentifier": identifier,
                "CFBundleExecutable": path.parent.parent.stem,
            }, stream)

    def _write_candidate(self, receipt: dict[str, object]) -> Path:
        from Scripts.reconstruction_gate_f.tests import candidate_mapping

        candidate = candidate_mapping()
        candidate["source"].update(receipt["source"])
        identities = {
            value["identity_id"]: value
            for value in candidate["application"]["qualification_executables"]
        }
        app_sha256 = self.module.file_sha256(self.app_executable)
        for identity_id in ("app", "native-live-app"):
            identities[identity_id].update(
                {
                    "bundle_identifier": "org.macscope.app",
                    "sha256": app_sha256,
                }
            )
        identities["native-decompiler"].update(
            {
                "bundle_identifier": "org.macscope.app.NativeDecompiler",
                "sha256": self.module.file_sha256(self.native_executable),
            }
        )
        path = self.root / "candidate.json"
        from Scripts.reconstruction_gate_f.canonical_json import write_canonical_json

        write_canonical_json(path, candidate)
        return path

    def _run_runner(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "/bin/bash",
                str(
                    self.runner_repository
                    / "Scripts/reconstruction/run_authority_stress_tests.sh"
                ),
                "--candidate-identity",
                str(self.candidate),
                "--preparation-receipt",
                str(self.receipt),
                "--qualification-run-id",
                QUALIFICATION_RUN_ID,
                "--qualification-run-nonce",
                QUALIFICATION_RUN_NONCE,
                "--predecessor-observations",
                str(self.predecessor_observations),
                "--xctestrun",
                str(self.xctestrun),
                "--candidate-app",
                str(self.app),
                "--result-bundle-path",
                str(self.result_bundle),
                "--artifact-root",
                str(self.artifact_root),
            ],
            text=True,
            capture_output=True,
            check=False,
        )

    def _assert_rejected_before_outputs(
        self,
        result: subprocess.CompletedProcess[str],
    ) -> None:
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(
            "prepared product identity differs from its receipt",
            result.stderr,
        )
        self.assertFalse(self.artifact_root.exists())
        self.assertFalse(self.result_bundle.exists())

    def test_structurally_valid_stale_xctestrun_is_rejected_before_xcodebuild(
        self,
    ) -> None:
        with self.xctestrun.open("rb") as stream:
            document = plistlib.load(stream)
        document["CoreTests"]["TestLanguage"] = "en"
        with self.xctestrun.open("wb") as stream:
            plistlib.dump(document, stream, sort_keys=True)
        # The mutation preserves the structural contract and changes only the
        # receipt-bound artifact identity.
        self.module._xctestrun_contract(self.xctestrun)
        self._assert_rejected_before_outputs(self._run_runner())

    def test_modified_core_tests_product_is_rejected_before_xcodebuild(self) -> None:
        self.core_executable.write_bytes(
            self.core_executable.read_bytes() + b"resigned-product-mutation"
        )
        self.core_executable.chmod(0o755)
        self._assert_rejected_before_outputs(self._run_runner())

    def test_execution_xctestrun_derives_from_the_immutable_prepared_snapshot(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        self.assertIn(
            '"$prepared_xctestrun_evidence" "$execution_xctestrun" "$plan_path" "$ledger_path"',
            source,
        )
        self.assertNotIn(
            '"$xctestrun" "$execution_xctestrun" "$plan_path" "$ledger_path"',
            source,
        )
        self.assertIn('os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)', source)
        self.assertIn(
            '"prepared xctestrun snapshot"',
            source,
        )
        self.assertIn(
            'hashlib.sha256(source_bytes).hexdigest() != expected_xctestrun_sha256',
            source,
        )
        self.assertIn(
            "prepared xctestrun snapshot differs from its preparation receipt",
            source,
        )


if __name__ == "__main__":
    unittest.main()
