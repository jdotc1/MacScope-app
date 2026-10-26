"""Synthetic list-schema cases; no retained package bytes or digests are read."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / 'qualification/build_native_release_archive.py'
spec = importlib.util.spec_from_file_location('native_release_producer', SOURCE)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class NativeReleaseListAdmissionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.package = self.root / 'staged'
        include = self.package / 'package/include/sleigh'
        include.mkdir(parents=True)
        self.header = include / 'fixture.hpp'
        self.header.write_text('// synthetic header\n')
        members = ['package', 'package/include', 'package/include/sleigh',
                   'package/include/sleigh/fixture.hpp']
        snapshot = [[p, 'directory' if (self.package / p).is_dir() else 'file',
                     m.metadata(self.package / p), None] for p in members]
        receipt = self.root / 'receipt.json'
        receipt.write_text(json.dumps({'root': str(self.package),
                                      'rootFields': m.metadata(self.package),
                                      'identity': {'package': {'relativeRoot': 'package'}},
                                      'snapshot': snapshot}))
        self.prior = {'stagedReceipt': {'path': str(receipt), 'fields': m.metadata(receipt)}}

    def test_list_snapshot_admits_without_reading_leaf_bytes(self):
        with mock.patch.object(Path, 'read_bytes', side_effect=AssertionError('leaf read')):
            identity = m.admitted_materialization(self.prior, self.package)
        self.assertEqual(identity['package']['relativeRoot'], 'package')

    def test_list_snapshot_rejects_changed_header_metadata(self):
        self.header.write_text('// changed synthetic header length\n')
        with self.assertRaisesRegex(ValueError, 'accepted native include identity changed'):
            m.admitted_materialization(self.prior, self.package)


if __name__ == '__main__':
    unittest.main()
