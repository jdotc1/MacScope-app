import importlib.util
import json
from pathlib import Path
import os
import subprocess
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
RUNNER = (
    REPOSITORY_ROOT
    / "Scripts"
    / "native-decompiler-xpc"
    / "run_native_bridge_golden.sh"
)
FILESYSTEM_HELPER = RUNNER.with_name("golden_filesystem.py")
LIVE_RUNNER = RUNNER.with_name("run_live_xpc_tests.sh")


def load_filesystem_helper():
    specification = importlib.util.spec_from_file_location(
        "golden_filesystem_bridge_runner_tests",
        FILESYSTEM_HELPER,
    )
    if specification is None or specification.loader is None:
        raise AssertionError("could not load golden filesystem helper")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class NativeDecompilerXPCBridgeRunnerTests(unittest.TestCase):
    def run_runner(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["/bin/bash", str(RUNNER), *arguments],
            cwd=REPOSITORY_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

    def test_help_documents_every_explicit_root(self) -> None:
        result = self.run_runner("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--build-root ABSOLUTE_PATH", result.stdout)
        self.assertIn("--materialization-root ABSOLUTE_PATH", result.stdout)
        self.assertIn("--native-archive-root ABSOLUTE_PATH", result.stdout)
        self.assertIn("--stage-stamp ABSOLUTE_PATH", result.stdout)
        self.assertIn("--developer-dir ABSOLUTE_PATH", result.stdout)
        self.assertIn("--sdk-root ABSOLUTE_PATH", result.stdout)
        self.assertIn("--sdk-name VALUE", result.stdout)
        self.assertIn("--target-build-dir ABSOLUTE_PATH", result.stdout)
        self.assertIn("--project-temp-dir ABSOLUTE_PATH", result.stdout)
        self.assertIn("--result ABSOLUTE_PATH", result.stdout)

    def test_missing_arguments_fail_before_host_tools_are_used(self) -> None:
        result = self.run_runner()
        self.assertEqual(result.returncode, 2)
        self.assertIn("all roots, the stage stamp, and the result path must be explicit", result.stderr)

    def test_relative_roots_fail_closed(self) -> None:
        result = self.run_runner(
            "--build-root",
            "relative-build",
            "--materialization-root",
            "relative-materialization",
            "--native-archive-root",
            "relative-archive",
            "--stage-stamp",
            "relative-stamp",
            "--developer-dir",
            "relative-developer",
            "--sdk-root",
            "relative-sdk",
            "--sdk-name",
            "macosx27.0",
            "--target-build-dir",
            "relative-products",
            "--project-temp-dir",
            "relative-intermediates",
            "--result",
            "relative-result",
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("all paths must be absolute", result.stderr)

    def test_runner_has_no_network_or_default_package_discovery(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        for forbidden in (
            "curl ",
            "wget ",
            "git clone",
            "brew ",
            "pkg-config",
            "find_package",
            "cmake ",
        ):
            self.assertNotIn(forbidden, source)
        self.assertIn("verify_sleigh_package.py", source)
        self.assertIn("verify --materialization-root", source)
        self.assertNotIn("xcode-select", source)
        self.assertNotIn("xcrun", source)
        self.assertNotIn("/usr/bin/ditto", source)
        self.assertIn("stage_verified_package.py", source)
        self.assertIn("stage stamp link input digests", source)

    def test_build_root_parent_is_canonicalized_before_containment(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        canonicalization = (
            'build_root_parent=$(ordinary_directory "$(dirname "$build_root")" '
            "'golden build root parent')"
        )
        self.assertIn(canonicalization, source)
        self.assertLess(source.index(canonicalization), source.index('mkdir -p "$build_root"'))
        self.assertIn(
            'require_contained "$build_root_parent" "$project_temp_dir" '
            "'golden build root parent'",
            source,
        )

    def test_runner_freezes_toolchain_compile_and_link_contract(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        required_fragments = (
            'developer_dir/usr/bin/xcodebuild',
            "^27([.[:space:]]|$)",
            "-std=c++20",
            "-fobjc-arc",
            "-arch arm64",
            "-mmacosx-version-min=27.0",
            "-Wall -Wextra -Wpedantic -Werror",
            "MACSCOPE_NATIVE_BRIDGE_STANDALONE_TEST",
            "libmacscope_native_decompiler_contract.a",
            "package/lib/libdecomp.a",
            "package/lib/libsla.a",
            "usr/lib/libz.tbd",
            "usr/lib/libc++.tbd",
            "-framework Foundation",
            "MACSCOPE_NATIVE_BRIDGE_CROSS_LANGUAGE_STANDALONE",
            "-target arm64-apple-macosx27.0",
            "-warnings-as-errors",
            "plutil",
            "-convert xml1",
            "swift_compiler_version",
            "swift_target_triple",
            "sdk_build",
        )
        for fragment in required_fragments:
            self.assertIn(fragment, source)

    def test_swift_harness_compiles_exact_production_wire_source_set(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        expected_sources = (
            "NativeDecompilerWirePrimitives.swift",
            "NativeDecompilerWireResultModels.swift",
            "NativeDecompilerWireBinaryPropertyListValidator.swift",
            "NativeDecompilerWireSemanticValidator.swift",
            "NativeDecompilerWireCodec.swift",
        )
        for filename in expected_sources:
            self.assertEqual(source.count(filename), 1, filename)
        self.assertNotIn('"$wire_model_dir"/*.swift', source)
        self.assertIn("NativeDecompilerObjCBridgeCrossLanguageTests.swift", source)

    def test_fixture_interface_and_determinism_checks_are_tracked(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        self.assertEqual(source.count("--emit-cross-language-fixture"), 2)
        self.assertIn('"$objc_mapping_one"', source)
        self.assertIn('"$objc_mapping_two"', source)
        self.assertIn('"$swift_reply_one"', source)
        self.assertIn('"$swift_reply_two"', source)
        self.assertGreaterEqual(source.count("cmp -s"), 5)

    def test_package_backed_mode_uses_a_verified_main_bundle_in_fresh_processes(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        required_fragments = (
            "NativeDecompilerBridgeGolden.app",
            '"$test_app_contents/Resources"',
            "NativeDecompilerPackage",
            "stage_verified_package.py",
            "staged native package manifest bytes differ",
            # The staged copy is verified through the shared helper (9cdfc5fc7).
            'verify_golden_package "$staged_materialization"',
            'verify --materialization-root "$1"',
            "CFBundleExecutable",
            "CFBundlePackageType",
            "--validate-package-backed",
            "package-backed reply bytes are not deterministic across fresh processes",
            "normalized package-backed Objective-C and Swift replies differ",
        )
        for fragment in required_fragments:
            self.assertIn(fragment, source)
        self.assertEqual(source.count("--package-backed-decompile"), 2)
        self.assertEqual(source.count("--validate-package-backed"), 2)

    def test_result_is_canonical_path_free_and_behavior_identity_bound(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        for key in (
            '"contractArchiveSHA256"',
            '"contractBuildIdentitySHA256"',
            '"stageStampSHA256"',
            '"materializationManifestSHA256"',
            '"materializationTreeSHA256"',
            '"decompilerArchiveSHA256"',
            '"sleighArchiveSHA256"',
            '"engineVersion"',
            '"engineGitRevision"',
            '"wrapperVersion"',
            '"wrapperGitRevision"',
            '"goldenSourceSHA256"',
            '"objcRequestSHA256"',
            '"objcReplySHA256"',
            '"objcMappingSHA256"',
            '"swiftReplySHA256"',
            '"packageBackedRequestSHA256"',
            '"packageBackedReplySHA256"',
            '"packageBackedSwiftReplySHA256"',
        ):
            self.assertIn(key, source)
        self.assertIn('identity != expected_identity', source)
        self.assertIn('separators=(",", ":")', source)
        self.assertIn("import json\nimport os\nimport pathlib\nimport plistlib", source)
        self.assertIn("os.fsync(stream.fileno())", source)
        self.assertNotIn("require_clean_repository", source)
        self.assertIn("native_decompiler_source_identity.py", source)
        self.assertIn("--profile golden", source)
        self.assertIn("trap cleanup EXIT\n", source)
        self.assertIn("trap 'cleanup; exit 143' TERM", source)

    def test_cancelled_runner_cleans_its_run_root_once_and_does_not_resume(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        block = source[source.index("cleanup() {"):source.index("trap 'cleanup; exit 143' TERM")]
        block += "trap 'cleanup; exit 143' TERM\n"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            calls = root / "calls"
            stub = root / "helper"
            stub.write_text('#!/bin/sh\necho "$2" >> "$CALLS"\n')
            stub.chmod(0o755)
            script = "\n".join([
                'python=/bin/sh', f'filesystem_helper="{stub}"', 'build_root=/b', 'build_root_identity=x',
                'result_temporary_name=', 'result_temporary_identity=',
                'run_root=/b/native-bridge-golden.test', 'run_root_identity=[1,2]',
                block, 'kill -TERM $$', 'sleep 1', 'echo resumed',
            ])
            result = subprocess.run(["/bin/bash", "-c", script], env={"CALLS": str(calls), "PATH": "/usr/bin:/bin"},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 143)
            self.assertNotIn("resumed", result.stdout)
            self.assertEqual(calls.read_text().split(), ["/b/native-bridge-golden.test"])

    def test_result_temporary_is_confined_to_xcode_intermediates(self) -> None:
        source = RUNNER.read_text(encoding="utf-8")
        self.assertIn(
            'result_temporary=$(/usr/bin/mktemp '
            '"$build_root/.native-bridge-golden-result.XXXXXX")',
            source,
        )
        self.assertNotIn(
            'result_temporary=$(/usr/bin/mktemp '
            '"$result_parent/.native-bridge-golden-result.XXXXXX")',
            source,
        )
        self.assertIn(
            '"$filesystem_helper" snapshot-regular \\\n'
            '    "$build_root" "$build_root_identity" "$result_temporary_name"',
            source,
        )

    def test_result_publication_rejects_destination_substitution_and_hardlinks(self) -> None:
        module = load_filesystem_helper()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            source_parent = root / "intermediates"
            destination_parent = root / "resources"
            source_parent.mkdir()
            destination_parent.mkdir()
            source_parent_identity = module.snapshot_directory(source_parent)
            destination_parent_identity = module.snapshot_directory(destination_parent)
            temporary = source_parent / ".golden-result"
            temporary.write_bytes(b"verified\n")
            temporary.chmod(0o644)
            temporary_identity = module.snapshot_regular(
                source_parent,
                source_parent_identity,
                temporary.name,
            )
            result = destination_parent / "golden.json"
            result.write_bytes(b"foreign\n")

            with self.assertRaisesRegex(module.GoldenFilesystemError, "appeared"):
                module.publish_result(
                    source_parent,
                    source_parent_identity,
                    temporary.name,
                    temporary_identity,
                    destination_parent,
                    destination_parent_identity,
                    result.name,
                    None,
                )
            self.assertEqual(result.read_bytes(), b"foreign\n")

            hardlinked = source_parent / "hardlinked-result"
            os.link(temporary, hardlinked)
            with self.assertRaisesRegex(module.GoldenFilesystemError, "singly linked"):
                module.snapshot_regular(
                    source_parent,
                    source_parent_identity,
                    temporary.name,
                )

    def test_live_runner_preserves_owned_cleanup_residue(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            environment = os.environ.copy()
            environment["TMPDIR"] = temporary_directory
            result = subprocess.run(
                ["/bin/bash", str(LIVE_RUNNER), "--self-test-owned-cleanup"],
                cwd=REPOSITORY_ROOT,
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("preserves owned and substituted residue", result.stdout)
            roots = sorted(
                Path(line.removeprefix("residue="))
                for line in result.stdout.splitlines()
                if line.startswith("residue=")
            )
            self.assertEqual(len(roots), 2)
            self.assertEqual(len(set(roots)), 2)
            for root in roots:
                self.assertEqual(root.parent, Path(temporary_directory))
                self.assertTrue(root.is_dir())
                self.assertTrue(root.name.startswith("macscope-owned-cleanup-test."))
            replacement = next(path for path in roots if not path.name.endswith(".original"))
            self.assertIn(replacement.with_name(f"{replacement.name}.original"), roots)
            sentinels = sorted(
                path.read_bytes()
                for root in roots
                for path in root.glob("*-sentinel")
            )
            self.assertEqual(sentinels, [b"foreign\n", b"owned\n"])

    def test_live_runner_binds_a_bounded_destructive_test_allowance(self) -> None:
        source = LIVE_RUNNER.read_text(encoding="utf-8")
        required_fragments = (
            "-test-timeouts-enabled YES",
            "-default-test-execution-time-allowance 120",
            "-maximum-test-execution-time-allowance 120",
        )
        for fragment in required_fragments:
            self.assertEqual(source.count(fragment), 1, fragment)

    def test_live_runner_separates_preparation_from_execution(self) -> None:
        source = LIVE_RUNNER.read_text(encoding="utf-8")
        preparation = source.split('if [[ -n "$prepare_derived_data" ]]', 1)[1].split(
            'if [[ "$execute_prepared" == true ]]', 1
        )[0]
        execution = source.split('if [[ "$execute_prepared" == true ]]', 1)[1]
        for fragment in (
            "generate_xcode_json_project.py",
            "xcodebuild build-for-testing",
            'MACSCOPE_SLEIGH_MATERIALIZATION_ROOT="$materialization_root"',
            'MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION="$LIVE_TEST_CONDITION"',
            '"$preparation_helper" create',
        ):
            self.assertIn(fragment, preparation)
            self.assertNotIn(fragment, execution)
        self.assertIn("xcodebuild test-without-building", execution)
        self.assertIn("--xcode-test-host-entitlements", execution)
        # Xcode exports build settings to script phases; the Ghostty VT phase's
        # build_ghostty_vt.sh rejects external source authority in production.
        self.assertNotIn("MACSCOPE_GHOSTTY_SOURCE_DIR", source)
        self.assertNotIn("MACSCOPE_GHOSTTY_TEST_SEAMS", source)
        self.assertNotIn(" xcodebuild test ", source)
        self.assertIn("--prepare-derived-data ABSENT_ABSOLUTE_PATH", source)
        self.assertIn("--execute-prepared", source)
        self.assertIn("mutually exclusive", source)

    def test_live_runner_verifies_the_xcode_owned_ghostty_build_before_accepting_its_symlink(self) -> None:
        source = LIVE_RUNNER.read_text(encoding="utf-8")
        preparation = source.split('if [[ -n "$prepare_derived_data" ]]', 1)[1].split(
            'if [[ "$execute_prepared" == true ]]', 1
        )[0]
        build = "xcodebuild build-for-testing"
        discovery = "**/MacScopeGhosttyVT/artifacts/lib/.macscope-ghostty-vt-manifest"
        verification_command = (
            '"$ghostty_verifier" \\\n'
            '        --work-root "$ghostty_vt_work_root" --verify-only 2>&1'
        )
        surfaced = 'printf \'%s\\n\' "$ghostty_verification" >&2'
        standard_library = (
            'ghostty_library="$ghostty_vt_work_root/artifacts/lib/libghostty-vt.dylib"'
        )
        for fragment in (discovery, verification_command, surfaced, standard_library):
            self.assertEqual(preparation.count(fragment), 1, fragment)
        # The verified artifact is the one Xcode produced and linked, so it is
        # discovered after the build and verified before its symlink is followed.
        self.assertLess(preparation.index(build), preparation.index(discovery))
        self.assertLess(
            preparation.index(discovery),
            preparation.index(verification_command),
        )
        self.assertLess(
            preparation.index(verification_command),
            preparation.index(surfaced),
        )
        self.assertLess(
            preparation.index(surfaced),
            preparation.index(standard_library),
        )
        self.assertLess(
            preparation.index(standard_library),
            preparation.index('"$preparation_helper" create'),
        )
        self.assertNotIn("--verify-only >/dev/null", preparation)
        self.assertNotIn("zig-out", preparation)
        self.assertNotIn(
            '[[ -f "$ghostty_library" && ! -L "$ghostty_library" ]]',
            preparation,
        )

    def test_live_runner_rejects_the_retired_ghostty_source_argument(self) -> None:
        result = subprocess.run(
            [
                "/bin/bash",
                str(LIVE_RUNNER),
                "--prepare-derived-data", "/tmp/macscope-absent-derived-data",
                "--preparation-receipt", "/tmp/macscope-absent-receipt.json",
                "--materialization-root", "/tmp/macscope-materialization",
                "--ghostty-source-dir", "/tmp/macscope-ghostty",
            ],
            cwd=REPOSITORY_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("--ghostty-source-dir is retired", result.stderr)
        self.assertNotIn("xcodebuild", result.stdout)
        self.assertNotIn("--ghostty-source-dir", self.live_usage())
        self.assertIn(
            "--materialization-root ABSOLUTE_PATH\n",
            self.live_usage(),
        )

    def live_usage(self) -> str:
        result = subprocess.run(
            ["/bin/bash", str(LIVE_RUNNER), "--help"],
            cwd=REPOSITORY_ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout

    def test_live_runner_execution_consumes_candidate_bound_receipt(self) -> None:
        source = LIVE_RUNNER.read_text(encoding="utf-8")
        self.assertIn("--preparation-receipt ABSOLUTE_PATH", source)
        self.assertIn("--candidate-identity ABSOLUTE_PATH", source)
        self.assertIn('"$preparation_helper" validate', source)
        self.assertIn('--receipt "$preparation_receipt"', source)
        self.assertIn('--xctestrun "$xctestrun"', source)
        self.assertIn('--candidate-app "$candidate_app"', source)
        self.assertIn('--candidate-identity "$candidate_identity"', source)
        self.assertIn('write_execution_report.py', source)
        for forwarding in (
            '--qualification-run-id "$qualification_run_id"',
            '--qualification-run-nonce "$qualification_run_nonce"',
            '--predecessor-observations-sha256 "$predecessor_observations_sha256"',
        ):
            self.assertEqual(source.count(forwarding), 1)
        self.assertNotIn("MACSCOPE_QUALIFICATION_RUN", source)
        self.assertIn("MACSCOPE_SIGNED_NATIVE_TEST_RESULTS=", source)
        self.assertIn("MACSCOPE_SIGNED_NATIVE_EXECUTABLE=", source)
        self.assertIn("MACSCOPE_SIGNED_NATIVE_EXECUTION_REPORT=", source)

    def test_live_runner_requires_orchestrator_execution_report_authority(self) -> None:
        result = subprocess.run(
            [
                "/bin/bash",
                str(LIVE_RUNNER),
                "--execute-prepared",
                "--preparation-receipt", "/tmp/preparation.json",
                "--xctestrun", "/tmp/tests.xctestrun",
                "--candidate-app", "/tmp/MacScope.app",
                "--candidate-identity", "/tmp/candidate.json",
                "--result-bundle-path", "/tmp/results.xcresult",
                "--artifact-root", "/tmp/artifacts",
            ],
            cwd=REPOSITORY_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("--qualification-run-id is required", result.stderr)

    def test_live_runner_preparation_checks_every_untracked_source_path(self) -> None:
        source = LIVE_RUNNER.read_text(encoding="utf-8")
        preparation = source.split('if [[ -n "$prepare_derived_data" ]]', 1)[1].split(
            'if [[ "$execute_prepared" == true ]]', 1
        )[0]
        self.assertIn(
            'status --porcelain=v1 --untracked-files=all',
            preparation,
        )

    def test_live_runner_rejects_dependency_inputs_in_execution_mode(self) -> None:
        result = subprocess.run(
            [
                "/bin/bash",
                str(LIVE_RUNNER),
                "--execute-prepared",
                "--materialization-root",
                "/tmp/forbidden-materialization",
            ],
            cwd=REPOSITORY_ROOT,
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn(
            "execution cannot accept build, dependency, or preparation-root arguments",
            result.stderr,
        )

    def test_live_runner_never_synthesizes_test_evidence_and_binds_pass_report_inputs(self) -> None:
        source = LIVE_RUNNER.read_text(encoding="utf-8")
        execution = source.split('if [[ "$execute_prepared" == true ]]', 1)[1]
        self.assertNotIn("{\"testNodes\":[]}", execution)
        self.assertIn(".test-results.partial.json", execution)
        self.assertIn('publish_regular_copy "$test_results_temporary" "$test_results_path"', execution)
        for fragment in (
            '--native-preparation-receipt "$preparation_receipt"',
            '--native-xctestrun "$xctestrun"',
            '--native-candidate-app "$candidate_app"',
            '--native-candidate-identity "$candidate_identity"',
            '--native-result-bundle "$result_bundle"',
            '--native-test-results "$test_results_path"',
            '--native-service-artifact "$native_artifact_path"',
            '--native-test-selector "$test_selector"',
        ):
            self.assertIn(fragment, execution)
        self.assertGreaterEqual(
            execution.count('"$preparation_helper" validate'),
            2,
        )

    def test_live_runner_execution_stdout_is_artifact_protocol_only(self) -> None:
        source = LIVE_RUNNER.read_text(encoding="utf-8")
        execution = source.split('if [[ "$execute_prepared" == true ]]', 1)[1]
        self.assertIn('-parallel-testing-enabled NO >&2', execution)
        self.assertIn('--xcode-test-host-entitlements >&2', execution)
        self.assertIn('"$execution_reporter" "${reporter_arguments[@]}" >&2', execution)
        self.assertIn("gate passed.' >&2", execution)
        self.assertEqual(
            execution.count("MACSCOPE_SIGNED_NATIVE_EXECUTION_REPORT="),
            1,
        )

    def test_live_runner_rejects_hardlinked_authority_before_host_tools(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            original = root / "preparation-original.json"
            original.write_text("{}", encoding="utf-8")
            preparation = root / "preparation.json"
            os.link(original, preparation)
            xctestrun = root / "tests.xctestrun"
            xctestrun.write_text("placeholder", encoding="utf-8")
            candidate_identity = root / "candidate.json"
            candidate_identity.write_text("{}", encoding="utf-8")
            candidate_app = root / "MacScope.app"
            candidate_app.mkdir()
            result = subprocess.run(
                [
                    "/bin/bash",
                    str(LIVE_RUNNER),
                    "--execute-prepared",
                    "--preparation-receipt", str(preparation),
                    "--xctestrun", str(xctestrun),
                    "--candidate-app", str(candidate_app),
                    "--candidate-identity", str(candidate_identity),
                    "--result-bundle-path", str(root / "results.xcresult"),
                    "--artifact-root", str(root / "artifacts"),
                    "--qualification-run-id", "native-live-test",
                    "--qualification-run-nonce", "a" * 64,
                    "--predecessor-observations-sha256", "b" * 64,
                ],
                cwd=REPOSITORY_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("singly linked ordinary file", result.stderr)
            self.assertNotIn("xcodebuild", result.stdout + result.stderr)

    def test_live_result_verifier_accepts_only_one_governed_exact_pass(self) -> None:
        selector = (
            "CoreTests/NativeDecompilerLiveXPCTests/"
            "testSignedServiceHonorsSupervisionAndRelaunchContract"
        )
        test_case = {
            "nodeType": "Test Case",
            "name": "testSignedServiceHonorsSupervisionAndRelaunchContract()",
            "result": "Passed",
            "children": [],
        }
        document = {
            "testNodes": [
                {
                    "nodeType": "Test Plan",
                    "name": "CoreTests",
                    "children": [
                        {
                            "nodeType": "Test Suite",
                            "name": "NativeDecompilerLiveXPCTests",
                            "children": [test_case],
                        }
                    ],
                }
            ]
        }
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "results.json"
            path.write_text(json.dumps(document), encoding="utf-8")
            passed = subprocess.run(
                [
                    "/bin/bash",
                    str(LIVE_RUNNER),
                    "--verify-test-results-json", str(path),
                    "--only-testing", selector,
                ],
                cwd=REPOSITORY_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(passed.returncode, 0, passed.stderr)

            document["testNodes"][0]["children"][0]["children"].append(
                dict(test_case)
            )
            path.write_text(json.dumps(document), encoding="utf-8")
            duplicate = subprocess.run(
                [
                    "/bin/bash",
                    str(LIVE_RUNNER),
                    "--verify-test-results-json", str(path),
                    "--only-testing", selector,
                ],
                cwd=REPOSITORY_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(duplicate.returncode, 1)
            self.assertIn("exact selected test case", duplicate.stderr)


    def test_governed_live_vectors_are_mirrored_and_compiled_under_the_live_condition(self) -> None:
        import re

        source = LIVE_RUNNER.read_text(encoding="utf-8")
        allowlist = source.split('case "$test_selector" in', 1)[1].split("        ;;", 1)[0]
        runner_methods = set(
            re.findall(r"CoreTests/NativeDecompilerLiveXPCTests/(test\w+)", allowlist)
        )
        condition = re.search(r"readonly LIVE_TEST_CONDITION='(\w+)'", source).group(1)
        import sys

        if str(REPOSITORY_ROOT) not in sys.path:
            sys.path.insert(0, str(REPOSITORY_ROOT))
        from Scripts.reconstruction import write_execution_report as reporter

        skip_path = REPOSITORY_ROOT / "docs/qualification/skip-allowlist.json"
        skip_methods = None
        if skip_path.exists():
            skip_allowlist = json.loads(skip_path.read_text(encoding="utf-8"))
            skip_methods = {
                entry["method"] for entry in skip_allowlist["entries"]
                if entry["file"] == "CoreTests/NativeDecompilerLiveXPCTests.swift"
            }
        swift = (
            REPOSITORY_ROOT
            / "MacScope/Tests/CoreTests/NativeDecompilerLiveXPCTests.swift"
        ).read_text(encoding="utf-8")
        swift_methods = set(
            re.findall(r"^    func (test\w+)\(\) async throws \{", swift, re.MULTILINE)
        )
        self.assertIn(
            "testSignedProviderPreservesAuthoredSnapshotCalleeAndReadonlyDataContext",
            runner_methods,
        )
        self.assertEqual(runner_methods, set(reporter.NATIVE_LIVE_METHODS))
        if skip_methods is not None:
            self.assertEqual(runner_methods, skip_methods)
        self.assertEqual(runner_methods, swift_methods)
        for method in sorted(runner_methods):
            with self.subTest(method=method):
                body = swift.split(f"    func {method}() async throws {{", 1)[1]
                self.assertTrue(body.lstrip().startswith(f"#if {condition}\n"))
                gated = body.split("        #else\n", 1)
                self.assertEqual(len(gated), 2)
                self.assertTrue(gated[1].lstrip().startswith("throw XCTSkip("))

    def test_live_result_verifier_accepts_the_authored_context_vector(self) -> None:
        method = "testSignedProviderPreservesAuthoredSnapshotCalleeAndReadonlyDataContext"
        selector = f"CoreTests/NativeDecompilerLiveXPCTests/{method}"
        document = {
            "testNodes": [
                {
                    "nodeType": "Test Plan",
                    "name": "CoreTests",
                    "children": [
                        {
                            "nodeType": "Test Suite",
                            "name": "NativeDecompilerLiveXPCTests",
                            "children": [
                                {
                                    "nodeType": "Test Case",
                                    "name": f"{method}()",
                                    "result": "Passed",
                                    "children": [],
                                }
                            ],
                        }
                    ],
                }
            ]
        }
        with tempfile.TemporaryDirectory() as temporary_directory:
            path = Path(temporary_directory) / "results.json"
            path.write_text(json.dumps(document), encoding="utf-8")
            passed = subprocess.run(
                [
                    "/bin/bash",
                    str(LIVE_RUNNER),
                    "--verify-test-results-json", str(path),
                    "--only-testing", selector,
                ],
                cwd=REPOSITORY_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(passed.returncode, 0, passed.stderr)
            self.assertIn(f"verified exact executed test: {selector}", passed.stdout)

class Xcode27HostTargetTests(unittest.TestCase):
    def test_host_minor_versions_preserve_major_and_architecture_boundary(self):
        import re

        script = (Path(__file__).resolve().parents[1] /
                  "native-decompiler-xpc/run_native_bridge_golden.sh").read_text()
        expression = re.search(r'\[\[ "\$swift_target_triple" =~ (.*?) \]\]', script)
        self.assertIsNotNone(expression)
        cases = (
            ("arm64-apple-macosx27.0", True),
            ("arm64-apple-macosx27.2.0", True),
            ("arm64-apple-macosx26.0", False),
            ("arm64-apple-macosx28.0", False),
            ("x86_64-apple-macosx27.2", False),
        )
        for triple, accepted in cases:
            with self.subTest(triple=triple):
                result = subprocess.run([
                    "/bin/bash", "-c", '[[ "$1" =~ $2 ]]', "test", triple,
                    expression.group(1),
                ])
                self.assertEqual(result.returncode == 0, accepted)


if __name__ == "__main__":
    unittest.main()
