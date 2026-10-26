"""Exercise isolated generation and failure-safe publication with real Xcode."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('json_generator', Path(__file__).resolve().parents[1] / 'generate_xcode_json_project.py')
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class JSONGenerationTests(unittest.TestCase):
    def fixture(self, root):
        source = root / 'MacScope'
        source.mkdir()
        (source / 'App.swift').write_text('public struct Example {}\n')
        (source / 'project.yml').write_text('name: MacScope\ntargets:\n  Example:\n    type: framework\n    platform: macOS\n    sources: [App.swift]\n')
        return source

    @unittest.skipUnless(shutil.which('xcodegen') and shutil.which('xcodebuild'), 'requires Xcode and XcodeGen')
    def test_generation_is_repeatable_and_preserves_workspace_and_custom_scheme(self):
        with tempfile.TemporaryDirectory() as directory:
            source = self.fixture(Path(directory))
            generator.generate(source, Path(shutil.which('xcodegen')))
            project = source / 'MacScope.xcodeproj'
            original = (project / 'project.xcproj').read_bytes()
            custom = project / 'xcshareddata/xcschemes/Custom.xcscheme'
            custom.parent.mkdir(parents=True, exist_ok=True)
            custom.write_text('custom scheme sentinel')
            user = project / 'xcuserdata/private'
            user.parent.mkdir()
            user.write_text('workspace sentinel')
            generator.generate(source, Path(shutil.which('xcodegen')))
            self.assertEqual(original, (project / 'project.xcproj').read_bytes())
            self.assertFalse((project / 'project.pbxproj').exists())
            self.assertEqual((project / 'project.xcproj').stat().st_mode & 0o777, 0o644)
            self.assertEqual(custom.read_text(), 'custom scheme sentinel')
            self.assertEqual(user.read_text(), 'workspace sentinel')

    def test_all_declared_external_sources_and_resources_exist_in_isolated_generation(self):
        # Exercise the real declarative path inventory at the XcodeGen boundary,
        # stopping before any Xcode conversion or generated-project publication.
        import re
        project_text = (Path(__file__).resolve().parents[2] / 'MacScope/project.yml').read_text()
        references = re.findall(r'^\s+(?:- )?path: (\.\./[^\s]+)\s*$', project_text, re.MULTILINE)
        self.assertIn('../ThirdParty/REA/generated/REAEmbeddedIdentity.swift', references)
        self.assertIn('../ThirdParty/REA/generated/MacScopeREAKernel.js', references)
        self.assertIn('../ThirdParty/REA/licenses', references)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.fixture(root)
            for relative in set(references):
                path = source / relative
                if relative.endswith(('.swift', '.js')):
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_bytes(b'governed source sentinel')
                else:
                    path.mkdir(parents=True, exist_ok=True)
                    (path / 'sentinel').write_bytes(b'governed resource sentinel')
            observed = []
            def run(command, *, cwd, check):
                self.assertEqual(command[-1], 'generate')
                for relative in references:
                    original, staged = source / relative, Path(cwd) / relative
                    self.assertTrue(staged.exists(), relative)
                    self.assertEqual(staged.resolve(), original.resolve(), relative)
                observed.append(True)
                raise subprocess.CalledProcessError(1, 'stop-before-conversion')
            with patch.object(generator.subprocess, 'run', side_effect=run):
                with self.assertRaises(subprocess.CalledProcessError):
                    generator.generate(source)
            self.assertEqual(observed, [True])
            self.assertFalse((source / 'MacScope.xcodeproj').exists())

    def test_symlinked_rea_root_rejected_before_generator_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.fixture(root)
            outside = root / 'outside'; outside.mkdir()
            dependency = root / 'ThirdParty/REA'
            dependency.parent.mkdir(); dependency.symlink_to(outside, target_is_directory=True)
            with patch.object(generator.subprocess, 'run') as run:
                with self.assertRaisesRegex(ValueError, 'REA input root'):
                    generator.generate(source)
                run.assert_not_called()

    def test_recovery_package_root_is_staged_before_generator_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.fixture(root)
            package = root / 'Packages/RecoveryKit'
            package.mkdir(parents=True)
            (package / 'Package.swift').write_text('// local package sentinel\n')
            package_source = package / 'Sources/RecoveryKit/Recovery.swift'
            package_source.parent.mkdir(parents=True)
            package_source.write_text('public struct Recovery {}\n')
            observed = []

            def run(command, *, cwd, check):
                self.assertEqual(command[-1], 'generate')
                staged = Path(cwd).parent / 'Packages/RecoveryKit'
                self.assertEqual(staged.resolve(), package.resolve())
                self.assertEqual((staged / 'Package.swift').read_text(),
                                 '// local package sentinel\n')
                self.assertEqual((staged / 'Sources/RecoveryKit/Recovery.swift').read_text(),
                                 'public struct Recovery {}\n')
                observed.append(True)
                raise subprocess.CalledProcessError(1, 'stop-before-conversion')

            with patch.object(generator.subprocess, 'run', side_effect=run):
                with self.assertRaises(subprocess.CalledProcessError):
                    generator.generate(source)
            self.assertEqual(observed, [True])
            self.assertFalse((source / 'MacScope.xcodeproj').exists())

    def test_symlinked_recovery_package_root_rejected_before_generator_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.fixture(root)
            outside = root / 'outside'
            outside.mkdir()
            package = root / 'Packages/RecoveryKit'
            package.parent.mkdir()
            package.symlink_to(outside, target_is_directory=True)
            with patch.object(generator.subprocess, 'run') as run:
                with self.assertRaisesRegex(ValueError, 'RecoveryKit input root.*ordinary directory'):
                    generator.generate(source)
                run.assert_not_called()

    def test_unchanged_publication_preserves_identity_and_changed_bytes_replace_atomically(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'input'
            self.assertTrue(generator._publish_bytes_if_changed(destination, b'first'))
            before = destination.stat()
            self.assertEqual(before.st_mode & 0o777, 0o644)
            self.assertFalse(generator._publish_bytes_if_changed(destination, b'first'))
            after = destination.stat()
            self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))
            replace = os.replace
            observed = []
            def atomic(source, target):
                self.assertEqual(destination.read_bytes(), b'first')
                self.assertEqual(Path(source).read_bytes(), b'second')
                self.assertEqual(Path(source).parent, destination.parent)
                observed.append(True)
                replace(source, target)
            with patch.object(generator.os, 'replace', side_effect=atomic):
                self.assertTrue(generator._publish_bytes_if_changed(destination, b'second'))
            self.assertEqual(observed, [True])
            self.assertEqual(destination.read_bytes(), b'second')
            self.assertNotEqual(destination.stat().st_ino, before.st_ino)
            self.assertEqual(list(Path(directory).iterdir()), [destination])

    def test_publish_file_follows_caller_umask_and_satisfies_restore_contract(self):
        """Bootstrap publishes the local xcconfig under qualification's ``umask 077``; restore
        requires an ordinary single-link mode-0600 file. A fixed 0644 failed every passing gate."""
        script = Path(__file__).resolve().parents[1] / 'generate_xcode_json_project.py'
        restore_path = Path(__file__).resolve().parents[1] / 'qualification' / 'restore_build_source.py'
        restore_spec = importlib.util.spec_from_file_location('restore_build_source_for_mode', restore_path)
        restore = importlib.util.module_from_spec(restore_spec)
        restore_spec.loader.exec_module(restore)
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'DependencyRoots.local.xcconfig'
            for umask, expected in ((0o077, 0o600), (0o022, 0o644)):
                completed = subprocess.run(
                    ['/bin/sh', '-c', f'umask {umask:03o}; exec "$0" -B "$1" --publish-file "$2"',
                     sys.executable, str(script), str(destination)],
                    input=b'MACSCOPE_X = 1\n', capture_output=True, check=False,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertEqual(destination.stat().st_mode & 0o777, expected)
            # Republishing identical bytes under the stricter umask must correct the mode too.
            completed = subprocess.run(
                ['/bin/sh', '-c', 'umask 077; exec "$0" -B "$1" --publish-file "$2"',
                 sys.executable, str(script), str(destination)],
                input=b'MACSCOPE_X = 1\n', capture_output=True, check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
            self.assertEqual(
                restore._read_stable_regular_file(destination, 'generated dependency-roots xcconfig'),
                b'MACSCOPE_X = 1\n',
            )

    def test_unchanged_bytes_still_reject_unsafe_destination_and_failed_replace_preserves_old(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = root / 'original'; original.write_bytes(b'first')
            for mode in ('symlink', 'hardlink', 'fifo'):
                target = root / mode
                if mode == 'symlink': target.symlink_to(original)
                elif mode == 'hardlink': os.link(original, target)
                else: os.mkfifo(target)
                with self.assertRaises(ValueError): generator._publish_bytes_if_changed(target, b'first')
                target.unlink()
            with patch.object(generator.os, 'replace', side_effect=OSError('publication interrupted')):
                with self.assertRaises(OSError): generator._publish_bytes_if_changed(original, b'second')
            self.assertEqual(original.read_bytes(), b'first')
            self.assertEqual(list(root.iterdir()), [original])

    def test_mocked_repeated_generation_preserves_project_shared_and_user_state(self):
        with tempfile.TemporaryDirectory() as directory:
            source = self.fixture(Path(directory))
            state = {'project': '{}', 'scheme': 'first'}
            def run(command, *, cwd, check):
                generated = Path(cwd) / 'MacScope.xcodeproj'
                generated.mkdir(exist_ok=True)
                (generated / 'project.xcproj').write_text(state['project'])
                workspace = generated / 'project.xcworkspace'; workspace.mkdir(exist_ok=True)
                (workspace / 'contents.xcworkspacedata').write_text('workspace')
                shared = generated / 'xcshareddata/xcschemes'; shared.mkdir(parents=True, exist_ok=True)
                (shared / 'MacScopeApp.xcscheme').write_text(state['scheme'])
            with patch.object(generator.subprocess, 'run', side_effect=run):
                generator.generate(source)
                project = source / 'MacScope.xcodeproj'
                custom = project / 'xcshareddata/xcschemes/Custom.xcscheme'; custom.write_text('custom')
                paths = [project / 'project.xcproj', project / 'xcshareddata/xcschemes/MacScopeApp.xcscheme',
                         project / 'project.xcworkspace/contents.xcworkspacedata', custom]
                identity = lambda path: (path.stat().st_ino, path.stat().st_mtime_ns)
                before = [identity(path) for path in paths]
                generator.generate(source)
                self.assertEqual(before, [identity(path) for path in paths])
                state.update(project='{"new":true}', scheme='second')
                generator.generate(source)
                self.assertEqual(paths[0].read_text(), state['project'])
                self.assertEqual(paths[1].read_text(), 'second')
                self.assertEqual(before[2:], [identity(path) for path in paths[2:]])
                self.assertFalse((project / 'project.pbxproj').exists())

    def test_failed_generation_does_not_replace_existing_project(self):
        with tempfile.TemporaryDirectory() as directory:
            source = self.fixture(Path(directory))
            project = source / 'MacScope.xcodeproj'
            project.mkdir()
            (project / 'project.xcproj').write_text('original')
            with patch.object(generator.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'xcodegen')):
                with self.assertRaises(subprocess.CalledProcessError):
                    generator.generate(source)
            self.assertEqual((project / 'project.xcproj').read_text(), 'original')

    def test_gitless_local_lumen_package_is_visible_to_isolated_generation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.fixture(root)
            package = root / 'ThirdParty/Lumen'
            package.mkdir(parents=True)
            (package / 'Package.swift').write_text('// sealed local Lumen package\n')
            package_source = package / 'Sources/LumenTokens/Token.swift'
            package_source.parent.mkdir(parents=True)
            package_source.write_text('public struct Token {}\n')

            def run(command, *, cwd, check):
                staged_package = Path(cwd).parent / 'ThirdParty/Lumen'
                self.assertTrue((staged_package / 'Package.swift').is_file(),
                                'The local package must exist beside isolated MacScope')
                self.assertEqual((staged_package / 'Sources/LumenTokens/Token.swift').read_text(),
                                 'public struct Token {}\n')
                self.assertFalse((staged_package / '.git').exists(),
                                 'A sealed source export does not require Git metadata')
                generated = Path(cwd) / 'MacScope.xcodeproj'
                generated.mkdir(exist_ok=True)
                (generated / 'project.xcproj').write_text('{}')
                workspace = generated / 'project.xcworkspace'
                workspace.mkdir(exist_ok=True)
                (workspace / 'contents.xcworkspacedata').write_text('workspace')

            with patch.object(generator.subprocess, 'run', side_effect=run):
                generator.generate(source)
            self.assertEqual((source / 'MacScope.xcodeproj/project.xcproj').read_text(), '{}')

    def test_lumen_package_root_symlink_is_rejected_before_generation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.fixture(root)
            external = root / 'external-package'
            external.mkdir()
            third_party = root / 'ThirdParty'
            third_party.mkdir()
            (third_party / 'Lumen').symlink_to(external, target_is_directory=True)
            with patch.object(generator.subprocess, 'run') as run:
                with self.assertRaisesRegex(ValueError, 'Lumen.*ordinary'):
                    generator.generate(source)
                run.assert_not_called()

    def test_refuses_legacy_project_instead_of_overwriting_it(self):
        with tempfile.TemporaryDirectory() as directory:
            source = self.fixture(Path(directory))
            project = source / 'MacScope.xcodeproj'
            project.mkdir()
            (project / 'project.pbxproj').write_text('original')
            with self.assertRaisesRegex(ValueError, 'convert the existing'):
                generator.generate(source)
            self.assertEqual((project / 'project.pbxproj').read_text(), 'original')


    def test_publishes_only_official_json_using_selected_absolute_tool(self):
        with tempfile.TemporaryDirectory() as directory:
            source = self.fixture(Path(directory))
            tool = Path(directory) / 'verified-xcodegen'
            calls = []
            def run(command, *, cwd, check):
                calls.append(command)
                staged = Path(cwd) / 'MacScope.xcodeproj'
                if command[0] == str(tool):
                    staged.mkdir()
                    (staged / 'project.pbxproj').write_text('intermediate')
                else:
                    self.assertEqual(command[:4], ['/usr/bin/xcrun', 'xcodebuild', '-convert-project', 'Xcode Project'])
                    (staged / 'project.pbxproj').unlink()
                    (staged / 'project.xcproj').write_text('{"official":"JSON"}')
                    (staged / 'project.xcproj').chmod(0o644)
                    (staged / 'project.xcworkspace').mkdir()
                    (staged / 'project.xcworkspace/contents.xcworkspacedata').write_text('official workspace')
            with patch.object(generator.subprocess, 'run', side_effect=run):
                generator.generate(source, tool)
            self.assertEqual(calls[0], [str(tool), 'generate'])
            self.assertEqual((source / 'MacScope.xcodeproj/project.xcworkspace/contents.xcworkspacedata').read_text(), 'official workspace')
            self.assertFalse((source / 'MacScope.xcodeproj/project.pbxproj').exists())
            self.assertEqual((source / 'MacScope.xcodeproj/project.xcproj').read_text(), '{"official":"JSON"}')
            workspace = source / 'MacScope.xcodeproj/project.xcworkspace/contents.xcworkspacedata'
            workspace.write_text('existing user workspace')
            with patch.object(generator.subprocess, 'run', side_effect=run):
                with self.assertRaisesRegex(ValueError, 'differ from generated authority'):
                    generator.generate(source, tool)
            self.assertEqual(workspace.read_text(), 'existing user workspace')

    def test_missing_or_symlinked_generated_workspace_refuses_publication(self):
        for mode in ('missing', 'symlink'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                source = self.fixture(Path(directory))
                def run(command, *, cwd, check):
                    generated = Path(cwd) / 'MacScope.xcodeproj'
                    generated.mkdir(exist_ok=True)
                    (generated / 'project.xcproj').write_text('{}')
                    if mode == 'symlink':
                        workspace = generated / 'project.xcworkspace'
                        workspace.mkdir(exist_ok=True)
                        target = generated / 'workspace-target'
                        target.write_text('workspace')
                        path = workspace / 'contents.xcworkspacedata'
                        if not path.is_symlink():
                            path.symlink_to(target)
                with patch.object(generator.subprocess, 'run', side_effect=run):
                    with self.assertRaises((ValueError, OSError)):
                        generator.generate(source)
                self.assertFalse((source / 'MacScope.xcodeproj/project.xcproj').exists())

    def test_shared_hardlink_or_symlink_never_modifies_outside_alias(self):
        for mode in ('destination-hardlink', 'destination-symlink', 'source-symlink', 'destination-fifo'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source, target = root / 'generated', root / 'existing'
                source.mkdir(); target.mkdir()
                outside = root / 'outside'
                outside.write_bytes(b'untouched')
                source_file, target_file = source / 'MacScopeApp.xcscheme', target / 'MacScopeApp.xcscheme'
                source_file.write_bytes(b'new')
                if mode == 'destination-hardlink': os.link(outside, target_file)
                elif mode == 'destination-symlink': target_file.symlink_to(outside)
                elif mode == 'destination-fifo': os.mkfifo(target_file)
                else:
                    source_file.unlink(); source_file.symlink_to(outside)
                with self.assertRaises(ValueError):
                    generator._publish_shared(source, target)
                self.assertEqual(outside.read_bytes(), b'untouched')

    def test_invalid_converted_json_preserves_all_existing_output(self):
        for payload in ('not JSON', '{"x":1,"x":2}', ' ' * (generator.MAX_PROJECT_BYTES + 1)):
            with self.subTest(size=len(payload)), tempfile.TemporaryDirectory() as directory:
                source = self.fixture(Path(directory))
                project = source / 'MacScope.xcodeproj'
                project.mkdir()
                existing = project / 'project.xcproj'
                existing.write_bytes(b'original')
                def run(command, *, cwd, check):
                    generated = Path(cwd) / 'MacScope.xcodeproj'
                    generated.mkdir(exist_ok=True)
                    (generated / 'project.xcproj').write_text(payload)
                with patch.object(generator.subprocess, 'run', side_effect=run):
                    with self.assertRaises(ValueError): generator.generate(source)
                self.assertEqual(list(project.iterdir()), [existing])
                self.assertEqual(existing.read_bytes(), b'original')
