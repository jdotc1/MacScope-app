"""Synthetic toolchain path admission: kinds and symlink targets, never metadata."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('tools_admission', Path(__file__).resolve().parents[1] / 'qualification/retained_toolchain_admission.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class RetainedToolchainTests(unittest.TestCase):
    def test_replaced_or_touched_tool_is_admitted_but_retargeted_link_is_not(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            target = root / 'tool'; target.write_bytes(b'original')
            link = root / 'selected'; link.symlink_to(target.name)
            rows = {}
            with mock.patch.object(Path, 'read_bytes', side_effect=AssertionError('no tool reads')):
                m._bind(link, rows)
                document = {'schema_version': 1, 'metadata': [{'path': p, 'snapshot': v} for p, v in rows.items()]}
                # New inode/ctime (a reboot, reinstall or touch) is immaterial.
                target.rename(root / 'prior'); target.write_bytes(b'original')
                m.revalidate(document)
                link.unlink(); link.symlink_to('prior')
                with self.assertRaisesRegex(ValueError, 'metadata changed'):
                    m.revalidate(document)

    def _developer(self, root, clang=b'clang build 1'):
        developer = root / 'Xcode.app/Contents/Developer'
        sdk = developer / 'Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
        tools = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin'
        for directory in (sdk, tools):
            directory.mkdir(parents=True, exist_ok=True)
        (developer.parent / 'version.plist').write_bytes(b'<plist>27A1</plist>')
        (sdk / 'SDKSettings.plist').write_bytes(b'<plist>sdk</plist>')
        (tools / 'clang++').write_bytes(clang)
        return developer

    def test_identity_files_match_the_canonical_qualifier_call(self):
        script = (Path(__file__).resolve().parents[1] / 'qualify_local_private_build.sh').read_text()
        call = script[script.index('CACHE_PLATFORM_IDENTITY="$("${DEPENDENCY_CACHE_TOOL[@]}" external-identity'):]
        call = call[:call.index('")"')]
        import re
        names = re.findall(r'--external-file "([a-z-]+)=', call)
        self.assertEqual([name for name, _ in m.platform_identity_files(Path('/D/Contents/Developer'))], names)

    def test_same_path_compiler_change_changes_the_platform_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            developer = self._developer(root)
            accepted = m.current_platform_identity(developer)
            self._developer(root, clang=b'clang build 2')  # in-place update, same path and size
            self.assertNotEqual(m.current_platform_identity(developer), accepted)
            self._developer(root, clang=b'clang build 1')  # reinstalling identical content is reusable
            self.assertEqual(m.current_platform_identity(developer), accepted)

    def test_identity_equals_the_qualifier_cli_value(self):
        import contextlib, io, subprocess, sys
        with tempfile.TemporaryDirectory() as temporary:
            developer = self._developer(Path(temporary).resolve())
            cache = Path(__file__).resolve().parents[1] / 'qualification/dependency_cache.py'
            args = [arg for name, path in m.platform_identity_files(developer)
                    for arg in ('--external-file', f'{name}={path}')]
            cli = subprocess.run([sys.executable, '-B', str(cache), 'external-identity', *args],
                                 check=True, capture_output=True, text=True).stdout.strip()
            self.assertEqual(m.current_platform_identity(developer), cli)


if __name__ == '__main__':
    unittest.main()
