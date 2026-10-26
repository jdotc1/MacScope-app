"""Synthetic native Release admissions keyed by git identity, digests and toolchain."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / 'qualification/native_release_admission.py'
SPEC = importlib.util.spec_from_file_location('native_release_admission', SOURCE)
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)

PROVIDER = 'Tools/NativeDecompilerBridge/src/GhidraProvider.cpp'
CONSUMER = 'Scripts/qualification/dev_dependency_cache.py'
TOOLCHAIN = {'DEVELOPER_DIR': '/Xcode/Developer', 'SDKROOT': '/Xcode/SDK', 'SDK_NAME': 'macosx27.0',
             'SDK_VERSION': '27.0', 'SDK_PRODUCT_BUILD_VERSION': '27A1', 'ARCHS': 'arm64',
             'MACOSX_DEPLOYMENT_TARGET': '27.0'}
STALE = [1, 2, 3, 4, 5, 6, 7]  # A pre-reboot lstat row: never compared.


class NativeReleaseAdmissionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def write(self, name, value):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))
        path.chmod(0o400)
        return {'path': str(path), 'fields': STALE}

    def admission(self):
        build = self.root / 'build'
        for name in m.OUTPUTS:
            (build / name).parent.mkdir(parents=True, exist_ok=True)
            (build / name).write_bytes(b'archive')
        package = self.root / 'package'
        (package / 'lib').mkdir(parents=True)
        (package / 'lib/libdecomp.a').write_bytes(b'decomp')
        (package / 'lib/libdecomp.a').chmod(0o444)
        golden = {'passed': True, 'wrapperGitRevision': 'w', 'goldenSourceSHA256': 'g'}
        golden_row = self.write('golden.json', golden)
        provenance = self.write('provenance.json', {'git_head_commit': 'c' * 40,
                                                    'native_decompiler_golden_result': golden,
                                                    'native_decompiler_engine': 'ghidra'})
        staged = self.write('staged.json', {'root': str(package), 'snapshot': [], 'identity': {}})
        outputs = [{'path': str(build / n), 'fields': STALE, 'sha256': 'a' * 64} for n in m.OUTPUTS]
        archive = self.write('archive.json', {
            'scope': 'accepted-standard-native-Release-component', 'source_commit': 'c' * 40,
            'native_build_root': str(build), 'toolchain': TOOLCHAIN, 'outputs': outputs,
            'computation_receipt': golden_row['path'], 'wrapper_profile': 'w', 'golden_profile': 'g',
            'accepted_authorities': [{'path': str(self.root / 'gone.json'), 'fields': STALE}],
            'package_identities': {}})
        prior = self.write('prior.json', {'oldGolden': golden_row, 'oldProvenance': provenance,
                                          'stagedReceipt': staged, 'toolchain': TOOLCHAIN})
        receipts = self.root / 'receipts'
        receipts.mkdir(mode=0o700)
        sources = {PROVIDER: {'blob_oid': 'b' * 40, 'mode': '100644'},
                   CONSUMER: {'blob_oid': 'd' * 40, 'mode': '100644'}}
        self.write('admission.json', {
            'schema_version': 1, 'scope': m.STANDARD_SCOPE, 'component_source_commit': 'c' * 40,
            'native_build_root': str(build), 'native_sources': sources, 'archive_receipt': archive,
            'prior_inputs': prior, 'outputs': outputs, 'receipt_directory': str(receipts)})
        env = dict(TOOLCHAIN, CONFIGURATION='Release', SWIFT_OPTIMIZATION_LEVEL='-O',
                   **{m.ENV: str(self.root / 'admission.json')})
        records = {path: dict(row, path=path) for path, row in sources.items()}
        return env, records

    def admit(self, env, records):
        with mock.patch.object(m, 'source_paths', return_value=sorted(records)):
            return m.admit(self.root, environment=env, source_records=records)

    def test_stale_metadata_and_moved_authorities_never_block_reuse(self):
        env, records = self.admission()
        # Reboot/move: every recorded lstat row is stale, receipts are now
        # writable, and an accepted authority file no longer exists.
        for name in ('admission.json', 'archive.json', 'prior.json'):
            (self.root / name).chmod(0o644)
        value = self.admit(env, records)
        self.assertEqual(value['golden']['passed'], True)
        self.assertEqual(value['staged']['root'], str(self.root / 'package'))

    def test_git_identity_and_toolchain_still_bind(self):
        env, records = self.admission()
        changed = dict(records, **{PROVIDER: dict(records[PROVIDER], blob_oid='e' * 40)})
        with self.assertRaisesRegex(ValueError, 'source/profile differs'):
            self.admit(env, changed)
        with self.assertRaisesRegex(ValueError, 'toolchain differs: SDK_PRODUCT_BUILD_VERSION'):
            self.admit(dict(env, SDK_PRODUCT_BUILD_VERSION='27A2'), records)
        consumer = dict(records, **{CONSUMER: dict(records[CONSUMER], blob_oid='f' * 40)})
        self.assertIn(CONSUMER, self.admit(env, consumer)['consumer_source_updates'])

    def test_missing_component_output_is_reported_plainly(self):
        env, records = self.admission()
        (self.root / 'build' / m.OUTPUTS[0]).unlink()
        with self.assertRaisesRegex(ValueError, 'output is missing \\(rebuild the native component\\)'):
            self.admit(env, records)

    def test_incomplete_package_copy_and_stale_phase_outputs_are_regenerated(self):
        env, records = self.admission()
        value = self.admit(env, records)
        resources = self.root / 'App/Resources'
        leftover = resources / 'NativeDecompilerPackage/lib/libdecomp.a'
        leftover.parent.mkdir(parents=True)
        leftover.write_bytes(b'partial')
        leftover.chmod(0o444)
        golden = resources / 'NativeDecompilerBridgeGolden.json'
        golden.write_text('stale')
        golden.chmod(0o444)
        marker = self.root / 'temp/NativeReleaseAdmission/bridge.json'
        marker.parent.mkdir(parents=True)
        marker.write_text('{"admission": {"path": "old", "fields": [1]}}')
        phase_env = dict(env, TARGET_BUILD_DIR=str(self.root / 'App'), UNLOCALIZED_RESOURCES_FOLDER_PATH='Resources',
                         TARGET_TEMP_DIR=str(self.root / 'temp'),
                         MACSCOPE_NATIVE_DECOMPILER_BUILD_ROOT=str(self.root / 'build'))
        for selected in ('bridge', 'package', 'golden'):
            m.phase(value, selected, phase_env)
        self.assertEqual(leftover.read_bytes(), b'decomp')
        self.assertEqual(json.loads(golden.read_text())['passed'], True)
        self.assertEqual(m.read(marker)['archive'], str(self.root / 'archive.json'))
        self.assertEqual(m.copy_package(value, self.root / 'package')['method'], 'retained-original-view')

    def test_source_manifest_rejects_duplicates(self):
        path = self.root / 'SOURCE_FILES.json'
        path.write_text('{"files": [], "files": []}')
        with self.assertRaisesRegex(ValueError, 'duplicate receipt field'):
            m.source_manifest(path)
        path.write_text(json.dumps({'files': [{'path': 'same'}, {'path': 'same'}]}))
        with self.assertRaisesRegex(ValueError, 'duplicate source manifest path'):
            m.source_manifest(path)

    def test_standard_cache_consumer_update_preserves_compiled_closure(self):
        accepted = {CONSUMER: {'blob_oid': 'a' * 40, 'mode': '100644'},
                    PROVIDER: {'blob_oid': 'b' * 40, 'mode': '100644'}}
        current = {**accepted, CONSUMER: {'blob_oid': 'c' * 40, 'mode': '100644'}}
        updates = m.accepted_source_updates(current, accepted, standard=True)
        self.assertEqual(updates, {CONSUMER: {'accepted': accepted[CONSUMER], 'current': current[CONSUMER]}})
        with self.assertRaisesRegex(ValueError, 'source/profile differs'):
            m.accepted_source_updates(current, accepted, standard=False)
        with self.assertRaisesRegex(ValueError, 'membership differs'):
            m.accepted_source_updates({CONSUMER: current[CONSUMER]}, accepted, standard=True)

    def test_native_filelists_retain_existing_output_ownership_without_self_inputs(self):
        receipts = self.root / 'receipts'
        receipts.mkdir(mode=0o700)
        build = self.root / 'native-build'
        value = {'receipt_directory': str(receipts), 'native_build_root': str(build),
                 'archive_receipt': {'path': str(self.root / 'archive.json')},
                 'prior_inputs': {'path': str(self.root / 'prior.json')}}
        m.write_filelists(value, self.root / 'admission.json')
        outputs = (receipts / 'bridge-outputs.xcfilelist').read_text().splitlines()
        inputs = (receipts / 'bridge-inputs.xcfilelist').read_text().splitlines()
        for relative in (*m.OUTPUTS, 'CMakeCache.txt', 'macscope-native-decompiler-link-inputs.xcfilelist'):
            self.assertIn(str(build / relative), outputs)
        self.assertEqual(inputs, [str(self.root / 'admission.json'), str(self.root / 'archive.json')])
        build.mkdir()
        self.assertEqual(m.project_paths(value), (str(build), str(receipts)))
        with self.assertRaisesRegex(ValueError, 'absolute single-line'):
            m.project_paths(dict(value, receipt_directory='relative-directory'))


if __name__ == '__main__':
    unittest.main()
