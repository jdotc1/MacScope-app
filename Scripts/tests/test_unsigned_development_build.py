import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("signing_policy", ROOT / "Scripts/check_local_signing_policy.py")
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class UnsignedDevelopmentPolicyTests(unittest.TestCase):
    def environment(self):
        return {
            **policy.EXPECTED_EFFECTIVE_SETTINGS,
            "TARGET_NAME": "MacScopeApp", "CONFIGURATION": "Debug", "ACTION": "build",
            "GENERATE_INFOPLIST_FILE": "NO", "INFOPLIST_FILE": "Resources/Info.plist",
            "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "YES",
            "MACSCOPE_DEV_UNSIGNED": "YES", "MACSCOPE_DEBUG_SOURCE_IDENTITY": "runtime-only",
            "CODE_SIGNING_ALLOWED": "NO", "CODE_SIGNING_REQUIRED": "NO",
            "CODE_SIGN_IDENTITY": "", "EXPANDED_CODE_SIGN_IDENTITY": "", "DEVELOPMENT_TEAM": "",
        }

    def test_explicit_debug_build_accepts_no_signing(self):
        self.assertEqual(policy.validate_build_environment(self.environment()), [])

    def test_unsigned_opt_in_cannot_enter_release_archive_ci_or_sign(self):
        for key, value in {
            "CONFIGURATION": "Release", "ACTION": "install",
            "MACSCOPE_DEBUG_SOURCE_IDENTITY": "source-qualified",
            "MACSCOPE_ISOLATED_CI_ADHOC_SIGNING": "YES", "CI": "true",
            "CODE_SIGNING_ALLOWED": "YES", "CODE_SIGNING_REQUIRED": "YES",
            "AD_HOC_CODE_SIGNING_ALLOWED": "YES", "CODE_SIGN_IDENTITY": "-",
            "EXPANDED_CODE_SIGN_IDENTITY": "certificate", "DEVELOPMENT_TEAM": "team",
        }.items():
            with self.subTest(key=key):
                environment = self.environment()
                environment[key] = value
                self.assertTrue(policy.validate_build_environment(environment))

    def test_unsigned_requires_explicit_opt_in_and_default_release_is_signed(self):
        environment = self.environment()
        del environment["MACSCOPE_DEV_UNSIGNED"]
        self.assertTrue(policy.validate_build_environment(environment))
        environment.update(policy.EXPECTED_EFFECTIVE_SETTINGS)
        environment["CONFIGURATION"] = "Release"
        self.assertEqual(policy.validate_build_environment(environment), [])


class UnsignedDevelopmentProjectTests(unittest.TestCase):
    def test_only_explicit_generation_replaces_consumers_and_forces_unsigned_guard(self):
        import sys
        sys.path.insert(0, str(ROOT / "Scripts"))
        from unsigned_development import specification, PHASES
        original = (ROOT / "MacScope/project.yml").read_text()
        changed = specification(original)
        self.assertEqual((ROOT / "MacScope/project.yml").read_text(), original)
        for phase in PHASES.values():
            self.assertIn("phase --phase " + phase + "\n", changed)
        self.assertNotIn("/usr/bin/codesign --force --sign", changed)
        self.assertNotIn("Contents/_CodeSignature/CodeResources", changed)
        self.assertIn("CODE_SIGNING_ALLOWED: YES", changed)
        self.assertIn("CODE_SIGNING_REQUIRED: YES", changed)

    def test_normal_entrypoint_does_not_reuse_development_project(self):
        text = (ROOT / "script/build_and_run.sh").read_text()
        import os
        import subprocess
        import tempfile

        # Exercise the real entrypoint's early guards without running bootstrap
        # or the signing/project validators that follow them.
        guard = text.split("generated_project_is_fresh() {", 1)[1].split(
            "  dependency_roots_are_current", 1)[0]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project = root / "MacScope.xcodeproj"
            project.mkdir()
            (root / "DependencyRoots.local.xcconfig").touch()
            for marker in (None, ".unsigned-development", ".cache-release"):
                with self.subTest(marker=marker):
                    if marker:
                        (project / marker).touch()
                    result = subprocess.run(
                        ["/bin/bash", "-euc", "generated_project_is_fresh() {" + guard
                         + "\nreturn 0\n}\ngenerated_project_is_fresh\n"],
                        env={**os.environ, "XCODEPROJ": str(project), "MACSCOPE_DIR": str(root)},
                        capture_output=True, text=True,
                    )
                    self.assertEqual(result.returncode, 1 if marker else 0, result.stderr)
                    if marker:
                        (project / marker).unlink()


