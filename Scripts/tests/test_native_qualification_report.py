"""Build-free native producer tests using actual subprocesses and retained files."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "Scripts/tests"), str(ROOT / "Scripts/native-decompiler-direct"),
                str(ROOT / "Scripts/native-decompiler-xpc"), str(ROOT)]
from test_sleigh_native_package import SleighPackageFixture, sleigh_package
from Scripts.lib.work_root import existing_work_root, work_root as macscope_work_root

PREFIX = "macscope_native_decompiler_"
PLAIN = ("contract_tests", "canonical_request_tests", "provider_tests",
         "ghidra_package_identity_tests", "opcode_vocabulary_binding_tests",
         "ghidra_provider_location_tests")
SCENARIOS = ("apple-profile-readiness", "target-normalization", "pac-output", "pac-memory",
             "pac-control", "hidden-pac-contrast", "pac-bounds", "pac-cancellation",
             "authored-names-and-direct-calls", "authored-complete-type-catalog",
             "authored-signature-merge-matrix", "authored-applied-noncode-objects",
             "authored-atomic-unsupported", "authored-application-cancellation",
             "authored-parameter-storage")


class NativeQualificationReportTests(unittest.TestCase):
    def setUp(self):
        path = ROOT / "Scripts/native-decompiler-xpc/native_qualification_report.py"
        self.assertTrue(path.is_file(), "Task 1 report producer does not exist")
        spec = importlib.util.spec_from_file_location("native_qualification_report", path)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        temporary_parent = macscope_work_root()
        self.temp = tempfile.TemporaryDirectory(dir=temporary_parent if temporary_parent.is_dir() else None)
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "source"
        self.build = self.root / "build"
        self.build.mkdir()
        self.report = self.build / "qualification"
        self.material = self.root / "materialization"
        self.profile = "none"
        self.package = self.material / "package"
        self.package.mkdir(parents=True)
        SleighPackageFixture(self.package).create()
        analysis = sleigh_package.analyze_package(self.package)
        manifest = sleigh_package.materialization_value(sleigh_package.APPROVED_ARTIFACTS["macos-arm64"], analysis)
        (self.material / "MATERIALIZATION.json").write_text(sleigh_package.canonical_json(manifest) + "\n")
        # The wrapper source identity also binds non-producer inputs (the
        # dependency-cache modules), so the fixture carries its fixed paths too.
        for relative in (set(self.module.producer_paths("none")) | set(self.module.producer_paths("address"))
                         | set(self.module.source_identity.WRAPPER_FIXED)):
            destination = self.repo / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, destination)
        shutil.copytree(ROOT / "Tools/NativeDecompilerBridge", self.repo / "Tools/NativeDecompilerBridge")
        self.dev = self.root / "Xcode.app/Contents/Developer"
        self.compiler = self.dev / "Toolchains/XcodeDefault.xctoolchain/usr/bin/clang++"
        self.sdk = self.dev / "Platforms/MacOSX.platform/Developer/SDKs/MacOSX27.2.sdk"
        self.sdk.mkdir(parents=True)
        (self.sdk / "SDKSettings.json").write_text('{"Version":"27.2"}')
        (self.sdk / "usr/lib").mkdir(parents=True)
        (self.sdk / "usr/lib/libz.tbd").write_text("zlib")
        self.executable(self.compiler, "print('Apple clang version 21.0.0')")
        self.executable(self.dev / "usr/bin/xcodebuild", "print('Xcode 27.2\\nBuild version 27C20')")
        self.cmake = self.root / "tools/cmake"
        self.ctest = self.root / "tools/ctest"
        self.executable(self.cmake, "print('cmake version 4.1.0')")
        self.inventory = {"kind": "ctestInfo", "version": {"major": 1, "minor": 0}, "tests": []}
        for suffix in PLAIN:
            name = PREFIX + suffix
            self.inventory["tests"].append({"name": name, "command": [str(self.build / name)], "properties": []})
        provider = PREFIX + "ghidra_provider_tests"
        self.inventory["tests"].append({"name": provider, "command": [str(self.build / provider), "--scenario-group", "core"], "properties": []})
        for scenario in SCENARIOS:
            self.inventory["tests"].append({"name": PREFIX + "ghidra_provider_" + scenario.replace("-", "_") + "_tests",
                "command": [str(self.build / provider), "--scenario", scenario], "properties": []})
        self.inventory["tests"].sort(key=lambda v: v["name"])
        self.names = [v["name"] for v in self.inventory["tests"]]
        for item in self.inventory["tests"]:
            self.executable(Path(item["command"][0]), "pass")
        for relative in ("libmacscope_native_decompiler_contract.a", "generated/MacScopeNativeDecompiler/GhidraBuildIdentity.hpp", "build.ninja"):
            path = self.build / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("governed " + relative)
        self.executable(self.build / "macscope_native_decompiler_relocatable_link_probe", "pass")
        digest = self.module.source_identity.profile_digest(self.repo, "wrapper")
        values = {"CMAKE_BUILD_TYPE": "Release", "CMAKE_CXX_COMPILER": str(self.compiler),
                  "CMAKE_OSX_SYSROOT": str(self.sdk), "CMAKE_OSX_ARCHITECTURES": "arm64",
                  "CMAKE_OSX_DEPLOYMENT_TARGET": "27.0", "CMAKE_EXPORT_COMPILE_COMMANDS": "ON",
                  "BUILD_TESTING": "ON", "MACSCOPE_ENABLE_GHIDRA_PROVIDER": "ON",
                  "MACSCOPE_ENABLE_SLEIGH_DECOMP_API_PROBE": "OFF",
                  "MACSCOPE_NATIVE_DECOMPILER_SANITIZER": "none",
                  "MACSCOPE_NATIVE_DECOMPILER_WRAPPER_GIT_REVISION": digest,
                  "MACSCOPE_SLEIGH_MATERIALIZATION_ROOT": str(self.material),
                  "CMAKE_HOME_DIRECTORY": str(self.repo / "Tools/NativeDecompilerBridge"),
                  "CMAKE_CACHEFILE_DIR": str(self.build), "CMAKE_COMMAND": str(self.cmake),
                  "CMAKE_CTEST_COMMAND": str(self.ctest)}
        (self.build / "CMakeCache.txt").write_text("\n".join(k + ":STRING=" + v for k, v in values.items()) + "\n")
        commands = [{"directory": str(self.build), "file": str(self.repo / "Tools/NativeDecompilerBridge/tests/ContractTests.cpp"),
                     "arguments": [str(self.compiler), "-arch", "arm64", "-isysroot", str(self.sdk),
                                   "-mmacosx-version-min=27.0", "-O3", "-DNDEBUG", "-c", "unit.cpp",
                                   "-o", "CMakeFiles/" + name + ".dir/unit.cpp.o"]}
                    for name in sorted({v["command"][0].split("/")[-1] for v in self.inventory["tests"]} | {"macscope_native_decompiler_contract"})]
        (self.build / "compile_commands.json").write_text(json.dumps(commands))
        self.plan = self.root / "plan.json"
        self.calls = self.root / "calls.jsonl"
        self.save_plan()
        self.executable(self.ctest, f"""
