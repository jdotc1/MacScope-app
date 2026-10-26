"""Capture-owned bridge to the production installer's pending BEGIN phase.

No acceptance is claimed here. The outer operator owns commit after all eight
gates, and owns recovery after process timeout/cancellation. Ordinary Python
failures after begin attempt the original rollback for this exact fresh nonce.
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import io
import os
from pathlib import Path
import secrets
import stat
import sys
import time

if __package__ in {None, ''}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from Scripts.reconstruction import install_release_to_applications as installer
from Scripts.reconstruction.app_quiescence import require_app_quiescent
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes, decode_canonical_bytes, canonical_sha256
from Scripts.reconstruction_gate_f.schema import is_sha256

PROJECTION_NAME = 'GateFInstalledBegin.projection.json'
EQUALITY_NAME = 'GateFInstalledBegin.source-equality.json'
PROJECTION_FIELDS = frozenset({'schema_version', 'projection_kind',
    'command_predecessor_observations_sha256', 'physical_predecessor', 'pending_state'})


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('candidate-identity', 'source-app', 'installed-app', 'artifact-root'):
        parser.add_argument('--' + name, required=True, type=Path)
    for name in ('qualification-run-id', 'qualification-run-nonce', 'command-predecessor-observations-sha256'):
        parser.add_argument('--' + name, required=True)
    return parser.parse_args(argv)


def retained_state(projection):
    """Decode exact originally observed bytes/metadata, never synthesize a stat."""
    if (not isinstance(projection, dict) or set(projection) != PROJECTION_FIELDS
            or type(projection['schema_version']) is not int or projection['schema_version'] != 1
            or projection['projection_kind'] != 'macscope-gate-f-installed-begin'
            or not is_sha256(projection['command_predecessor_observations_sha256'])):
        raise ValueError('invalid installed begin projection schema')
    physical = projection['physical_predecessor']
    if (not isinstance(physical, dict) or set(physical) != {'document', 'sha256'}
            or not isinstance(physical['document'], dict)
            or set(physical['document']) != {'identity', 'present'}
            or type(physical['document']['present']) is not bool
            or physical['sha256'] != canonical_sha256(physical['document'])):
        raise ValueError('invalid installed begin physical predecessor')
    value = projection['pending_state']
    if (not isinstance(value, dict) or set(value) != {'path', 'metadata', 'payload_utf8', 'sha256'}
            or not isinstance(value['path'], str) or not Path(value['path']).is_absolute()
            or Path(value['path']).name != 'transaction.json'
            or not isinstance(value['metadata'], list) or len(value['metadata']) != 6
            or any(type(v) is not int or v < 0 for v in value['metadata'])
            or value['metadata'][2] != 0o600 or not isinstance(value['payload_utf8'], str)):
        raise ValueError('invalid installed begin retained state')
    payload = value['payload_utf8'].encode('utf-8')
    if (len(payload) > installer.MAX_PENDING_TRANSACTION_BYTES
            or value['metadata'][3] != len(payload)
            or hashlib.sha256(payload).hexdigest() != value['sha256']):
        raise ValueError('installed begin retained state digest/length differs')
    state = decode_canonical_bytes(payload)
    if (state['predecessor_observations_sha256'] != physical['sha256']
            or state['predecessor_present'] != physical['document']['present']
            or state['predecessor_identity'] != physical['document']['identity']):
        raise ValueError('installed begin physical predecessor differs from state')
    return installer.StableFile(Path(value['path']), tuple(value['metadata']), payload)


def projection_document(snapshot, physical, command_digest):
    value = dict(schema_version=1, projection_kind='macscope-gate-f-installed-begin',
        command_predecessor_observations_sha256=command_digest,
        physical_predecessor=dict(document=physical.document, sha256=physical.sha256),
        pending_state=dict(path=str(snapshot.path), metadata=list(snapshot.metadata),
            payload_utf8=snapshot.payload.decode('utf-8'), sha256=hashlib.sha256(snapshot.payload).hexdigest()))
    retained_state(value)
    return value


def expected_markers(state, snapshot):
    return {
        'MACSCOPE_INSTALL_RELEASE_PHASE': 'pending',
        'MACSCOPE_INSTALL_RELEASE_CANDIDATE_TOKEN': state['candidate_token'],
        'MACSCOPE_INSTALL_RELEASE_TRANSACTION_ID': state['transaction_id'],
        'MACSCOPE_INSTALL_RELEASE_TRANSACTION_NONCE': state['transaction_nonce'],
        'MACSCOPE_INSTALL_RELEASE_PENDING_STATE': str(snapshot.path),
        'MACSCOPE_INSTALL_RELEASE_PENDING_STATE_SHA256': hashlib.sha256(snapshot.payload).hexdigest(),
        'MACSCOPE_INSTALL_RELEASE_ACCEPTANCE_RECEIPT': state['acceptance_receipt_path'],
    }


def recovery_document(*, token, nonce, physical_digest, run_id, run_nonce, artifact_root, pending_state):
    return dict(candidate_token=token, transaction_nonce=nonce,
        physical_predecessor_sha256=physical_digest, qualification_run_id=run_id,
        qualification_run_nonce=run_nonce, artifact_root=str(artifact_root),
        pending_state_path=str(pending_state))


def validate_markers(stdout, state, snapshot, artifact_root):
    expected = expected_markers(state, snapshot)
    expected.update(MACSCOPE_GATE_F_INSTALLED_BEGIN_PROJECTION=str(artifact_root / PROJECTION_NAME),
        MACSCOPE_GATE_F_INSTALLED_BEGIN_SOURCE_EQUALITY=str(artifact_root / EQUALITY_NAME))
    expected['MACSCOPE_GATE_F_INSTALLED_BEGIN_RECOVERY'] = canonical_bytes(recovery_document(
        token=state['candidate_token'], nonce=state['transaction_nonce'],
        physical_digest=state['predecessor_observations_sha256'], run_id=state['qualification_run_id'],
        run_nonce=state['qualification_run_nonce'], artifact_root=artifact_root, pending_state=snapshot.path)).decode('utf-8')
    found = {}
    for line in stdout.decode('utf-8').splitlines():
        if line.startswith(('MACSCOPE_INSTALL_RELEASE_', 'MACSCOPE_GATE_F_INSTALLED_BEGIN_')):
            key, separator, value = line.partition('=')
            if not separator or key in found:
                raise ValueError('duplicate or malformed installed begin marker')
            found[key] = value
    if found != expected:
        raise ValueError('installed begin markers differ from retained transaction')


def _root_identity(path):
    metadata = installer._directory_anchor(path, label='begin output root')
    if metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) & 0o077:
        raise ValueError('begin output root must be private and owned by this user')
    return metadata.st_dev, metadata.st_ino


def _publish(descriptor, document):
    payload = canonical_bytes(document)
    offset = 0
    while offset < len(payload):
        count = os.write(descriptor, payload[offset:])
        if count <= 0:
            raise OSError('begin output write made no progress')
        offset += count
    os.fsync(descriptor)


def main(argv=None):
    args = parse_args(argv)
    descriptors = {}
    owned_nonce = None
    authority = physical = None
    invocation = []
    root_fd = None
    try:
        if not is_sha256(args.command_predecessor_observations_sha256):
            raise ValueError('command predecessor digest must be lowercase SHA-256')
        # Reuse the installer's canonical-path and disjointness rules before
        # creating even an empty output: those writes would invalidate an app
        # when a caller placed the artifact root inside either signed bundle.
        source_app = installer._canonical_existing(args.source_app, directory=True, label='source app')
        installed_app = installer._canonical_destination(args.installed_app)
        root = installer._canonical_transaction_artifact_root(args.artifact_root)
        if root in {source_app, installed_app} or source_app in root.parents or installed_app in root.parents:
            raise ValueError('artifact root must be disjoint from source and installed apps')
        if not root.exists():
            os.mkdir(root, 0o700)
        root_identity = _root_identity(root)
        root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        if (os.fstat(root_fd).st_dev, os.fstat(root_fd).st_ino) != root_identity:
            raise ValueError('begin output root changed while opening')
        for name in (PROJECTION_NAME, EQUALITY_NAME):
            try:
                descriptors[name] = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                    0o600, dir_fd=root_fd)
            except OSError as error:
                raise ValueError('begin output is not fresh: ' + name) from error
        authority = installer._load_source_authority(args.candidate_identity, args.source_app)
        token = authority.candidate_identity_sha256
        pending = installer._pending_root(args.installed_app, token)
        if (installer._path_exists(pending)
                or installer._path_exists(installer._committing_root(args.installed_app, token))
                or installer._committed_roots(args.installed_app, token)):
            raise ValueError('existing transaction cannot be admitted as a fresh begin')
        from Scripts.reconstruction_gate_f.installed_capture_adapter import _bundle
        _bundle(args.source_app, authority.candidate)
        physical = installer.capture_predecessor_observation(args.installed_app)
        invocation = ['--candidate-identity', str(args.candidate_identity), '--source-app', str(args.source_app),
            '--installed-app', str(args.installed_app), '--artifact-root', str(root),
            '--qualification-run-id', args.qualification_run_id, '--qualification-run-nonce', args.qualification_run_nonce,
            '--predecessor-observations-sha256', physical.sha256, '--transaction-token', token]
        owned_nonce = secrets.token_hex(32)
        started = time.time_ns()
        recovery = recovery_document(token=token, nonce=owned_nonce, physical_digest=physical.sha256,
            run_id=args.qualification_run_id, run_nonce=args.qualification_run_nonce,
            artifact_root=root, pending_state=pending / 'transaction.json')
        print('MACSCOPE_GATE_F_INSTALLED_BEGIN_RECOVERY=' + canonical_bytes(recovery).decode('utf-8'), flush=True)
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            require_app_quiescent(args.source_app, args.installed_app)
            status = installer.main(['--phase', 'begin'] + invocation,
                _transaction_nonce_factory=lambda: owned_nonce)
        print(output.getvalue(), end='', flush=True)
        if status:
            raise ValueError('production installer begin failed')
        state, snapshot = installer._pending_read_stable(pending)
        if state['transaction_nonce'] != owned_nonce or not started <= state['began_at_unix_ns'] <= state['exposed_at_unix_ns'] <= time.time_ns():
            raise ValueError('begin does not own a fresh pending transaction')
        installer._pending_validate_state(state, authority=authority, token=token,
            installed_app=args.installed_app, source_app=args.source_app, artifact_root=root,
            qualification_run=installer.QualificationRunAuthority(args.qualification_run_id, args.qualification_run_nonce),
            predecessor_observations_sha256=physical.sha256)
        if {key: value for key, value in (line.partition('=')[::2] for line in output.getvalue().splitlines())} != expected_markers(state, snapshot):
            raise ValueError('production begin markers differ from physical state')
        _bundle(args.source_app, authority.candidate)
        _bundle(args.installed_app, authority.candidate)
        equality = installer._collect_exact_equality(installer.collect_installed_source_equality,
            args.source_app, args.installed_app, authority, phase='begin projection')
        if canonical_sha256(equality) != state['source_equality_sha256']:
            raise ValueError('begin physical source equality differs')
        projection = projection_document(snapshot, physical, args.command_predecessor_observations_sha256)
        for name, document in ((PROJECTION_NAME, projection), (EQUALITY_NAME, equality)):
            _publish(descriptors[name], document)
            observed = (root / name).lstat()
            opened = os.fstat(descriptors[name])
            if observed.st_nlink != 1 or installer._metadata(observed) != installer._metadata(opened):
                raise ValueError('begin output identity changed during publication')
        os.fsync(root_fd)
        if _root_identity(root) != root_identity or installer._pending_read_stable(pending)[1] != snapshot:
            raise ValueError('begin root or pending state changed during publication')
        installer._require_source_unchanged(authority, phase='begin projection publication')
        print('MACSCOPE_GATE_F_INSTALLED_BEGIN_PROJECTION=' + str(root / PROJECTION_NAME))
        print('MACSCOPE_GATE_F_INSTALLED_BEGIN_SOURCE_EQUALITY=' + str(root / EQUALITY_NAME))
        return 0
    except Exception as error:
        print('ERROR: installed begin bridge failed: ' + str(error), file=sys.stderr, flush=True)
        if owned_nonce is not None:
            try:
                if installer._path_exists(pending):
                    state, _ = installer._pending_read_stable(pending)
                    if state['transaction_nonce'] != owned_nonce:
                        raise ValueError('recovery state is not owned by this invocation')
                    require_app_quiescent(args.source_app, args.installed_app)
                    if installer.main(['--phase', 'rollback'] + invocation):
                        raise ValueError('production rollback failed')
            except Exception as recovery_error:
                print('ERROR: exact transaction recovery required; state preserved at ' + str(pending)
                    + ': ' + str(recovery_error), file=sys.stderr, flush=True)
        return 1
    finally:
        for descriptor in descriptors.values():
            os.close(descriptor)
        if root_fd is not None:
            os.close(root_fd)


if __name__ == '__main__':
    raise SystemExit(main())
