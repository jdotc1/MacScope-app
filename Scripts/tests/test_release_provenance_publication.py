"""New descriptor publication behavior; synthetic files only."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location('publication', Path(__file__).resolve().parents[1] / 'qualification/release_provenance_admission.py')
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)


class ReleasePublicationTests(unittest.TestCase):
    def test_new_native_package_does_not_invalidate_unchanged_ghostty_evidence(self):
        old = {'ghostty_surface_manifest_sha256': 'ghostty',
               'sleigh_materialization_manifest_sha256': 'old-native'}
        evidence = {'configuration': 'Release',
                    'ghostty_surface_source_manifest_sha256': 'ghostty'}
        def read_json(path, label):
            return old if path.name == 'QUALIFICATION_INPUTS.json' else evidence
        admitted = {'current_release': True,
                    'overlay': {'retained_release_qualification_inputs': '/retained/QUALIFICATION_INPUTS.json'},
                    'receipt': dict(old, sleigh_materialization_manifest_sha256='new-native')}
        self.assertEqual(publication.retained_release_evidence(admitted, read_json), evidence)
        admitted.pop('retained_release_evidence')
        admitted['receipt']['ghostty_surface_manifest_sha256'] = 'changed-ghostty'
        with self.assertRaises(publication.AdmissionError):
            publication.retained_release_evidence(admitted, read_json)
        admitted['receipt']['ghostty_surface_manifest_sha256'] = 'ghostty'
        admitted['current_release'] = False
        with self.assertRaises(publication.AdmissionError):
            publication.retained_release_evidence(admitted, read_json)

    def test_publication_reuses_held_input_without_reading_or_hashing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            accepted = root / 'accepted'; accepted.write_bytes(b'accepted bytes')
            output = root / 'provenance.json'
            lease = publication.Lease()
            try:
                lease.file(accepted)
                with mock.patch.object(os, 'read', side_effect=AssertionError('no input read')):
                    publication.publish(output, b'{"new":true}\n', lease, lambda: None)
                self.assertEqual(output.read_bytes(), b'{"new":true}\n')
            finally:
                lease.close()

    def test_changed_input_stops_before_replacing_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            accepted = root / 'accepted'; accepted.write_bytes(b'accepted')
            output = root / 'provenance.json'; output.write_bytes(b'previous')
            lease = publication.Lease()
            try:
                lease.file(accepted)
                accepted.write_bytes(b'modified')
                with self.assertRaises(publication.AdmissionError):
                    publication.publish(output, b'new', lease, lambda: None)
                self.assertEqual(output.read_bytes(), b'previous')
            finally:
                lease.close()

    def test_swapped_parent_stops_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            parent = root / 'inputs'; parent.mkdir()
            accepted = parent / 'accepted'; accepted.write_bytes(b'accepted')
            lease = publication.Lease()
            try:
                lease.file(accepted)
                parent.rename(root / 'old_inputs'); parent.mkdir()
                (parent / 'accepted').write_bytes(b'accepted')
                with self.assertRaises(publication.AdmissionError):
                    publication.publish(root / 'provenance.json', b'new', lease, lambda: None)
            finally:
                lease.close()

    def test_current_release_unpacks_inherited_digests_and_holds_consulted_files(self):
        import types
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            run = root / 'run'; run.mkdir()
            receipt_path = run / 'QUALIFICATION_INPUTS.json'
            for path in (receipt_path, root / 'SOURCE_PROVENANCE.json', root / 'SOURCE_FILES.json',
                         run / 'DEPENDENCY_CACHE_EVENTS.json'):
                path.write_text('{}')
            retained = root / 'retained.json'; retained.write_text('{}')
            consulted = root / 'manifest'; consulted.write_text('manifest')
            manifest = types.SimpleNamespace(
                admit_manifests=lambda *args: ({'ghostty_surface_manifest_sha256': 'g'}, [consulted]))
            native = types.SimpleNamespace(admit=lambda root, source_records: {'native': True})
            helpers = {'qualification_manifest_inheritance.py': manifest,
                       'native_release_admission.py': native}
            with mock.patch.dict(os.environ, {'MACSCOPE_RETAINED_RELEASE_QUALIFICATION_INPUTS': str(retained)}), \
                    mock.patch.object(publication, 'load_helper', lambda root, name: helpers[name]):
                admitted = publication.admit_current(
                    root, receipt_path, {'ghostty_surface_manifest_sha256': 'g'}, [], None)
            try:
                self.assertIn(consulted, admitted['lease'].files)
                consulted.write_text('changed manifest')
                with self.assertRaises(publication.AdmissionError):
                    publication.revalidate(admitted)
            finally:
                publication.close(admitted)


if __name__ == '__main__':
    unittest.main()