import json, os, signal, sys
from pathlib import Path
if sys.argv[1:] == ['--version']:
    print('ctest version 4.1.0'); raise SystemExit(0)
plan = json.loads(Path({str(self.plan)!r}).read_text())
with Path({str(self.calls)!r}).open('a') as out: out.write(json.dumps(sys.argv[1:]) + '\\n')
if '--show-only=json-v1' in sys.argv:
    print(plan.get('inventory_raw', json.dumps(plan['inventory']))); raise SystemExit(0)
if plan.get('mutate'):
    Path(plan['mutate']).write_text('changed during CTest')
if plan.get('replace_inventory'):
    destination = Path(sys.argv[sys.argv.index('--output-junit') + 1]).parent / 'ctest.inventory.json'
    destination.write_text(json.dumps(plan['inventory'], indent=2))
if plan.get('interrupt'): os.kill(os.getpid(), signal.SIGTERM)
if not plan.get('absent'):
    Path(sys.argv[sys.argv.index('--output-junit') + 1]).write_text(plan['xml'])
print('synthetic CTest output', flush=True)
raise SystemExit(plan['exit'])
""")

    @staticmethod
    def executable(path, body):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!" + sys.executable + "\n" + body + "\n")
        path.chmod(0o755)

    def xml(self, names=None, child="", attributes=""):
        names = self.names if names is None else names
        return '<testsuite name="(empty)" tests="%d" failures="0" disabled="0" skipped="0" errors="0" time="0.021" %s>' % (len(names), attributes) + ''.join('<testcase name="%s" classname="%s" status="run" time="0.001">%s</testcase>' % (n, n, child) for n in names) + '</testsuite>'

    def save_plan(self, **changes):
        value = {"inventory": self.inventory, "xml": self.xml(), "exit": 0}
        value.update(changes)
        self.plan.write_text(json.dumps(value))

    def kwargs(self):
        return dict(repository_root=self.repo, build_root=self.build, report_dir=self.report,
                    materialization_root=self.material, profile=self.profile, developer_dir=self.dev)

    def run(self, result=None):
        if result is not None:  # unittest invokes TestCase.run(result).
            return super().run(result)
        return self.module.run_ctest(**self.kwargs(), ctest=self.ctest, jobs=3)

    def extras(self):
        for relative in ("macscope-native-decompiler-link-inputs.xcfilelist", "macscope-native-decompiler-link-probe-inspection.txt",
                         "macscope-native-decompiler-link-probe.otool-l.txt", "macscope-native-decompiler-link-probe.otool-L.txt"):
            (self.build / relative).write_text("final " + relative)

    def finalize(self):
        self.extras()
        return self.module.finalize_native_qualification(**self.kwargs())

    def validate(self, path):
        args = self.kwargs()
        args.pop("report_dir")
        args["expected_profile"] = args.pop("profile")
        return self.module.validate_native_report(report_path=path, **args)

    def test_single_ctest_execution_matches_exact_inventory(self):
        self.assertEqual(self.run(), 0)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(calls, [["--test-dir", str(self.build), "--show-only=json-v1"],
            ["--test-dir", str(self.build), "--parallel", "3", "--output-on-failure", "--no-tests=error", "--output-junit", str(self.report / "ctest.junit.xml")]])
        execution = json.loads((self.report / "ctest.execution.json").read_bytes())
        self.assertEqual([v["name"] for v in execution["tests"]], self.names)
        self.assertTrue(all(v["status"] == "passed" for v in execution["tests"]))
        for field in ("inventory", "junit", "input_snapshot"):
            ref = execution[field]
            raw = (self.report / ref["relative_path"]).read_bytes()
            self.assertEqual((ref["byte_count"], ref["sha256"]), (len(raw), hashlib.sha256(raw).hexdigest()))
        report = self.finalize()
        with patch.object(self.module.subprocess, "run", side_effect=AssertionError("replay must not execute")), patch.object(self.module.subprocess, "Popen", side_effect=AssertionError("replay must not execute")):
            self.assertEqual(self.validate(report)["profile"], "none")
        self.assertEqual(len(self.calls.read_text().splitlines()), 2)

    def selected_aliases(self, *, check_driver=True):
        clang = self.compiler.with_name("clang")
        self.compiler.rename(clang); self.compiler.symlink_to("clang")
        self.executable(clang, ("from pathlib import Path\nassert Path(__import__('sys').argv[0]).name == 'clang++'\n"
            if check_driver else "") + "print('Apple clang version 21.0.0')")
        prefix = self.root / "homebrew"
        (prefix / "bin").mkdir(parents=True)
        selected = {}
        cache = self.build / "CMakeCache.txt"
        payload = cache.read_text()
        for name, original in (("cmake", self.cmake), ("ctest", self.ctest)):
            target = prefix / "Cellar/cmake/4.4.4/bin" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            original.rename(target)
            alias = prefix / "bin" / name
            alias.symlink_to("../Cellar/cmake/4.4.4/bin/" + name)
            payload = payload.replace(str(original), str(alias if name == "cmake" else target))
            selected[name] = target
            setattr(self, name, alias)
        cache.write_text(payload)
        return clang, selected

    def test_selected_tool_aliases_preserve_driver_mode_and_canonical_identity(self):
        clang, selected = self.selected_aliases()
        try:
            code = self.run()
        except ValueError as error:
            self.fail("declared selected-tool aliases must admit: " + str(error))
        self.assertEqual(code, 0)
        result = self.finalize()
        with patch.object(self.module, "_capture", side_effect=AssertionError("replay must not probe")):
            report = self.validate(result)
        self.assertEqual(report["toolchain"]["compiler"]["absolute_path"], str(clang))
        self.assertEqual(report["toolchain"]["cmake"]["absolute_path"], str(selected["cmake"]))
        self.assertEqual(report["toolchain"]["ctest"]["absolute_path"], str(selected["ctest"]))
        # Same bytes do not make the C-mode driver spelling interchangeable.
        commands = self.build / "compile_commands.json"
        commands.write_bytes(commands.read_bytes().replace(str(self.compiler).encode(), str(clang).encode()))
        with self.assertRaises(ValueError): self.validate(result)

    def test_selected_tool_alias_retarget_during_observation_is_rejected(self):
        _, selected = self.selected_aliases()
        replacement = self.root / "homebrew/Cellar/cmake/4.4.5/bin/cmake"
        replacement.parent.mkdir(parents=True)
        shutil.copyfile(selected["cmake"], replacement); replacement.chmod(0o755)
        version = self.module._version
        def retarget(path, *args):
            result = version(path, *args)
            if path == self.cmake:
                self.cmake.unlink(); self.cmake.symlink_to("../Cellar/cmake/4.4.5/bin/cmake")
            return result
        with patch.object(self.module, "_version", side_effect=retarget):
            with self.assertRaises(ValueError): self.run()
        self.assertFalse(self.report.exists())

    def test_selected_ctest_alias_retarget_after_inventory_cannot_execute_tests(self):
        _, selected = self.selected_aliases()
        replacement = self.root / "homebrew/Cellar/cmake/4.4.5/bin/ctest"
        replacement.parent.mkdir(parents=True)
        shutil.copyfile(selected["ctest"], replacement); replacement.chmod(0o755)
        capture = self.module._capture
        def retarget(argv, *args, **kwargs):
            value = capture(argv, *args, **kwargs)
            if "--show-only=json-v1" in argv:
                self.ctest.unlink(); self.ctest.symlink_to("../Cellar/cmake/4.4.5/bin/ctest")
            return value
        with patch.object(self.module, "_capture", side_effect=retarget):
            with self.assertRaises(ValueError): self.run()
        self.assertEqual([json.loads(line) for line in self.calls.read_text().splitlines()],
            [["--test-dir", str(self.build), "--show-only=json-v1"]])
        self.assertFalse((self.report / "native-qualification.json").exists())

    def test_selected_tool_aliases_reject_undeclared_targets_before_any_execution(self):
        clang, selected = self.selected_aliases()
        for path, target in ((self.compiler, str(clang)), (self.compiler, "../bin/clang"),
                (self.cmake, "../Cellar/cmake/4.4.4/bin/ctest"),
                (self.ctest, "../Cellar/other/4.4.4/bin/ctest")):
            original = os.readlink(path)
            path.unlink(); path.symlink_to(target)
            try:
                with self.subTest(path=path.name, target=target), patch.object(self.module, "_capture", side_effect=AssertionError("unsafe alias must not execute")):
                    with self.assertRaises(ValueError): self.run()
                self.assertFalse(self.report.exists())
            finally:
                path.unlink(); path.symlink_to(original)
        # A declared leaf cannot hide another alias or a hardlinked executable.
        target = selected["cmake"]
        held = target.with_name("held-cmake"); target.rename(held); target.symlink_to(held.name)
        with self.assertRaises(ValueError): self.run()
        target.unlink(); held.rename(target)
        hardlink = clang.with_name("hardlinked-clang"); os.link(clang, hardlink)
        with self.assertRaises(ValueError): self.run()

    def test_sanitizer_selected_compiler_alias_matches_canonical_package_identity(self):
        clang, _ = self.selected_aliases(check_driver=False)
        self.sanitizer_fixture("address")
        with patch.object(self.module.sleigh_sanitizer_profile, "_native_metadata", side_effect=self.synthetic_nm):
            self.assertEqual(self.run(), 0)
            result = self.finalize()
        with patch.object(self.module, "_capture", side_effect=AssertionError("replay must not probe")):
            self.assertEqual(self.validate(result)["toolchain"]["compiler"]["absolute_path"], str(clang))

    def test_missing_extra_duplicate_skipped_or_zero_cases_rejected(self):
        variants = [[], self.names[:-1], self.names + ["unknown"], self.names + [self.names[0]]]
        for index, names in enumerate(variants):
            with self.subTest(names=names):
                self.report = self.build / ("qualification-" + str(index))
                self.save_plan(xml=self.xml(names))
                self.assertEqual(self.run(), 0)
                with self.assertRaises((ValueError, RuntimeError)):
                    self.finalize()
                self.assertFalse((self.report / "native-qualification.json").exists())
        self.report = self.build / "qualification-skipped"
        self.save_plan(xml=self.xml(child="<skipped/>"))
        self.assertEqual(self.run(), 0)
        with self.assertRaises((ValueError, RuntimeError)): self.finalize()

    def test_failed_or_interrupted_ctest_has_no_success_marker(self):
        for index, changes in enumerate(({"exit": 17}, {"absent": True}, {"xml": "<testsuite"}, {"interrupt": True})):
            with self.subTest(changes=changes):
                self.report = self.build / ("failure-" + str(index))
                self.save_plan(**changes)
                code = self.run()
                self.assertEqual(code, -15 if changes.get("interrupt") else changes.get("exit", 0))
                self.assertTrue((self.report / "ctest.execution.json").is_file())
                with self.assertRaises((ValueError, RuntimeError)): self.finalize()
                self.assertFalse((self.report / "native-qualification.json").exists())
        before = {v.name: v.read_bytes() for v in self.report.iterdir()}
        with self.assertRaises((ValueError, RuntimeError, FileExistsError)): self.run()
        self.assertEqual(before, {v.name: v.read_bytes() for v in self.report.iterdir()})

    def test_report_rejects_entities_links_and_mutation(self):
        self.assertEqual(self.run(), 0)
        report = self.finalize()
        for target in (self.report / "ctest.junit.xml", self.build / (PREFIX + "contract_tests"), self.compiler,
                       self.sdk / "SDKSettings.json", self.repo / "Scripts/native-decompiler-xpc/build_native_bridge.sh",
                       self.repo / "Scripts/reconstruction_gate_f/schema.py"):
            with self.subTest(target=target):
                original = target.read_bytes()
                target.write_bytes(original + b"\nmutation")
                with self.assertRaises((ValueError, RuntimeError)): self.validate(report)
                target.write_bytes(original)
        raw = report.read_bytes()
        for mode in ("symlink", "hardlink"):
            with self.subTest(mode=mode):
                other = self.build / ("other-" + mode)
                report.rename(other)
                if mode == "symlink": report.symlink_to(other)
                else: os.link(other, report)
                with self.assertRaises((ValueError, RuntimeError)): self.validate(report)
                report.unlink()
                other.rename(report)
        report.write_bytes(raw.replace(b'"schema_version":1', b'"schema_version":true'))
        with self.assertRaises((ValueError, RuntimeError)): self.validate(report)

    def test_inventory_mutations_rejected_before_execution(self):
        for index, mutate in enumerate((lambda v: v["tests"].pop(), lambda v: v["tests"].append(v["tests"][0]),
            lambda v: v["tests"][0].update(command=["/bin/true"]),
            lambda v: v["tests"][0].update(properties=[{"name": "DISABLED", "value": True}]))):
            inventory = json.loads(json.dumps(self.inventory)); mutate(inventory)
            self.report = self.build / ("inventory-" + str(index))
            self.save_plan(inventory=inventory)
            with self.assertRaises((ValueError, RuntimeError)): self.run()
        self.assertTrue(all("--show-only=json-v1" in json.loads(v) for v in self.calls.read_text().splitlines()))

    def test_malformed_xml_and_closed_documents_rejected(self):
        variants = ["<!DOCTYPE testsuite [<!ENTITY x 'secret'>]>" + self.xml(),
                    self.xml().replace('time="0.001"', 'time="NaN"'),
                    self.xml().replace('time="0.001"', 'time="-1"'),
                    self.xml().replace('failures="0"', 'failures="1"'),
                    self.xml(child="<failure/>"), self.xml().replace('status="run"', 'status="notrun"')]
        for index, xml in enumerate(variants):
            self.report = self.build / ("xml-" + str(index)); self.save_plan(xml=xml)
            self.assertEqual(self.run(), 0)
            with self.assertRaises((ValueError, RuntimeError)): self.finalize()
        self.report = self.build / "closed"; self.save_plan(); self.assertEqual(self.run(), 0)
        execution_path = self.report / "ctest.execution.json"
        original = execution_path.read_bytes()
        for field, value in (("exit_code", False), ("started_at_unix_ms", True), ("extra", "unexpected")):
            data = json.loads(original); data[field] = value
            execution_path.write_bytes(self.module.canonical_bytes(data))
            with self.assertRaises((ValueError, RuntimeError)): self.finalize()
        execution_path.write_bytes(original)
        data = json.loads(original); data["junit"]["relative_path"] = "../ctest.junit.xml"
        execution_path.write_bytes(self.module.canonical_bytes(data))
        with self.assertRaises((ValueError, RuntimeError)): self.finalize()

    def test_source_or_executable_change_during_execution_rejected(self):
        for index, target in enumerate((self.repo / "Tools/NativeDecompilerBridge/CMakeLists.txt", self.build / (PREFIX + "contract_tests"))):
            self.report = self.build / ("during-" + str(index))
            original = target.read_bytes(); self.save_plan(mutate=str(target))
            self.assertEqual(self.run(), 0)
            with self.assertRaises((ValueError, RuntimeError)): self.finalize()
            target.write_bytes(original)

    def test_inventory_version_rejects_boolean_integers(self):
        for index, version in enumerate(({"major": True, "minor": 0}, {"major": 1, "minor": False})):
            self.report = self.build / ("bool-version-" + str(index))
            inventory = json.loads(json.dumps(self.inventory)); inventory["version"] = version
            self.save_plan(inventory=inventory)
            with self.assertRaises(ValueError): self.run()

    def test_invalid_governed_inputs_reject_before_tools_or_output_reservation(self):
        cache = self.build / "CMakeCache.txt"
        original = cache.read_bytes()
        mutations = (
            (cache, original.replace(b"BUILD_TESTING:STRING=ON", b"BUILD_TESTING:STRING=OFF")),
            (cache, original.replace(b"MACSCOPE_NATIVE_DECOMPILER_SANITIZER:STRING=none", b"MACSCOPE_NATIVE_DECOMPILER_SANITIZER:STRING=address")),
            (self.package / "lib/libdecomp.a", b"unverified archive"),
            (self.repo / "Tools/NativeDecompilerBridge/CMakeLists.txt", b"unbound wrapper source"),
        )
        for index, (target, changed) in enumerate(mutations):
            with self.subTest(target=target):
                self.report = self.build / ("invalid-input-" + str(index))
                before = target.read_bytes(); target.write_bytes(changed)
                try:
                    with patch.object(self.module.subprocess, "run", side_effect=AssertionError("invalid inputs must not execute")), patch.object(self.module.subprocess, "Popen", side_effect=AssertionError("invalid inputs must not probe")):
                        with self.assertRaises((ValueError, RuntimeError)): self.run()
                    self.assertFalse(self.report.exists())
                    self.assertFalse(self.calls.exists())
                finally:
                    target.write_bytes(before)
        self.report = self.build / "missing-product"
        executable = self.build / (PREFIX + "contract_tests")
        executable.rename(self.build / "held-contract-test")
        with patch.object(self.module.subprocess, "run", side_effect=AssertionError("missing products must not execute")), patch.object(self.module.subprocess, "Popen", side_effect=AssertionError("missing products must not probe")):
            with self.assertRaises((ValueError, OSError)): self.run()
        self.assertFalse(self.report.exists())

    def test_ctest_mismatch_rejects_before_tools_or_output_reservation(self):
        other = self.root / "tools/unbound-ctest"
        self.executable(other, "raise AssertionError('unadmitted CTest executed')")
        with patch.object(self.module.subprocess, "run", side_effect=AssertionError("unadmitted tool must not execute")), patch.object(self.module.subprocess, "Popen", side_effect=AssertionError("unadmitted tool must not probe")):
            with self.assertRaises(ValueError):
                self.module.run_ctest(**self.kwargs(), ctest=other, jobs=3)
        self.assertFalse(self.report.exists())
        self.assertFalse(self.calls.exists())

    def test_sanitizer_command_profile_rejects_before_tools_or_output_reservation(self):
        self.sanitizer_fixture("address")
        commands_path = self.material.parent / "build/compile_commands.json"
        commands = json.loads(commands_path.read_bytes())
        commands[0]["arguments"].remove("-fsanitize=address")
        commands_path.write_text(json.dumps(commands))
        manifest_path = self.material / "MATERIALIZATION.json"
        manifest = json.loads(manifest_path.read_bytes())
        manifest["sourceBuild"]["instrumentation"]["compileCommandsSha256"] = hashlib.sha256(commands_path.read_bytes()).hexdigest()
        manifest_path.write_text(sleigh_package.canonical_json(manifest) + "\n")
        with patch.object(self.module.subprocess, "run", side_effect=AssertionError("invalid sanitizer profile must not execute")), patch.object(self.module.subprocess, "Popen", side_effect=AssertionError("invalid sanitizer profile must not probe")):
            with self.assertRaises((ValueError, RuntimeError)): self.run()
        self.assertFalse(self.report.exists())
        self.assertFalse(self.calls.exists())

    def test_shared_sanitizer_admission_is_read_only_and_nonexecuting(self):
        self.sanitizer_fixture("address")
        admission = getattr(self.module.sleigh_sanitizer_profile, "admit_sanitizer_compile_commands", None)
        self.assertIsNotNone(admission, "producer/replay need shared nonexecuting sanitizer admission")
        commands_path = self.material.parent / "build/compile_commands.json"
        before = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in self.root.rglob("*") if path.is_file()}
        with patch.object(self.module.subprocess, "run", side_effect=AssertionError("admission must not execute")), patch.object(self.module.subprocess, "Popen", side_effect=AssertionError("admission must not probe")):
            objects = admission(commands_path, self.compiler, self.sdk, "address")
        self.assertEqual(objects, {"sleigh_decomp": {"unit.cc.o": self.native_objects[0]},
                                   "sleigh_sla": {"unit.cc.o": self.native_objects[1]}})
        with patch.object(self.module.sleigh_sanitizer_profile, "admit_sanitizer_compile_commands", wraps=admission) as shared:
            with patch.object(self.module.sleigh_sanitizer_profile, "_native_metadata", side_effect=self.synthetic_nm):
                instrumentation = self.module.sleigh_sanitizer_profile.inspect_sanitizer_build(
                    self.package, commands_path, self.compiler, self.sdk, "address")
            shared.assert_called_once_with(commands_path, self.compiler, self.sdk, "address")
            shared.reset_mock()
            with patch.object(self.module.subprocess, "run", side_effect=AssertionError("replay admission must not execute")), patch.object(self.module.subprocess, "Popen", side_effect=AssertionError("replay admission must not probe")):
                self.module._sanitizer_archive_replay(self.material, commands_path, instrumentation, self.compiler, self.sdk)
            shared.assert_called_once_with(commands_path, self.compiler, self.sdk, "address")
        self.assertEqual(before, {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in self.root.rglob("*") if path.is_file()})
        commands = json.loads(commands_path.read_bytes())
        commands[0]["arguments"].remove("-fsanitize=address")
        commands_path.write_text(json.dumps(commands))
        with patch.object(self.module.subprocess, "run", side_effect=AssertionError("invalid admission must not execute")), patch.object(self.module.subprocess, "Popen", side_effect=AssertionError("invalid admission must not probe")):
            with self.assertRaises((ValueError, RuntimeError)):
                admission(commands_path, self.compiler, self.sdk, "address")

    def test_zero_byte_executable_ref_rejects_boolean_count(self):
        executable = self.build / (PREFIX + "contract_tests")
        executable.write_bytes(b"")
        self.assertEqual(self.run(), 0)
        execution_path = self.report / "ctest.execution.json"
        execution = json.loads(execution_path.read_bytes())
        next(row for row in execution["tests"] if row["name"] == executable.name)["executable"]["byte_count"] = False
        execution_path.write_bytes(self.module.canonical_bytes(execution))
        with self.assertRaises(ValueError): self.finalize()

    def test_valid_inventory_replacement_during_execution_rejected(self):
        self.save_plan(replace_inventory=True)
        self.assertEqual(self.run(), 0)
        with self.assertRaises(ValueError): self.finalize()
        self.assertFalse((self.report / "native-qualification.json").exists())

    def test_external_reference_rejected_before_reading_unadmitted_file(self):
        self.assertEqual(self.run(), 0)
        report = self.finalize()
        outside = self.root / "outside.txt"; outside.write_text("unadmitted")
        value = json.loads(report.read_bytes())
        value["producer_files"][0] = {"absolute_path": str(outside), "byte_count": 10,
                                     "sha256": hashlib.sha256(b"unadmitted").hexdigest()}
        report.write_bytes(self.module.canonical_bytes(value))
        external = self.module._external
        def admitted_only(path):
            self.assertNotEqual(path, outside, "unadmitted report reference was read")
            return external(path)
        with patch.object(self.module, "_external", side_effect=admitted_only):
            with self.assertRaises(ValueError): self.validate(report)

    def test_tool_executable_mutation_and_cache_binding_rejected(self):
        self.assertEqual(self.run(), 0)
        report = self.finalize()
        for target in (self.cmake, self.ctest):
            original = target.read_bytes(); target.write_bytes(original + b"\n# drift\n")
            with self.assertRaises(ValueError): self.validate(report)
            target.write_bytes(original)
        cache = self.build / "CMakeCache.txt"; original = cache.read_bytes()
        other = self.root / "tools/other-ctest"; shutil.copyfile(self.ctest, other)
        cache.write_bytes(original.replace(str(self.ctest).encode(), str(other).encode()))
        with self.assertRaises(ValueError): self.validate(report)

    def test_oversized_and_invalid_raw_evidence_rejected(self):
        for index, raw in enumerate(("{", "\xff", " " * (16 * 1024 * 1024 + 1))):
            self.report = self.build / ("bad-raw-" + str(index)); self.save_plan(inventory_raw=raw)
            with self.assertRaises(ValueError): self.run()
        self.report = self.build / "large-junit"
        self.save_plan(xml=self.xml() + " " * (16 * 1024 * 1024))
        self.assertEqual(self.run(), 0)
        with self.assertRaises(ValueError): self.finalize()

    def sanitizer_fixture(self, profile):
        from test_sleigh_sanitizer_profile import SleighSanitizerProfileTests
        self.profile = profile
        publication = self.build / "native-source" / ("SleighNativeSource-" + profile)
        publication.mkdir(parents=True)
        previous = self.material
        self.material = publication / "materialization"
        previous.rename(self.material)
        self.package = self.material / "package"
        commands = []
        self.native_objects = []
        strings = b"\x00___" + (b"asan_init" if profile == "address" else b"ubsan_handle_add_overflow") + b"\x00"
        # An authored arm64 MH_OBJECT with one undefined instrumentation symbol;
        # native nm can inspect it without compiling any code.
        object_bytes = (struct.pack("<8I", 0xfeedfacf, 0x100000c, 0, 1, 1, 24, 0, 0)
                        + struct.pack("<6I", 2, 24, 56, 1, 72, len(strings))
                        + struct.pack("<IBBHQ", 1, 1, 0, 0, 0) + strings)
        for target, archive in (("sleigh_decomp", "libdecomp.a"), ("sleigh_sla", "libsla.a")):
            output = "src/CMakeFiles/" + target + ".dir/unit.cc.o"
            path = publication / "build" / output; path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(object_bytes); self.native_objects.append(path)
            (self.package / "lib" / archive).write_bytes(SleighSanitizerProfileTests.archive_bytes({"unit.cc.o": object_bytes}))
            commands.append({"directory": str(publication / "build"), "file": "unit.cc",
                "arguments": [str(self.compiler), "-fsanitize=" + profile,
                    "-fno-omit-frame-pointer" if profile == "address" else "-fno-sanitize-recover=all",
                    "-O1", "-g", "-DNDEBUG", "-arch", "arm64", "-isysroot", str(self.sdk),
                    "-mmacosx-version-min=27.0", "-o", output, "-c", "unit.cc"]})
        commands_path = publication / "build/compile_commands.json"
        commands_path.write_text(json.dumps(commands))
        self.nm_symbols = "                 U ___" + ("asan_init" if profile == "address" else "ubsan_handle_add_overflow") + "\n"
        # Replace only the native tool boundary, including in the independent
        # copied verifier subprocess. Real schema-3 verification still parses
        # every compile command, object and archive, and compares their bytes.
        fixture_inspector = self.repo / "Scripts/native-decompiler-direct/sleigh_sanitizer_profile.py"
        with fixture_inspector.open("a") as out:
            out.write("\ndef _native_metadata(arguments):\n"
                      "    if arguments[:2] != ['/usr/bin/nm', '-u'] or len(arguments) != 3:\n"
                      "        raise PackageContractError('unexpected synthetic metadata probe')\n"
                      "    return " + repr(self.nm_symbols) + "\n")
        with patch.object(self.module.sleigh_sanitizer_profile, "_native_metadata", side_effect=self.synthetic_nm):
            instrumentation = self.module.sleigh_sanitizer_profile.inspect_sanitizer_build(
                self.package, commands_path, self.compiler, self.sdk, profile)
        toolchain = {"compiler": {"path": str(self.compiler.resolve(strict=True)), "sha256": hashlib.sha256(self.compiler.read_bytes()).hexdigest(), "version": "Apple clang version 21.0.0"},
                     "cmake": {"path": str(self.cmake.resolve(strict=True)), "sha256": hashlib.sha256(self.cmake.read_bytes()).hexdigest(), "version": "cmake version 4.1.0"},
                     "ninja": {"path": "/tools/ninja", "sha256": "a" * 64, "version": "1.13.1"}}
        manifest = sleigh_package.source_materialization_value(sleigh_package.analyze_package(self.package), toolchain,
                       sanitizer=profile, instrumentation=instrumentation)
        (self.material / "MATERIALIZATION.json").write_text(sleigh_package.canonical_json(manifest) + "\n")
        (publication / "SOURCE_BUILD_MATERIALIZATION.json").write_text('{"synthetic":"source-build"}')
        cache = self.build / "CMakeCache.txt"
        cache.write_text(cache.read_text().replace(str(previous), str(self.material)).replace("CMAKE_BUILD_TYPE:STRING=Release", "CMAKE_BUILD_TYPE:STRING=RelWithDebInfo")
                         .replace("MACSCOPE_NATIVE_DECOMPILER_SANITIZER:STRING=none", "MACSCOPE_NATIVE_DECOMPILER_SANITIZER:STRING=" + profile))
        bridge_path = self.build / "compile_commands.json"
        bridge_commands = json.loads(bridge_path.read_text())
        for command in bridge_commands:
            command["arguments"].extend(self.module.sleigh_package.SANITIZER_FLAGS[profile])
        bridge_path.write_text(json.dumps(bridge_commands))

    def synthetic_nm(self, argv):
        self.assertEqual(argv[:2], ["/usr/bin/nm", "-u"])
        self.assertIn(Path(argv[2]), {self.package / "lib/libdecomp.a", self.package / "lib/libsla.a"})
        return self.nm_symbols

    def sanitizer_replay(self, profile):
        self.sanitizer_fixture(profile)
        with patch.object(self.module.sleigh_sanitizer_profile, "_native_metadata", side_effect=self.synthetic_nm):
            self.assertEqual(self.run(), 0)
            report = self.finalize()
        with patch.object(self.module.subprocess, "run", side_effect=AssertionError("replay must not execute")), patch.object(self.module.subprocess, "Popen", side_effect=AssertionError("replay must not execute")):
            self.assertEqual(self.validate(report)["profile"], profile)
            original = self.native_objects[0].read_bytes()
            self.native_objects[0].write_bytes(original + b"drift")
            with self.assertRaises(ValueError): self.validate(report)
            self.native_objects[0].write_bytes(original)
            cache = self.build / "CMakeCache.txt"; original_cache = cache.read_bytes()
            cache.write_bytes(original_cache.replace(("SANITIZER:STRING=" + profile).encode(), b"SANITIZER:STRING=none"))
            with self.assertRaises(ValueError): self.validate(report)
            cache.write_bytes(original_cache)
            commands = self.build / "compile_commands.json"; original_commands = commands.read_bytes()
            commands.write_bytes(original_commands.replace(("-fsanitize=" + profile).encode(), b"-fsanitize=none"))
            with self.assertRaises(ValueError): self.validate(report)
            commands.write_bytes(original_commands)

    def test_asan_replay_without_execution_rejects_object_and_profile_drift(self):
        self.sanitizer_replay("address")

    def test_ubsan_replay_without_execution_rejects_object_and_profile_drift(self):
        self.sanitizer_replay("undefined")

    def test_finalize_cli_emits_only_revalidated_unique_marker(self):
        self.assertEqual(self.run(), 0)
        self.extras()
        command = [sys.executable, "-B", str(self.repo / "Scripts/native-decompiler-xpc/native_qualification_report.py"), "finalize"]
        for key, value in self.kwargs().items():
            command.extend(["--" + key.replace("_", "-"), str(value)])
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "MACSCOPE_NATIVE_QUALIFICATION_REPORT=" + str(self.report / "native-qualification.json") + "\n")
        result = subprocess.run(command, capture_output=True, text=True, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("MACSCOPE_NATIVE_QUALIFICATION_REPORT=", result.stdout)


if __name__ == "__main__": unittest.main()
