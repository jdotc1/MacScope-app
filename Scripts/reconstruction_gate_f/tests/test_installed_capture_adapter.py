"""Portable physical observers; replace external tool output, never pass validators."""
import contextlib
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import sqlite3
import subprocess
import tempfile
from types import SimpleNamespace
from Scripts.lib.work_root import existing_work_root, work_root as macscope_work_root
import unittest
from unittest import mock

from Scripts.reconstruction_gate_f import installed_capture_adapter as adapter
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes
from Scripts.reconstruction_gate_f.command_catalog import installed_gate_output_slots
from Scripts.reconstruction_gate_f.schema import parse_candidate_identity, ReceiptType
from Scripts.reconstruction_gate_f.tests import candidate_mapping
from Scripts.tests.test_local_signing_policy import ArtifactFixtureRunner, make_artifact_bundle, update_release_provenance
from Scripts.tests.test_ws24_emit_installed_qualification_report import BridgeFixture


class InstalledCaptureAdapterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=existing_work_root())
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.source = make_artifact_bundle(self.root / 'release')
        update_release_provenance(self.source, git_head_commit='1' * 40, git_head_tree='2' * 40)
        self.app = self.root / 'installed/MacScope.app'
        shutil.copytree(self.source, self.app)
        self.runner = ArtifactFixtureRunner()
        self.addCleanup(mock.patch.stopall)
        mock.patch.object(adapter.signing, 'run_artifact_command', self.runner).start()
        mock.patch.object(adapter.materializer, '_run', self.codesign).start()
        identity = adapter.materializer._codesign_identity(self.source)
        mapping = candidate_mapping()
        mapping['source'].update(commit='1' * 40, tree='2' * 40)
        digests = adapter.materializer.bundle_tree_digests(self.source)
        mapping['application'].update(identity, bundle_sha256=digests.content_sha256,
            closed_tree_sha256=digests.closed_tree_sha256, root_mode=self.source.stat().st_mode & 0o7777,
            executable_sha256=hashlib.sha256((self.source / 'Contents/MacOS/MacScope').read_bytes()).hexdigest())
        self.candidate, issues = parse_candidate_identity(mapping)
        self.assertFalse(issues)
        self.inputs = dict(source_release_app=str(self.source), installed_app=str(self.app))

    def codesign(self, argv, **kwargs):
        if '--verify' in argv:
            return subprocess.CompletedProcess(argv, 0, '', '')
        if '--verbose=4' in argv:
            return subprocess.CompletedProcess(argv, 0, '', 'Authority=Fixture signer\nTeamIdentifier=TEAM000000\nCodeDirectory v=20500 flags=0x10000(runtime)\n')
        if '-r-' in argv:
            return subprocess.CompletedProcess(argv, 0, 'designated => fixture exact requirement\n', '')
        if '--entitlements' in argv:
            return subprocess.CompletedProcess(argv, 0, plistlib.dumps({}), b'')
        prefix = next(arg.split('=', 1)[1] for arg in argv if arg.startswith('--extract-certificates='))
        Path(prefix + '0').write_bytes(b'fixture certificate')
        return subprocess.CompletedProcess(argv, 0, '', '')

    def test_strict_observer_checks_real_bundle_and_tool_outcomes(self):
        self.assertEqual(adapter._bundle(self.source, self.candidate)['team_identifier'], 'TEAM000000')
        self.runner.override('verify', 'app', returncode=1, stderr='signature invalid')
        with self.assertRaisesRegex(ValueError, 'signing/provenance'):
            adapter._bundle(self.source, self.candidate)

    def test_bundle_mutations_reject_wrong_source_and_tree(self):
        for field, value in (('git_head_commit', 'a' * 40), ('git_head_tree', 'b' * 40)):
            path = self.source / 'Contents/Resources/MacScopeBuildProvenance.json'
            original = path.read_bytes()
            update_release_provenance(self.source, **{field: value})
            with self.subTest(field=field), self.assertRaises(ValueError):
                adapter._bundle(self.source, self.candidate)
            path.write_bytes(original)
        (self.source / 'Contents/Resources/new-resource').write_bytes(b'drift')
        with self.assertRaisesRegex(ValueError, 'closed tree'):
            adapter._bundle(self.source, self.candidate)

    def test_equality_reobserves_bytes_and_captured_json(self):
        value, errors = adapter.signing.collect_installed_source_equality(self.source, self.app)
        result = adapter._equality(self.inputs, self.candidate, canonical_bytes(value))
        self.assertEqual(result.get('release_root_mode'), self.source.stat().st_mode & 0o7777)
        self.assertEqual(result.get('installed_root_mode'), self.app.stat().st_mode & 0o7777)
        self.assertFalse(errors)
        self.assertEqual({k: v for k, v in result.items() if not k.endswith('_root_mode')}, value)
        wrong = dict(value, installed_executable_sha256='f' * 64)
        with self.assertRaisesRegex(ValueError, 'captured equality'):
            adapter._equality(self.inputs, self.candidate, canonical_bytes(wrong))
        (self.app / 'Contents/MacOS/MacScope').write_bytes(b'wrong app')
        with self.assertRaises(ValueError):
            adapter._equality(self.inputs, self.candidate, canonical_bytes(value))

    def test_preflight_uses_real_sqlite_grants_and_runner_identity(self):
        db = self.root / 'TCC.db'
        runner = self.root / 'Runner.app'
        helper = self.root / 'Helper.app'
        for app, identifier in ((runner, 'fixture.runner'), (helper, 'fixture.helper')):
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier}))
        with contextlib.closing(sqlite3.connect(db)) as connection, connection:
            connection.execute('CREATE TABLE access (service TEXT, client TEXT, auth_value INTEGER, last_modified INTEGER)')
            for service, client in ((adapter.preflight.DEVELOPER_TOOL, adapter.preflight.DEFAULT_XCODE_BUNDLE_ID),
                    (adapter.preflight.ACCESSIBILITY, adapter.preflight.DEFAULT_XCODE_BUNDLE_ID),
                    (adapter.preflight.ACCESSIBILITY, 'fixture.helper'), (adapter.preflight.ACCESSIBILITY, 'fixture.runner')):
                connection.execute('INSERT INTO access VALUES (?, ?, 2, 0)', (service, client))
        argv = ('/usr/bin/python3', '-B', 'Scripts/ws24_check_xcuitest_host.py', '--runner-app', str(runner),
                '--xcode-helper-app', str(helper), '--tcc-db', str(db), '--generated-at-unix-ms', '1234')
        payload = json.dumps(adapter.preflight.make_report(adapter.preflight.parse_args(list(argv[3:])))).encode()
        adapter._preflight(argv, payload)
        stale = json.loads(payload)
        stale['generatedAtUnixMs'] = 1
        with self.assertRaisesRegex(ValueError, 'differs'):
            adapter._preflight(argv, canonical_bytes(stale))
        with contextlib.closing(sqlite3.connect(db)) as connection, connection:
            connection.execute("UPDATE access SET auth_value = 0 WHERE client = 'fixture.runner'")
        with self.assertRaisesRegex(ValueError, 'denied'):
            adapter._preflight(argv, payload)
        self.assertIs(adapter.ROLES['installed.xcuitest-preflight'], ReceiptType.COMMAND_EXECUTION)

    def test_shell_uses_producer_schema_and_capture_interval(self):
        fixture = SimpleNamespace(installed_app=self.app, sha256=lambda p: hashlib.sha256(p.read_bytes()).hexdigest())
        report = BridgeFixture.shell_report(fixture, adapter.installed.FULL_SURFACE_MODE, generated=3000)
        path = self.root / 'shell.json'
        path.write_bytes(canonical_bytes(report))
        adapter._shell(path, self.inputs, self.candidate, 2900, 3100)
        for field, value in (('sourceCommit', 'f' * 40), ('sourceTree', 'f' * 40),
                ('status', 'failed'), ('appExecutableSHA256', 'f' * 64), ('generatedAtUnixMilliseconds', 2800)):
            path.write_bytes(canonical_bytes(dict(report, **{field: value})))
            with self.subTest(field=field), self.assertRaises((ValueError, adapter.installed.ReportError)):
                adapter._shell(path, self.inputs, self.candidate, 2900, 3100)
        path.write_bytes(canonical_bytes(dict(report, generatedAtUnixMilliseconds=3200)))
        with self.assertRaisesRegex(ValueError, 'escapes'):
            adapter._shell(path, self.inputs, self.candidate, 2900, 3100)

    def test_aggregate_envelopes_are_complete_and_revalidated(self):
        root = self.root / 'aggregate'
        root.mkdir()
        fixture = BridgeFixture(root)
        candidate, issues = parse_candidate_identity(json.loads(fixture.candidate_identity.read_bytes()))
        self.assertFalse(issues)
        # Real pending transaction and independently observed operability gates.
        _, state, gates = fixture.authority()
        gates.update({gate: ('a' * 64, 3100000000, 3100000000) for gate in ('cli', 'gui', 'mcp')})
        report = {'accepted': True, 'deficiencies': [], 'physical-fixture-only': True}
        fixture.output.write_bytes(canonical_bytes(report))
        digest = hashlib.sha256(fixture.output.read_bytes()).hexdigest()
        timestamp = fixture.output.stat().st_mtime_ns
        gates.update({gate: (digest, timestamp, timestamp) for gate in ('signing', 'shellbroker-launchagent')})
        adapter.installed.write_acceptance_gate_outputs(fixture.gate_outputs, state=state, gate_evidence=gates)
        inputs = {'installed_report': str(fixture.output)}
        inputs.update({name: str(fixture.gate_outputs[gate]) for gate, name in installed_gate_output_slots()})
        adapter._aggregate_outputs(inputs, candidate, report, state, dict(gates))
        # All producer-shaped bytes still pass; an external inode alias must
        # independently invalidate both the aggregate and every gate envelope.
        for index, output in enumerate((fixture.output, *fixture.gate_outputs.values())):
            alias = self.root / ('alias-' + str(index))
            os.link(output, alias)
            self.assertEqual(output.stat().st_nlink, 2)
            try:
                with self.subTest(output=output.name), self.assertRaisesRegex(ValueError, 'single-link'):
                    adapter._aggregate_outputs(inputs, candidate, report, state, dict(gates))
            finally:
                alias.unlink()
        adapter._aggregate_outputs(inputs, candidate, report, state, dict(gates))
        path = fixture.gate_outputs['mcp']
        original = path.read_bytes()
        path.unlink()
        with self.assertRaises((OSError, ValueError)):
            adapter._aggregate_outputs(inputs, candidate, report, state, dict(gates))
        mutated = json.loads(original)
        mutated['qualification_run_nonce'] = 'f' * 64
        path.write_bytes(canonical_bytes(mutated))
        with self.assertRaisesRegex(ValueError, 'envelope'):
            adapter._aggregate_outputs(inputs, candidate, report, state, dict(gates))
        path.write_bytes(original)
        fixture.output.write_bytes(canonical_bytes(dict(report, accepted=False)))
        with self.assertRaisesRegex(ValueError, 'aggregate differs'):
            adapter._aggregate_outputs(inputs, candidate, report, state, dict(gates))

    def test_shell_pair_requires_both_fresh_distinct_renderer_reports(self):
        fixture = SimpleNamespace(installed_app=self.app, sha256=lambda p: hashlib.sha256(p.read_bytes()).hexdigest())
        full = self.root / 'shell.json'
        legacy = self.root / 'shell.legacy-grid.json'
        first = BridgeFixture.shell_report(fixture, adapter.installed.FULL_SURFACE_MODE, generated=3000)
        second = BridgeFixture.shell_report(fixture, adapter.installed.LEGACY_GRID_MODE, generated=3050)
        full.write_bytes(canonical_bytes(first))
        legacy.write_bytes(canonical_bytes(second))
        inputs = dict(self.inputs, installed_shell_smoke_report=str(full), installed_full_surface_report=str(full),
                      installed_legacy_grid_report=str(legacy))
        adapter._shell_pair(inputs, self.candidate, 2900, 3100)
        legacy.unlink()
        with self.assertRaises((OSError, ValueError, adapter.installed.ReportError)):
            adapter._shell_pair(inputs, self.candidate, 2900, 3100)
        for mutated in (dict(second, sourceCommit='f' * 40), dict(second, generatedAtUnixMilliseconds=3200),
                        dict(second, observedReply='reply:another-run'),
                        dict(second, rendererEvidence=dict(second['rendererEvidence'], shellSessionID=first['rendererEvidence']['shellSessionID']))):
            legacy.write_bytes(canonical_bytes(mutated))
            with self.subTest(mutated=mutated), self.assertRaises((ValueError, adapter.installed.ReportError)):
                adapter._shell_pair(inputs, self.candidate, 2900, 3100)

    def test_favorable_json_is_not_capture_admission(self):
        with self.assertRaisesRegex(ValueError, 'independently retained'):
            adapter.validate_installed_outputs({'accepted': True})

    def test_log_and_capture_aliases_and_same_byte_replacements_reject(self):
        for name in ('captured.log', 'capture.json'):
            path = self.root / name
            path.write_bytes(b'original captured bytes')
            snapshot = adapter._snapshot_file(path, root=self.root)
            adapter._require_unchanged_files({path: snapshot})
            alias = self.root / ('alias-' + name)
            os.link(path, alias)
            try:
                with self.subTest(name=name, mutation='existing-hardlink'), self.assertRaisesRegex(ValueError, 'single-link'):
                    adapter._snapshot_file(path, root=self.root)
                with self.subTest(name=name, mutation='late-hardlink'), self.assertRaisesRegex(ValueError, 'single-link'):
                    adapter._require_unchanged_files({path: snapshot})
            finally:
                alias.unlink()
            snapshot = adapter._snapshot_file(path, root=self.root)
            replacement = self.root / ('replacement-' + name)
            replacement.write_bytes(snapshot[0])
            replacement.replace(path)
            self.assertEqual(path.read_bytes(), snapshot[0])
            with self.subTest(name=name, mutation='same-byte-inode-replacement'), self.assertRaisesRegex(ValueError, 'identity changed'):
                adapter._require_unchanged_files({path: snapshot})

    def test_final_source_fence_follows_real_signing_observation(self):
        producer = self.root / 'producer.py'
        original = b'original producer source\n'
        producer.write_bytes(original)
        admission = SimpleNamespace(capture=SimpleNamespace(admission=SimpleNamespace(candidate=self.candidate)))
        authority = adapter._observe('signing.strict-release', admission, None, None, None, self.inputs)
        def source_fence():
            if producer.read_bytes() != original:
                raise ValueError('producer source changed during physical observation')
        adapter._final_observation('signing.strict-release', admission, None, None, None,
                                   self.inputs, authority, source_fence)
        def late_tool_result(argv, **kwargs):
            # Raw tool output remains valid and the original signing observer
            # still derives the same authority, but producer bytes changed.
            producer.write_bytes(b'changed during second codesign observation\n')
            return self.codesign(argv, **kwargs)
        with mock.patch.object(adapter.materializer, '_run', late_tool_result):
            with self.assertRaisesRegex(ValueError, 'source changed'):
                adapter._final_observation('signing.strict-release', admission, None, None, None,
                                           self.inputs, authority, source_fence)


if __name__ == '__main__':
    unittest.main()
