"""Portable physical tests for the owned native golden producer."""

from __future__ import annotations

import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
PRODUCER = ROOT / "Scripts/native-decompiler-xpc/run_gatef_native_golden.py"
VALIDATOR = ROOT / "Scripts/native-decompiler-xpc/native_golden_evidence.py"


def load(path):
    if not path.is_file():
        raise AssertionError(f"missing native golden implementation: {path.name}")
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def canonical(value):
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class GoldenFixture:
    """Synthetic expensive producers, using real files and the real stager."""

    def __init__(self, root, module):
        self.root, self.module = root, module
        self.parent = root / "run/native-work"
        self.normal = self.parent / "normal"
        self.work = self.parent / "golden"
        self.source = root / "dependency"
        self.developer = root / "Developer"
        self.sdk = self.developer / "SDKs/MacOSX27.2.sdk"
        self.calls = []
        self.mutation = None
        self.failure = False
        self.wrapper_digest = "a" * 64
        self.golden_digest = "b" * 64
        for path, data in (
            (self.source / "package/lib/libdecomp.a", b"decomp"),
            (self.source / "package/lib/libsla.a", b"sleigh"),
            (self.normal / "libmacscope_native_decompiler_contract.a", b"contract"),
            (self.normal / "generated/MacScopeNativeDecompiler/GhidraBuildIdentity.hpp", b"identity"),
            (self.normal / "CMakeCache.txt", b"cache"),
            (self.sdk / "SDKSettings.json", b"{}\n"),
            (self.sdk / "usr/lib/libz.tbd", b"zlib"),
            (self.sdk / "usr/lib/libc++.tbd", b"cxx"),
            (self.developer / "usr/bin/xcodebuild", b"xcode"),
            *[(self.developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin" / name, name.encode())
              for name in ("swiftc", "clang++", "lipo")],
        ):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.manifest = {"package": {"treeSha256": "c" * 64}}
        (self.source / "MATERIALIZATION.json").write_bytes(canonical(self.manifest))
        self.argv = ["--source-materialization-root", str(self.source),
                     "--native-archive-root", str(self.normal), "--work-root", str(self.work),
                     "--developer-dir", str(self.developer), "--sdk-root", str(self.sdk),
                     "--sdk-name", "macosx27.2"]

    def result_payload(self, result, stamp, materialization):
        outcome_keys = ("objcMappingSHA256", "objcReplySHA256", "objcRequestSHA256",
                        "packageBackedReplySHA256", "packageBackedRequestSHA256",
                        "packageBackedSwiftReplySHA256", "swiftReplySHA256")
        return {**{key: "d" * 64 for key in outcome_keys},
            "architecture": "arm64", "deploymentTarget": "27.0",
            "backendID": "ghidra-native-decompiler", "engineVersion": "12.1.2",
            "engineGitRevision": "c0f584bf229fffba61b36431f3ce30c0c3e4e682",
            "wrapperVersion": "dcp05c-v1", "wrapperGitRevision": self.wrapper_digest,
            "goldenSourceSHA256": self.golden_digest, "passed": True, "schemaVersion": 1,
            "xcodeVersion": "27.2", "xcodeBuild": "27C100", "sdkName": "macosx27.2",
            "sdkVersion": "27.2", "sdkBuild": "27C99", "swiftCompilerVersion": "6.4",
            "swiftTargetTriple": "arm64-apple-macosx27.2.0",
            "contractArchiveSHA256": digest(self.normal / "libmacscope_native_decompiler_contract.a"),
            "contractBuildIdentitySHA256": digest(self.normal / "generated/MacScopeNativeDecompiler/GhidraBuildIdentity.hpp"),
            "decompilerArchiveSHA256": digest(materialization / "package/lib/libdecomp.a"),
            "sleighArchiveSHA256": digest(materialization / "package/lib/libsla.a"),
            "stageStampSHA256": digest(stamp), "materializationTreeSHA256": "c" * 64,
            "materializationManifestSHA256": digest(materialization / "MATERIALIZATION.json")}

    def command(self, command, **kwargs):
        self.calls.append(command)
        executable = Path(command[0]).name
        if "stage_xcode_resources.py" in [Path(value).name for value in command]:
            def arg(name):
                return command[command.index(name) + 1]
            self.module._STAGE.stage_xcode_resources(
                Path(arg("--source-materialization-root")), Path(arg("--target-build-dir")),
                Path(arg("--unlocalized-resources-folder-path")), Path(arg("--metadata-directory")))
            return subprocess.CompletedProcess(command, 0)
        if executable == "bash":
            def arg(name):
                return Path(command[command.index(name) + 1])
            result, stamp, materialization = arg("--result"), arg("--stage-stamp"), arg("--materialization-root")
            payload = self.result_payload(result, stamp, materialization)
            if self.mutation:
                self.mutation(payload, stamp, materialization)
            if not result.exists():
                result.write_bytes(canonical(payload))
            print("generic passed text from expensive producer")
            return subprocess.CompletedProcess(command, 17 if self.failure else 0)
        if executable == "xcodebuild":
            output = "Xcode 27.2\nBuild version 27C100\n"
            if command[-1] == "SDKVersion": output = "27.2\n"
            if command[-1] == "ProductBuildVersion": output = "27C99\n"
        elif executable == "swiftc":
            output = "Apple Swift version 6.4 (fixture)\nTarget: arm64-apple-macosx27.2.0\n"
        else:
            raise AssertionError(f"unexpected expensive command {command}")
        return subprocess.CompletedProcess(command, 0, output, "")

    @contextlib.contextmanager
    def seams(self):
        # The package verifier is the only unavailable dependency: these bytes
        # deliberately are not the pinned native package. Staging stays real.
        with mock.patch.object(self.module._STAGE._STAGER, "verify_materialization",
                               side_effect=lambda path, **kw: json.loads((path / "MATERIALIZATION.json").read_bytes())), \
             mock.patch.object(self.module._IDENTITY, "profile_digest",
                               side_effect=lambda root, profile: self.wrapper_digest if profile == "wrapper" else self.golden_digest):
            yield

    def run(self):
        output = io.StringIO()
        with self.seams(), contextlib.redirect_stdout(output):
            code = self.module.main(self.argv, command_runner=self.command)
        return code, output.getvalue()


class NativeGoldenProducerTests(unittest.TestCase):
    def test_golden_compiled_wire_source_mutation_prevents_final_marker(self):
        module = load(PRODUCER)
        for name in ("NativeDecompilerWireTargetProfile.swift", "NativeDecompilerWireAuthoredModels.swift",
                     "NativeDecompilerWireCanonicalRequest.swift"):
            with self.subTest(source=name), tempfile.TemporaryDirectory() as directory:
                fixture = GoldenFixture(Path(directory).resolve(), module)
                repository = fixture.root / "repository"
                relative = "MacScope/Models/NativeDecompilerWire/" + name
                paths = set(module._IDENTITY.profile_paths(ROOT, "golden")) | {relative}
                paths.update("Scripts/native-decompiler-xpc/" + script for script in (
                    "run_gatef_native_golden.py", "native_golden_evidence.py", "stage_xcode_resources.py"))
                for path in paths:
                    destination = repository / path
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(ROOT / path, destination)
                def mutate(*args):
                    (repository / relative).write_bytes(b"changed compiled source\n")
                fixture.mutation = mutate
                with mock.patch.object(module, "REPOSITORY_ROOT", repository), \
                     mock.patch.object(module, "SCRIPT_ROOT", repository / "Scripts/native-decompiler-xpc"):
                    code, output = fixture.run()
                self.assertTrue(any(Path(call[0]).name == "bash" for call in fixture.calls))
                self.assertEqual(code, 1)
                self.assertNotIn("MACSCOPE_NATIVE_GOLDEN_", output)

    def test_selected_xcode_declared_tool_aliases_bind_link_and_executable(self):
        module = load(PRODUCER)
        for mutation in (None, "escape", "wrong-target", "target-link", "hardlink", "retarget", "replace-link", "change-target"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                fixture = GoldenFixture(Path(directory).resolve(), module)
                tools = fixture.developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin"
                for name, target in (("swiftc", "swift-frontend"), ("clang++", "clang")):
                    (tools / name).unlink()
                    (tools / target).write_bytes(target.encode())
                    (tools / name).symlink_to(target)
                if mutation == "escape":
                    (tools / "swiftc").unlink()
                    (tools / "swiftc").symlink_to("../bin/swift-frontend")
                elif mutation == "wrong-target":
                    (tools / "swiftc").unlink()
                    (tools / "swiftc").symlink_to("clang")
                elif mutation == "target-link":
                    (tools / "swift-frontend").unlink()
                    (tools / "swift-frontend").symlink_to("clang")
                elif mutation == "hardlink":
                    (tools / "swift-frontend").unlink()
                    os.link(tools / "clang", tools / "swift-frontend")
                elif mutation in ("retarget", "replace-link", "change-target"):
                    def mutate(*args):
                        if mutation == "change-target":
                            (tools / "swift-frontend").write_bytes(b"changed compiler")
                        else:
                            alias = tools / "swiftc"
                            replacement = tools / "replacement"
                            replacement.symlink_to("clang" if mutation == "retarget" else "swift-frontend")
                            replacement.replace(alias)
                    fixture.mutation = mutate
                code, output = fixture.run()
                self.assertEqual(code, 0 if mutation is None else 1)
                if mutation is not None:
                    self.assertNotIn("MACSCOPE_NATIVE_GOLDEN_", output)

    def test_owned_directory_substitution_before_staging_preserves_foreign_tree(self):
        module = load(PRODUCER)
        for name in ("products", "metadata", "stage"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                fixture = GoldenFixture(Path(directory).resolve(), module)
                foreign = fixture.root / "foreign"
                foreign.mkdir()
                (foreign / "sentinel").write_bytes(b"foreign")
                target = fixture.work / ("metadata/stage" if name == "stage" else name)
                original_mkdir = os.mkdir
                replaced = []
                def replace_after_mkdir(path, *args, **kwargs):
                    value = original_mkdir(path, *args, **kwargs)
                    if Path(path).name == name and target.exists():
                        target.rename(fixture.root / ("owned-" + name))
                        foreign.rename(target)
                        replaced.append(target)
                    return value
                with mock.patch.object(module.os, "mkdir", side_effect=replace_after_mkdir):
                    code, output = fixture.run()
                self.assertTrue(replaced)
                self.assertEqual(code, 1)
                self.assertNotIn("MACSCOPE_NATIVE_GOLDEN_", output)
                self.assertFalse(any("stage_xcode_resources.py" in [Path(x).name for x in call] for call in fixture.calls))
                self.assertEqual(sorted(path.name for path in target.iterdir()), ["sentinel"])

    def test_stage_directory_substitution_prevents_golden_execution(self):
        module = load(PRODUCER)
        with tempfile.TemporaryDirectory() as directory:
            fixture = GoldenFixture(Path(directory).resolve(), module)
            original = fixture.command
            def command(argv, **kwargs):
                completed = original(argv, **kwargs)
                if "stage_xcode_resources.py" in [Path(x).name for x in argv]:
                    stage = fixture.work / "metadata/stage"
                    stage.rename(fixture.root / "owned-stage")
                    shutil.copytree(fixture.root / "owned-stage", stage)
                return completed
            fixture.command = command
            code, output = fixture.run()
            self.assertEqual(code, 1)
            self.assertNotIn("MACSCOPE_NATIVE_GOLDEN_", output)
            self.assertFalse(any(Path(call[0]).name == "bash" for call in fixture.calls))

    def test_new_directory_entry_substitution_before_open_rejected(self):
        module = load(PRODUCER)
        with tempfile.TemporaryDirectory() as directory:
            fixture = GoldenFixture(Path(directory).resolve(), module)
            original_stat = os.stat
            substituted = []
            def substitute_after_stat(path, *args, **kwargs):
                value = original_stat(path, *args, **kwargs)
                if path == "products" and kwargs.get("dir_fd") is not None and not substituted:
                    products = fixture.work / "products"
                    products.rename(fixture.root / "owned-products")
                    products.mkdir(mode=0o700)
                    substituted.append(products)
                return value
            with mock.patch.object(module.os, "stat", side_effect=substitute_after_stat):
                code, output = fixture.run()
            self.assertTrue(substituted)
            self.assertEqual(code, 1)
            self.assertEqual(list(substituted[0].iterdir()), [])
            self.assertNotIn("MACSCOPE_NATIVE_GOLDEN_", output)

    def test_final_result_read_parent_substitution_prevents_publication(self):
        module = load(PRODUCER)
        with tempfile.TemporaryDirectory() as directory:
            fixture = GoldenFixture(Path(directory).resolve(), module)
            original_read = module._STAGE._read_stable_bytes
            reads = []
            def replace_after_final_read(path, *args):
                payload = original_read(path, *args)
                if path.name == "NativeDecompilerBridgeGolden.json":
                    reads.append(path)
                    if len(reads) == 2:
                        products = fixture.work / "products"
                        products.rename(fixture.root / "owned-products")
                        products.symlink_to(fixture.root / "owned-products", target_is_directory=True)
                return payload
            with mock.patch.object(module._STAGE, "_read_stable_bytes", side_effect=replace_after_final_read):
                code, output = fixture.run()
            self.assertEqual(len(reads), 2)
            self.assertEqual(code, 1)
            self.assertNotIn("MACSCOPE_NATIVE_GOLDEN_", output)

    def test_final_tool_probe_mutation_prevents_publication(self):
        module = load(PRODUCER)
        with tempfile.TemporaryDirectory() as directory:
            fixture = GoldenFixture(Path(directory).resolve(), module)
            original_command = fixture.command
            probes = []
            def mutate_after_final_probe(command, **kwargs):
                completed = original_command(command, **kwargs)
                if Path(command[0]).name == "swiftc":
                    probes.append(command)
                    if len(probes) == 2:
                        (fixture.sdk / "SDKSettings.json").write_bytes(b"changed SDK")
                return completed
            fixture.command = mutate_after_final_probe
            code, output = fixture.run()
            self.assertEqual(len(probes), 2)
            self.assertEqual(code, 1)
            self.assertNotIn("MACSCOPE_NATIVE_GOLDEN_", output)

    def test_same_byte_result_replacement_prevents_publication(self):
        module = load(PRODUCER)
        with tempfile.TemporaryDirectory() as directory:
            fixture = GoldenFixture(Path(directory).resolve(), module)
            original = module._EVIDENCE.validate_golden_payload
            def replace_after_validation(payload, **kwargs):
                value = original(payload, **kwargs)
                result = fixture.work / "products/NativeDecompilerBridgeGolden.json"
                replacement = result.with_suffix(".replacement")
                replacement.write_bytes(payload)
                replacement.replace(result)
                return value
            with mock.patch.object(module._EVIDENCE, "validate_golden_payload", side_effect=replace_after_validation):
                code, output = fixture.run()
            self.assertEqual(code, 1)
            self.assertNotIn("MACSCOPE_NATIVE_GOLDEN_", output)

    def test_wrapper_stages_before_one_golden_execution(self):
        module = load(PRODUCER)
        with tempfile.TemporaryDirectory() as directory:
            fixture = GoldenFixture(Path(directory).resolve(), module)
            code, output = fixture.run()
            self.assertEqual(code, 0)
            staging = [call for call in fixture.calls if "stage_xcode_resources.py" in [Path(x).name for x in call]]
            golden = [call for call in fixture.calls if Path(call[0]).name == "bash"]
            self.assertEqual(len(staging), 1)
            self.assertEqual(len(golden), 1)
            self.assertLess(fixture.calls.index(staging[0]), fixture.calls.index(golden[0]))
            stage_command = staging[0]
            self.assertEqual(stage_command[stage_command.index("--target-build-dir") + 1], str(fixture.work / "products"))
            self.assertEqual(stage_command[stage_command.index("--unlocalized-resources-folder-path") + 1], "NativeGate/Contents/Resources")
            self.assertEqual(stage_command[stage_command.index("--metadata-directory") + 1], str(fixture.work / "metadata/stage"))
            golden_command = golden[0]
            expected = {
                "--stage-stamp": fixture.work / "metadata/stage/NativeDecompilerPackage.stage.json",
                "--materialization-root": fixture.work / "products/NativeGate/Contents/Resources/NativeDecompilerPackage",
                "--project-temp-dir": fixture.parent,
                "--build-root": fixture.work / "metadata/build",
                "--result": fixture.work / "products/NativeDecompilerBridgeGolden.json",
                "--native-archive-root": fixture.normal,
            }
            for option, path in expected.items():
                self.assertEqual(golden_command[golden_command.index(option) + 1], str(path))
            markers = [line for line in output.splitlines() if line.startswith("MACSCOPE_NATIVE_GOLDEN_")]
            self.assertEqual(markers, [
                "MACSCOPE_NATIVE_GOLDEN_RESULT=" + str(expected["--result"]),
                "MACSCOPE_NATIVE_GOLDEN_STAGE_STAMP=" + str(expected["--stage-stamp"]),
                "MACSCOPE_NATIVE_GOLDEN_MATERIALIZATION=" + str(expected["--materialization-root"])])

    def test_golden_input_parent_alias_or_preexisting_root_rejected(self):
        module = load(PRODUCER)
        for mutation in ("external", "preexisting", "parent-alias", "archive-link", "source-alias"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                fixture = GoldenFixture(Path(directory).resolve(), module)
                sentinel = fixture.root / "sentinel"
                sentinel.write_bytes(b"foreign")
                if mutation == "external":
                    fixture.argv[fixture.argv.index("--native-archive-root") + 1] = str(fixture.source)
                elif mutation == "preexisting":
                    fixture.work.mkdir()
                    (fixture.work / "foreign").write_bytes(b"foreign")
                elif mutation == "parent-alias":
                    alias = fixture.root / "alias"
                    alias.symlink_to(fixture.parent, target_is_directory=True)
                    fixture.argv[fixture.argv.index("--work-root") + 1] = str(alias / "golden")
                elif mutation == "archive-link":
                    archive = fixture.normal / "libmacscope_native_decompiler_contract.a"
                    archive.unlink()
                    os.link(sentinel, archive)
                else:
                    alias = fixture.root / "source-alias"
                    alias.symlink_to(fixture.source, target_is_directory=True)
                    fixture.argv[fixture.argv.index("--source-materialization-root") + 1] = str(alias)
                code, output = fixture.run()
                self.assertNotEqual(code, 0)
                self.assertNotIn("MACSCOPE_NATIVE_GOLDEN_", output)
                self.assertFalse(any(Path(call[0]).name == "bash" for call in fixture.calls))
                self.assertEqual(sentinel.read_bytes(), b"foreign")
                if mutation == "preexisting": self.assertEqual((fixture.work / "foreign").read_bytes(), b"foreign")
                else: self.assertFalse(fixture.work.exists())

    def test_golden_stage_or_result_mutation_prevents_marker(self):
        module = load(PRODUCER)
        mutations = {
            "backend": lambda payload, stamp, materialization: payload.update(backendID="wrong"),
            "wrapper": lambda payload, stamp, materialization: payload.update(wrapperGitRevision="e" * 64),
            "golden": lambda payload, stamp, materialization: payload.update(goldenSourceSHA256="e" * 64),
            "stamp": lambda payload, stamp, materialization: stamp.write_bytes(b"{}\n"),
            "stage": lambda payload, stamp, materialization: (materialization / "package/lib/libdecomp.a").write_bytes(b"changed"),
            "schema-bool": lambda payload, stamp, materialization: payload.update(schemaVersion=True),
            "failed-payload": lambda payload, stamp, materialization: payload.update(passed=False),
        }
        for name in (*mutations, "archive", "toolchain", "source", "noncanonical", "foreign-result", "failed-process"):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                fixture = GoldenFixture(Path(directory).resolve(), module)
                if name in mutations: fixture.mutation = mutations[name]
                if name == "archive": fixture.mutation = lambda *args: (fixture.normal / "libmacscope_native_decompiler_contract.a").write_bytes(b"changed")
                if name == "toolchain": fixture.mutation = lambda *args: (fixture.sdk / "SDKSettings.json").write_bytes(b"changed")
                if name == "source": fixture.mutation = lambda *args: setattr(fixture, "golden_digest", "e" * 64)
                if name == "noncanonical": fixture.mutation = lambda payload, *args: (fixture.work / "products/NativeDecompilerBridgeGolden.json").write_text(json.dumps(payload))
                if name == "foreign-result":
                    foreign = fixture.root / "foreign-result.json"
                    foreign.write_bytes(b"foreign")
                    fixture.mutation = lambda *args: (fixture.work / "products/NativeDecompilerBridgeGolden.json").symlink_to(foreign)
                fixture.failure = name == "failed-process"
                code, output = fixture.run()
                self.assertNotEqual(code, 0)
                self.assertNotIn("MACSCOPE_NATIVE_GOLDEN_", output)
                if name == "foreign-result": self.assertEqual(foreign.read_bytes(), b"foreign")

    def test_payload_requires_closed_canonical_success(self):
        validator = load(VALIDATOR)
        module = load(PRODUCER)
        with tempfile.TemporaryDirectory() as directory:
            fixture = GoldenFixture(Path(directory).resolve(), module)
            code, _ = fixture.run()
            self.assertEqual(code, 0)
            result = fixture.work / "products/NativeDecompilerBridgeGolden.json"
            value = json.loads(result.read_bytes())
            expected = {key: value[key] for key in validator.IDENTITY_KEYS}
            self.assertEqual(validator.validate_golden_payload(result.read_bytes(), expected_identity=expected), value)
            for payload in (canonical({**value, "extra": True}), canonical({**value, "schemaVersion": True}),
                            canonical({**value, "passed": False}), b'{"passed":true,"passed":true}\n',
                            json.dumps(value).encode()):
                with self.assertRaises(validator.GoldenEvidenceError):
                    validator.validate_golden_payload(payload, expected_identity=expected)


if __name__ == "__main__":
    unittest.main()
