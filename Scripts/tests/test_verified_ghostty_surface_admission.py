from pathlib import Path
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'Scripts/dependencies'))
import verified_ghostty_surface_admission as admission

DEV_CACHE_TOOL = ROOT / 'Scripts/qualification/dev_dependency_cache.py'
DEV_CACHE_SPEC = importlib.util.spec_from_file_location('ghostty_view_dev_cache_under_test', DEV_CACHE_TOOL)
assert DEV_CACHE_SPEC is not None and DEV_CACHE_SPEC.loader is not None
DEV_CACHE = importlib.util.module_from_spec(DEV_CACHE_SPEC)
DEV_CACHE_SPEC.loader.exec_module(DEV_CACHE)


class VerifiedGhosttySurfaceAdmissionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name).resolve()
        self.work = self.base / 'work'
        self.source = self.work / 'GhosttySurface'
        artifact = self.source / 'macos/GhosttyKit.xcframework'
        manifest = {'schema': '3', 'external_io_abi_version': '1', 'networking': 'disabled',
                    'architecture': 'arm64', 'library_identifier': 'macos-arm64'}
        for role, relative, _, digest_key in admission.LEAVES:
            path = artifact / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(role.encode())
            manifest[digest_key] = hashlib.sha256(path.read_bytes()).hexdigest()
        self.manifest = self.source / 'macos/.macscope-ghostty-surface-manifest'
        self.manifest.write_text(''.join(f'{k}={v}\n' for k,v in manifest.items()))
        identity = self.source / '.git/macscope-vendored-inputs'
        identity.parent.mkdir()
        identity.write_text('tree=verified\npackages=verified\nzig_receipt=verified\n')
        for path in [*self.source.rglob('*'), self.source]:
            path.chmod(0o555 if path.is_dir() else 0o444)
        self.descriptor = self.base / 'admission.json'
        self.digest = admission.describe(self.source, self.descriptor)

    def tearDown(self):
        for path in [self.base, *self.base.rglob('*')]:
            if not path.is_symlink():
                path.chmod(0o700 if path.is_dir() else 0o600)
        self.temp.cleanup()

    def test_verified_immutable_view_and_resume_descriptor_admitted(self):
        admission.admit(self.source, self.descriptor, self.digest)
        before = self.descriptor.stat()
        self.assertEqual(admission.describe(self.source, self.descriptor), self.digest)
        after = self.descriptor.stat()
        self.assertEqual((before.st_ino,before.st_mtime_ns),(after.st_ino,after.st_mtime_ns))

    def test_dev_cache_reuses_gitless_view_receipt_and_refuses_changed_leaf(self):
        # This is the frozen cache-view shape: the producer identity remains,
        # but HEAD is absent. The build script's --verify-only route needs HEAD.
        self.assertFalse((self.source / '.git/HEAD').exists())
        DEV_CACHE.verify_view('ghostty-surface', ROOT, self.source)
        view_directory = self.base / 'view-receipt'
        view_directory.mkdir()
        descriptors = DEV_CACHE.descriptors('ghostty-surface', ROOT, self.source, view_directory)
        entry = self.base / 'entry'
        entry.mkdir()
        records, total = DEV_CACHE.CACHE.payload_records(self.source)
        (entry / 'ENTRY.json').write_bytes(DEV_CACHE.CACHE.canonical_json(
            {'payload_records': records, 'total_bytes': total}))
        key = 'a' * 64
        receipt = view_directory / 'VIEW.json'
        value = {
            'schema_version': DEV_CACHE.VIEW_SCHEMA_VERSION,
            'component': 'ghostty-surface', 'key': key,
            'entry': str(entry), 'view': str(self.source),
            'entry_receipt_sha256': DEV_CACHE.CACHE.sha256(entry / 'ENTRY.json'),
            'entry_metadata_sha256': DEV_CACHE.CACHE.entry_metadata_digest(entry),
            'view_metadata_sha256': DEV_CACHE.CACHE.entry_metadata_digest(self.source),
            'descriptors': descriptors,
        }
        receipt.write_text(json.dumps(value))
        receipt.chmod(0o444)
        self.assertIsNotNone(DEV_CACHE.view_receipt_valid(
            receipt, entry, self.source, 'ghostty-surface', key
        ))
        archive = self.source / 'macos/GhosttyKit.xcframework/macos-arm64/libghostty-internal.a'
        os.utime(archive, ns=(1, 1))  # metadata only: still admitted
        self.assertIsNotNone(DEV_CACHE.view_receipt_valid(
            receipt, entry, self.source, 'ghostty-surface', key
        ))
        archive.chmod(0o644)
        archive.write_bytes(b'drift')
        archive.chmod(0o444)
        self.assertIsNone(DEV_CACHE.view_receipt_valid(
            receipt, entry, self.source, 'ghostty-surface', key
        ))
        with self.assertRaises(DEV_CACHE.DevCacheError):
            DEV_CACHE.descriptors('ghostty-surface', ROOT, self.source, view_directory)

    def test_leaf_drift_writable_input_and_changed_root_rejected(self):
        archive = self.source / 'macos/GhosttyKit.xcframework/macos-arm64/libghostty-internal.a'
        archive.chmod(0o644)
        with self.assertRaises(ValueError):
            admission.admit(self.source,self.descriptor,self.digest)
        archive.write_bytes(b'drift')
        archive.chmod(0o444)
        with self.assertRaises(ValueError):
            admission.admit(self.source,self.descriptor,self.digest)
        with self.assertRaises(ValueError):
            admission.admit(self.work,self.descriptor,self.digest)

    def test_descriptor_identity_and_symlink_rejected(self):
        with self.assertRaises(ValueError):
            admission.admit(self.source,self.descriptor,'0'*64)
        alias = self.base / 'alias'
        alias.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(ValueError):
            admission.admit(alias,self.descriptor,self.digest)

    def bootstrap_fragment(self, qualified):
        bootstrap = (ROOT / 'Scripts/bootstrap.sh').read_text()
        start = bootstrap.index('if [[ -n "${MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR:')
        end = bootstrap.index('echo "    Ghostty surface:', start)
        scripts = self.base / 'Scripts'
        (scripts / 'dependencies').mkdir(parents=True, exist_ok=True)
        for name in ('verified_ghostty_surface_admission.py','stage_verified_ghostty_surface.py'):
            shutil.copyfile(ROOT / 'Scripts/dependencies' / name, scripts / 'dependencies' / name)
        marker = self.base / 'producer-invoked'
        builder = scripts / 'dependencies/build_vendored_ghostty_surface.sh'
        builder.write_text('#!/bin/bash\nset -eu\n[ "$1" = --work-root ]\nprintf ordinary > "'+str(marker)+'"\n')
        builder.chmod(0o755)
        env = os.environ.copy()
        for key in ('MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR','MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR_SHA256'):
            env.pop(key,None)
        env.update(SCRIPT_DIR=str(scripts),GHOSTTY_SURFACE_SOURCE_DIR=str(self.source),GHOSTTY_SURFACE_WORK_ROOT=str(self.work))
        if qualified:
            env.update(MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR=str(self.descriptor),MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR_SHA256=self.digest)
        return bootstrap[start:end],env,marker

    def test_bootstrap_qualified_path_avoids_producer_ordinary_path_retains_it(self):
        fragment,env,marker = self.bootstrap_fragment(True)
        result = subprocess.run(['/bin/bash','-eu','-c',fragment],env=env,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(marker.exists())
        fragment,env,marker = self.bootstrap_fragment(False)
        result = subprocess.run(['/bin/bash','-eu','-c',fragment],env=env,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(marker.exists())

    def test_qualifier_creates_handoff_after_verification_and_exports_before_bootstrap(self):
        qualifier = (ROOT / 'Scripts/qualify_local_private_build.sh').read_text()
        create = qualifier.index('GHOSTTY_SURFACE_ADMISSION_SHA256=')
        self.assertGreater(create, qualifier.index('ghostty-surface "${GHOSTTY_SURFACE_CACHE_KEY}"'))
        export = qualifier.index('export MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR=')
        self.assertLess(create, export)
        self.assertLess(export, qualifier.index('timed_stage project.bootstrap'))
        self.assertIn('export MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR_SHA256="${GHOSTTY_SURFACE_ADMISSION_SHA256}"', qualifier)

    def test_partial_qualified_configuration_fails_without_fallback(self):
        fragment,env,marker = self.bootstrap_fragment(True)
        env.pop('MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR_SHA256')
        result = subprocess.run(['/bin/bash','-eu','-c',fragment],env=env,capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(marker.exists())

if __name__ == '__main__':
    unittest.main()
