import copy
import hashlib
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock
from Scripts.tests.test_generated_project_evidence import make_project_evidence_fixture
from Scripts.qualification import generated_project_evidence
from Scripts.qualification.restore_build_source import _generated_project_identity


ROOT = Path(__file__).resolve().parents[2]
HELPER = (
    ROOT
    / "Scripts"
    / "reconstruction"
    / "native_live_preparation_receipt.py"
)


def load_helper():
    specification = importlib.util.spec_from_file_location(
        "native_live_preparation_receipt_tests",
        HELPER,
    )
    if specification is None or specification.loader is None:
        raise AssertionError("could not load native live preparation helper")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class NativeLivePreparationReceiptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load_helper()
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.repository = self.root / "repository"
        (self.repository / "MacScope/MacScope.xcodeproj").mkdir(parents=True)
        (self.repository / "MacScope/project.yml").write_text("name: MacScope\n")
        (self.repository / "MacScope/MacScope.xcodeproj/project.xcproj").write_text(
            "// generated\n"
        )
        self._git("init", "-b", "feature/native-receipt-test")
        self._git("config", "user.name", "Receipt Test")
        self._git("config", "user.email", "receipt@example.invalid")
        self._git("add", "MacScope/project.yml")
        self._git("commit", "-m", "fixture")
        # The generated project is gitignored production output. The receipt
        # still binds its bytes, while Git cleanliness binds tracked source.
        (self.repository / ".git/info/exclude").write_text("MacScope/MacScope.xcodeproj/\n")
        actual_project = make_project_evidence_fixture(
            self.root, self._git("rev-parse", "HEAD"), self._git("rev-parse", "HEAD^{tree}"),
            (self.repository / "MacScope/project.yml").read_bytes(),
        )
        self.actual_project = generated_project_evidence.capture(
            self.root, _generated_project_identity(actual_project, require_complete=True)
        )

        self.products = self.root / "DerivedData/Build/Products"
        self.debug = self.products / "Debug"
        self.app = self.debug / "MacScope.app"
        self.native_bundle = (
            self.app / "Contents/XPCServices/NativeDecompilerXPCService.xpc"
        )
        self.core_tests = (
            self.app / "Contents/PlugIns/CoreTests.xctest"
        )
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
                        "IsAppHostedTestBundle": True,
                        "TestHostBundleIdentifier": "org.macscope.app",
                        "TestHostPath": "__TESTROOT__/Debug/MacScope.app",
                        "TestBundlePath": "__TESTHOST__/Contents/PlugIns/CoreTests.xctest",
                    },
                },
                stream,
            )
        self.toolchain = {
            "developer_dir": "/Applications/Xcode-beta.app/Contents/Developer",
            "xcodebuild_sha256": "1" * 64,
            "xcode_version": "27.0",
            "xcode_build": "27A5252f",
            "swiftc_sha256": "2" * 64,
            "swift_version": (
                "Apple Swift version 6.4\nTarget: arm64-apple-macosx27.0"
            ),
            "sdk_path": "/Applications/Xcode-beta.app/SDKs/MacOSX.sdk",
            "sdk_settings_sha256": "3" * 64,
            "sdk_version": "27.0",
            "sdk_build": "26A5419a",
        }

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _git(self, *arguments: str) -> str:
        result = subprocess.run(
            ["/usr/bin/git", *arguments],
            cwd=self.repository,
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()

    @staticmethod
    def _write_plist(path: Path, identifier: str) -> None:
        executable_names = {
            "org.macscope.app": "MacScope",
            "org.macscope.app.NativeDecompiler": "NativeDecompilerXPCService",
            "org.macscope.app.ui-runner": "MacScopeInstalledAppUITests-Runner",
            "org.macscope.app.ui-tests": "MacScopeInstalledAppUITests",
        }
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleIdentifier": identifier,
                    "CFBundleExecutable": executable_names.get(
                        identifier,
                        identifier.rsplit(".", 1)[-1],
                    ),
                },
                stream,
            )

    def _receipt(self):
        return self.module.create_document(
            self.repository,
            "gitfox-local:MacScope",
            self.xctestrun,
            self.app,
            toolchain=self.toolchain,
        )

    def test_stale_original_project_is_not_preparation_authority(self) -> None:
        receipt = self._receipt()
        original = self.repository / "MacScope/MacScope.xcodeproj/project.xcproj"
        self.assertNotEqual(hashlib.sha256(original.read_bytes()).hexdigest(), receipt["source"]["generated_project_sha256"])
        self.assertEqual(hashlib.sha256(self.actual_project.read_bytes()).hexdigest(), receipt["source"]["generated_project_sha256"])
        original.unlink()
        self.assertEqual(self._receipt()["source"], receipt["source"])

    def test_historical_receipt_without_actual_evidence_cannot_validate_products(self) -> None:
        receipt = self._receipt()
        evidence_root = self.root / generated_project_evidence.DIRECTORY
        evidence_root.rename(self.root / "held-evidence")
        with self.assertRaises(self.module.PreparationReceiptError):
            self.module.validate_prepared_artifacts(receipt, self.xctestrun, self.app)

    def test_native_preparation_binds_release_app_and_debug_coretests(self) -> None:
        release_app = self.products / "Release/MacScope.app"
        shutil.copytree(self.app, release_app)
        receipt = self.module.create_document(
            self.repository,
            "gitfox-local:MacScope",
            self.xctestrun,
            release_app,
            toolchain=self.toolchain,
            test_bundle=self.core_tests,
        )

        self.assertEqual(receipt["artifacts"]["app"]["path"], str(release_app))
        self.assertEqual(
            receipt["artifacts"]["core_tests"]["path"], str(self.core_tests)
        )
        self.assertEqual(
            self.module.validate_prepared_artifacts(
                receipt,
                self.xctestrun,
                release_app,
            ),
            self.module.canonical_sha256(receipt),
        )

    def _receipt_with_publication_fence(self):
        fences = []
        receipt = self.module.create_document(
            self.repository,
            "gitfox-local:MacScope",
            self.xctestrun,
            self.app,
            toolchain=self.toolchain,
            publication_fences=fences,
        )
        self.assertEqual(len(fences), 1)
        return receipt, fences[0]

    def _candidate(self, receipt):
        from Scripts.reconstruction_gate_f.tests import candidate_mapping

        candidate = candidate_mapping()
        candidate["source"].update(receipt["source"])
        identities = {
            value["identity_id"]: value
            for value in candidate["application"]["qualification_executables"]
        }
        identities["app"].update(
            {
                "bundle_identifier": "org.macscope.app",
                "sha256": self.module.file_sha256(self.app_executable),
            }
        )
        identities["native-live-app"].update(
            {
                "bundle_identifier": "org.macscope.app",
                "sha256": self.module.file_sha256(self.app_executable),
            }
        )
        identities["native-decompiler"].update(
            {
                "bundle_identifier": "org.macscope.app.NativeDecompiler",
                "sha256": self.module.file_sha256(self.native_executable),
            }
        )
        path = self.root / "candidate.json"
        path.write_text(json.dumps(candidate, sort_keys=True))
        return path

    def _make_release_bundle(
        self,
        bundle: Path,
        executable_name: str,
        identifier: str,
    ) -> Path:
        executable = bundle / "Contents/MacOS" / executable_name
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_bytes(b"release:" + executable_name.encode("ascii"))
        executable.chmod(0o755)
        info = {
            "CFBundleExecutable": executable_name,
            "CFBundleIdentifier": identifier,
        }
        info_path = bundle / "Contents/Info.plist"
        with info_path.open("wb") as stream:
            plistlib.dump(info, stream, fmt=plistlib.FMT_BINARY, sort_keys=True)
        return executable

    def _make_release_app(self, receipt) -> tuple[Path, dict[str, Path]]:
        from Scripts.check_local_signing_policy import (
            EXPECTED_RELEASE_PROVENANCE_SCALARS,
            RELEASE_PROVENANCE_SHA256_FIELDS,
        )
        from Scripts.reconstruction import install_release_to_applications as installer

        app = self.root / "Release/MacScope.app"
        app_executable = self._make_release_bundle(
            app,
            "MacScope",
            "org.macscope.app",
        )
        launch_agent = app / "Contents/MacOS/ShellBrokerLaunchAgent"
        launch_agent.write_bytes(b"release:ShellBrokerLaunchAgent")
        (app / "Contents/MacOS/SourceExecutionRunner").write_bytes(b"fixture:SourceExecutionRunner")
        launch_agent.chmod(0o755)
        identities = {
            "analysis-worker": (
                "AnalysisWorkerXPCService",
                "org.macscope.app.AnalysisWorker",
            ),
            "ai-agent-worker": (
                "AIAgentWorkerXPCService",
                "org.macscope.app.AIAgentWorker",
            ),
            "native-decompiler": (
                "NativeDecompilerXPCService",
                "org.macscope.app.NativeDecompiler",
            ),
            "shell-broker": (
                "ShellBrokerXPCService",
                "org.macscope.app.ShellBroker",
            ),
        }
        executables = {
            identity_id: self._make_release_bundle(
                app / "Contents/XPCServices" / f"{name}.xpc",
                name,
                identifier,
            )
            for identity_id, (name, identifier) in identities.items()
        }
        code_resources = (
            app
            / "Contents/XPCServices/NativeDecompilerXPCService.xpc/Contents/"
            "_CodeSignature/CodeResources"
        )
        code_resources.parent.mkdir(parents=True, exist_ok=True)
        code_resources.write_bytes(b"release:native:CodeResources")

        source = receipt["source"]
        compiler = "6.4"
        target = "arm64-apple-macosx27.0"
        provenance = {
            field: hashlib.sha256(f"fixture:{field}".encode("ascii")).hexdigest()
            for field in RELEASE_PROVENANCE_SHA256_FIELDS
        }
        provenance.update(EXPECTED_RELEASE_PROVENANCE_SCALARS)
        provenance.update(
            {
                "git_head_commit": source["commit"],
                "git_head_tree": source["tree"],
                "project_yml_sha256": source["project_yml_sha256"],
                "xcode_version": self.toolchain["xcode_version"],
                "xcode_build": self.toolchain["xcode_build"],
                "swift_compiler_version": compiler,
                "swift_target_triple": target,
                "sdk_version": self.toolchain["sdk_version"],
                "sdk_build": self.toolchain["sdk_build"],
                "native_decompiler_embedded_service_bundle_identifier": (
                    "org.macscope.app.NativeDecompiler"
                ),
                "native_decompiler_embedded_service_executable_sha256": (
                    self.module.file_sha256(executables["native-decompiler"])
                ),
                "native_decompiler_embedded_service_code_resources_sha256": (
                    self.module.file_sha256(code_resources)
                ),
                "machokit_analysis_worker_executable_sha256": (
                    self.module.file_sha256(executables["analysis-worker"])
                ),
                "native_decompiler_golden_result": {
                    "xcodeVersion": self.toolchain["xcode_version"],
                    "xcodeBuild": self.toolchain["xcode_build"],
                    "swiftCompilerVersion": compiler,
                    "swiftTargetTriple": target,
                    "sdkVersion": self.toolchain["sdk_version"],
                    "sdkBuild": self.toolchain["sdk_build"],
                },
            }
        )
        provenance_path = app / installer.BUILD_PROVENANCE_RELATIVE_PATH
        provenance_path.parent.mkdir(parents=True, exist_ok=True)
        provenance_path.write_bytes(
            (
                json.dumps(
                    provenance,
                    ensure_ascii=True,
                    allow_nan=False,
                    sort_keys=True,
                    separators=(",", ":"),
                )
                + "\n"
            ).encode("utf-8")
        )
        provenance_path.chmod(0o644)
        return app, {"app": app_executable, **executables, "code-resources": code_resources}

    def _installed_candidate(self, receipt, app: Path, executables: dict[str, Path]) -> Path:
        from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes
        from Scripts.reconstruction_gate_f.materialize_candidate_identity import (
            bundle_tree_digests,
        )
        from Scripts.reconstruction_gate_f.tests import candidate_mapping

        candidate = candidate_mapping()
        candidate["source"].update(receipt["source"])
        candidate_tools = {tool["tool_id"]: tool for tool in candidate["tools"]}
        candidate_tools["xcode"].update(
            {
                "identity_sha256": self.toolchain["xcodebuild_sha256"],
                "version": (
                    f"Xcode {self.toolchain['xcode_version']} | "
                    f"Build version {self.toolchain['xcode_build']}"
                ),
            }
        )
        candidate_tools["swift"].update(
            {
                "identity_sha256": self.toolchain["swiftc_sha256"],
                "version": self.toolchain["swift_version"].replace("\n", " | "),
            }
        )
        candidate_tools["sdk"].update(
            {
                "identity_sha256": self.toolchain["sdk_settings_sha256"],
                "version": self.toolchain["sdk_version"],
            }
        )

        digests = bundle_tree_digests(app)
        application = candidate["application"]
        application.update(
            {
                "bundle_identifier": "org.macscope.app",
                "bundle_sha256": digests.content_sha256,
                "closed_tree_sha256": digests.closed_tree_sha256,
                "root_mode": app.stat().st_mode & 0o7777,
                "executable_sha256": self.module.file_sha256(executables["app"]),
                "embedded_executables": [
                    {
                        "identity_id": identity_id,
                        "sha256": self.module.file_sha256(executables[identity_id]),
                    }
                    for identity_id in sorted(
                        (
                            "analysis-worker",
                            "ai-agent-worker",
                            "native-decompiler",
                            "shell-broker",
                        )
                    )
                ],
            }
        )
        qualifications = {
            item["identity_id"]: item
            for item in application["qualification_executables"]
        }
        qualifications["app"].update(
            {
                "bundle_identifier": "org.macscope.app",
                "sha256": self.module.file_sha256(self.app_executable),
            }
        )
        qualifications["native-live-app"].update(
            {
                "bundle_identifier": "org.macscope.app",
                "sha256": self.module.file_sha256(self.app_executable),
            }
        )
        qualifications["native-decompiler"].update(
            {
                "bundle_identifier": "org.macscope.app.NativeDecompiler",
                "sha256": self.module.file_sha256(self.native_executable),
            }
        )
        path = self.root / "installed-candidate.json"
        path.write_bytes(canonical_bytes(candidate))
        return path

    def _receipt_path(self, receipt) -> Path:
        path = self.root / "NativeLivePreparation.receipt.json"
        path.write_bytes(self.module.canonical_bytes(receipt))
        return path

    def test_receipt_binds_candidate_and_every_prepared_product(self) -> None:
        receipt = self._receipt()
        candidate = self._candidate(receipt)
        self.assertEqual(
            self.module.validate_prepared_artifacts(
                self.module.parse_document(receipt),
                self.xctestrun,
                self.app,
            ),
            self.module.canonical_sha256(receipt),
        )
        self.assertEqual(
            self.module.validate_prepared(
                self.module.parse_document(receipt),
                self.xctestrun,
                self.app,
                candidate,
            ),
            self.module.canonical_sha256(receipt),
        )
        self.assertEqual(
            set(receipt["artifacts"]),
            {"xctestrun", "app", "native_decompiler", "core_tests"},
        )

    def test_tampered_prepared_artifacts_are_rejected(self) -> None:
        for path in (self.xctestrun, self.native_executable, self.core_executable):
            with self.subTest(path=path.name):
                receipt = self._receipt()
                candidate = self._candidate(receipt)
                original = path.read_bytes()
                try:
                    path.write_bytes(original + b"tamper")
                    path.chmod(0o755 if path in {self.native_executable, self.core_executable} else 0o644)
                    with self.assertRaisesRegex(
                        self.module.PreparationReceiptError,
                        "xctestrun cannot be decoded safely|prepared product identity differs|qualification product executable mismatch",
                    ):
                        self.module.validate_prepared(
                            receipt,
                            self.xctestrun,
                            self.app,
                            candidate,
                        )
                finally:
                    path.write_bytes(original)
                    path.chmod(0o755 if path in {self.native_executable, self.core_executable} else 0o644)

    def test_non_app_hosted_core_tests_contract_is_rejected(self) -> None:
        with self.xctestrun.open("rb") as stream:
            document = plistlib.load(stream)
        document["CoreTests"]["IsAppHostedTestBundle"] = False
        with self.xctestrun.open("wb") as stream:
            plistlib.dump(document, stream)
        with self.assertRaisesRegex(
            self.module.PreparationReceiptError,
            "app-hosted",
        ):
            self.module._xctestrun_contract(self.xctestrun)

    def test_validate_xctestrun_cli_accepts_xcode_27_app_host_contract(self) -> None:
        result = subprocess.run(
            [
                "python3",
                "-B",
                str(HELPER),
                "validate-xctestrun",
                "--xctestrun",
                str(self.xctestrun),
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"MACSCOPE_XCTESTRUN_CONTRACT={self.xctestrun}", result.stdout)

    def test_candidate_source_drift_is_rejected(self) -> None:
        receipt = self._receipt()
        candidate = self._candidate(receipt)
        value = json.loads(candidate.read_text())
        value["source"]["tree"] = "f" * 40
        candidate.write_text(json.dumps(value, sort_keys=True))
        with self.assertRaisesRegex(
            self.module.PreparationReceiptError,
            "source does not match",
        ):
            self.module.validate_prepared(receipt, self.xctestrun, self.app, candidate)

    def test_creation_rejects_hidden_untracked_source_input(self) -> None:
        hidden_input = self.repository / ".build-inputs/nested/opaque.json"
        hidden_input.parent.mkdir(parents=True)
        hidden_input.write_text("untracked\n", encoding="utf-8")

        with self.assertRaisesRegex(
            self.module.PreparationReceiptError,
            "including all untracked files",
        ):
            self._receipt()

    def test_creation_rejects_source_drift_after_product_hashing(self) -> None:
        project = self.repository / "MacScope/project.yml"
        original_fence = self.module._require_unchanged_source_snapshot
        mutated = False

        def mutate_and_fence(root, snapshot, *, phase):
            nonlocal mutated
            if not mutated:
                project.write_text("name: changed-during-preparation\n", encoding="utf-8")
                mutated = True
            return original_fence(root, snapshot, phase=phase)

        with mock.patch.object(
            self.module,
            "_require_unchanged_source_snapshot",
            side_effect=mutate_and_fence,
        ):
            with self.assertRaisesRegex(
                self.module.PreparationReceiptError,
                "source identity drifted",
            ):
                self._receipt()

        self.assertTrue(mutated)

    def test_creation_rejects_in_place_product_write_before_final_fence(self) -> None:
        original_fence = self.module._require_unchanged_prepared_file_snapshot
        original_executable = self.app_executable.read_bytes()
        mutated = False

        def mutate_and_fence(snapshot, *, phase):
            nonlocal mutated
            if not mutated and phase.startswith("preparation receipt publication"):
                self.app_executable.write_bytes(b"bad")
                self.app_executable.chmod(0o755)
                mutated = True
            return original_fence(snapshot, phase=phase)

        try:
            with mock.patch.object(
                self.module,
                "_require_unchanged_prepared_file_snapshot",
                side_effect=mutate_and_fence,
            ):
                with self.assertRaisesRegex(
                    self.module.PreparationReceiptError,
                    "file changed before preparation receipt publication|bundle tree changed before preparation receipt publication",
                ):
                    self._receipt()
        finally:
            self.app_executable.write_bytes(original_executable)
            self.app_executable.chmod(0o755)

        self.assertTrue(mutated)

    def test_creation_rejects_rename_symlink_swap_before_final_fence(self) -> None:
        original_fence = self.module._require_unchanged_prepared_file_snapshot
        replacement = self.app_executable.with_name("MacScope.pre-swap")
        swapped = False

        def swap_and_fence(snapshot, *, phase):
            nonlocal swapped
            if not swapped and phase.startswith("preparation receipt publication"):
                self.app_executable.rename(replacement)
                self.app_executable.symlink_to(replacement.name)
                swapped = True
            return original_fence(snapshot, phase=phase)

        try:
            with mock.patch.object(
                self.module,
                "_require_unchanged_prepared_file_snapshot",
                side_effect=swap_and_fence,
            ):
                with self.assertRaisesRegex(
                    self.module.PreparationReceiptError,
                    "ordinary file|symbolic link|cannot be safely read",
                ):
                    self._receipt()
        finally:
            if self.app_executable.is_symlink():
                self.app_executable.unlink()
            if replacement.exists():
                replacement.rename(self.app_executable)

        self.assertTrue(swapped)

    def test_publication_revalidates_generated_project_and_product_before_create(self) -> None:
        receipt, fence = self._receipt_with_publication_fence()
        generated_project = self.actual_project
        generated_project.write_text("// changed after receipt materialization\n", encoding="utf-8")
        output = self.root / "preparation.json"

        with self.assertRaisesRegex(
            self.module.PreparationReceiptError,
            "file changed before preparation receipt create-only publication",
        ):
            self.module._write_create_only(
                output,
                receipt,
                publication_fence=fence,
            )
        self.assertFalse(output.exists())

    def test_publication_revalidates_product_bundle_before_create(self) -> None:
        receipt, fence = self._receipt_with_publication_fence()
        self.app_executable.write_bytes(b"changed after receipt materialization")
        self.app_executable.chmod(0o755)
        output = self.root / "preparation.json"

        with self.assertRaisesRegex(
            self.module.PreparationReceiptError,
            "file changed before preparation receipt create-only publication|bundle tree changed before preparation receipt create-only publication",
        ):
            self.module._write_create_only(
                output,
                receipt,
                publication_fence=fence,
            )
        self.assertFalse(output.exists())

    def test_validate_prepared_holds_outer_product_snapshot_through_candidate_validation(self) -> None:
        receipt = self._receipt()
        candidate = self._candidate(receipt)
        original_validate_products = self.module.validate_products
        mutated = False

        def validate_then_mutate(*args, **kwargs):
            nonlocal mutated
            result = original_validate_products(*args, **kwargs)
            if not mutated:
                self.app_executable.write_bytes(b"changed-after-artifact-validation")
                self.app_executable.chmod(0o755)
                mutated = True
            return result

        try:
            with mock.patch.object(
                self.module,
                "validate_products",
                side_effect=validate_then_mutate,
            ):
                with self.assertRaisesRegex(
                    self.module.PreparationReceiptError,
                    "bundle tree changed before complete prepared candidate validation",
                ):
                    self.module.validate_prepared(
                        receipt,
                        self.xctestrun,
                        self.app,
                        candidate,
                    )
        finally:
            self.app_executable.write_bytes(b"app")
            self.app_executable.chmod(0o755)
        self.assertTrue(mutated)

    def test_installed_ui_preparation_binds_exact_ui_products_and_refuses_decoy_target(self) -> None:
        runner = self.debug / "MacScopeInstalledAppUITests-Runner.app"
        bundle = runner / "Contents/PlugIns/MacScopeInstalledAppUITests.xctest"
        for path, payload in (
            (runner / "Contents/MacOS/MacScopeInstalledAppUITests-Runner", b"runner"),
            (bundle / "Contents/MacOS/MacScopeInstalledAppUITests", b"ui-tests"),
        ):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(payload)
            path.chmod(0o755)
        self._write_plist(runner / "Contents/Info.plist", "org.macscope.app.ui-runner")
        self._write_plist(bundle / "Contents/Info.plist", "org.macscope.app.ui-tests")
        duplicate_products = []
        for name in (
            "AIAgentWorkerXPCService",
            "AnalysisWorkerXPCService",
            "NativeDecompilerXPCService",
            "ShellBrokerXPCService",
        ):
            duplicate = self.debug / f"{name}.xpc"
            embedded = self.app / f"Contents/XPCServices/{name}.xpc"
            if name == "NativeDecompilerXPCService":
                embedded = self.native_bundle
            for product in (duplicate, embedded):
                executable = product / f"Contents/MacOS/{name}"
                executable.parent.mkdir(parents=True, exist_ok=True)
                executable.write_bytes(b"native" if name == "NativeDecompilerXPCService" else name.encode())
                executable.chmod(0o755)
                self._write_plist(product / "Contents/Info.plist", f"org.macscope.app.{name}")
            duplicate_products.append(f"__TESTROOT__/Debug/{name}.xpc")
        duplicate_package = self.debug / "NativeDecompilerXPCService.xpc/Contents/Resources/NativeDecompilerPackage"
        embedded_package = self.native_bundle / "Contents/Resources/NativeDecompilerPackage"
        for package, mode in ((duplicate_package, 0o700), (embedded_package, 0o755)):
            package.mkdir(parents=True)
            package.chmod(mode)
            (package / "MATERIALIZATION.json").write_bytes(b"{}")
        duplicate_agent = self.debug / "ShellBrokerLaunchAgent"
        embedded_agent = self.app / "Contents/MacOS/ShellBrokerLaunchAgent"
        for agent in (duplicate_agent, embedded_agent):
            agent.write_bytes(b"launch-agent")
            agent.chmod(0o755)
        duplicate_products.append("__TESTROOT__/Debug/ShellBrokerLaunchAgent")
        ui_xctestrun = self.products / "MacScopeInstalledAppUITests.xctestrun"
        with ui_xctestrun.open("wb") as stream:
            plistlib.dump(
                {
                    "__xctestrun_metadata__": {"ContainerInfo": {"SchemeName": "MacScopeInstalledAppUITests"}},
                    "MacScopeInstalledAppUITests": {
                        "BlueprintName": "MacScopeInstalledAppUITests",
                        "TestBundlePath": "__TESTHOST__/Contents/PlugIns/MacScopeInstalledAppUITests.xctest",
                        "TestHostPath": "__TESTROOT__/Debug/MacScopeInstalledAppUITests-Runner.app",
                        "UITargetAppPath": "__TESTROOT__/Debug/MacScope.app",
                        "DependentProductPaths": [
                            "__TESTROOT__/Debug/MacScope.app",
                            "__TESTROOT__/Debug/MacScopeInstalledAppUITests-Runner.app",
                            "__TESTROOT__/Debug/MacScopeInstalledAppUITests-Runner.app/Contents/PlugIns/MacScopeInstalledAppUITests.xctest",
                            *duplicate_products,
                        ],
                    },
                }, stream,
            )
        receipt = self.module.create_document(
            self.repository, "gitfox-local:MacScope", ui_xctestrun, self.app,
            toolchain=self.toolchain,
            preparation_mode=self.module.INSTALLED_UI_PREPARATION_MODE,
            test_bundle=bundle,
            ui_runner=runner,
        )
        release_app = self.products / "Release/MacScope.app"
        shutil.copytree(self.app, release_app)
        release_receipt = self.module.create_document(
            self.repository, "gitfox-local:MacScope", ui_xctestrun, release_app,
            toolchain=self.toolchain,
            preparation_mode=self.module.INSTALLED_UI_PREPARATION_MODE,
            test_bundle=bundle,
            ui_runner=runner,
        )
        self.assertEqual(
            self.module.validate_prepared_artifacts(
                release_receipt,
                ui_xctestrun,
                release_app,
                test_bundle=bundle,
                ui_runner=runner,
            ),
            self.module.canonical_sha256(release_receipt),
        )
        candidate = self._candidate(receipt)
        self.assertEqual(
            self.module.validate_prepared(
                receipt, ui_xctestrun, self.app, candidate,
                test_bundle=bundle, ui_runner=runner,
            ),
            self.module.canonical_sha256(receipt),
        )
        with ui_xctestrun.open("rb") as stream:
            document = plistlib.load(stream)
        document["MacScopeInstalledAppUITests"]["UITargetAppPath"] = "__TESTROOT__/Debug/Decoy.app"
        with ui_xctestrun.open("wb") as stream:
            plistlib.dump(document, stream)
        with self.assertRaisesRegex(self.module.PreparationReceiptError, "sealed target product"):
            self.module.validate_prepared_artifacts(
                receipt, ui_xctestrun, self.app, test_bundle=bundle, ui_runner=runner
            )
        document["MacScopeInstalledAppUITests"]["UITargetAppPath"] = "__TESTROOT__/Debug/MacScope.app"
        document["MacScopeInstalledAppUITests"]["TestHostPath"] = "__TESTROOT__/Debug/Decoy-Runner.app"
        with ui_xctestrun.open("wb") as stream:
            plistlib.dump(document, stream)
        with self.assertRaisesRegex(self.module.PreparationReceiptError, "sealed UI runner"):
            self.module.validate_prepared_artifacts(
                receipt, ui_xctestrun, self.app, test_bundle=bundle, ui_runner=runner
            )

        document["MacScopeInstalledAppUITests"]["TestHostPath"] = "__TESTROOT__/Debug/MacScopeInstalledAppUITests-Runner.app"
        document["MacScopeInstalledAppUITests"]["DependentProductPaths"].append(
            "__TESTROOT__/Debug/Uncatalogued.xpc"
        )
        with ui_xctestrun.open("wb") as stream:
            plistlib.dump(document, stream)
        with self.assertRaisesRegex(self.module.PreparationReceiptError, "unsealed product"):
            self.module._installed_ui_xctestrun_contract(
                ui_xctestrun, test_bundle=bundle, ui_runner=runner, candidate_app=self.app
            )

        document["MacScopeInstalledAppUITests"]["DependentProductPaths"].pop()
        with ui_xctestrun.open("wb") as stream:
            plistlib.dump(document, stream)
        duplicate_agent.write_bytes(b"drift")
        duplicate_agent.chmod(0o755)
        with self.assertRaisesRegex(self.module.PreparationReceiptError, "differs from its sealed"):
            self.module._installed_ui_xctestrun_contract(
                ui_xctestrun, test_bundle=bundle, ui_runner=runner, candidate_app=self.app
            )

    def test_installed_release_uses_candidate_embedded_native_and_receipt_provenance(self) -> None:
        receipt = self._receipt()
        release_app, executables = self._make_release_app(receipt)
        candidate = self._installed_candidate(receipt, release_app, executables)
        receipt_path = self._receipt_path(receipt)

        authority = self.module.validate_installed_release(
            receipt_path,
            candidate,
            release_app,
        )

        self.assertEqual(authority.native_executable, executables["native-decompiler"])
        self.assertEqual(
            authority.native_executable_sha256,
            self.module.file_sha256(executables["native-decompiler"]),
        )
        self.assertNotEqual(
            authority.native_executable_sha256,
            receipt["artifacts"]["native_decompiler"]["sha256"],
        )
        self.module.require_unchanged_installed_release(
            authority,
            phase="focused installed Release test",
        )

    def test_installed_release_rejects_prepared_native_hash_as_release_authority(self) -> None:
        from Scripts.reconstruction_gate_f.canonical_json import (
            canonical_bytes,
            decode_canonical_bytes,
        )

        receipt = self._receipt()
        release_app, executables = self._make_release_app(receipt)
        candidate = self._installed_candidate(receipt, release_app, executables)
        document = decode_canonical_bytes(candidate.read_bytes())
        native = next(
            item
            for item in document["application"]["embedded_executables"]
            if item["identity_id"] == "native-decompiler"
        )
        native["sha256"] = receipt["artifacts"]["native_decompiler"]["sha256"]
        candidate.write_bytes(canonical_bytes(document))

        with self.assertRaisesRegex(
            self.module.PreparationReceiptError,
            "installed Release bytes differ from candidate authority",
        ):
            self.module.validate_installed_release(
                self._receipt_path(receipt),
                candidate,
                release_app,
            )

    def test_installed_release_rejects_receipt_toolchain_drift(self) -> None:
        receipt = self._receipt()
        release_app, executables = self._make_release_app(receipt)
        candidate = self._installed_candidate(receipt, release_app, executables)
        receipt["toolchain"]["xcode_build"] = "27Z999"

        with self.assertRaisesRegex(
            self.module.PreparationReceiptError,
            "preparation xcode identity differs",
        ):
            self.module.validate_installed_release(
                self._receipt_path(receipt),
                candidate,
                release_app,
            )

    def test_installed_release_rejects_native_code_resources_or_service_drift(self) -> None:
        for changed_identity in ("code-resources", "native-decompiler"):
            with self.subTest(changed_identity=changed_identity):
                receipt = self._receipt()
                release_app, executables = self._make_release_app(receipt)
                candidate = self._installed_candidate(receipt, release_app, executables)
                path = executables[changed_identity]
                original = path.read_bytes()
                try:
                    path.write_bytes(original + b":drift")
                    if changed_identity == "native-decompiler":
                        path.chmod(0o755)
                    with self.assertRaisesRegex(
                        self.module.PreparationReceiptError,
                        "installed Release bytes differ from candidate authority",
                    ):
                        self.module.validate_installed_release(
                            self._receipt_path(receipt),
                            candidate,
                            release_app,
                        )
                finally:
                    path.write_bytes(original)
                    path.chmod(0o755 if changed_identity == "native-decompiler" else 0o644)

    def test_installed_release_fence_rejects_post_validation_service_mutation(self) -> None:
        receipt = self._receipt()
        release_app, executables = self._make_release_app(receipt)
        authority = self.module.validate_installed_release(
            self._receipt_path(receipt),
            self._installed_candidate(receipt, release_app, executables),
            release_app,
        )
        executables["native-decompiler"].write_bytes(b"post-validation mutation")
        executables["native-decompiler"].chmod(0o755)

        with self.assertRaisesRegex(
            self.module.PreparationReceiptError,
            "bundle tree changed|source app",
        ):
            self.module.require_unchanged_installed_release(
                authority,
                phase="adversarial post-validation fence",
            )

    def test_installed_release_refuses_prepared_debug_app_and_hardlinks(self) -> None:
        receipt = self._receipt()
        release_app, executables = self._make_release_app(receipt)
        candidate = self._installed_candidate(receipt, release_app, executables)
        receipt_path = self._receipt_path(receipt)

        with self.assertRaisesRegex(
            self.module.PreparationReceiptError,
            "cannot target the prepared Debug app",
        ):
            self.module.validate_installed_release(
                receipt_path,
                candidate,
                self.app,
            )

        hardlink = self.root / "native-service-hardlink"
        os.link(executables["native-decompiler"], hardlink)
        with self.assertRaisesRegex(
            self.module.PreparationReceiptError,
            "hardlink|single-link|candidate authority",
        ):
            self.module.validate_installed_release(
                receipt_path,
                candidate,
                release_app,
            )

        alias_root = self.root / "authority-alias"
        alias_root.symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(
            self.module.PreparationReceiptError,
            "candidate identity must be an absolute canonical path",
        ):
            self.module.validate_installed_release(
                receipt_path,
                alias_root / candidate.name,
                release_app,
            )

    def test_receipt_schema_is_closed_and_create_only(self) -> None:
        receipt = self._receipt()
        receipt["candidate_identity"] = "forbidden"
        with self.assertRaisesRegex(
            self.module.PreparationReceiptError,
            "closed field set",
        ):
            self.module.parse_document(receipt)
        output = self.root / "receipt.json"
        valid = self._receipt()
        self.module._write_create_only(output, valid)
        self.assertEqual(output.read_bytes(), self.module.canonical_bytes(valid))
        with self.assertRaisesRegex(
            self.module.PreparationReceiptError,
            "absent absolute path",
        ):
            self.module._write_create_only(output, valid)

    def test_closed_tree_rejects_hardlinks(self) -> None:
        duplicate = self.core_tests / "Contents/MacOS/CoreTests-copy"
        os.link(self.core_executable, duplicate)
        with self.assertRaisesRegex(
            self.module.PreparationReceiptError,
            "hardlink",
        ):
            self.module.closed_tree_sha256(self.core_tests)

    def test_toolchain_executable_resolves_governed_symlink_before_hashing(self) -> None:
        tool = self.root / "toolchain/bin/swift-driver"
        tool.parent.mkdir(parents=True)
        tool.write_bytes(b"#!/bin/sh\nexit 0\n")
        tool.chmod(0o755)
        shim = self.root / "toolchain/bin/swiftc"
        shim.symlink_to(tool.name)

        self.assertEqual(self.module._canonical_tool(shim), tool.resolve(strict=True))
        self.assertEqual(
            self.module.file_sha256(self.module._canonical_tool(shim)),
            self.module.file_sha256(tool),
        )

        nonexecutable = self.root / "toolchain/bin/not-a-tool"
        nonexecutable.write_bytes(b"not executable\n")
        with self.assertRaisesRegex(
            self.module.PreparationReceiptError,
            "not executable",
        ):
            self.module._canonical_tool(nonexecutable)

    def test_toolchain_directory_resolves_governed_sdk_symlink_without_weakening_products(self) -> None:
        developer_dir = self.root / "Xcode.app/Contents/Developer"
        sdks = developer_dir / "Platforms/MacOSX.platform/Developer/SDKs"
        canonical_sdk = sdks / "MacOSX.sdk"
        canonical_sdk.mkdir(parents=True)
        versioned_sdk = sdks / "MacOSX27.0.sdk"
        versioned_sdk.symlink_to(canonical_sdk.name)

        self.assertEqual(
            self.module._canonical_toolchain_directory(
                versioned_sdk,
                developer_dir=developer_dir,
            ),
            canonical_sdk.resolve(strict=True),
        )

        outside = self.root / "outside-sdk"
        outside.mkdir()
        escaping_sdk = sdks / "Escaping.sdk"
        escaping_sdk.symlink_to(outside)
        with self.assertRaisesRegex(
            self.module.PreparationReceiptError,
            "outside the audited Xcode developer directory",
        ):
            self.module._canonical_toolchain_directory(
                escaping_sdk,
                developer_dir=developer_dir,
            )


if __name__ == "__main__":
    unittest.main()
