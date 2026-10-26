import copy
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("clang_import_configuration", ROOT / "Scripts/types/clang_import_configuration.py")
config = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(config)


class ClangImportConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dp06-config-", dir=ROOT.parent)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.compiler = self.root / "clang"
        self.compiler.write_text("fake discovery only")
        self.compiler.chmod(0o700)
        self.sdk = self.root / "sdk"
        self.sdk.mkdir()
        self.resource = self.root / "resource"
        self.resource.mkdir()
        self.profile = config.load_profile(ROOT / "Scripts/types/profiles/minimal-darwin.json")
        self.sdk_version = "fixture-sdk-version"
        self.calls = []

    def fake(self, argv, *, input_bytes=b""):
        self.calls.append(argv)
        if argv[-2:] == ["--find", "clang"]: return str(self.compiler)
        if argv[-1] == "--show-sdk-path": return str(self.sdk)
        if argv[-1] == "--show-sdk-version": return self.sdk_version
        if argv[-1] == "--show-sdk-build-version": return "fixture-sdk-build"
        if argv[-1] == "-print-resource-dir": return str(self.resource)
        if argv[-1] == "--version": return "fixture compiler full build string"
        if "-dM" in argv:
            self.assertEqual(input_bytes, b"")
            return "#define __APPLE__ 1\n#define __LP64__ 1\n"
        self.fail(f"unexpected discovery call: {argv}")

    def test_target_language_sdk_and_macros_change_cache_key(self):
        base = config.resolve_configuration(self.profile, self.root, self.fake)
        self.assertEqual(base, config.resolve_configuration(self.profile, self.root, self.fake))
        for changes in [dict(target="arm64e-apple-macosx27.0", architecture="arm64e"),
                        dict(language="objective-c", objc_runtime="macosx-27.0", arc=True),
                        dict(defines=["FEATURE=1"]), dict(undefines=["FEATURE"]), dict(blocks=False)]:
            profile = {**self.profile, **changes}
            with self.subTest(changes=changes):
                self.assertNotEqual(base["configurationID"], config.resolve_configuration(profile, self.root, self.fake)["configurationID"])
        self.sdk_version = "different SDK"
        self.assertNotEqual(base["configurationID"], config.resolve_configuration(self.profile, self.root, self.fake)["configurationID"])
        a = {**self.profile, "defines": ["A=1", "B=2"]}
        b = {**self.profile, "defines": ["B=2", "A=1"]}
        self.assertNotEqual(config.resolve_configuration(a, self.root, self.fake)["configurationID"], config.resolve_configuration(b, self.root, self.fake)["configurationID"])
        self.assertIn("-nostdinc", base["arguments"])
        self.assertNotIn("CPATH", base["environment"])

    def test_rejects_arbitrary_plugin_shell_and_mixed_target_settings(self):
        for extra in [{"arguments": ["-Xclang", "-load", "plugin.dylib"]}, {"command": "sh -c echo"},
                      {"architecture": "arm64e"}, {"arc": True}, {"modules": "implicit"},
                      {"defines": ["NAME\n#include <file>"]}, {"include_roots": ["input:../"]}]:
            with self.subTest(extra=extra), self.assertRaises(config.ConfigurationError):
                config.resolve_configuration({**self.profile, **extra}, self.root, self.fake)

    def test_tool_runner_does_not_inherit_host_include_environment(self):
        completed = mock.Mock(returncode=0, stdout=b"fixture", stderr=b"")
        with mock.patch.dict(os.environ, {"CPATH": "/host/include", "SDKROOT": "/wrong/sdk"}), \
             mock.patch.object(config.subprocess, "run", return_value=completed) as run:
            self.assertEqual(config.run_tool(["/fake/clang", "--version"]), "fixture")
        self.assertEqual(run.call_args.kwargs["env"], config.CLEAN_ENV)
        self.assertNotIn("shell", run.call_args.kwargs)
        self.assertEqual(run.call_args.kwargs["timeout"], 20)


if __name__ == "__main__":
    unittest.main()
