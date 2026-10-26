"""Synthetic same-run evidence preservation only; no real receipts or builds."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

HELPER = Path(__file__).resolve().parents[1] / 'qualification/persistent_release_evidence.py'
spec = importlib.util.spec_from_file_location('persistent_evidence_test', HELPER)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class PersistentReleaseEvidenceTests(unittest.TestCase):
    def test_preserves_proof_and_objects_before_same_run_rebuild(self):
        native = m.native_module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            run = root / 'run.main-release-2'
            release = run / 'DerivedData/Build/Products/Release'
            golden = release / 'NativeDecompilerXPCService.xpc/Contents/Resources/NativeDecompilerBridgeGolden.json'
            provenance = release / 'MacScope.app/Contents/Resources/MacScopeBuildProvenance.json'
            for path in (golden, provenance):
                path.parent.mkdir(parents=True)
                path.write_text('{"accepted": true}')
            archive = run / 'DerivedData/Build/Intermediates.noindex/archive.a'
            archive.parent.mkdir(parents=True)
            archive.write_bytes(b'retained object archive')
            object_fields = native.fields(archive)
            (run / 'source').mkdir()
            (run / 'source/SOURCE_FILES.json').write_text('{"files": []}')
            (run / 'QUALIFICATION_INPUTS.json').write_text('{"old": true}')
            prior = {'head': 'old-component', 'oldGolden': native.record(golden),
                     'oldProvenance': native.record(provenance), 'sources': {'native.cpp': 'old'}}
            prior_path = root / 'OLD_PRIOR.json'
            native.D.publish(prior_path, prior)
            admission = {'scope': native.STANDARD_SCOPE, 'prior_inputs': native.record(prior_path),
                         'archive_receipt': native.record(prior_path), 'native_build_root': str(archive.parent),
                         'outputs': [native.record(archive)], 'receipt_directory': str(root)}
            admission_path = root / 'OLD_ADMISSION.json'
            native.D.publish(admission_path, admission)
            original_read = Path.read_bytes
            def receipt_only(path):
                if path in (golden, provenance, archive):
                    raise AssertionError('artifact read')
                return original_read(path)
            # Stale (pre-reboot) metadata in the recorded rows never blocks.
            prior_path.chmod(0o600)
            with mock.patch.object(Path, 'read_bytes', receipt_only):
                result = m.preserve(run, admission_path, native)
            current = native.read(result)
            projected = native.bound(current['prior_inputs'])
            self.assertEqual(native.bound(projected['retained_origin']), prior)
            self.assertEqual(native.fields(archive), object_fields)
            self.assertFalse(golden.exists())
            self.assertFalse(provenance.exists())
            self.assertTrue((result.parent / 'run-records/source/SOURCE_FILES.json').exists())
            self.assertTrue((result.parent / 'run-records/QUALIFICATION_INPUTS.json').exists())
            for key in ('oldGolden', 'oldProvenance'):
                self.assertEqual(native.bound(projected[key]), {'accepted': True})
            # Already preserved evidence is returned unchanged on the next run.
            self.assertEqual(m.preserve(run, result, native), result)


if __name__ == '__main__':
    unittest.main()
