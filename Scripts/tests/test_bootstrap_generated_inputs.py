"""Exercise only bootstrap's actual machine-local publication fragment, without builds."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BootstrapGeneratedInputsTests(unittest.TestCase):
    def test_sleigh_cached_admission_skips_rehash_but_external_root_is_verified(self):
        script = (ROOT / 'Scripts/bootstrap.sh').read_text()
        self.assertIn('SLEIGH_CACHE_ADMITTED=0', script)
        resolve_start = script.index('SLEIGH_PREPARATION="$(dev_dependency_resolve sleigh-native-source)"')
        # The cache resolver admits after it checks root coherence.
        admit = script.index('SLEIGH_CACHE_ADMITTED=1', resolve_start)
        # The only other admission is retained Release inheritance (fff93dcc9),
        # and it follows the qualifier-receipt check in admit_bootstrap.
        retained = script.index('SLEIGH_CACHE_ADMITTED=1')
        self.assertEqual(script.count('SLEIGH_CACHE_ADMITTED=1'), 2)
        self.assertLess(script.index('admit_bootstrap(Path'), retained)
        self.assertLess(retained, resolve_start)
        self.assertIn('incoherent SLEIGH roots', script[resolve_start:admit])
        start = script.index('if [[ "${SLEIGH_CACHE_ADMITTED}" == 1 ]]')
        end = script.index('echo "    Native SLEIGH package — OK"', start)
        fragment = script[start:end]
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            verifier = base / 'native-decompiler-direct' / 'verify_sleigh_package.py'
            verifier.parent.mkdir()
            marker = base / 'verified'
            verifier.write_text('from pathlib import Path\nPath(' + repr(str(marker)) + ').write_text("called")\n')
            environment = dict(os.environ, SCRIPT_DIR=str(base), SLEIGH_ROOT=str(base / 'view'))
            environment['SLEIGH_CACHE_ADMITTED'] = '1'
            subprocess.run(['/bin/bash', '-euc', fragment], env=environment, check=True, capture_output=True)
            self.assertFalse(marker.exists(), 'an admitted view must never invoke the package verifier')
            environment['SLEIGH_CACHE_ADMITTED'] = '0'
            subprocess.run(['/bin/bash', '-euc', fragment], env=environment, check=True, capture_output=True)
            self.assertEqual(marker.read_text(), 'called')

    def test_actual_xcconfig_fragment_preserves_unchanged_identity_and_publishes_changed_roots(self):
        script = (ROOT / 'Scripts/bootstrap.sh').read_text()
        start = script.index('/usr/bin/python3 -B "${SCRIPT_DIR}/generate_xcode_json_project.py" \\\n  --publish-file "${LOCAL_DEPENDENCY_ROOTS}" --publish-mode 0600 <<XCCONFIG')
        end = script.index('\nXCCONFIG', start) + len('\nXCCONFIG')
        fragment = script[start:end]
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'DependencyRoots.local.xcconfig'
            environment = dict(os.environ, SCRIPT_DIR=str(ROOT / 'Scripts'), LOCAL_DEPENDENCY_ROOTS=str(target))
            names = ['GHOSTTY_SURFACE_WORK_ROOT', 'GHOSTTY_SURFACE_SOURCE_DIR', 'GHOSTTY_SURFACE_ARTIFACT_ROOT',
                     'GHOSTTY_SURFACE_FRAMEWORK', 'SLEIGH_COMPONENT_ROOT', 'SLEIGH_SOURCE_BUILD_ROOT', 'SLEIGH_ROOT', 'MACHOKIT_ROOT',
                     'PARSER_ENGINE_CACHE_ROOT', 'PATTERN_ADAPTER_ROOT']
            environment.update({name: '/verified/' + name.lower() for name in names})
            def publish(): subprocess.run(['/bin/bash', '-euc', fragment], env=environment, check=True)
            publish(); original = target.read_bytes(); before = target.stat()
            self.assertEqual(before.st_mode & 0o777, 0o600)
            publish(); after = target.stat()
            self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))
            self.assertEqual(target.read_bytes(), original)
            target.chmod(0o644)
            publish()
            self.assertEqual(target.read_bytes(), original)
            self.assertEqual(target.stat().st_mode & 0o777, 0o600,
                             "an unchanged-byte hit must repair legacy public permissions")
            environment['MACHOKIT_ROOT'] = '/verified/changed'
            # Hold the current inode alive: Linux may recycle an earlier, already
            # replaced inode after the permission repair above.
            with target.open('rb') as prior_file:
                current_identity = os.fstat(prior_file.fileno()).st_ino
                publish()
                self.assertNotEqual(target.stat().st_ino, current_identity)
                self.assertEqual(prior_file.read(), original)
            self.assertIn(b'MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT = /verified/changed', target.read_bytes())
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            self.assertEqual(list(Path(directory).iterdir()), [target])
