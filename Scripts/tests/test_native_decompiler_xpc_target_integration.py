#!/usr/bin/env python3
"""Focused integration contracts for the DCP-04 Xcode target."""

from __future__ import annotations

from collections import Counter
import hashlib
import importlib.util
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
PROJECT_YML = ROOT / "MacScope" / "project.yml"
RESOURCE_STAGER = (
    ROOT
    / "Scripts"
    / "native-decompiler-xpc"
    / "stage_xcode_resources.py"
)
GOLDEN_FILESYSTEM = (
    ROOT
    / "Scripts"
    / "native-decompiler-xpc"
    / "golden_filesystem.py"
)
BUILD_NATIVE_BRIDGE = (
    ROOT
    / "Scripts"
    / "native-decompiler-xpc"
    / "build_native_bridge.sh"
)
SOURCE_IDENTITY_HELPER = BUILD_NATIVE_BRIDGE.with_name(
    "native_decompiler_source_identity.py"
)

EXPECTED_SERVICE_SOURCES = [
    "Models/NativeDecompilerWire/NativeDecompilerWireBinaryPropertyListValidator.swift",
    "Models/NativeDecompilerWire/NativeDecompilerWireCodec.swift",
    "Models/NativeDecompilerWire/NativeDecompilerWirePrimitives.swift",
    "Models/NativeDecompilerWire/NativeDecompilerWireTargetProfile.swift",
    "Models/NativeDecompilerWire/NativeDecompilerWireAuthoredModels.swift",
    "Models/NativeDecompilerWire/NativeDecompilerWireCanonicalRequest.swift",
    "Models/NativeDecompilerWire/NativeDecompilerWireResultModels.swift",
    "Models/NativeDecompilerWire/NativeDecompilerWireSemanticValidator.swift",
    "Models/NativeDecompilerWire/NativeDecompilerXPCPeerRequirement.swift",
    "Models/NativeDecompilerWire/NativeDecompilerLiveXPCTestProtocol.swift",
    "NativeDecompilerXPCService/NativeDecompilerCancellationState.swift",
    "NativeDecompilerXPCService/NativeDecompilerLiveXPCTestControl.swift",
    "NativeDecompilerXPCService/NativeDecompilerRequestScheduler.swift",
    "NativeDecompilerXPCService/NativeDecompilerServiceComposition.swift",
    "NativeDecompilerXPCService/NativeDecompilerServiceHost.swift",
    "NativeDecompilerXPCService/NativeDecompilerServiceListenerDelegate.swift",
    "NativeDecompilerXPCService/NativeDecompilerXPCPrincipal.swift",
    "Services/XPC/OwnedChildWire.swift",
    "NativeDecompilerXPCService/main.swift",
    "NativeDecompilerXPCService/Bridge/NativeDecompilerWireBridge.hpp",
    "NativeDecompilerXPCService/Bridge/NativeDecompilerWireCodec.mm",
    "NativeDecompilerXPCService/Bridge/NativeDecompilerObjCBridge.h",
    "NativeDecompilerXPCService/Bridge/NativeDecompilerObjCBridge.mm",
    "NativeDecompilerXPCService/NativeDecompilerXPCService-Bridging-Header.h",
]

EXPECTED_CORE_TEST_SERVICE_SOURCES = [
    "NativeDecompilerXPCService/NativeDecompilerCancellationState.swift",
    "NativeDecompilerXPCService/NativeDecompilerRequestScheduler.swift",
    "NativeDecompilerXPCService/NativeDecompilerServiceHost.swift",
    "NativeDecompilerXPCService/NativeDecompilerXPCPrincipal.swift",
    "NativeDecompilerXPCService/NativeDecompilerServiceListenerDelegate.swift",
    "NativeDecompilerXPCService/NativeDecompilerServiceComposition.swift",
]

STANDALONE_BRIDGE_TESTS = {
    "NativeDecompilerObjCBridgeTests.mm",
    "NativeDecompilerObjCBridgeCrossLanguageTests.swift",
}


def load_resource_stager():
    specification = importlib.util.spec_from_file_location(
        "stage_xcode_resources",
        RESOURCE_STAGER,
    )
    if specification is None or specification.loader is None:
        raise AssertionError("could not load Xcode resource stager")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def load_golden_filesystem():
    if not GOLDEN_FILESYSTEM.is_file():
        raise AssertionError("golden filesystem helper is unavailable")
    specification = importlib.util.spec_from_file_location(
        "golden_filesystem",
        GOLDEN_FILESYSTEM,
    )
    if specification is None or specification.loader is None:
        raise AssertionError("could not load golden filesystem helper")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


class NativeDecompilerCTestPartitionTests(unittest.TestCase):
    """Derive the scenario partition from both maintained source inventories."""

    HARNESS = "macscope_native_decompiler_ghidra_provider_tests"

    @classmethod
    def setUpClass(cls) -> None:
        native_root = ROOT / "Tools/NativeDecompilerBridge"
        cls.cmake = (native_root / "CMakeLists.txt").read_text(encoding="utf-8")
        cls.harness = (native_root / "tests/GhidraProviderTests.cpp").read_text(encoding="utf-8")

    def registrations(self) -> list[tuple[str, list[str]]]:
        # Expand the literal IN ITEMS loops used by these registrations, including
        # their string(REPLACE) name suffixes. Keep direct add_test calls as well;
        # the test must not carry another handwritten copy of the scenario list.
        expanded = self.cmake
        loops = list(re.finditer(
            r"foreach\(\s*(\w+)\s+IN\s+ITEMS\s+(.*?)\)(.*?)endforeach\(\)",
            self.cmake, re.DOTALL,
        ))
        for loop in reversed(loops):
            variable, items, body = loop.groups()
            if self.HARNESS not in body:
                continue
            self.assertNotIn("foreach(", body, "nested scenario loops need explicit expansion")
            copies = []
            for item in shlex.split(items, comments=True):
                values = {variable: item}
                for replacement in re.findall(r"string\((REPLACE\s+.*?)\)", body):
                    operation, old, new, destination, source = shlex.split(replacement)
                    self.assertEqual(operation, "REPLACE")
                    source_value = re.sub(r"\$\{(\w+)\}", lambda m: values[m[1]], source)
                    values[destination] = source_value.replace(old, new)
                copies.append(re.sub(
                    r"\$\{(\w+)\}", lambda m: values.get(m[1], m[0]), body,
                ))
            expanded = expanded[:loop.start()] + "\n".join(copies) + expanded[loop.end():]

        registrations = []
        for body in re.findall(r"\badd_test\(\s*(.*?)\)", expanded, re.DOTALL):
            tokens = shlex.split(body, comments=True)
            if "COMMAND" not in tokens:
                continue
            command_index = tokens.index("COMMAND")
            if tokens[command_index + 1] != self.HARNESS:
                continue
            self.assertEqual(tokens[0], "NAME")
            self.assertEqual(command_index, 2)
            self.assertFalse(any("${" in token for token in tokens), "unexpanded registration")
            registrations.append((tokens[1], tokens[command_index + 2:]))
        return registrations

    def test_ctest_core_and_standalone_scenarios_cover_harness_exactly_once(self) -> None:
        registry = re.search(
            r"std::array\s*<\s*std::string_view\s*,\s*(\d+)\s*>\s*"
            r"kSeparatelyRegisteredScenarios\s*=\s*\{(.*?)\};",
            self.harness, re.DOTALL,
        )
        self.assertIsNotNone(registry, "the core group needs an explicit exclusion inventory")
        excluded = re.findall(r'"([a-z0-9-]+)"', registry[2])
        self.assertEqual(len(excluded), int(registry[1]))
        self.assertEqual(len(excluded), len(set(excluded)), "duplicate core exclusion")
        selectors = re.findall(r'\bshouldRun\(\s*"([a-z0-9-]+)"\s*\)', self.harness)
        self.assertEqual(len(selectors), len(set(selectors)), "duplicate harness scenario")
        self.assertEqual(len(selectors), len(re.findall(r"\bshouldRun\(", self.harness)))

        registrations = self.registrations()
        self.assertEqual(len(registrations), len({name for name, _ in registrations}))
        umbrella = [arguments for name, arguments in registrations if name == self.HARNESS]
        self.assertEqual(umbrella, [["--scenario-group", "core"]])
        standalone = []
        for name, arguments in registrations:
            if name == self.HARNESS:
                continue
            self.assertEqual(len(arguments), 2, name)
            self.assertEqual(arguments[0], "--scenario", name)
            expected_name = self.HARNESS.removesuffix("_tests") + "_" + arguments[1].replace("-", "_") + "_tests"
            self.assertEqual(name, expected_name, "standalone CTest identity drift")
            standalone.append(arguments[1])
        self.assertEqual(Counter(excluded), Counter(standalone))
        self.assertTrue(set(excluded) <= set(selectors), "excluded scenario absent from harness")
        core = set(selectors) - set(excluded)
        self.assertTrue(core, "the umbrella must retain real core coverage")
        self.assertEqual(Counter(list(core) + standalone), Counter(selectors))

    def test_core_group_is_opt_in_and_explicit_scenario_selection_is_retained(self) -> None:
        main = self.harness[self.harness.index("int main("):]
        self.assertRegex(main, r"std::optional<std::string_view>\s+selectedScenario\s*;")
        self.assertRegex(main, r"bool\s+coreScenariosOnly\s*=\s*false\s*;")
        self.assertRegex(
            main,
            r'if\s*\(argc\s*==\s*3\s*&&\s*std::string_view\(argv\[1\]\)\s*==\s*'
            r'"--scenario"\)\s*\{\s*selectedScenario\s*=\s*argv\[2\];\s*\}',
        )
        self.assertRegex(
            main,
            r'else if\s*\(argc\s*==\s*3\s*&&\s*std::string_view\(argv\[1\]\)\s*==\s*'
            r'"--scenario-group"\s*&&\s*std::string_view\(argv\[2\]\)\s*==\s*"core"\)'
            r'\s*\{\s*coreScenariosOnly\s*=\s*true;',
        )
        predicate = re.search(r"const auto shouldRun\s*=.*?\{(.*?)\n\s*\};", main, re.DOTALL)
        self.assertIsNotNone(predicate)
        self.assertRegex(
            predicate[1],
            r"if\s*\(coreScenariosOnly\s*&&\s*std::find\("
            r"\s*kSeparatelyRegisteredScenarios.begin\(\),"
            r"\s*kSeparatelyRegisteredScenarios.end\(\),\s*name\)\s*!="
            r"\s*kSeparatelyRegisteredScenarios.end\(\)\)\s*\{\s*return false;",
        )
        self.assertRegex(predicate[1], r"return\s+!selectedScenario\s*\|\|\s*\*selectedScenario\s*==\s*name;")


