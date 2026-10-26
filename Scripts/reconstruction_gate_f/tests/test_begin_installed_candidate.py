"""Actual portable installation transactions; only external signing tools replaced."""
import contextlib
import functools
import importlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from types import SimpleNamespace
import unittest
from unittest import mock

from Scripts.reconstruction import install_release_to_applications as installer
from Scripts.reconstruction import app_quiescence
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes
from Scripts.reconstruction_gate_f.tests import test_installed_capture_adapter as physical
from Scripts.tests import test_install_release_to_applications as transactions
from Scripts.tests import test_app_quiescence as census_fixtures


class BeginInstalledCandidateTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(importlib.util.find_spec('Scripts.reconstruction_gate_f.begin_installed_candidate'),
                             'the production BEGIN bridge is absent')
        self.bridge = importlib.import_module('Scripts.reconstruction_gate_f.begin_installed_candidate')
        self.fixture = physical.InstalledCaptureAdapterTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        # Only external observations are controlled. The real fail-closed guard
        # and its bounded libproc census decoder remain active in every test.
        self.census = census_fixtures.FakeLibproc()
        self.census.paths = {os.getpid(): str(Path(sys.executable).resolve()).encode() + b'\0'}
        real_process_paths = app_quiescence._process_paths
        mock.patch.object(app_quiescence, '_bundle_applications', return_value=()).start()
        mock.patch.object(app_quiescence, '_process_paths',
            side_effect=lambda: real_process_paths(libproc=self.census)).start()
        f = self.fixture
        self.root, self.source, self.installed = f.root, f.source, f.app
        self.artifacts, self.candidate = self.root / 'begin-artifacts', self.root / 'candidate.json'
        owner = transactions.InstallReleaseToApplicationsTests()
        self.owner = owner
        owner.candidate, owner.atomic_calls = self.candidate, []
        owner.root, owner.artifacts, owner.applications = self.root, self.artifacts, self.installed.parent
        owner._write_candidate(self.source)
        mapping = json.loads(self.candidate.read_bytes())
        mapping['application'].update(physical.adapter.materializer._codesign_identity(self.source))
        self.candidate.write_bytes(canonical_bytes(mapping))
        self.real_main = installer.main
        mock.patch.object(installer, 'main', functools.partial(self.real_main,
            _allow_test_destination=True, _atomic_rename=owner._atomic_rename)).start()
        self.args = ['--candidate-identity', str(self.candidate), '--source-app', str(self.source),
            '--installed-app', str(self.installed), '--artifact-root', str(self.artifacts),
            '--qualification-run-id', 'run-fixture', '--qualification-run-nonce', '7' * 64,
            '--command-predecessor-observations-sha256', '8' * 64]

    def run_bridge(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = self.bridge.main(self.args)
        return status, out.getvalue(), err.getvalue()

    def launch_owned_process(self, app):
        executable = app / 'Contents/MacOS/MacScope'
        # Real process lifetime, controlled external executable-identity census.
        # This does not launch the synthetic unsigned bundle or any user app.
        process = subprocess.Popen(['/bin/cat'], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)

        def close_owned_process():
            # EOF stops only this test-owned child; no process receives a signal.
            process.communicate(timeout=5)

        self.addCleanup(close_owned_process)
        process.stdin.write(b'owned-process-ready\n')
        process.stdin.flush()
        self.assertEqual(process.stdout.readline(), b'owned-process-ready\n')
        self.census.paths[process.pid] = str(executable).encode() + b'\0'
        return process

    def assert_live_process_refuses_begin(self, app):
        process = self.launch_owned_process(app)
        before = {path: installer._capture_exact_bundle(path) for path in (self.source, self.installed)}
        with mock.patch.object(installer, 'main', wraps=installer.main) as observed_installer:
            status, stdout, stderr = self.run_bridge()
        self.assertNotEqual(status, 0)
        self.assertIn('app quiescence unproven', stderr)
        self.assertIn('PID ' + str(process.pid), stderr)
        self.assertEqual(observed_installer.call_count, 0, 'neither BEGIN nor rollback may be invoked')
        self.assertNotIn('MACSCOPE_INSTALL_RELEASE_PHASE=', stdout)
        self.assertFalse(tuple(self.installed.parent.glob('.MacScope.pending-*')))
        self.assertIsNone(process.poll(), 'the guard must not signal even this owned test child')
        for path, snapshot in before.items():
            self.assertEqual(installer._capture_exact_bundle(path), snapshot)

    def test_live_source_process_refuses_begin_without_any_installer_mutation(self):
        self.assert_live_process_refuses_begin(self.source)

    def test_live_installed_process_refuses_begin_without_any_installer_mutation(self):
        self.assert_live_process_refuses_begin(self.installed)

    def test_live_process_after_begin_preserves_owned_pending_instead_of_rollback(self):
        retained = {}

        def fail_publication_after_process_start(*_args):
            retained['process'] = self.launch_owned_process(self.installed)
            pending, = tuple(self.installed.parent.glob('.MacScope.pending-*'))
            state, snapshot = installer._pending_read_stable(pending)
            retained.update(pending=pending, state=state, snapshot=snapshot,
                predecessor=installer._capture_exact_bundle(Path(state['predecessor_path'])),
                installed=installer._capture_exact_bundle(self.installed))
            raise OSError('fixture projection failure after process start')

        with mock.patch.object(self.bridge, '_publish', side_effect=fail_publication_after_process_start), \
                mock.patch.object(installer, 'main', wraps=installer.main) as observed_installer:
            status, stdout, stderr = self.run_bridge()
        self.assertNotEqual(status, 0)
        self.assertIn('fixture projection failure', stderr)
        self.assertIn('app quiescence unproven', stderr)
        self.assertIn('exact transaction recovery required; state preserved', stderr)
        self.assertEqual([call.args[0][1] for call in observed_installer.call_args_list], ['begin'])
        self.assertNotIn('MACSCOPE_INSTALL_RELEASE_PHASE=rolled-back', stdout)
        self.assertIsNone(retained['process'].poll())
        self.assertEqual(installer._pending_read_stable(retained['pending']),
                         (retained['state'], retained['snapshot']))
        self.assertEqual(installer._capture_exact_bundle(Path(retained['state']['predecessor_path'])),
                         retained['predecessor'])
        self.assertEqual(installer._capture_exact_bundle(self.installed), retained['installed'])

    def test_actual_begin_retains_exact_state_and_separates_digests(self):
        expected = installer.capture_predecessor_observation(self.installed)
        status, out, err = self.run_bridge()
        self.assertEqual(status, 0, err)
        projection = json.loads((self.artifacts / 'GateFInstalledBegin.projection.json').read_bytes())
        self.assertEqual(projection['command_predecessor_observations_sha256'], '8' * 64)
        self.assertEqual(projection['physical_predecessor']['sha256'], expected.sha256)
        self.assertNotEqual(expected.sha256, '8' * 64)
        retained = self.bridge.retained_state(projection)
        state, actual = installer._pending_read_stable(retained.path.parent)
        self.assertEqual(retained, actual)
        self.assertEqual(state['predecessor_observations_sha256'], expected.sha256)
        self.assertIn('MACSCOPE_INSTALL_RELEASE_PHASE=pending', out)
        recovery_lines = [line for line in out.splitlines() if line.startswith('MACSCOPE_GATE_F_INSTALLED_BEGIN_RECOVERY=')]
        self.assertEqual(len(recovery_lines), 1, 'pre-mutation recovery identity must be retained')
        recovery = json.loads(recovery_lines[0].partition('=')[2])
        self.assertEqual(recovery['transaction_nonce'], state['transaction_nonce'])
        self.assertEqual(recovery['physical_predecessor_sha256'], expected.sha256)
        self.assertLess(out.index('MACSCOPE_GATE_F_INSTALLED_BEGIN_RECOVERY='), out.index('MACSCOPE_INSTALL_RELEASE_PHASE=pending'))
        self.assertFalse((self.artifacts / installer.ACCEPTANCE_RECEIPT_NAME).exists())
        equality, errors = installer.collect_installed_source_equality(self.source, self.installed)
        self.assertFalse(errors)
        equality.update(release_root_mode=self.source.stat().st_mode & 0o7777,
                        installed_root_mode=self.installed.stat().st_mode & 0o7777)
        self.assertEqual(json.loads((self.artifacts / 'GateFInstalledBegin.source-equality.json').read_bytes()), equality)

    def test_output_collision_rejects_before_destination_mutation(self):
        self.artifacts.mkdir(mode=0o700)
        output = self.artifacts / 'GateFInstalledBegin.projection.json'
        output.symlink_to(self.candidate)
        before = installer.capture_predecessor_observation(self.installed)
        status, _, err = self.run_bridge()
        self.assertNotEqual(status, 0)
        self.assertIn('output', err)
        self.assertEqual(installer.capture_predecessor_observation(self.installed).sha256, before.sha256)
        self.assertFalse(tuple(self.installed.parent.glob('.MacScope.pending-*')))

    def assert_bundle_nested_output_rejected_unchanged(self, app, *, alias_flag=None):
        target = app / 'Contents/begin-artifacts'
        self.args[self.args.index('--artifact-root') + 1] = str(target)
        if alias_flag is not None:
            alias = self.root / 'bundle-parent-alias'
            alias.symlink_to(app.parent, target_is_directory=True)
            self.args[self.args.index(alias_flag) + 1] = str(alias / app.name)
        snapshots = {path: installer._capture_exact_bundle(path) for path in (self.source, self.installed)}
        status, stdout, _ = self.run_bridge()
        self.assertNotEqual(status, 0)
        self.assertFalse(target.exists(), 'rejected nested output must not be created inside an app')
        self.assertNotIn('MACSCOPE_GATE_F_INSTALLED_BEGIN_RECOVERY=', stdout)
        for path, before in snapshots.items():
            after = installer._capture_exact_bundle(path)
            self.assertEqual(after, before, 'rejected request changed the complete bundle snapshot')

    def test_source_nested_output_rejects_before_any_bundle_write(self):
        self.assert_bundle_nested_output_rejected_unchanged(self.source)

    def test_installed_nested_output_rejects_before_any_bundle_write(self):
        self.assert_bundle_nested_output_rejected_unchanged(self.installed)

    def test_source_parent_alias_cannot_hide_nested_output(self):
        self.assert_bundle_nested_output_rejected_unchanged(self.source, alias_flag='--source-app')

    def test_installed_parent_alias_cannot_hide_nested_output(self):
        self.assert_bundle_nested_output_rejected_unchanged(self.installed, alias_flag='--installed-app')

    def test_post_begin_publication_failure_rolls_back_owned_transaction(self):
        before = installer.capture_predecessor_observation(self.installed)
        with mock.patch.object(self.bridge, '_publish', side_effect=OSError('fixture disk failure')):
            status, out, err = self.run_bridge()
        self.assertNotEqual(status, 0)
        self.assertIn('rolled-back', out)
        self.assertIn('fixture disk failure', err)
        restored = installer.capture_predecessor_observation(self.installed)
        self.assertEqual(restored.snapshot.digests, before.snapshot.digests)
        self.assertEqual(restored.snapshot.directory_identity[:3], before.snapshot.directory_identity[:3])
        self.assertFalse(tuple(self.installed.parent.glob('.MacScope.pending-*')))

    def test_existing_pending_cannot_be_relabelled_fresh(self):
        status, _, err = self.run_bridge()
        self.assertEqual(status, 0, err)
        self.args[self.args.index('--artifact-root') + 1] = str(self.root / 'another-root')
        status, _, err = self.run_bridge()
        self.assertNotEqual(status, 0)
        self.assertIn('existing transaction', err)
        self.assertEqual(len(tuple(self.installed.parent.glob('.MacScope.pending-*'))), 1)

    def test_rollback_failure_preserves_exact_pending_state_and_reports_recovery(self):
        original = installer.main
        def fail_rollback(argv, **kwargs):
            return 1 if argv[argv.index('--phase') + 1] == 'rollback' else original(argv, **kwargs)
        with mock.patch.object(self.bridge, '_publish', side_effect=OSError('fixture disk failure')), \
                mock.patch.object(installer, 'main', side_effect=fail_rollback):
            status, stdout, err = self.run_bridge()
        self.assertNotEqual(status, 0)
        self.assertIn('exact transaction recovery required; state preserved', err)
        self.assertNotIn('MACSCOPE_GATE_F_INSTALLED_BEGIN_PROJECTION=', stdout)
        pending = tuple(self.installed.parent.glob('.MacScope.pending-*'))
        self.assertEqual(len(pending), 1)
        state, _ = installer._pending_read_stable(pending[0])
        self.assertEqual(state['phase'], 'pending')
        self.assertTrue(Path(state['predecessor_path']).is_dir())

    def test_actual_commit_keeps_begin_projection_replayable(self):
        started = time.time_ns() // 1_000_000
        status, stdout, err = self.run_bridge()
        ended = time.time_ns() // 1_000_000
        self.assertEqual(status, 0, err)
        projection_path = self.artifacts / 'GateFInstalledBegin.projection.json'
        original_bytes = projection_path.read_bytes()
        projection = json.loads(original_bytes)
        retained = self.bridge.retained_state(projection)
        state = json.loads(retained.payload)
        token = state['candidate_token']
        # Synthetic eight-gate envelopes exercise the real transaction state
        # machine; they make no app/GUI/native acceptance claim.
        self.owner._write_acceptance_receipt(token)
        argv = ['--phase', 'commit', '--transaction-token', token,
            '--candidate-identity', str(self.candidate), '--source-app', str(self.source),
            '--installed-app', str(self.installed), '--artifact-root', str(self.artifacts),
            '--qualification-run-id', 'run-fixture', '--qualification-run-nonce', '7' * 64,
            '--predecessor-observations-sha256', projection['physical_predecessor']['sha256']]
        for gate in self.owner.acceptance_gate_arguments:
            argv += ['--acceptance-gate-input', gate]
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = installer.main(argv)
        self.assertEqual(status, 0, err.getvalue())
        self.assertFalse(retained.path.exists())
        self.assertEqual(projection_path.read_bytes(), original_bytes)
        candidate = installer._load_source_authority(self.candidate, self.source).candidate
        inputs = dict(candidate_identity_path=str(self.candidate), source_release_app=str(self.source),
            installed_app=str(self.installed), install_release_artifact_root=str(self.artifacts))
        run = SimpleNamespace(run_id='run-fixture', nonce='7' * 64)
        value = physical.adapter._begin_outputs(inputs, candidate, run, stdout.encode(), started, ended, '8' * 64)
        self.assertEqual(value['installed_root_mode'], self.installed.stat().st_mode & 0o7777)
        committed = installer._committed_root(self.installed, token, state['transaction_id'])
        marker = committed / installer.COMMIT_AUTHORITY_NAME
        marker.unlink()
        with self.assertRaises((ValueError, physical.adapter.installed.ReportError)):
            physical.adapter._begin_outputs(inputs, candidate, run, stdout.encode(), started, ended, '8' * 64)

    def test_projection_rejects_changed_state_digest_and_unknown_fields(self):
        status, _, err = self.run_bridge()
        self.assertEqual(status, 0, err)
        projection = json.loads((self.artifacts / 'GateFInstalledBegin.projection.json').read_bytes())
        projection['pending_state']['sha256'] = '0' * 64
        with self.assertRaises(ValueError):
            self.bridge.retained_state(projection)
        projection['unexpected'] = True
        with self.assertRaises(ValueError):
            self.bridge.retained_state(projection)

    def test_adapter_binds_real_begin_to_capture_markers_digest_and_interval(self):
        started = time.time_ns() // 1_000_000
        status, stdout, err = self.run_bridge()
        ended = time.time_ns() // 1_000_000
        self.assertEqual(status, 0, err)
        self.assertTrue(hasattr(physical.adapter, '_begin_outputs'), 'BEGIN physical adapter is absent')
        candidate = installer._load_source_authority(self.candidate, self.source).candidate
        inputs = dict(candidate_identity_path=str(self.candidate), source_release_app=str(self.source),
            installed_app=str(self.installed), install_release_artifact_root=str(self.artifacts))
        run = SimpleNamespace(run_id='run-fixture', nonce='7' * 64)
        value = physical.adapter._begin_outputs(inputs, candidate, run, stdout.encode(), started, ended, '8' * 64)
        self.assertEqual(value['installed_root_mode'], self.installed.stat().st_mode & 0o7777)
        for text, start, digest in ((stdout, started, '9' * 64), (stdout, ended + 1, '8' * 64),
                                   (stdout.replace('PHASE=pending', 'PHASE=committed'), started, '8' * 64)):
            with self.subTest(start=start, digest=digest), self.assertRaises(ValueError):
                physical.adapter._begin_outputs(inputs, candidate, run, text.encode(), start, ended, digest)
