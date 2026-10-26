from __future__ import annotations

import unittest
from unittest import mock
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap

from Scripts.ci import run_macos_governance as runner
from Scripts.dependencies import cp1_frontend_cache as frontend


class MacOSGovernanceRunnerTests(unittest.TestCase):
    def test_selection_is_exact_hosted_complement(self):
        self.assertEqual(
            runner.selected_modules(),
            tuple("Scripts.tests." + name[:-3] for name in sorted(runner.MACOS_ONLY_REASONS)),
        )
        self.assertIn("Scripts.tests.test_local_private_build_qualification", runner.selected_modules())
        self.assertIn("Scripts.tests.test_release_build_provenance", runner.selected_modules())
        self.assertIn("Scripts.tests.test_sleigh_aarch64_feature_vectors", runner.selected_modules())

    def test_failure_is_not_hidden_by_runner(self):
        result = mock.Mock(testsRun=1, failures=[("case", "failure")], errors=[], skipped=[])
        result.wasSuccessful.return_value = False
        with mock.patch.object(runner.sys, "platform", "darwin"), \
             mock.patch.object(runner, "selected_modules", return_value=("fixture",)), \
             mock.patch.object(runner.unittest.defaultTestLoader, "loadTestsFromNames") as load, \
             mock.patch.object(runner.unittest, "TextTestRunner") as execute:
            load.return_value.countTestCases.return_value = 1
            execute.return_value.run.return_value = result
            self.assertEqual(runner.main(), 1)

    def test_wrong_host_cannot_report_success(self):
        with mock.patch.object(runner.sys, "platform", "linux"):
            self.assertEqual(runner.main(), 2)

    def test_workflow_provisions_frontend_and_propagates_failure(self):
        workflow = (runner.ROOT / ".github/workflows/ci.yml").read_text()
        step = workflow.split("      - name: Run macOS Python governance suite\n", 1)[1]
        step = step.split("      - name:", 1)[0]
        body = textwrap.dedent(step.split("        run: |\n", 1)[1])
        self.assertIn('export CP1_SLEIGH_LIFT', body)
        self.assertIn('--out "$MACSCOPE_DEPENDENCY_CACHE_ROOT/cp1-sleigh-lift"', body)
        self.assertLess(body.index("build_cp1_sleigh_lift.sh"), body.index("run_macos_governance.py"))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            builder = root / "Scripts/dependencies/build_cp1_sleigh_lift.sh"
            builder.parent.mkdir(parents=True)
            governance = root / "Scripts/ci/run_macos_governance.py"
            governance.parent.mkdir(parents=True)
            governance.write_text(
                'import os\nfrom pathlib import Path\n'
                'Path("observed").write_text(os.environ["CP1_SLEIGH_LIFT"])\n')
            environment = dict(os.environ, MACSCOPE_DEPENDENCY_CACHE_ROOT=str(root / "cache with spaces"))
            for exit_code in (0, 7):
                with self.subTest(builder_exit=exit_code):
                    builder.write_text('#!/bin/bash\n[[ "$1" == --out ]] || exit 9\n'
                                       f'echo "$2/frontend"\nexit {exit_code}\n')
                    builder.chmod(0o755)
                    result = subprocess.run(["/bin/bash", "-eu", "-c", body], cwd=root,
                                            env=environment, capture_output=True, text=True)
                    self.assertEqual(result.returncode, exit_code, result.stderr)
                    observed = root / "observed"
                    if exit_code == 0:
                        self.assertEqual(observed.read_text(), str(root / "cache with spaces/cp1-sleigh-lift/frontend"))
                        observed.unlink()
                    else:
                        self.assertFalse(observed.exists())


