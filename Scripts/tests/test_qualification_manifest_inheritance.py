"""Synthetic contracts only; never consult retained source or dependency caches."""
import json
import shutil
from pathlib import Path
import tempfile
import unittest

from Scripts.qualification.qualification_manifest_inheritance import SPECS, admit_manifests, revalidate, copy_admitted_machokit

REPOSITORY = Path(__file__).resolve().parents[2]


class ManifestInheritanceTests(unittest.TestCase):
    def test_machokit_view_is_keyed_by_source_closure_and_refills_partial_copy(self):
        def source(root, blob):
            (root / 'Scripts').mkdir(parents=True)
            shutil.copy2(REPOSITORY / 'Scripts/machokit_source_identity.py', root / 'Scripts')
            rows = [{'path': 'ThirdParty/MachOKit/Package.swift', 'blob_oid': blob, 'sha256': 'a' * 64}]
            (root / 'SOURCE_FILES.json').write_text(json.dumps({'files': rows}))
        old_source, new_source = self.root / 'old/source', self.root / 'new/source'
        source(old_source, 'b' * 40)
        source(new_source, 'b' * 40)
        self.write(self.old / 'QUALIFICATION_INPUTS.json', dict(self.prior, build_source_root=str(old_source)))
        accepted = self.old / 'private-machokit-input'
        (accepted / 'Sources').mkdir(parents=True)
        (accepted / 'Sources/MachOKit.swift').write_text('pinned')
        destination = self.run / 'private-machokit-input'
        (destination / 'Sources').mkdir(parents=True)
        (destination / 'Sources/partial.swift').write_text('left by an interrupted run')
        (destination / 'Sources').chmod(0o555)
        copy_admitted_machokit(new_source, self.receipt, destination)
        self.assertEqual(sorted(p.name for p in destination.rglob('*')), ['MachOKit.swift', 'Sources'])
        rows = json.loads((new_source / 'SOURCE_FILES.json').read_text())
        rows['files'][0]['blob_oid'] = 'c' * 40
        (new_source / 'SOURCE_FILES.json').write_text(json.dumps(rows))
        with self.assertRaisesRegex(ValueError, 'closure differs'):
            copy_admitted_machokit(new_source, self.receipt, destination)

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='manifest-inheritance-')
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.cache = self.root / 'cache'
        self.run = self.root / 'new'
        self.old = self.root / 'old'
        contract = {'component_manifest_sha256': 'a' * 64, 'component_pins': [], 'notices_sha256': 'b' * 64}
        self.current = {'dependency_cache_root': str(self.cache), 'source_identity': {
            'git_head_commit': 'c' * 40, 'git_head_tree': 'd' * 40, 'dependency_contract': contract}}
        self.prior = dict(self.current, schema_version=4, mode='release', dependency_network_used=False)
        self.events = {'schema_version': 1, 'dependency_cache_root': str(self.cache),
                       'source': {'commit': 'c' * 40, 'tree': 'd' * 40}, 'events': []}
        for component, field, root_field, relative, view_relative in SPECS:
            key = 'e' * 64
            entry = self.cache / 'artifacts/v1' / component / key
            view = self.run / 'dependencies' / component
            if component == 'ghostty-vt':
                root = self.run / 'dependencies/ghostty-vt-qualification'
            elif component == 'sleigh-native-source':
                root = view / 'materialization'
            else:
                root = view
            self.current[root_field] = str(root)
            self.prior[field] = 'f' * 64
            rows = [{'path': relative, 'kind': 'file', 'sha256': 'f' * 64, 'size': 5}]
            self.file(root / view_relative)
            self.file(view / relative)
            if component == 'ghostty-vt':
                for leaf in ('artifacts/lib/libghostty-vt.0.1.0.dylib',
                             'artifacts/include/ghostty/vt.h', 'artifacts/include/module.modulemap'):
                    self.file(view / leaf)
                    rows.append({'path': leaf, 'kind': 'file', 'sha256': 'f' * 64, 'size': 5})
                self.file(root / 'zig-out/lib/libghostty-vt.dylib')
            self.write(entry / 'ENTRY.json', {'schema_version': 1, 'component': component,
                                             'key': key, 'payload_records': rows})
            self.events['events'].append({'component': component, 'entry': str(entry), 'key': key,
                                         'run_view': str(view), 'status': 'receipt-reused-hit'})
        self.receipt = self.old / 'QUALIFICATION_INPUTS.json'
        self.event_path = self.run / 'DEPENDENCY_CACHE_EVENTS.json'
        self.write(self.receipt, self.prior)
        self.write(self.old / 'DEPENDENCY_CACHE_EVENTS.json', self.events)
        self.write(self.event_path, self.events)

    def file(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('dummy')

    def write(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))

    def test_inherits_declared_identities_regardless_of_file_metadata(self):
        for path in (self.receipt, self.event_path):
            path.chmod(0o444)  # Mode/ctime changes (as after a reboot) are immaterial.
        digests, lease = admit_manifests(self.receipt, self.current, self.event_path)
        self.assertEqual(digests, {spec[1]: 'f' * 64 for spec in SPECS})
        revalidate(lease)
        self.event_path.chmod(0o644)
        self.event_path.unlink()
        with self.assertRaisesRegex(ValueError, 'disappeared'):
            revalidate(lease)

    def test_refuses_changed_dependency_contract(self):
        changed = json.loads(json.dumps(self.current))
        changed['source_identity']['dependency_contract']['notices_sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'contract differs'):
            admit_manifests(self.receipt, changed, self.event_path)

    def test_refuses_nonreused_dependency_event(self):
        self.events['events'][0]['status'] = 'published-miss'
        self.write(self.event_path, self.events)
        with self.assertRaisesRegex(ValueError, 'not reused'):
            admit_manifests(self.receipt, self.current, self.event_path)