class NativeDecompilerXPCTargetIntegrationTests(unittest.TestCase):
    """Catch accidental native linkage, signing, and staging-boundary drift."""

    def test_native_bridge_build_reads_complete_xcode_version_without_sigpipe(self) -> None:
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            developer_dir = root / "Xcode.app/Contents/Developer"
            xcodebuild = developer_dir / "usr/bin/xcodebuild"
            xcodebuild.parent.mkdir(parents=True)
            xcodebuild.write_text(
                "#!/bin/bash\n"
                "/usr/bin/printf 'Xcode 27.0\\n'\n"
                "/usr/bin/printf 'Build version 27A5237l\\n%1048576s' ''\n",
                encoding="utf-8",
            )
            xcodebuild.chmod(0o755)

            fake_bin = root / "fake-bin"
            fake_bin.mkdir()
            verifier_marker = root / "verifier-reached"
            (fake_bin / "python3").write_text(
                "#!/bin/bash\n"
                ": > \"$MACSCOPE_TEST_VERIFIER_MARKER\"\n"
                "exit 73\n",
                encoding="utf-8",
            )
            (fake_bin / "python3").chmod(0o755)
            (fake_bin / "xcode-select").write_text(
                "#!/bin/bash\n"
                "printf '%s\\n' \"$MACSCOPE_TEST_DEVELOPER_DIR\"\n",
                encoding="utf-8",
            )
            (fake_bin / "xcode-select").chmod(0o755)
            for command in ("cmake", "file", "ninja", "strings"):
                tool = fake_bin / command
                tool.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
                tool.chmod(0o755)

            identity = subprocess.run(
                [
                    "/usr/bin/python3",
                    "-B",
                    str(SOURCE_IDENTITY_HELPER),
                    "--repository-root",
                    str(ROOT),
                    "--profile",
                    "wrapper",
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(identity.returncode, 0, identity.stderr)
            materialization = root / "materialization"
            materialization.mkdir()
            environment = os.environ.copy()
            environment.pop("DEVELOPER_DIR", None)
            environment.update(
                {
                    "MACSCOPE_TEST_DEVELOPER_DIR": str(developer_dir),
                    "MACSCOPE_TEST_VERIFIER_MARKER": str(verifier_marker),
                    "PATH": f"{fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin",
                }
            )
            result = subprocess.run(
                [
                    "/bin/bash",
                    str(BUILD_NATIVE_BRIDGE),
                    "--source-root",
                    str(ROOT / "Tools/NativeDecompilerBridge"),
                    "--build-root",
                    str(root / "build"),
                    "--materialization-root",
                    str(materialization),
                    "--wrapper-revision",
                    identity.stdout.strip(),
                    "--configuration",
                    "Release",
                ],
                cwd=ROOT,
                env=environment,
                capture_output=True,
                text=True,
                check=False,
            )

            self.assertEqual(result.returncode, 73, result.stdout + result.stderr)
            self.assertTrue(
                verifier_marker.is_file(),
                "the wrapper exited before the post-toolchain package verifier",
            )

    def project(self) -> dict[str, object]:
        result = subprocess.run(
            [
                "/usr/bin/ruby",
                "-ryaml",
                "-rjson",
                "-e",
                (
                    "value=YAML.safe_load(File.read(ARGV.fetch(0)), "
                    "permitted_classes: [], aliases: false); "
                    "STDOUT.write(JSON.generate(value))"
                ),
                str(PROJECT_YML),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertIsInstance(value, dict)
        return value

    def target(self) -> dict[str, object]:
        targets = self.project()["targets"]
        self.assertIn("NativeDecompilerXPCService", targets)
        return targets["NativeDecompilerXPCService"]

    def test_bootstrap_keeps_guards_without_recursively_running_target_tests(self) -> None:
        bootstrap = (ROOT / "Scripts/bootstrap.sh").read_text(encoding="utf-8")
        self.assertNotIn("test_native_decompiler_xpc_target_integration.py", bootstrap)
        self.assertIn("check_local_signing_policy.py", bootstrap)
        self.assertIn("validate_offline_build_surface.py", bootstrap)

    def test_golden_runner_cleanup_refuses_substituted_unowned_tree(self) -> None:
        module = load_golden_filesystem()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            owned = root / "native-bridge-golden.owned"
            owned.mkdir()
            (owned / "original-sentinel").write_bytes(b"owned\n")
            owned_identity = module.snapshot_directory(owned)
            original = root / "native-bridge-golden.original"
            owned.rename(original)
            owned.mkdir()
            sentinel = owned / "replacement-sentinel"
            sentinel.write_bytes(b"foreign\n")

            with self.assertRaisesRegex(module.GoldenFilesystemError, "substituted"):
                module.cleanup_owned_directory(owned, owned_identity)

            self.assertEqual(sentinel.read_bytes(), b"foreign\n")
            module.cleanup_owned_directory(original, owned_identity)
            self.assertFalse(original.exists())

    def test_golden_runner_cleanup_regular_preserves_final_check_replacement(self) -> None:
        module = load_golden_filesystem()
        with tempfile.TemporaryDirectory() as temporary_directory:
            parent = pathlib.Path(temporary_directory)
            parent_identity = module.snapshot_directory(parent)
            sentinel = parent / "sentinel"
            sentinel.write_bytes(b"owned\n")
            sentinel_identity = module.snapshot_regular(
                parent,
                parent_identity,
                sentinel.name,
            )
            displaced = parent / "sentinel.displaced"
            real_stat = module.os.stat
            child_stat_calls = 0
            substitution_occurred = False

            def substitute_after_final_check(path, *args, **kwargs):
                nonlocal child_stat_calls, substitution_occurred
                observed = real_stat(path, *args, **kwargs)
                if (
                    path == sentinel.name
                    and kwargs.get("dir_fd") is not None
                    and kwargs.get("follow_symlinks") is False
                ):
                    child_stat_calls += 1
                    if child_stat_calls == 2:
                        sentinel.rename(displaced)
                        sentinel.write_bytes(b"foreign\n")
                        substitution_occurred = True
                return observed

            with mock.patch.object(
                module.os,
                "stat",
                side_effect=substitute_after_final_check,
            ):
                with self.assertRaisesRegex(module.GoldenFilesystemError, "substituted"):
                    module.cleanup_owned_regular(
                        parent,
                        parent_identity,
                        sentinel.name,
                        sentinel_identity,
                    )

            self.assertTrue(substitution_occurred)
            self.assertFalse(sentinel.exists())
            self.assertEqual(displaced.read_bytes(), b"owned\n")
            preserved = list(parent.glob(".sentinel.cleanup.*"))
            self.assertEqual(len(preserved), 1)
            self.assertEqual(preserved[0].read_bytes(), b"foreign\n")

    def test_golden_runner_publishes_across_independently_verified_parents(self) -> None:
        module = load_golden_filesystem()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source_parent = root / "intermediates"
            destination_parent = root / "products" / "Service.xpc" / "Contents" / "Resources"
            source_parent.mkdir()
            destination_parent.mkdir(parents=True)
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

            module.publish_result(
                source_parent,
                source_parent_identity,
                temporary.name,
                temporary_identity,
                destination_parent,
                destination_parent_identity,
                "golden.json",
                None,
            )

            self.assertEqual(
                (destination_parent / "golden.json").read_bytes(),
                b"verified\n",
            )
            self.assertEqual(temporary.read_bytes(), b"verified\n")

    def test_golden_runner_publication_refuses_parent_and_destination_substitution(
        self,
    ) -> None:
        module = load_golden_filesystem()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source_parent = root / "intermediates"
            destination_parent = root / "publication"
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
            original = root / "publication.original"
            destination_parent.rename(original)
            destination_parent.mkdir()
            foreign = destination_parent / "golden.json"
            foreign.write_bytes(b"foreign\n")

            with self.assertRaisesRegex(module.GoldenFilesystemError, "parent.*substituted"):
                module.publish_result(
                    source_parent,
                    source_parent_identity,
                    temporary.name,
                    temporary_identity,
                    destination_parent,
                    destination_parent_identity,
                    foreign.name,
                    None,
                )

            self.assertEqual(foreign.read_bytes(), b"foreign\n")
            self.assertEqual(temporary.read_bytes(), b"verified\n")

            foreign.unlink()
            destination_parent.rmdir()
            original.rename(destination_parent)
            appeared = destination_parent / "golden.json"
            real_open = module.os.open

            def destination_appears(path, flags, *args, **kwargs):
                if path == appeared.name and flags & module.os.O_EXCL:
                    appeared.write_bytes(b"appeared\n")
                return real_open(path, flags, *args, **kwargs)

            with mock.patch.object(
                module.os,
                "open",
                side_effect=destination_appears,
            ):
                with self.assertRaisesRegex(module.GoldenFilesystemError, "appeared"):
                    module.publish_result(
                        source_parent,
                        source_parent_identity,
                        temporary.name,
                        temporary_identity,
                        destination_parent,
                        destination_parent_identity,
                        appeared.name,
                        None,
                    )
            self.assertEqual(appeared.read_bytes(), b"appeared\n")
            self.assertEqual(temporary.read_bytes(), b"verified\n")

    def test_golden_runner_publication_reads_verified_descriptor_after_source_replacement(
        self,
    ) -> None:
        module = load_golden_filesystem()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
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
            displaced = source_parent / ".golden-result.displaced"
            real_open_regular = module._open_regular
            substitution_occurred = False

            def substitute_after_open(parent_fd, name, expected=None):
                nonlocal substitution_occurred
                descriptor, observed = real_open_regular(parent_fd, name, expected)
                if name == temporary.name and not substitution_occurred:
                    temporary.rename(displaced)
                    temporary.write_bytes(b"foreign\n")
                    temporary.chmod(0o644)
                    substitution_occurred = True
                return descriptor, observed

            with mock.patch.object(
                module,
                "_open_regular",
                side_effect=substitute_after_open,
            ):
                module.publish_result(
                    source_parent,
                    source_parent_identity,
                    temporary.name,
                    temporary_identity,
                    destination_parent,
                    destination_parent_identity,
                    "golden.json",
                    None,
                )

            self.assertTrue(substitution_occurred)
            self.assertEqual(
                (destination_parent / "golden.json").read_bytes(),
                b"verified\n",
            )
            self.assertEqual(temporary.read_bytes(), b"foreign\n")
            self.assertEqual(displaced.read_bytes(), b"verified\n")

    def test_golden_runner_publishes_exclusively_reuses_and_refreshes_verified_result(
        self,
    ) -> None:
        module = load_golden_filesystem()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
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

            module.publish_result(
                source_parent,
                source_parent_identity,
                temporary.name,
                temporary_identity,
                destination_parent,
                destination_parent_identity,
                "golden.json",
                None,
            )
            result = destination_parent / "golden.json"
            self.assertEqual(result.read_bytes(), b"verified\n")
            self.assertEqual(temporary.read_bytes(), b"verified\n")

            result_identity = module.snapshot_regular(
                destination_parent,
                destination_parent_identity,
                result.name,
            )
            reuse_temporary = source_parent / ".golden-result-reuse"
            reuse_temporary.write_bytes(b"verified\n")
            reuse_temporary.chmod(0o644)
            reuse_temporary_identity = module.snapshot_regular(
                source_parent,
                source_parent_identity,
                reuse_temporary.name,
            )
            module.publish_result(
                source_parent,
                source_parent_identity,
                reuse_temporary.name,
                reuse_temporary_identity,
                destination_parent,
                destination_parent_identity,
                result.name,
                result_identity,
            )
            self.assertEqual(
                module.snapshot_regular(
                    destination_parent,
                    destination_parent_identity,
                    result.name,
                ),
                result_identity,
            )
            self.assertEqual(reuse_temporary.read_bytes(), b"verified\n")

            refresh_temporary = source_parent / ".golden-result-refresh"
            refresh_temporary.write_bytes(b"new verified bytes\n")
            refresh_temporary.chmod(0o644)
            refresh_temporary_identity = module.snapshot_regular(
                source_parent,
                source_parent_identity,
                refresh_temporary.name,
            )
            module.publish_result(
                source_parent,
                source_parent_identity,
                refresh_temporary.name,
                refresh_temporary_identity,
                destination_parent,
                destination_parent_identity,
                result.name,
                result_identity,
            )
            self.assertEqual(result.read_bytes(), b"new verified bytes\n")
            self.assertNotEqual(
                module.snapshot_regular(
                    destination_parent,
                    destination_parent_identity,
                    result.name,
                ),
                result_identity,
            )

    def test_service_target_is_closed_signed_and_embedded(self) -> None:
        project = self.project()
        target = self.target()
        self.assertEqual(target["type"], "xpc-service")
        self.assertEqual(target["platform"], "macOS")
        self.assertEqual(target["deploymentTarget"], "27.0")
        self.assertEqual(
            [entry["path"] if isinstance(entry, dict) else entry for entry in target["sources"]],
            EXPECTED_SERVICE_SOURCES,
        )

        protocol_definitions = []
        for source in (ROOT / "MacScope").rglob("*.swift"):
            if "protocol NativeDecompilerXPCProtocol" in source.read_text(encoding="utf-8"):
                protocol_definitions.append(source.relative_to(ROOT / "MacScope").as_posix())
        self.assertEqual(
            protocol_definitions,
            ["Models/NativeDecompilerWire/NativeDecompilerWirePrimitives.swift"],
        )
        self.assertEqual(
            [source for source in EXPECTED_SERVICE_SOURCES if not (ROOT / "MacScope" / source).is_file()],
            [],
            "the closed NativeDecompilerXPCService source list must name only accepted files",
        )

        settings = target["settings"]["base"]
        self.assertEqual(settings["PRODUCT_NAME"], "NativeDecompilerXPCService")
        self.assertEqual(
            settings["PRODUCT_BUNDLE_IDENTIFIER"],
            "org.macscope.app.NativeDecompiler",
        )
        self.assertEqual(settings["INFOPLIST_FILE"], "NativeDecompilerXPCService/Info.plist")
        self.assertIs(settings["GENERATE_INFOPLIST_FILE"], False)
        self.assertIs(settings["SKIP_INSTALL"], True)
        self.assertEqual(settings["CLANG_CXX_LANGUAGE_STANDARD"], "c++20")
        self.assertEqual(
            settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"],
            "$(inherited) $(MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION)",
        )
        self.assertEqual(
            settings["SWIFT_OBJC_BRIDGING_HEADER"],
            "NativeDecompilerXPCService/NativeDecompilerXPCService-Bridging-Header.h",
        )

        app_dependencies = project["targets"]["MacScopeApp"]["dependencies"]
        self.assertEqual(
            [
                dependency
                for dependency in app_dependencies
                if dependency.get("target") == "NativeDecompilerXPCService"
            ],
            [
                {
                    "target": "NativeDecompilerXPCService",
                    "embed": True,
                    "codeSign": True,
                }
            ],
        )

    def test_native_link_and_package_resources_are_service_only(self) -> None:
        project = self.project()
        service = self.target()
        service_flags = service["settings"]["base"]["OTHER_LDFLAGS"]
        staged_package = (
            "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)"
            "/NativeDecompilerPackage/package/lib"
        )
        external_package = "$(MACSCOPE_SLEIGH_MATERIALIZATION_ROOT)/package/lib"
        for required in (
            "libmacscope_native_decompiler_contract.a",
            f'{staged_package}/libdecomp.a',
            f'{staged_package}/libsla.a',
            "-lz",
            "-lc++",
        ):
            self.assertIn(required, service_flags)
        self.assertNotIn(external_package, service_flags)

        app_settings = project["targets"]["MacScopeApp"]["settings"]["base"]
        app_flags = str(app_settings.get("OTHER_LDFLAGS", ""))
        for forbidden in (
            "macscope_native_decompiler",
            "libdecomp",
            "libsla",
            "SLEIGH_MATERIALIZATION",
        ):
            self.assertNotIn(forbidden, app_flags)

        phase_names = [phase["name"] for phase in service["preBuildScripts"]]
        self.assertEqual(
            phase_names,
            [
                "Verify certificate-backed signing environment",
                "Build verified native decompiler bridge",
                "Stage verified native decompiler package",
                "Validate native decompiler bridge golden",
            ],
        )
        build_phase, stage_phase, golden_phase = service["preBuildScripts"][1:]
        for phase in (build_phase, golden_phase):
            self.assertTrue(phase["basedOnDependencyAnalysis"])
            self.assertEqual(len(phase["inputFileLists"]), 1)
        self.assertFalse(
            stage_phase["basedOnDependencyAnalysis"],
            "the package verifier must observe nested leaf mutations on every build",
        )
        self.assertEqual(len(stage_phase["inputFileLists"]), 1)
        for phase in (build_phase, golden_phase, stage_phase):
            self.assertEqual(len(phase["outputFileLists"]), 1)
        # The lists are named through overridable settings so a typed Release
        # admission can supply its own (fff93dcc9); the default stays the
        # checked-in list.
        self.assertEqual(
            stage_phase["outputFileLists"][0], "$(MACSCOPE_NATIVE_PACKAGE_OUTPUT_FILE_LIST)"
        )
        self.assertIn(
            "NativeDecompilerPackageOutputs.xcfilelist",
            self.project()["settings"]["base"]["MACSCOPE_NATIVE_PACKAGE_OUTPUT_FILE_LIST"],
        )
        self.assertIn("build_native_bridge.sh", build_phase["script"])
        self.assertIn("native_decompiler_source_identity.py", build_phase["script"])
        self.assertNotIn("git -C", build_phase["script"])
        bridge_build_script = (
            ROOT / "Scripts/native-decompiler-xpc/build_native_bridge.sh"
        ).read_text(encoding="utf-8")
        self.assertIn("CMAKE_BUILD_PARALLEL_LEVEL", bridge_build_script)
        self.assertIn("MACSCOPE_NATIVE_CTEST_JOBS", bridge_build_script)
        self.assertIn("hw.perflevel0.logicalcpu", bridge_build_script)
        self.assertIn(
            '"$ctest_bin" --test-dir "$build_root" --parallel "$native_ctest_jobs" --output-on-failure',
            bridge_build_script,
        )
        self.assertIn("/usr/bin/getconf _NPROCESSORS_ONLN", bridge_build_script)
        self.assertIn('[[ ! "$parallel_jobs" =~ ^[1-9][0-9]*$ ]]', bridge_build_script)
        self.assertIn('--build "$build_root" --parallel "$parallel_jobs"', bridge_build_script)
        self.assertNotIn('--parallel 4', bridge_build_script)
        # MS-36/MS-37. Xcode's script-phase PATH never contains Homebrew's Apple
        # Silicon prefix, so every offline build tool must be resolved explicitly
        # rather than by a bare `command -v` lookup that only succeeds in a login
        # shell. Regressing to the implicit form silently un-builds the project
        # from Xcode, the Xcode MCP server, and any Xcode-driven CI.
        self.assertIn("resolve_required_tool", bridge_build_script)
        self.assertIn("/opt/homebrew/bin", bridge_build_script)
        self.assertNotIn(
            "for command in cmake file ninja python3 strings; do", bridge_build_script
        )
        for tool in ("cmake", "ctest", "ninja", "file", "strings", "python3"):
            self.assertIn(
                'resolve_required_tool %s "${MACSCOPE_%s:-}"' % (tool, tool.upper()),
                bridge_build_script,
            )
        # CMake re-resolves the generator program itself, so pinning the binary is
        # not enough — the -G Ninja lookup must be given the resolved path too.
        self.assertIn('"-DCMAKE_MAKE_PROGRAM=$ninja_bin"', bridge_build_script)
        # The diagnostic must name the missing tool; the previous message did not,
        # leaving the build log with no route to the cause.
        self.assertIn(
            "ERROR: required offline build tool is unavailable: %s", bridge_build_script
        )
        self.assertIn("run_native_bridge_golden.sh", golden_phase["script"])
        self.assertIn(
            '--build-root "$MACSCOPE_NATIVE_DECOMPILER_GOLDEN_BUILD_ROOT"',
            golden_phase["script"],
        )
        self.assertIn(
            '--materialization-root "$STAGED_MATERIALIZATION_ROOT"',
            golden_phase["script"],
        )
        self.assertIn(
            '--native-archive-root "$MACSCOPE_NATIVE_DECOMPILER_BUILD_ROOT"',
            golden_phase["script"],
        )
        for argument in (
            '--stage-stamp "$TARGET_TEMP_DIR/NativeDecompilerPackageStage/NativeDecompilerPackage.stage.json"',
            '--developer-dir "$DEVELOPER_DIR"',
            '--sdk-root "$SDKROOT"',
            '--sdk-name "$SDK_NAME"',
            '--target-build-dir "$TARGET_BUILD_DIR"',
            '--project-temp-dir "$PROJECT_TEMP_DIR"',
            '--result "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/NativeDecompilerBridgeGolden.json"',
        ):
            self.assertIn(argument, golden_phase["script"])
        self.assertNotIn("MACSCOPE_SLEIGH_MATERIALIZATION_ROOT", golden_phase["script"])
        self.assertIn("stage_xcode_resources.py", stage_phase["script"])
        self.assertIn(
            '/usr/bin/python3 -B "$SRCROOT/../Scripts/native-decompiler-xpc/stage_xcode_resources.py"',
            stage_phase["script"],
        )
        self.assertIn(
            'STAGE_METADATA_DIR="$TARGET_TEMP_DIR/NativeDecompilerPackageStage"',
            stage_phase["script"],
        )
        self.assertIn('--metadata-directory "$STAGE_METADATA_DIR"', stage_phase["script"])
        self.assertNotIn("DERIVED_FILE_DIR", stage_phase["script"])
        self.assertIn("$TARGET_BUILD_DIR", stage_phase["script"])
        self.assertIn("$UNLOCALIZED_RESOURCES_FOLDER_PATH", stage_phase["script"])
        combined_scripts = build_phase["script"] + golden_phase["script"] + stage_phase["script"]
        self.assertNotIn("curl", combined_scripts)
        self.assertNotIn("wget", combined_scripts)

    def test_core_tests_compile_only_the_pure_swift_service_test_seam(self) -> None:
        core_tests = self.project()["targets"]["CoreTests"]
        direct_sources = [
            entry["path"] if isinstance(entry, dict) else entry
            for entry in core_tests["sources"]
        ]
        for source in EXPECTED_CORE_TEST_SERVICE_SOURCES:
            self.assertEqual(direct_sources.count(source), 1)

        for forbidden in (
            "NativeDecompilerXPCService/main.swift",
            "NativeDecompilerXPCService/Bridge/NativeDecompilerWireBridge.hpp",
            "NativeDecompilerXPCService/Bridge/NativeDecompilerWireCodec.mm",
            "NativeDecompilerXPCService/Bridge/NativeDecompilerObjCBridge.h",
            "NativeDecompilerXPCService/Bridge/NativeDecompilerObjCBridge.mm",
            "NativeDecompilerXPCService/NativeDecompilerXPCService-Bridging-Header.h",
        ):
            self.assertNotIn(forbidden, direct_sources)

        test_tree = next(
            entry
            for entry in core_tests["sources"]
            if isinstance(entry, dict) and entry.get("path") == "Tests/CoreTests"
        )
        self.assertTrue(STANDALONE_BRIDGE_TESTS.issubset(set(test_tree["excludes"])))
        conditions = core_tests["settings"]["base"]["SWIFT_ACTIVE_COMPILATION_CONDITIONS"]
        self.assertIn("TESTING_NATIVE_DECOMPILER_SERVICE_COMPOSITION", conditions.split())
        self.assertIn("$(MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION)", conditions.split())

    def test_app_globs_do_not_compile_native_service_or_bridge_sources(self) -> None:
        project = self.project()
        app = project["targets"]["MacScopeApp"]
        app_sources = app["sources"]
        paths = [entry["path"] if isinstance(entry, dict) else entry for entry in app_sources]
        self.assertNotIn("NativeDecompilerXPCService", paths)
        self.assertEqual(
            [path for path in paths if path.startswith("NativeDecompilerXPCService/")],
            ["NativeDecompilerXPCService/NativeDecompilerLiveXPCTestControl.swift"],
        )
        self.assertEqual(
            app["settings"]["base"]["SWIFT_ACTIVE_COMPILATION_CONDITIONS"],
            "$(inherited) $(MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION) "
            "$(MACSCOPE_GHOSTTY_SURFACE_ENABLED)",
        )
        self.assertEqual(
            project["settings"]["base"]["MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION"],
            "",
        )

    def test_app_release_provenance_is_bound_to_the_embedded_golden_resource(self) -> None:
        app = self.project()["targets"]["MacScopeApp"]
        phases = [
            phase
            for phase in app["postBuildScripts"]
            if phase["name"] == "Generate sealed Release build provenance"
        ]
        self.assertEqual(len(phases), 1)
        phase = phases[0]
        golden = (
            "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/XPCServices/"
            "NativeDecompilerXPCService.xpc/Contents/Resources/"
            "NativeDecompilerBridgeGolden.json"
        )
        package_root = (
            "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/XPCServices/"
            "NativeDecompilerXPCService.xpc/Contents/Resources/NativeDecompilerPackage"
        )
        analysis_worker = (
            "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/XPCServices/"
            "AnalysisWorkerXPCService.xpc/Contents/MacOS/AnalysisWorkerXPCService"
        )
        self.assertEqual(
            phase["inputFiles"],
            [
                golden,
                package_root + "/MATERIALIZATION.json",
                package_root + "/package",
                package_root + "/package/lib/libdecomp.a",
                package_root + "/package/lib/libsla.a",
                package_root.removesuffix("/Contents/Resources/NativeDecompilerPackage")
                + "/Contents/Info.plist",
                package_root.removesuffix("/Contents/Resources/NativeDecompilerPackage")
                + "/Contents/MacOS/NativeDecompilerXPCService",
                package_root.removesuffix("/Contents/Resources/NativeDecompilerPackage")
                + "/Contents/_CodeSignature/CodeResources",
                "$(MACSCOPE_GHOSTTY_SURFACE_MANIFEST)",
                "$(MACSCOPE_GHOSTTY_SURFACE_STAGED_DESCRIPTOR)",
                "$(MACSCOPE_GHOSTTY_SURFACE_ARCHIVE)",
                "$(MACSCOPE_GHOSTTY_SURFACE_HEADER)",
                "$(MACSCOPE_GHOSTTY_SURFACE_MODULE_MAP)",
                analysis_worker,
                "$(MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT)/MATERIALIZATION.json",
            ],
        )
        self.assertFalse(phase["basedOnDependencyAnalysis"])
        self.assertEqual(
            phase["outputFiles"],
            [
                "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/"
                "MacScopeBuildProvenance.json"
            ],
        )

        continuation = "\\"
        self.assertEqual(
            phase["script"].splitlines(),
            [
                'if [ "$CONFIGURATION" != "Release" ] && [ "$CONFIGURATION" != "Debug" ]; then',
                '  exit 1',
                'fi',
                f'/usr/bin/python3 "$SRCROOT/../Scripts/generate_release_build_provenance.py" {continuation}',
                f'  --repo-root "$SRCROOT/.." {continuation}',
                f'  --project-yml "$SRCROOT/project.yml" {continuation}',
                f'  --project-file-path "$PROJECT_FILE_PATH" {continuation}',
                f'  --configuration "$CONFIGURATION" {continuation}',
                f'  --debug-source-identity "$MACSCOPE_DEBUG_SOURCE_IDENTITY" {continuation}',
                f'  --ghostty-source-dir "$SRCROOT/../ThirdParty/GhosttyVT/Source" {continuation}',
                f'  --ghostty-surface-manifest "$MACSCOPE_GHOSTTY_SURFACE_MANIFEST" {continuation}',
                f'  --ghostty-surface-staged-root "$MACSCOPE_GHOSTTY_SURFACE_STAGED_ROOT" {continuation}',
                f'  --sleigh-materialization-root "$MACSCOPE_SLEIGH_MATERIALIZATION_ROOT" {continuation}',
                f'  --machokit-materialization-root "$MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT" {continuation}',
                f'  --analysis-worker-executable "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/XPCServices/AnalysisWorkerXPCService.xpc/Contents/MacOS/AnalysisWorkerXPCService" {continuation}',
                f'  --native-decompiler-live-test-condition "$MACSCOPE_NATIVE_DECOMPILER_LIVE_TEST_CONDITION" {continuation}',
                f'  --swift-active-compilation-conditions "$SWIFT_ACTIVE_COMPILATION_CONDITIONS" {continuation}',
                f'  --other-swift-flags "$OTHER_SWIFT_FLAGS" {continuation}',
                f'  --architectures "$ARCHS" {continuation}',
                f'  --deployment-target "$MACOSX_DEPLOYMENT_TARGET" {continuation}',
                f'  --sdk-name "$SDK_NAME" {continuation}',
                f'  --sdk-version "$SDK_VERSION" {continuation}',
                f'  --sdk-build "$SDK_PRODUCT_BUILD_VERSION" {continuation}',
                f'  --developer-dir "$DEVELOPER_DIR" {continuation}',
                f'  --swift-executable "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc" {continuation}',
                f'  --native-decompiler-golden-result "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/XPCServices/NativeDecompilerXPCService.xpc/Contents/Resources/NativeDecompilerBridgeGolden.json" {continuation}',
                '  --output "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/MacScopeBuildProvenance.json"',
            ],
        )
        self.assertTrue(phase["script"].endswith("\n"))

    def test_release_embed_preserves_manifest_bound_native_archives(self) -> None:
        app = self.project()["targets"]["MacScopeApp"]
        self.assertEqual(app["settings"]["base"]["COPY_PHASE_STRIP"], False)

    def test_checked_in_file_lists_are_closed_and_path_relocatable(self) -> None:
        names = (
            "NativeDecompilerBridgeInputs.xcfilelist",
            "NativeDecompilerBridgeOutputs.xcfilelist",
            "NativeDecompilerBridgeGoldenInputs.xcfilelist",
            "NativeDecompilerBridgeGoldenOutputs.xcfilelist",
            "NativeDecompilerPackageInputs.xcfilelist",
            "NativeDecompilerPackageOutputs.xcfilelist",
        )
        root = ROOT / "Scripts" / "native-decompiler-xpc"
        for name in names:
            with self.subTest(name=name):
                payload = (root / name).read_text(encoding="utf-8")
                self.assertTrue(payload.endswith("\n"))
                self.assertNotIn("/Users/", payload)
                self.assertNotIn("/private/tmp", payload)
                self.assertNotIn("$HOME", payload)
                self.assertEqual(len(payload.splitlines()), len(set(payload.splitlines())))

        stage = next(
            phase
            for phase in self.project()["targets"]["NativeDecompilerXPCService"]["preBuildScripts"]
            if phase["name"] == "Stage verified native decompiler package"
        )
        self.assertEqual(len(stage["outputFileLists"]), 1)
        stage_outputs = root / "NativeDecompilerPackageOutputs.xcfilelist"
        self.assertTrue(stage_outputs.is_file())
        self.assertEqual(
            stage_outputs.read_text(encoding="utf-8").splitlines(),
            [
                "$(TARGET_TEMP_DIR)/NativeDecompilerPackageStage/"
                "NativeDecompilerPackage.stage.json"
            ],
        )

        bridge_inputs = (root / "NativeDecompilerBridgeInputs.xcfilelist").read_text(
            encoding="utf-8"
        ).splitlines()
        expected_native_files = {
            "$(SRCROOT)/../" + path.relative_to(ROOT).as_posix()
            for path in (ROOT / "Tools/NativeDecompilerBridge").rglob("*")
            if path.is_file()
        }
        self.assertTrue(expected_native_files.issubset(set(bridge_inputs)))
        self.assertEqual(
            bridge_inputs.count(
                "$(MACSCOPE_SLEIGH_MATERIALIZATION_ROOT)/package/lib/cmake/sleigh"
            ),
            1,
        )
        for directory in (
            "$(SRCROOT)/../Tools/NativeDecompilerBridge/include",
            "$(SRCROOT)/../Tools/NativeDecompilerBridge/src",
            "$(SRCROOT)/../Tools/NativeDecompilerBridge/tests",
        ):
            self.assertIn(directory, bridge_inputs)

    def test_ghostty_source_build_rechecks_signing_inputs_on_every_build(self) -> None:
        root = ROOT / "Scripts" / "native-decompiler-xpc"
        phase = next(
            phase
            for phase in self.project()["targets"]["MacScopeApp"]["preBuildScripts"]
            if phase["name"] == "Build repository-owned Ghostty VT"
        )
        self.assertFalse(
            phase["basedOnDependencyAnalysis"],
            "signing mode and identity are script inputs that Xcode cannot infer from the dylib",
        )
        self.assertEqual(
            phase["inputFiles"],
            [
                "$(SRCROOT)/../Scripts/build_ghostty_vt.sh",
                "$(SRCROOT)/../Scripts/dependencies/stage_verified_ghostty_vt.py",
                "$(SRCROOT)/../Scripts/dependencies/stage_verified_ghostty_surface.py",
                "$(SRCROOT)/../Scripts/ghostty-vt-source.contract",
                "$(SRCROOT)/../Scripts/dependencies/zig_toolchain_receipt.py",
                # The phase resolves the shared verified VT view through the
                # developer dependency cache, so both helpers are inputs.
                "$(SRCROOT)/../Scripts/qualification/dev_dependency_cache.py",
                "$(SRCROOT)/../Scripts/qualification/dependency_cache.py",
                "$(SRCROOT)/../ThirdParty/GhosttyVT/Source/build.zig",
                "$(SRCROOT)/../ThirdParty/GhosttyVT/Source/build.zig.zon",
            ],
        )
        self.assertEqual(
            phase["outputFiles"],
            [
                "$(MACSCOPE_GHOSTTY_VT_BUILD_ROOT)/artifacts/lib/.macscope-ghostty-vt-manifest",
                "$(MACSCOPE_GHOSTTY_VT_BUILD_ROOT)/artifacts/lib/libghostty-vt.dylib",
                "$(MACSCOPE_GHOSTTY_VT_BUILD_ROOT)/artifacts/include/ghostty/vt.h",
                "$(MACSCOPE_GHOSTTY_VT_BUILD_ROOT)/artifacts/include/module.modulemap",
                "$(TARGET_BUILD_DIR)/$(FRAMEWORKS_FOLDER_PATH)/libghostty-vt.dylib",
            ],
        )
        self.assertEqual(
            phase["script"].count(
                '"$SRCROOT/../Scripts/build_ghostty_vt.sh" \\\n'
                '    --work-root "$MACSCOPE_GHOSTTY_VT_BUILD_ROOT"'
            ),
            1,
        )
        self.assertNotIn("MACSCOPE_GHOSTTY_VT_WORK_ROOT", phase["script"])

        golden_inputs = (root / "NativeDecompilerBridgeGoldenInputs.xcfilelist").read_text(
            encoding="utf-8"
        ).splitlines()
        for source in (
            "$(SRCROOT)/../Scripts/native-decompiler-xpc/run_native_bridge_golden.sh",
            "$(SRCROOT)/../Scripts/native-decompiler-xpc/golden_filesystem.py",
            "$(SRCROOT)/Tests/CoreTests/NativeDecompilerObjCBridgeTests.mm",
            "$(SRCROOT)/Tests/CoreTests/NativeDecompilerObjCBridgeCrossLanguageTests.swift",
            "$(SRCROOT)/../Scripts/native-decompiler-xpc/stage_verified_package.py",
            "$(SRCROOT)/../Tools/NativeDecompilerBridge/include",
            "$(SRCROOT)/../Tools/NativeDecompilerBridge/src",
            "$(MACSCOPE_NATIVE_DECOMPILER_BUILD_ROOT)/libmacscope_native_decompiler_contract.a",
            "$(MACSCOPE_NATIVE_DECOMPILER_BUILD_ROOT)/CMakeCache.txt",
            "$(MACSCOPE_NATIVE_DECOMPILER_BUILD_ROOT)/generated/MacScopeNativeDecompiler/GhidraBuildIdentity.hpp",
            "$(TARGET_TEMP_DIR)/NativeDecompilerPackageStage/NativeDecompilerPackage.stage.json",
            "$(SDKROOT)/usr/lib/libz.tbd",
            "$(SDKROOT)/usr/lib/libc++.tbd",
        ):
            self.assertIn(source, golden_inputs)
        self.assertFalse(
            any("/NativeDecompilerPackage/" in line for line in golden_inputs),
            "the always-run package stage stamp is the golden phase's verified package input",
        )
        self.assertFalse(any("MACSCOPE_SLEIGH_MATERIALIZATION_ROOT" in line for line in golden_inputs))
        golden_outputs = (root / "NativeDecompilerBridgeGoldenOutputs.xcfilelist").read_text(
            encoding="utf-8"
        ).splitlines()
        self.assertEqual(
            golden_outputs,
            [
                "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)"
                "/NativeDecompilerBridgeGolden.json"
            ],
        )

    def _create_verified_source(self, root: pathlib.Path) -> pathlib.Path:
        from Scripts.tests.test_native_decompiler_xpc_package import (  # noqa: PLC0415
            SleighPackageFixture,
            canonical_manifest,
            sleigh_package,
        )

        source = root / "source"
        package = source / "package"
        package.mkdir(parents=True)
        SleighPackageFixture(package).create()
        (source / "MATERIALIZATION.json").write_text(
            sleigh_package.canonical_json(canonical_manifest(package)) + "\n",
            encoding="utf-8",
        )
        return source

    def _stage_paths(
        self,
        root: pathlib.Path,
    ) -> tuple[pathlib.Path, pathlib.Path, pathlib.PurePosixPath, dict[str, pathlib.Path]]:
        target_build = root / "Build" / "Products"
        target_build.mkdir(parents=True)
        metadata = root / "Build" / "Intermediates" / "Service"
        metadata.mkdir(parents=True)
        resources = pathlib.PurePosixPath(
            "NativeDecompilerXPCService.xpc/Contents/Resources"
        )
        paths = {
            "package": target_build / resources / "NativeDecompilerPackage",
            "input": metadata / "NativeDecompilerPackage.inputs.xcfilelist",
            "output": metadata / "NativeDecompilerPackage.outputs.xcfilelist",
            "stamp": metadata / "NativeDecompilerPackage.stage.json",
        }
        return target_build, metadata, resources, paths

    def test_staged_link_inputs_are_digest_bound_and_external_replacement_isolated(self) -> None:
        module = load_resource_stager()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = self._create_verified_source(root)
            target_build, metadata, resources, paths = self._stage_paths(root)
            module.stage_xcode_resources(source, target_build, resources, metadata)

            destination = paths["package"]
            stamp_path = paths["stamp"]
            stamp_before = stamp_path.read_bytes()
            stamp = json.loads(stamp_before)
            expected = []
            staged_bytes: dict[str, bytes] = {}
            for archive in ("libdecomp.a", "libsla.a"):
                relative = f"package/lib/{archive}"
                staged = destination / relative
                payload = staged.read_bytes()
                staged_bytes[relative] = payload
                expected.append(
                    {
                        "relativePath": relative,
                        "sha256": hashlib.sha256(payload).hexdigest(),
                    }
                )
            self.assertEqual(stamp["linkInputs"], expected)

            for relative in staged_bytes:
                external = source / relative
                replacement = external.with_name(f".{external.name}.replacement")
                replacement.write_bytes(b"attacker-replacement\n")
                replacement.replace(external)

            for relative, payload in staged_bytes.items():
                self.assertEqual((destination / relative).read_bytes(), payload)
            self.assertEqual(stamp_path.read_bytes(), stamp_before)

    def test_resource_stager_supports_two_consecutive_verified_builds(self) -> None:
        from Scripts.tests.test_native_decompiler_xpc_package import (  # noqa: PLC0415
            SleighPackageFixture,
            canonical_manifest,
            sleigh_package,
        )

        module = load_resource_stager()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "source"
            package = source / "package"
            package.mkdir(parents=True)
            SleighPackageFixture(package).create()
            (source / "MATERIALIZATION.json").write_text(
                sleigh_package.canonical_json(canonical_manifest(package)) + "\n",
                encoding="utf-8",
            )
            target_build = root / "Build" / "Products" / "Service.xpc"
            target_build.mkdir(parents=True)
            metadata = root / "Build" / "Intermediates" / "Service"
            metadata.mkdir(parents=True)

            with mock.patch.object(
                module._STAGER,
                "_stage_verified_package_anchored",
                wraps=module._STAGER._stage_verified_package_anchored,
            ) as publisher:
                first = module.stage_xcode_resources(
                    source,
                    target_build,
                    pathlib.PurePosixPath("Contents/Resources"),
                    metadata,
                )
                with mock.patch.object(
                    module,
                    "_sha256",
                    side_effect=AssertionError(
                        "exact reuse must use digests from the verified package snapshot"
                    ),
                ):
                    second = module.stage_xcode_resources(
                        source,
                        target_build,
                        pathlib.PurePosixPath("Contents/Resources"),
                        metadata,
                    )

            self.assertEqual(first, second)
            self.assertEqual(publisher.call_count, 1)
            destination = target_build / "Contents/Resources/NativeDecompilerPackage"
            self.assertEqual(module.verify_materialization(destination), first)
            self.assertTrue((metadata / "NativeDecompilerPackage.stage.json").is_file())
            self.assertFalse(
                any(path.name.startswith(".NativeDecompilerRetired-") for path in metadata.iterdir())
            )
            self.assertFalse(
                any(
                    path.name.startswith(".NativeDecompilerPackage.")
                    for path in destination.parent.iterdir()
                )
            )

    def test_shared_view_reuse_survives_metadata_only_drift_but_not_content_change(self) -> None:
        module = load_resource_stager()
        stager = module._STAGER
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory).resolve()
            source = self._create_verified_source(root)
            target_build, metadata, resources, paths = self._stage_paths(root)
            receipts = root / "receipts"
            receipts.mkdir(mode=0o700)
            descriptor = os.open(source, stager._directory_open_flags())
            try:
                snapshot = stager._closed_tree_snapshot(descriptor)
            finally:
                os.close(descriptor)
            accepted = {
                "identity": json.loads((source / "MATERIALIZATION.json").read_text()),
                "files": {relative: (fields[4], digest)
                          for relative, kind, fields, digest in snapshot if kind == "file"},
            }
            with mock.patch.dict(os.environ, {
                "MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE": "shared-view",
                "MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT": str(receipts),
            }), mock.patch.object(stager, "_reused_source_receipt", return_value=accepted), \
                 mock.patch.object(stager, "_checked_verify", wraps=stager._checked_verify) as verify:
                first = module.stage_xcode_resources(source, target_build, resources, metadata)
                self.assertEqual(verify.call_count, 1)
                self.assertTrue(stager._staged_receipt_path(paths["package"].resolve()).is_file())
                library = paths["package"] / "package/lib/libdecomp.a"
                before = library.stat()
                # A later run after a reboot/copy/touch: only metadata moved.
                os.utime(library, ns=(1, 1))
                os.utime(paths["package"], ns=(1, 1))
                self.assertNotEqual(library.stat().st_ctime_ns, before.st_ctime_ns)
                with mock.patch.object(module, "_sha256", side_effect=AssertionError("rehash")), \
                     mock.patch.object(stager, "_closed_tree_snapshot",
                                       wraps=stager._closed_tree_snapshot) as snapshots:
                    second = module.stage_xcode_resources(source, target_build, resources, metadata)
                # Every tree snapshot reused recorded digests; none read package bytes.
                self.assertTrue(snapshots.call_args_list)
                for call in snapshots.call_args_list:
                    self.assertTrue(call.kwargs.get("prior_snapshot") is not None
                                    or call.kwargs.get("digest_evidence") is not None)
                self.assertEqual(first, second)
                self.assertEqual(verify.call_count, 1)
                library.chmod(0o644)
                library.write_bytes(b"x" * (before.st_size + 1))
                with self.assertRaises(module.XcodeResourceStageError):
                    module._existing_owned_state(
                        paths["package"], paths["input"], paths["output"], paths["stamp"]
                    )

    def test_receipt_mode_replaces_an_owned_copy_staged_without_a_receipt(self) -> None:
        # dev_loop sequence: a plain build staged the package without receipt
        # mode, then --native-verbose put the DerivedData into shared-view mode.
        # The owned copy has no staged receipt; it is retired and republished
        # with one, not refused, and the next run reuses it exactly.
        module = load_resource_stager()
        stager = module._STAGER
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory).resolve()
            source = self._create_verified_source(root)
            target_build, metadata, resources, paths = self._stage_paths(root)
            identity = module.stage_xcode_resources(source, target_build, resources, metadata)
            legacy_stamp = paths["stamp"].lstat().st_ino
            receipts = root / "receipts"
            receipts.mkdir(mode=0o700)
            descriptor = os.open(source, stager._directory_open_flags())
            try:
                snapshot = stager._closed_tree_snapshot(descriptor)
            finally:
                os.close(descriptor)
            accepted = {
                "identity": json.loads((source / "MATERIALIZATION.json").read_text()),
                "files": {relative: (fields[4], digest)
                          for relative, kind, fields, digest in snapshot if kind == "file"},
            }

            def shared_view_only(canonical):
                if canonical != source:
                    raise RuntimeError("SLEIGH consumer does not name the receipt-bound shared view")
                return accepted

            with mock.patch.dict(os.environ, {
                "MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE": "shared-view",
                "MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT": str(receipts),
            }), mock.patch.object(stager, "_reused_source_receipt", side_effect=shared_view_only):
                with self.assertRaises(module.UnattestedOwnedPackageError):
                    module._existing_owned_state(
                        paths["package"], paths["input"], paths["output"], paths["stamp"]
                    )
                self.assertEqual(
                    module.stage_xcode_resources(source, target_build, resources, metadata), identity)
                self.assertNotEqual(paths["stamp"].lstat().st_ino, legacy_stamp)
                self.assertTrue(stager._staged_receipt_path(paths["package"].resolve()).is_file())
                republished = paths["stamp"].lstat().st_ino
                self.assertEqual(
                    module.stage_xcode_resources(source, target_build, resources, metadata), identity)
                self.assertEqual(paths["stamp"].lstat().st_ino, republished, "exact reuse")

    def test_unattested_copy_with_mismatched_owned_lists_is_not_retired(self) -> None:
        module = load_resource_stager()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory).resolve()
            source = self._create_verified_source(root)
            target_build, metadata, resources, paths = self._stage_paths(root)
            module.stage_xcode_resources(source, target_build, resources, metadata)
            paths["input"].chmod(0o600)
            paths["input"].write_text("tampered\n", encoding="utf-8")
            with self.assertRaises(module.XcodeResourceStageError):
                module._require_owned_staging_set(
                    paths["package"], paths["input"], paths["output"], paths["stamp"])
            with self.assertRaisesRegex(module.XcodeResourceStageError, "Xcode Clean|fresh|stamp"):
                module.stage_xcode_resources(source, target_build, resources, metadata)
            self.assertTrue(paths["package"].is_dir(), "unproven state is preserved")

    def _receipt_recovery_fixture(self, root, module):
        source = self._create_verified_source(root)
        target, metadata, resources, paths = self._stage_paths(root)
        identity = module.stage_xcode_resources(source, target, resources, metadata)
        stager = module._STAGER
        anchor = stager._open_verified_materialization(source, "fixture source")
        try:
            accepted = {
                "identity": identity,
                "files": {relative: (fields[4], digest)
                          for relative, kind, fields, digest in anchor[3] if kind == "file"},
            }
        finally:
            os.close(anchor[1])
        receipts = root / "receipts"
        receipts.mkdir(mode=0o700)
        return source, target, metadata, resources, paths, accepted, receipts

    def _staging_state(self, paths):
        # Small authored fixtures only: preserve bytes, names and stable metadata.
        entries = set(paths.values())
        entries.update(paths["package"].rglob("*"))
        return {str(path): (path.lstat(),
                           path.read_bytes() if path.is_file() and not path.is_symlink() else None,
                           os.readlink(path) if path.is_symlink() else None)
                for path in entries}

    def _stable_staging_state(self, paths):
        return {path: ((metadata.st_dev, metadata.st_ino, metadata.st_mode,
                        metadata.st_nlink, metadata.st_size,
                        metadata.st_mtime_ns, metadata.st_ctime_ns), payload, link)
                for path, (metadata, payload, link) in self._staging_state(paths).items()}

    def test_absent_receipt_recovery_uses_source_evidence_without_rehashing(self) -> None:
        module = load_resource_stager()
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary).resolve()
            source, target, metadata, resources, paths, accepted, receipts = self._receipt_recovery_fixture(root, module)
            stager = module._STAGER
            with mock.patch.dict(os.environ, {
                "MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE": "shared-view",
                "MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT": str(receipts),
                "MACSCOPE_NATIVE_PRIOR_RECEIPT_ROOT": "",
            }), mock.patch.object(stager, "_reused_source_receipt", return_value=accepted), \
                 mock.patch.object(stager, "_closed_tree_snapshot", wraps=stager._closed_tree_snapshot) as snapshots, \
                 mock.patch.object(module, "_retire_owned_state", wraps=module._retire_owned_state) as retire:
                self.assertEqual(module.stage_xcode_resources(source, target, resources, metadata), accepted["identity"])
                retire.assert_called_once()
                self.assertTrue(stager._staged_receipt_path(paths["package"]).is_file())
                # Only newly copied bytes are hashed; admission/recovery use evidence.
                self.assertTrue(any(call.kwargs.get("hash_files") is False for call in snapshots.call_args_list))
                first_copy = next(index for index, call in enumerate(snapshots.call_args_list)
                                  if not call.kwargs)
                for call in snapshots.call_args_list[:first_copy]:
                    self.assertTrue(call.kwargs.get("hash_files") is False
                                    or call.kwargs.get("digest_evidence") is not None
                                    or call.kwargs.get("prior_snapshot") is not None)

    def test_invalid_staged_contents_refuse_without_recovery_mutation(self) -> None:
        for receipt_present in (False, True):
            for defect in ("hardlink", "symlink", "missing", "extra", "size", "directory"):
                with self.subTest(receipt=receipt_present, defect=defect), tempfile.TemporaryDirectory() as temporary:
                    module = load_resource_stager()
                    root = pathlib.Path(temporary).resolve()
                    source, target, metadata, resources, paths, accepted, receipts = self._receipt_recovery_fixture(root, module)
                    stager = module._STAGER
                    with mock.patch.dict(os.environ, {
                        "MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE": "shared-view",
                        "MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT": str(receipts),
                        "MACSCOPE_NATIVE_PRIOR_RECEIPT_ROOT": "",
                    }), mock.patch.object(stager, "_reused_source_receipt", return_value=accepted):
                        if receipt_present:
                            module.stage_xcode_resources(source, target, resources, metadata)
                        leaf = paths["package"] / "package/include/sleigh/ghidra/libdecomp.hh"
                        if defect == "hardlink":
                            os.link(leaf, root / "alias")
                        elif defect == "symlink":
                            leaf.unlink()
                            leaf.symlink_to(source / "package/include/sleigh/ghidra/libdecomp.hh")
                        elif defect == "missing":
                            leaf.unlink()
                        elif defect == "extra":
                            (paths["package"] / "extra").write_bytes(b"foreign")
                        elif defect == "directory":
                            (paths["package"] / "extra-directory").mkdir()
                        else:
                            leaf.write_bytes(b"different-size-payload")
                        before = self._stable_staging_state(paths)
                        with mock.patch.object(module, "_retire_owned_state") as retire, \
                             mock.patch.object(stager, "_stage_verified_package_anchored") as publish:
                            with self.assertRaises(module.PackageAdmissionError) as failure:
                                module.stage_xcode_resources(source, target, resources, metadata)
                        self.assertNotIsInstance(failure.exception, module.UnattestedOwnedPackageError)
                        retire.assert_not_called()
                        publish.assert_not_called()
                        self.assertEqual(self._stable_staging_state(paths), before)

    def test_invalid_receipt_and_receipt_io_errors_are_not_absence(self) -> None:
        for defect in ("json", "snapshot", "writable", "symlink", "read-io", "stat-io"):
            with self.subTest(defect=defect), tempfile.TemporaryDirectory() as temporary:
                module = load_resource_stager()
                root = pathlib.Path(temporary).resolve()
                source, target, metadata, resources, paths, accepted, receipts = self._receipt_recovery_fixture(root, module)
                stager = module._STAGER
                with mock.patch.dict(os.environ, {
                    "MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE": "shared-view",
                    "MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT": str(receipts),
                    "MACSCOPE_NATIVE_PRIOR_RECEIPT_ROOT": "",
                }), mock.patch.object(stager, "_reused_source_receipt", return_value=accepted):
                    module.stage_xcode_resources(source, target, resources, metadata)
                    receipt = stager._staged_receipt_path(paths["package"])
                    if defect in ("json", "snapshot"):
                        value = json.loads(receipt.read_text())
                        value["snapshot"] = [["broken"]]
                        receipt.chmod(0o600)
                        receipt.write_text("{" if defect == "json" else json.dumps(value))
                        receipt.chmod(0o400)
                    elif defect == "writable":
                        receipt.chmod(0o600)
                    elif defect == "symlink":
                        receipt.unlink()
                        receipt.symlink_to(root / "nonexistent")
                    before = self._stable_staging_state(paths)
                    real_read = pathlib.Path.read_text
                    real_stat = pathlib.Path.lstat
                    io_error = PermissionError("injected receipt I/O failure")

                    def read(path, *args, **kwargs):
                        if path == receipt and defect == "read-io":
                            raise io_error
                        return real_read(path, *args, **kwargs)

                    def inspect(path, *args, **kwargs):
                        if path == receipt and defect == "stat-io":
                            raise io_error
                        return real_stat(path, *args, **kwargs)

                    with mock.patch.object(pathlib.Path, "read_text", new=read), \
                         mock.patch.object(pathlib.Path, "lstat", new=inspect), \
                         mock.patch.object(module, "_retire_owned_state") as retire, \
                         mock.patch.object(stager, "_stage_verified_package_anchored") as publish:
                        with self.assertRaises(module.PackageAdmissionError) as failure:
                            module.stage_xcode_resources(source, target, resources, metadata)
                    if defect.endswith("io"):
                        self.assertIs(failure.exception.__cause__, io_error)
                    self.assertNotIn("absent", str(failure.exception))
                    retire.assert_not_called()
                    publish.assert_not_called()
                    self.assertEqual(self._stable_staging_state(paths), before)

    def test_absent_receipt_recovery_refuses_changes_during_source_admission(self) -> None:
        for changed in ("package", "leaf", "input", "source"):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as temporary:
                module = load_resource_stager()
                root = pathlib.Path(temporary).resolve()
                source, target, metadata, resources, paths, accepted, receipts = self._receipt_recovery_fixture(root, module)
                stager = module._STAGER
                original = stager._open_verified_materialization
                after_mutation = None

                def change_after_source(path, label, **kwargs):
                    nonlocal after_mutation
                    anchor = original(path, label, **kwargs)
                    if pathlib.Path(path) == source:
                        if changed == "package":
                            paths["package"].rename(root / "displaced")
                            shutil.copytree(root / "displaced", paths["package"])
                        else:
                            leaf = (source / "package/lib/libsla.a" if changed == "source"
                                    else paths["package"] / "package/lib/libsla.a" if changed == "leaf"
                                    else paths["input"])
                            replacement = root / "replacement"
                            replacement.write_bytes(leaf.read_bytes())
                            replacement.replace(leaf)
                        after_mutation = self._stable_staging_state(paths)
                    return anchor

                with mock.patch.dict(os.environ, {
                    "MACSCOPE_NATIVE_VERIFICATION_RECEIPT_MODE": "shared-view",
                    "MACSCOPE_NATIVE_SOURCE_IDENTITY_RECEIPT_ROOT": str(receipts),
                    "MACSCOPE_NATIVE_PRIOR_RECEIPT_ROOT": "",
                }), mock.patch.object(stager, "_reused_source_receipt", return_value=accepted), \
                     mock.patch.object(stager, "_open_verified_materialization", side_effect=change_after_source), \
                     mock.patch.object(module, "_retire_owned_state") as retire, \
                     mock.patch.object(stager, "_stage_verified_package_anchored") as publish:
                    with self.assertRaises(module.PackageAdmissionError):
                        module.stage_xcode_resources(source, target, resources, metadata)
                self.assertIsNotNone(after_mutation)
                retire.assert_not_called()
                publish.assert_not_called()
                self.assertEqual(self._stable_staging_state(paths), after_mutation)

    def test_reuse_rejects_hard_links_anywhere_in_source_or_destination_tree(self) -> None:
        for location in ("source", "destination"):
            with self.subTest(location=location), tempfile.TemporaryDirectory() as temporary_directory:
                module = load_resource_stager()
                root = pathlib.Path(temporary_directory)
                source = self._create_verified_source(root)
                target_build, metadata, resources, paths = self._stage_paths(root)
                module.stage_xcode_resources(source, target_build, resources, metadata)
                materialization = source if location == "source" else paths["package"]
                header = materialization / "package/include/sleigh/ghidra/libdecomp.hh"
                alias = root / f"{location}-header-hardlink"
                os.link(header, alias)

                with self.assertRaisesRegex(
                    module.XcodeResourceStageError,
                    "hard-linked|singly linked|closed",
                ):
                    module.stage_xcode_resources(source, target_build, resources, metadata)

                self.assertTrue(alias.is_file())

    def test_reuse_revalidates_live_outputs_after_source_verification(self) -> None:
        for label in ("package", "input", "output", "stamp"):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary_directory:
                module = load_resource_stager()
                root = pathlib.Path(temporary_directory)
                source = self._create_verified_source(root)
                target_build, metadata, resources, paths = self._stage_paths(root)
                module.stage_xcode_resources(source, target_build, resources, metadata)
                original_open = module._STAGER._open_verified_materialization
                mutated = False

                def mutate_after_source_verification(path, description, **kwargs):
                    nonlocal mutated
                    result = original_open(path, description, **kwargs)
                    if pathlib.Path(path) == source and not mutated:
                        target = paths[label]
                        if target.is_dir():
                            shutil.rmtree(target)
                        else:
                            target.unlink()
                        if label == "package":
                            target.mkdir()
                        else:
                            target.write_bytes(b"foreign-live-output\n")
                        mutated = True
                    return result

                with mock.patch.object(
                    module._STAGER,
                    "_open_verified_materialization",
                    side_effect=mutate_after_source_verification,
                ):
                    with self.assertRaises(module.XcodeResourceStageError):
                        module.stage_xcode_resources(source, target_build, resources, metadata)

                self.assertTrue(mutated)

    def test_stamp_publication_rejects_metadata_ancestor_substitution(self) -> None:
        for substitution in ("metadata-parent", "intermediate-ancestor"):
            with self.subTest(substitution=substitution), tempfile.TemporaryDirectory() as temporary_directory:
                module = load_resource_stager()
                root = pathlib.Path(temporary_directory)
                source = self._create_verified_source(root)
                target_build, metadata, resources, paths = self._stage_paths(root)
                original_write = module._STAGER._write_bytes_exclusively
                displaced = root / f"displaced-{substitution}"
                marker = metadata / "foreign-tree-marker"
                preserved_metadata: dict[str, tuple[int, int, bytes]] = {}
                substituted = False

                def substitute_before_stamp(path, parent_descriptor, payload, label):
                    nonlocal substituted
                    if label == "ownership stamp" and not substituted:
                        replaced = (
                            metadata
                            if substitution == "metadata-parent"
                            else metadata.parent
                        )
                        replaced.rename(displaced)
                        metadata.mkdir(parents=True)
                        marker.write_bytes(b"foreign-replacement-tree\n")
                        original_metadata = (
                            displaced
                            if substitution == "metadata-parent"
                            else displaced / metadata.name
                        )
                        for name in (paths["input"].name, paths["output"].name):
                            original = original_metadata / name
                            metadata_fields = original.lstat()
                            preserved_metadata[name] = (
                                metadata_fields.st_dev,
                                metadata_fields.st_ino,
                                original.read_bytes(),
                            )
                        substituted = True
                    return original_write(path, parent_descriptor, payload, label)

                with mock.patch.object(
                    module._STAGER,
                    "_write_bytes_exclusively",
                    side_effect=substitute_before_stamp,
                ):
                    with self.assertRaises(module.XcodeResourceStageError):
                        module.stage_xcode_resources(
                            source,
                            target_build,
                            resources,
                            metadata,
                        )

                self.assertTrue(substituted)
                self.assertEqual(marker.read_bytes(), b"foreign-replacement-tree\n")
                self.assertFalse(
                    paths["stamp"].exists(),
                    "the retained metadata descriptor must not publish into the foreign tree",
                )
                original_metadata = (
                    displaced
                    if substitution == "metadata-parent"
                    else displaced / metadata.name
                )
                self.assertEqual(
                    {
                        name: (
                            (original_metadata / name).lstat().st_dev,
                            (original_metadata / name).lstat().st_ino,
                            (original_metadata / name).read_bytes(),
                        )
                        for name in preserved_metadata
                    },
                    preserved_metadata,
                )
                self.assertTrue((original_metadata / paths["stamp"].name).is_file())
                self.assertEqual(
                    module.verify_materialization(paths["package"]),
                    module.verify_materialization(source),
                )

    def test_wrapper_path_substitution_cannot_publish_into_foreign_tree(self) -> None:
        from Scripts.tests.test_native_decompiler_xpc_package import (  # noqa: PLC0415
            canonical_manifest,
            sleigh_package,
        )

        for substitution in ("resource-parent", "metadata-parent", "source-root"):
            with self.subTest(substitution=substitution), tempfile.TemporaryDirectory() as temporary_directory:
                module = load_resource_stager()
                root = pathlib.Path(temporary_directory)
                source = self._create_verified_source(root)
                target_build, metadata, resources, paths = self._stage_paths(root)
                original_stage = module._STAGER._stage_verified_package_anchored
                if substitution == "resource-parent":
                    replaced = paths["package"].parent
                elif substitution == "metadata-parent":
                    replaced = metadata
                else:
                    replaced = source
                displaced = root / f"displaced-{substitution}"
                marker = None
                replacement_source = None
                replacement_snapshot: dict[str, tuple[int, int, bytes]] = {}
                original_source_identity = module.verify_materialization(source)
                replacement_source_identity = None
                if substitution == "source-root":
                    replacement_root = root / "replacement-fixture"
                    replacement_root.mkdir()
                    replacement_source = self._create_verified_source(replacement_root)
                    (replacement_source / "package/lib/libdecomp.a").write_bytes(
                        b"different-valid-replacement-source\n"
                    )
                    (replacement_source / "MATERIALIZATION.json").write_text(
                        sleigh_package.canonical_json(
                            canonical_manifest(replacement_source / "package")
                        )
                        + "\n",
                        encoding="utf-8",
                    )
                    replacement_source_identity = module.verify_materialization(
                        replacement_source
                    )
                    self.assertNotEqual(
                        replacement_source_identity,
                        original_source_identity,
                    )
                    replacement_snapshot = {
                        path.relative_to(replacement_source).as_posix(): (
                            path.lstat().st_dev,
                            path.lstat().st_ino,
                            path.read_bytes(),
                        )
                        for path in replacement_source.rglob("*")
                        if path.is_file()
                    }
                else:
                    marker = replaced / "foreign-tree-marker"
                substituted = False

                def substitute_before_anchored_package_stager(*args, **kwargs):
                    nonlocal substituted
                    self.assertFalse(substituted)
                    replaced.rename(displaced)
                    if substitution == "source-root":
                        assert replacement_source is not None
                        replacement_source.rename(replaced)
                    else:
                        replaced.mkdir(parents=True)
                        assert marker is not None
                        marker.write_bytes(b"foreign-replacement-tree\n")
                    substituted = True
                    return original_stage(*args, **kwargs)

                with mock.patch.object(
                    module._STAGER,
                    "_stage_verified_package_anchored",
                    side_effect=substitute_before_anchored_package_stager,
                ):
                    with self.assertRaises(module.XcodeResourceStageError):
                        module.stage_xcode_resources(
                            source,
                            target_build,
                            resources,
                            metadata,
                        )

                self.assertTrue(substituted)
                self.assertFalse(paths["package"].exists())
                self.assertFalse(paths["input"].exists())
                self.assertFalse(paths["output"].exists())
                self.assertFalse(paths["stamp"].exists())
                if substitution == "source-root":
                    self.assertEqual(
                        module.verify_materialization(displaced),
                        original_source_identity,
                    )
                    self.assertEqual(
                        module.verify_materialization(replaced),
                        replacement_source_identity,
                    )
                    self.assertEqual(
                        {
                            path.relative_to(replaced).as_posix(): (
                                path.lstat().st_dev,
                                path.lstat().st_ino,
                                path.read_bytes(),
                            )
                            for path in replaced.rglob("*")
                            if path.is_file()
                        },
                        replacement_snapshot,
                    )
                else:
                    assert marker is not None
                    self.assertEqual(marker.read_bytes(), b"foreign-replacement-tree\n")
                    self.assertEqual(list(replaced.iterdir()), [marker])
                if substitution == "resource-parent":
                    self.assertFalse((displaced / paths["package"].name).exists())
                elif substitution == "metadata-parent":
                    self.assertFalse((displaced / paths["input"].name).exists())
                    self.assertFalse((displaced / paths["output"].name).exists())
                    self.assertFalse((displaced / paths["stamp"].name).exists())

    def test_same_identity_from_different_source_root_replaces_stale_owned_lists(self) -> None:
        module = load_resource_stager()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = self._create_verified_source(root)
            target_build, metadata, resources, paths = self._stage_paths(root)
            identity = module.stage_xcode_resources(source, target_build, resources, metadata)
            different_source = root / "different-canonical-root" / "source"
            shutil.copytree(source, different_source)
            self.assertEqual(module.verify_materialization(different_source), identity)
            self.assertIn(str(source.resolve()), paths["input"].read_text(encoding="utf-8"))

            replaced = module.stage_xcode_resources(different_source, target_build, resources, metadata)

            self.assertEqual(replaced, identity)
            self.assertEqual(module.verify_materialization(paths["package"]), identity)
            input_payload = paths["input"].read_text(encoding="utf-8")
            self.assertIn(str(different_source.resolve()), input_payload)
            self.assertNotIn(str(source.resolve()), input_payload)
            self.assertTrue(paths["stamp"].is_file())

    def test_owned_staging_for_a_different_package_is_replaced(self) -> None:
        # A lane DerivedData reused across branches holds this stager's own,
        # stamp-attested set for another package or source; it is retired and
        # republished (read-only package trees included), not refused.
        module = load_resource_stager()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = self._create_verified_source(root)
            target_build, metadata, resources, paths = self._stage_paths(root)
            first = module.stage_xcode_resources(source, target_build, resources, metadata)
            stale_inode = paths["stamp"].lstat().st_ino
            with mock.patch.object(
                module, "_expected_file_list_payloads", return_value=(b"other\n", b"other\n")
            ):
                second = module.stage_xcode_resources(source, target_build, resources, metadata)
            self.assertEqual(second, first)
            self.assertEqual(module.verify_materialization(paths["package"]), second)
            self.assertNotEqual(paths["stamp"].lstat().st_ino, stale_inode)
            self.assertEqual(module.stage_xcode_resources(source, target_build, resources, metadata), first)

    def test_exact_reuse_rejects_source_mutation_after_publication_validation(self) -> None:
        module = load_resource_stager()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = self._create_verified_source(root)
            target_build, metadata, resources, paths = self._stage_paths(root)
            identity = module.stage_xcode_resources(
                source,
                target_build,
                resources,
                metadata,
            )
            before_payloads = {
                path: path.read_bytes()
                for path in (paths["input"], paths["output"], paths["stamp"])
            }
            before_identities = {
                path: (path.lstat().st_dev, path.lstat().st_ino)
                for path in paths.values()
            }
            original_revalidate = module._revalidate_publication_set
            mutated = False

            def mutate_source_after_publication_validation(*args, **kwargs):
                nonlocal mutated
                result = original_revalidate(*args, **kwargs)
                if kwargs.get("label") == "existing owned state" and not mutated:
                    (source / "package/lib/libdecomp.a").write_bytes(
                        b"mutated-after-publication-validation\n"
                    )
                    mutated = True
                return result

            with mock.patch.object(
                module,
                "_revalidate_publication_set",
                side_effect=mutate_source_after_publication_validation,
            ):
                with self.assertRaises(module.XcodeResourceStageError):
                    module.stage_xcode_resources(
                        source,
                        target_build,
                        resources,
                        metadata,
                    )

            self.assertTrue(mutated)
            self.assertEqual(module.verify_materialization(paths["package"]), identity)
            self.assertEqual(
                {
                    path: path.read_bytes()
                    for path in (paths["input"], paths["output"], paths["stamp"])
                },
                before_payloads,
            )
            self.assertEqual(
                {
                    path: (path.lstat().st_dev, path.lstat().st_ino)
                    for path in paths.values()
                },
                before_identities,
            )

    def test_later_metadata_anchor_failure_closes_earlier_anchor(self) -> None:
        module = load_resource_stager()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = self._create_verified_source(root)
            target_build, metadata, resources, paths = self._stage_paths(root)
            module.stage_xcode_resources(source, target_build, resources, metadata)
            original_open = module._open_owned_file_anchor
            first_descriptor: int | None = None
            calls = 0

            def fail_second_anchor(path, label):
                nonlocal calls, first_descriptor
                calls += 1
                if calls == 2:
                    raise module.XcodeResourceStageError(
                        "injected later metadata anchor failure"
                    )
                anchor = original_open(path, label)
                if calls == 1:
                    first_descriptor = anchor[1]
                return anchor

            with mock.patch.object(
                module,
                "_open_owned_file_anchor",
                side_effect=fail_second_anchor,
            ):
                with self.assertRaisesRegex(
                    module.XcodeResourceStageError,
                    "later metadata anchor failure",
                ):
                    module._existing_owned_state(
                        paths["package"],
                        paths["input"],
                        paths["output"],
                        paths["stamp"],
                    )

            self.assertIsNotNone(first_descriptor)
            assert first_descriptor is not None
            try:
                os.fstat(first_descriptor)
            except OSError:
                descriptor_closed = True
            else:
                descriptor_closed = False
                os.close(first_descriptor)
            self.assertTrue(descriptor_closed, "earlier metadata anchor descriptor leaked")

    def test_resource_parent_early_fstat_failure_closes_all_open_descriptors(self) -> None:
        module = load_resource_stager()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            target = root / "target"
            target.mkdir()
            original_dup = os.dup
            original_fstat = os.fstat
            opened_descriptors: list[int] = []

            def fake_open_anchored_directory(path, label):
                descriptor = os.open(path, module._STAGER._directory_open_flags())
                opened_descriptors.append(descriptor)
                return pathlib.Path(path).resolve(), descriptor, os.stat(path)

            def record_duplicate(descriptor):
                duplicate = original_dup(descriptor)
                opened_descriptors.append(duplicate)
                return duplicate

            with mock.patch.object(
                module._STAGER,
                "_open_anchored_directory",
                side_effect=fake_open_anchored_directory,
            ), mock.patch.object(
                module.os,
                "dup",
                side_effect=record_duplicate,
            ), mock.patch.object(
                module.os,
                "fstat",
                side_effect=OSError("injected early fstat failure"),
            ):
                with self.assertRaises(Exception):
                    module._resource_parent(
                        target,
                        pathlib.PurePosixPath("Contents/Resources"),
                    )

            leaked = []
            for descriptor in set(opened_descriptors):
                try:
                    original_fstat(descriptor)
                except OSError:
                    continue
                leaked.append(descriptor)
                os.close(descriptor)
            self.assertFalse(leaked, f"resource parent leaked descriptors: {leaked}")

    def test_initial_directory_anchor_rejects_resolve_time_symlink_substitution(self) -> None:
        module = load_resource_stager()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            requested = root / "requested"
            requested.mkdir()
            outside = root / "outside"
            outside.mkdir()
            original_resolve = module.Path.resolve
            substituted = False

            def substitute_during_resolve(path, *arguments, **keywords):
                nonlocal substituted
                if pathlib.Path(path) == requested and not substituted:
                    requested.rmdir()
                    requested.symlink_to(outside, target_is_directory=True)
                    substituted = True
                return original_resolve(path, *arguments, **keywords)

            with mock.patch.object(
                module.Path,
                "resolve",
                new=substitute_during_resolve,
            ):
                with self.assertRaisesRegex(module.XcodeResourceStageError, "changed|unsafe"):
                    module._ordinary_directory(requested, "requested directory")

            self.assertTrue(substituted)

    def test_xcode_phase_python_scripts_execute_at_python_39_compatibility_floor(self) -> None:
        module = load_resource_stager()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = self._create_verified_source(root)
            target_build, metadata, resources, paths = self._stage_paths(root)
            command = [
                "/usr/bin/python3",
                str(RESOURCE_STAGER),
                "--source-materialization-root",
                str(source),
                "--target-build-dir",
                str(target_build),
                "--unlocalized-resources-folder-path",
                resources.as_posix(),
                "--metadata-directory",
                str(metadata),
            ]
            version_result = subprocess.run(
                [
                    "/usr/bin/python3",
                    "-c",
                    "import json,sys; print(json.dumps(list(sys.version_info[:2])))",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(version_result.returncode, 0, version_result.stderr)
            system_version = tuple(json.loads(version_result.stdout))
            self.assertGreaterEqual(system_version, (3, 9))
            compatibility_sources = (
                RESOURCE_STAGER,
                GOLDEN_FILESYSTEM,
                ROOT / "Scripts/native-decompiler-xpc/native_decompiler_source_identity.py",
                ROOT / "Scripts/native-decompiler-xpc/stage_verified_package.py",
                ROOT / "Scripts/generate_release_build_provenance.py",
                ROOT / "Scripts/check_local_signing_policy.py",
            )
            compatibility_program = (
                "import ast,pathlib,sys;"
                "[ast.parse(pathlib.Path(p).read_bytes(), filename=p, feature_version=(3,9)) "
                "for p in sys.argv[1:]]"
            )
            compatibility_result = subprocess.run(
                [
                    "/usr/bin/python3",
                    "-c",
                    compatibility_program,
                    *(str(path) for path in compatibility_sources),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(
                compatibility_result.returncode,
                0,
                compatibility_result.stderr,
            )
            for invocation in (1, 2):
                result = subprocess.run(command, capture_output=True, text=True, check=False)
                self.assertEqual(
                    result.returncode,
                    0,
                    f"system Python staging invocation {invocation} failed: {result.stderr}",
                )
            self.assertEqual(
                module.verify_materialization(paths["package"]),
                json.loads((source / "MATERIALIZATION.json").read_text(encoding="utf-8")),
            )
            for script in (
                ROOT / "Scripts/generate_release_build_provenance.py",
                ROOT / "Scripts/check_local_signing_policy.py",
            ):
                result = subprocess.run(
                    ["/usr/bin/python3", str(script), "--help"],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_predeclared_lists_stage_once_and_reject_mismatch_or_swap(self) -> None:
        for scenario in ("valid", "mismatch", "swap"):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as temporary:
                module = load_resource_stager()
                root = pathlib.Path(temporary).resolve()
                source = self._create_verified_source(root)
                target, metadata, resources, paths = self._stage_paths(root)
                relative = sorted(p.relative_to(source) for p in source.rglob("*") if p.is_file())
                for key, base in (("input", source), ("output", paths["package"])):
                    paths[key].write_text("".join(str(base / p) + "\n" for p in relative))
                original_lists = {k: paths[k].read_bytes() for k in ("input", "output")}
                if scenario == "mismatch":
                    paths["output"].write_text("/unowned/package\n")
                stage = module._STAGER._stage_verified_package_anchored

                def publish(*args, **kwargs):
                    if scenario == "swap":
                        replacement = metadata / "replacement"
                        replacement.write_bytes(paths["input"].read_bytes())
                        replacement.replace(paths["input"])
                    return stage(*args, **kwargs)

                with mock.patch.object(module._STAGER, "_stage_verified_package_anchored",
                                       side_effect=publish):
                    if scenario == "valid":
                        result = module.stage_xcode_resources(source, target, resources, metadata)
                        self.assertEqual(result, json.loads((source / "MATERIALIZATION.json").read_text()))
                        self.assertTrue(paths["package"].is_dir())
                        self.assertTrue(paths["stamp"].is_file())
                        for key, payload in original_lists.items():
                            self.assertEqual(paths[key].read_bytes(), payload)
                    else:
                        with self.assertRaises(module.XcodeResourceStageError):
                            module.stage_xcode_resources(source, target, resources, metadata)
                        self.assertFalse(paths["stamp"].exists())
                        if scenario == "mismatch":
                            self.assertFalse(paths["package"].exists())
                            self.assertEqual(paths["output"].read_text(), "/unowned/package\n")

    def test_resource_stager_recovers_after_xcode_cleans_product_but_retains_owned_metadata(self) -> None:
        module = load_resource_stager()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = self._create_verified_source(root)
            target_build, metadata, resources, paths = self._stage_paths(root)
            first = module.stage_xcode_resources(source, target_build, resources, metadata)

            shutil.rmtree(paths["package"])
            self.assertFalse(paths["package"].exists())
            self.assertTrue(paths["stamp"].is_file())

            second = module.stage_xcode_resources(source, target_build, resources, metadata)

            self.assertEqual(second, first)
            self.assertEqual(module.verify_materialization(paths["package"]), first)
            self.assertTrue(paths["stamp"].is_file())
            self.assertFalse(
                any(path.name.startswith(".NativeDecompilerRetired-") for path in metadata.iterdir())
            )

    def test_metadata_only_recovery_rejects_changed_metadata_without_mutation(self) -> None:
        module = load_resource_stager()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = self._create_verified_source(root)
            target_build, metadata, resources, paths = self._stage_paths(root)
            module.stage_xcode_resources(source, target_build, resources, metadata)
            shutil.rmtree(paths["package"])
            paths["input"].write_bytes(b"foreign-metadata\n")
            before = {
                path: (path.lstat().st_dev, path.lstat().st_ino, path.read_bytes())
                for path in (paths["input"], paths["output"], paths["stamp"])
            }

            with mock.patch.object(
                module.os,
                "unlink",
                side_effect=AssertionError("metadata-only state must not be unlinked"),
            ), mock.patch.object(
                module.os,
                "rmdir",
                side_effect=AssertionError("metadata-only state must not be removed"),
            ):
                with self.assertRaisesRegex(
                    module.XcodeResourceStageError,
                    "Xcode Clean|fresh|ownership stamp",
                ):
                    module.stage_xcode_resources(source, target_build, resources, metadata)

            self.assertFalse(paths["package"].exists())
            self.assertEqual(
                {
                    path: (path.lstat().st_dev, path.lstat().st_ino, path.read_bytes())
                    for path in (paths["input"], paths["output"], paths["stamp"])
                },
                before,
            )

    def test_partial_live_state_fails_unchanged_without_cleanup_mutations(self) -> None:
        for label in ("package", "input", "output", "stamp"):
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary_directory:
                module = load_resource_stager()
                root = pathlib.Path(temporary_directory)
                source = self._create_verified_source(root)
                target_build, metadata, resources, paths = self._stage_paths(root)
                target = paths[label]
                if label == "package":
                    target.mkdir(parents=True)
                    marker = target / "foreign-marker"
                else:
                    marker = target
                marker.write_bytes(b"foreign-partial-state\n")
                before = (marker.lstat().st_dev, marker.lstat().st_ino, marker.read_bytes())

                with mock.patch.object(
                    module,
                    "_move_exclusively",
                    side_effect=AssertionError("partial state must never be renamed"),
                    create=True,
                ), mock.patch.object(
                    module.os,
                    "unlink",
                    side_effect=AssertionError("partial state must never be unlinked"),
                ), mock.patch.object(
                    module.os,
                    "rmdir",
                    side_effect=AssertionError("partial state must never be removed"),
                ):
                    with self.assertRaisesRegex(
                        module.XcodeResourceStageError,
                        "Xcode Clean|fresh|complete staging set|owned",
                    ):
                        module.stage_xcode_resources(
                            source,
                            target_build,
                            resources,
                            metadata,
                        )

                self.assertEqual(
                    (marker.lstat().st_dev, marker.lstat().st_ino, marker.read_bytes()),
                    before,
                )

    def test_fresh_empty_parents_publish_through_direct_exclusive_creation(self) -> None:
        module = load_resource_stager()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = self._create_verified_source(root)
            target_build, metadata, resources, paths = self._stage_paths(root)
            with mock.patch.object(
                module._STAGER,
                "_write_bytes_exclusively",
                wraps=module._STAGER._write_bytes_exclusively,
            ) as exclusive_write:
                identity = module.stage_xcode_resources(
                    source,
                    target_build,
                    resources,
                    metadata,
                )

            self.assertEqual(exclusive_write.call_count, 3)
            self.assertEqual(module.verify_materialization(paths["package"]), identity)
            self.assertTrue(paths["input"].is_file())
            self.assertTrue(paths["output"].is_file())
            self.assertTrue(paths["stamp"].is_file())

    def test_resource_stager_never_replaces_an_unowned_destination(self) -> None:
        module = load_resource_stager()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "source"
            source.mkdir()
            target_build = root / "Build" / "Products" / "Service.xpc"
            destination = target_build / "Contents/Resources/NativeDecompilerPackage"
            destination.mkdir(parents=True)
            marker = destination / "foreign.txt"
            marker.write_text("do not remove\n", encoding="utf-8")
            metadata = root / "Build" / "Intermediates" / "Service"
            metadata.mkdir(parents=True)

            with self.assertRaisesRegex(
                module.XcodeResourceStageError,
                "Xcode Clean|fresh|owned",
            ):
                module.stage_xcode_resources(
                    source,
                    target_build,
                    pathlib.PurePosixPath("Contents/Resources"),
                    metadata,
                )

            self.assertEqual(marker.read_text(encoding="utf-8"), "do not remove\n")

    def test_resource_stager_does_not_follow_a_product_path_symlink(self) -> None:
        module = load_resource_stager()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = root / "source"
            source.mkdir()
            target_build = root / "Build" / "Products"
            target_build.mkdir(parents=True)
            outside = root / "outside"
            outside.mkdir()
            (target_build / "NativeDecompilerXPCService.xpc").symlink_to(
                outside,
                target_is_directory=True,
            )
            metadata = root / "Build" / "Intermediates" / "Service"
            metadata.mkdir(parents=True)

            with self.assertRaisesRegex(module.XcodeResourceStageError, "ordinary"):
                module.stage_xcode_resources(
                    source,
                    target_build,
                    pathlib.PurePosixPath(
                        "NativeDecompilerXPCService.xpc/Contents/Resources"
                    ),
                    metadata,
                )

            self.assertFalse((outside / "Contents").exists())

    def test_complete_owned_state_for_a_different_package_is_replaced(self) -> None:
        from Scripts.tests.test_native_decompiler_xpc_package import (  # noqa: PLC0415
            canonical_manifest,
            sleigh_package,
        )

        module = load_resource_stager()
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = pathlib.Path(temporary_directory)
            source = self._create_verified_source(root)
            different_root = root / "different"
            different_root.mkdir()
            different_source = self._create_verified_source(different_root)
            (different_source / "package/lib/libdecomp.a").write_bytes(b"different\n")
            (different_source / "MATERIALIZATION.json").write_text(
                sleigh_package.canonical_json(
                    canonical_manifest(different_source / "package")
                )
                + "\n",
                encoding="utf-8",
            )
            target_build = root / "Build" / "Products"
            target_build.mkdir(parents=True)
            metadata = root / "Build" / "Intermediates" / "Service"
            metadata.mkdir(parents=True)
            resources = pathlib.PurePosixPath(
                "NativeDecompilerXPCService.xpc/Contents/Resources"
            )

            identity = module.stage_xcode_resources(
                source,
                target_build,
                resources,
                metadata,
            )
            stamp = metadata / "NativeDecompilerPackage.stage.json"
            input_list = metadata / "NativeDecompilerPackage.inputs.xcfilelist"
            output_list = metadata / "NativeDecompilerPackage.outputs.xcfilelist"
            before = (stamp.read_bytes(), input_list.read_bytes(), output_list.read_bytes())
            destination = (
                target_build
                / "NativeDecompilerXPCService.xpc/Contents/Resources/NativeDecompilerPackage"
            )
            before_identities = {
                path: (path.lstat().st_dev, path.lstat().st_ino)
                for path in (destination, stamp, input_list, output_list)
            }

            # Cross-branch DerivedData reuse: this stager's own complete set for
            # another package is retired and the new package published.
            replaced = module.stage_xcode_resources(
                different_source,
                target_build,
                resources,
                metadata,
            )

            self.assertNotEqual(replaced, identity)
            self.assertEqual(module.verify_materialization(destination), replaced)
            self.assertEqual((destination / "package/lib/libdecomp.a").read_bytes(), b"different\n")
            self.assertNotEqual(
                (stamp.read_bytes(), input_list.read_bytes(), output_list.read_bytes()),
                before,
            )
            self.assertNotEqual(stamp.lstat().st_ino, before_identities[stamp][1])
            self.assertEqual(
                module.stage_xcode_resources(different_source, target_build, resources, metadata),
                replaced,
            )

if __name__ == "__main__":
    unittest.main()