class UnsignedDevelopmentCopyTests(unittest.TestCase):
    def test_read_only_cache_copy_has_writable_owned_build_directory(self):
        import sys
        import tempfile
        sys.path.insert(0, str(ROOT / 'Scripts'))
        from unsigned_development import copy
        with tempfile.TemporaryDirectory(dir=ROOT.parent) as temporary:
            root = Path(temporary)
            source = root / 'accepted-cache'
            source.mkdir()
            (source / 'archive.a').write_bytes(b'accepted fixture')
            (source / 'archive.a').chmod(0o444)
            source.chmod(0o555)
            destination = root / 'build'
            try:
                copy(source, destination)
                (destination / 'link-inputs.xcfilelist').write_text('archive.a\n')
                self.assertEqual((destination / 'archive.a').read_bytes(), b'accepted fixture')
                self.assertEqual(source.stat().st_mode & 0o222, 0)
            finally:
                source.chmod(0o700)
                if destination.exists():
                    destination.chmod(0o700)


class UnsignedDevelopmentMetadataFreshnessTests(unittest.TestCase):
    def test_generation_and_guard_bind_metadata_and_membership_without_payload_hashes(self):
        import sys
        import tempfile
        from unittest.mock import patch
        import json
        sys.path.insert(0, str(ROOT / 'Scripts'))
        import unsigned_development as development
        with tempfile.TemporaryDirectory(dir=ROOT.parent) as temporary:
            root = Path(temporary)
            source = root / 'MacScope'
            source.mkdir()
            for relative in ('project.yml', 'DependencyRoots.xcconfig', 'SigningIdentity.xcconfig', 'DependencyRoots.local.xcconfig', '../ThirdParty/SleighNative/PATCHED_RESOURCES.json', '../Scripts/unsigned_development.py', '../Scripts/generate_xcode_json_project.py'):
                path = source / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('fixture')
            package = root / 'accepted-package'
            package.mkdir()
            (source / 'LocalPackages').symlink_to(package, target_is_directory=True)
            project = source / 'MacScope.xcodeproj'
            def generate(*args, **kwargs):
                project.mkdir(exist_ok=True)
                (project / 'project.xcproj').write_text('generated')
                (project / '.unsigned-development').write_text('development')
            with patch('generate_xcode_json_project.generate', side_effect=generate), patch('project_freshness.sha256_file', side_effect=AssertionError('must not hash payloads')), patch('project_freshness.generated_project_source_paths', return_value=['App.swift']) as paths, patch.object(development, 'ROOT', root), patch('check_local_signing_policy.validate_build_environment', return_value=[]):
                receipt = development.generate_development_project(source)
                admission = root / 'admission.json'
                admission.write_text(json.dumps({'repository': str(root), 'generation': receipt}))
                environment = {'MACSCOPE_DEV_UNSIGNED': 'YES', 'MACSCOPE_DEV_UNSIGNED_ADMISSION': str(admission)}
                development.guard(environment)
                paths.return_value = ['App.swift', 'New.swift']
                with self.assertRaisesRegex(ValueError, 'source membership'):
                    development.guard(environment)
                paths.return_value = ['App.swift']
                (project / 'project.xcproj').write_text('changed')
                with self.assertRaisesRegex(ValueError, 'input metadata'):
                    development.guard(environment)
                receipt = development.generate_development_project(source)
                (source / 'SigningIdentity.xcconfig').write_text('changed')
                with self.assertRaisesRegex(ValueError, 'input metadata'):
                    development.validate_development_generation(source, receipt)