class CP1FrontendCacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        # macOS may expose its temporary directory through /var -> /private/var.
        # The producer canonicalizes roots; bind assertions and the no-payload-
        # reopen guard to that same filesystem identity.
        self.root = Path(self.temporary.name).resolve() / "source"
        self.root.mkdir()
        self.out = self.root.parent / "cache"
        self.library = self.root / "ThirdParty/SleighNative/package/lib/libsla.a"
        self.library.parent.mkdir(parents=True)
        self.library.write_text("library payload must not be read")
        (self.root / "ThirdParty/SleighNative/package/include/sleigh/ghidra").mkdir(parents=True)
        source = self.root / frontend.SOURCE
        source.parent.mkdir(parents=True)
        source.write_text("synthetic frontend")
        self.receipt = {
            "schemaVersion": 1, "componentId": "fixture",
            "sleighGitRevision": "a" * 40, "ghidraGitRevision": "b" * 40,
            "artifact": {"sha256": "a" * 64},
            "package": {"treeSha256": "b" * 64,
                        "criticalFileSha256": {"lib/libsla.a": "c" * 64}},
        }
        self.write_receipt()
        self.inputs = {path: "d" * 40 for path in frontend.BUILD_INPUTS}
        self.toolchain = {"compiler": "/fixture/clang++", "compiler_version": "fixture clang",
                          "sdk": "/fixture/sdk", "sdk_build": "fixture SDK"}
        for attribute, value in (("committed_inputs", self.inputs), ("toolchain_identity", self.toolchain)):
            patch = mock.patch.object(frontend, attribute, return_value=value)
            patch.start()
            self.addCleanup(patch.stop)
        patch = mock.patch.object(frontend.subprocess, "run", side_effect=self.compile_frontend)
        self.compiler = patch.start()
        self.addCleanup(patch.stop)
        original_open = Path.open
        library = self.library

        def guarded_open(path, *args, **kwargs):
            if path.resolve() == library:
                raise AssertionError("library payload was reopened instead of trusting its receipt")
            return original_open(path, *args, **kwargs)

        patch = mock.patch.object(Path, "open", guarded_open)
        patch.start()
        self.addCleanup(patch.stop)

    def write_receipt(self):
        (self.root / frontend.MATERIALIZATION).write_text(json.dumps(self.receipt))

    @staticmethod
    def compile_frontend(arguments, **kwargs):
        target = Path(arguments[arguments.index("-o") + 1])
        target.write_text("#!/bin/sh\nexit 0\n")
        target.chmod(0o755)
        return subprocess.CompletedProcess(arguments, 0)

    def test_same_recorded_identity_builds_once_without_reading_library(self):
        first = frontend.build(self.root, self.out)
        second = frontend.build(self.root, self.out)
        self.assertEqual(first, second)
        self.assertEqual(self.compiler.call_count, 1)
        receipt = json.loads((first.parent / "RECEIPT.json").read_text())
        self.assertEqual(receipt["dependency"]["library_sha256"], "c" * 64)
        self.assertEqual(receipt["inputs"], self.inputs)
        self.assertEqual(receipt["toolchain"], self.toolchain)
        command = self.compiler.call_args.args[0]
        self.assertEqual(command[0], self.toolchain["compiler"])
        self.assertIn(str(self.library), command)
        self.assertEqual(command[command.index("-isysroot") + 1], self.toolchain["sdk"])

    def test_changed_dependency_source_or_toolchain_selects_new_entry(self):
        paths = {frontend.build(self.root, self.out)}
        self.receipt["package"]["criticalFileSha256"]["lib/libsla.a"] = "e" * 64
        self.write_receipt()
        paths.add(frontend.build(self.root, self.out))
        self.inputs[frontend.SOURCE] = "f" * 40
        paths.add(frontend.build(self.root, self.out))
        self.toolchain["compiler_version"] = "new fixture compiler"
        paths.add(frontend.build(self.root, self.out))
        self.assertEqual(len(paths), 4)
        self.assertEqual(self.compiler.call_count, 4)

    def test_missing_or_malformed_dependency_receipt_refuses_without_compile(self):
        original = copy.deepcopy(self.receipt)
        for digest in (None, "invalid"):
            with self.subTest(digest=digest):
                self.receipt = copy.deepcopy(original)
                recorded = self.receipt["package"]["criticalFileSha256"]
                if digest is None:
                    del recorded["lib/libsla.a"]
                else:
                    recorded["lib/libsla.a"] = digest
                self.write_receipt()
                with self.assertRaisesRegex(ValueError, "recorded.*identit"):
                    frontend.build(self.root, self.out)
        (self.root / frontend.MATERIALIZATION).unlink()
        with self.assertRaises(FileNotFoundError):
            frontend.build(self.root, self.out)
        self.compiler.assert_not_called()

    def test_incomplete_or_mismatched_frontend_receipt_is_refused(self):
        executable = frontend.build(self.root, self.out)
        receipt = executable.parent / "RECEIPT.json"
        for contents in (None, "not JSON", "{}\n"):
            with self.subTest(contents=contents):
                if contents is None:
                    receipt.unlink()
                else:
                    receipt.write_text(contents)
                with self.assertRaisesRegex(ValueError, "matching executable and identity receipt"):
                    frontend.build(self.root, self.out)
        self.assertEqual(self.compiler.call_count, 1)

    def test_failed_compile_never_publishes_success(self):
        self.compiler.side_effect = subprocess.CalledProcessError(7, "fixture compiler")
        with self.assertRaises(subprocess.CalledProcessError):
            frontend.build(self.root, self.out)
        self.assertEqual(list(self.out.glob("*/sleigh-lift*")), [])
        self.assertEqual(list(self.out.glob("*/RECEIPT.json")), [])

    def test_repository_output_and_alias_are_refused(self):
        alias = self.root.parent / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        for path in (self.root / "cache", alias / "cache", Path("relative")):
            with self.subTest(path=path), self.assertRaisesRegex(ValueError, "--out must be"):
                frontend.build(self.root, path)
        self.compiler.assert_not_called()


if __name__ == "__main__":
    unittest.main()
