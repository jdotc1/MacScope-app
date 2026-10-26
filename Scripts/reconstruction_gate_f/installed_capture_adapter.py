"""Bootstrap installed outcomes derived from retained execution and bytes.

This adapter never launches an app, changes permissions or publishes evidence.
The signing/TCC observers are read-only; aggregate validation reuses the actual
producer's physical observers and validators without writing its outputs.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import stat

from Scripts import check_local_signing_policy as signing
from Scripts import ws24_check_xcuitest_host as preflight
from Scripts import ws24_emit_installed_qualification_report as installed
from Scripts.reconstruction import native_live_preparation_receipt as preparation
from Scripts.reconstruction import install_release_to_applications as installer
from . import begin_installed_candidate as begin
from . import materialize_candidate_identity as materializer
from .artifact_validator import read_descriptor_relative_bytes
from .canonical_json import canonical_bytes, canonical_sha256, to_primitive
from .command_catalog import CampaignProfile, INSTALLED_CAPTURE_COMMANDS, installed_gate_output_slots, campaign_profile_for_inputs
from .executor_request_adapter import ExecutorReceiptAdmission
from .qualification_artifact_validator import validate_source_export
from .schema import ArtifactKind, ReceiptType, candidate_identity_sha256, candidate_to_mapping

COMMANDS = INSTALLED_CAPTURE_COMMANDS
ROLES = {
    "install.release-to-applications": ReceiptType.INSTALLED_SOURCE_EQUALITY,
    "signing.strict-release": ReceiptType.STRICT_SIGNING,
    "installed.source-equality": ReceiptType.INSTALLED_SOURCE_EQUALITY,
    "installed.shell-smoke": ReceiptType.INSTALLED_LAUNCH_LOG,
    "installed.xcuitest-preflight": ReceiptType.COMMAND_EXECUTION,
    "installed.emit-report": ReceiptType.INSTALLED_WORKFLOW,
}


def installed_semantic_kind(command_id, source, *, inputs=None):
    """Use only after validate_installed_outputs has revalidated all outcomes."""
    if command_id == "signing.strict-release" and source.command_output.startswith("log:"):
        return ArtifactKind.SIGNING_REPORT
    if command_id == "installed.source-equality" and source.command_output == "artifact:stdout-json:source-equality-report":
        return ArtifactKind.SOURCE_EQUALITY_REPORT
    if command_id == 'install.release-to-applications' and inputs and source.command_output == 'artifact:' + str(Path(inputs['install_release_artifact_root']) / begin.EQUALITY_NAME):
        return ArtifactKind.SOURCE_EQUALITY_REPORT
    if command_id == "installed.shell-smoke" and source.command_output.startswith("artifact:"):
        return ArtifactKind.LAUNCH_LOG
    # Envelopes remain ordinary JSON; only the aggregate is a workflow report.
    if command_id == "installed.emit-report" and inputs and source.command_output == "artifact:" + inputs["installed_report"]:
        return ArtifactKind.WORKFLOW_REPORT
    return source.kind


def _read(path):
    path = Path(path)
    if not path.is_absolute() or path.parent.resolve(strict=True) != path.parent:
        raise ValueError("installed artifact has a noncanonical parent")
    return read_descriptor_relative_bytes(path.parent, path.name, maximum_bytes=16 * 1024 * 1024)[0]


def _single_link_metadata(path):
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise ValueError("installed capture/output must be an ordinary single-link file")
    return installed._stable_metadata(metadata)


def _snapshot_file(path, *, root=None):
    """Keep inode identity and reject aliases across the bounded byte read."""
    path = Path(path)
    if not path.is_absolute() or path.parent.resolve(strict=True) != path.parent:
        raise ValueError("installed capture/output has a noncanonical parent")
    root = path.parent if root is None else root
    relative = path.relative_to(root).as_posix()
    before = _single_link_metadata(path)
    payload = read_descriptor_relative_bytes(root, relative, maximum_bytes=16 * 1024 * 1024)[0]
    if _single_link_metadata(path) != before:
        raise ValueError("installed capture/output identity changed during snapshot")
    return payload, before


def _require_unchanged_files(snapshots):
    if any(_snapshot_file(path) != snapshot for path, snapshot in snapshots.items()):
        raise ValueError("installed capture/output bytes or file identity changed during final fence")


def _json(payload):
    def closed(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("installed JSON has a duplicate key")
            result[key] = value
        return result
    return json.loads(payload, object_pairs_hook=closed)


def _bundle(app, candidate):
    errors = signing.validate_app_bundle(app, "Release", command_runner=signing.run_artifact_command, expected_source_commit=candidate.source.commit,
                                         expected_source_tree=candidate.source.tree)
    if errors:
        raise ValueError("installed signing/provenance rejected: " + "; ".join(errors))
    snapshot = materializer.capture_bundle_snapshot(app, app_root=True)
    expected = candidate.application
    if (snapshot.digests.content_sha256 != expected.bundle_sha256
            or snapshot.digests.closed_tree_sha256 != expected.closed_tree_sha256
            or app.stat().st_mode & 0o7777 != expected.root_mode):
        raise ValueError("physical app closed tree differs from admitted candidate")
    identity = materializer._codesign_identity(app)
    if any(identity[key] != getattr(expected, key) for key in identity):
        raise ValueError("physical app signing identity differs from admitted candidate")
    materializer.require_unchanged_bundle_snapshot(snapshot, phase="installed capture admission")
    return identity


def _equality(inputs, candidate, stdout):
    source, app = Path(inputs["source_release_app"]), Path(inputs["installed_app"])
    _bundle(source, candidate)
    _bundle(app, candidate)
    value, errors = signing.collect_installed_source_equality(source, app)
    if errors or value is None:
        raise ValueError("physical installed equality rejected: " + "; ".join(errors))
    if _json(stdout) != value:
        raise ValueError("captured equality differs from fresh physical bundle observation")
    return dict(value, release_root_mode=source.stat().st_mode & 0o7777,
                installed_root_mode=app.stat().st_mode & 0o7777)


def _preflight(argv, stdout):
    arguments = preflight.parse_args(list(argv[3:]))
    expected = preflight.make_report(arguments)
    if expected["accepted"] is not True or expected["missingGrants"]:
        raise ValueError("current installed XCUITest preflight denied")
    if _json(stdout) != expected:
        raise ValueError("captured preflight differs from physical runner/TCC observation")


def _prepared_runner(inputs, candidate):
    candidate_path = Path(inputs['candidate_identity_path'])
    if _json(_read(candidate_path)) != candidate_to_mapping(candidate):
        raise ValueError('preflight candidate file differs from independent admission')
    receipt = preparation.load_receipt(Path(inputs['installed_ui_preparation_receipt']))
    if receipt['build']['preparation_mode'] != preparation.INSTALLED_UI_PREPARATION_MODE:
        raise ValueError('preflight runner lacks installed UI preparation authority')
    preparation.validate_prepared(receipt, Path(inputs['installed_ui_xctestrun']),
        Path(inputs['source_release_app']), candidate_path,
        test_bundle=Path(inputs['installed_ui_test_bundle']), ui_runner=Path(inputs['installed_ui_runner_app']))


def _shell(path, inputs, candidate, started, ended):
    app = Path(inputs["installed_app"])
    _bundle(app, candidate)
    return _shell_report(path, app, candidate, started, ended, installed.FULL_SURFACE_MODE)[0]


def _shell_report(path, app, candidate, started, ended, mode):
    provenance = app / "Contents/Resources/MacScopeBuildProvenance.json"
    result = installed._validate_installed_shell_report(path,
        label="capture-bound installed shell", expected_mode=mode,
        installed_executable=app / "Contents/MacOS/MacScope",
        installed_executable_sha256=candidate.application.executable_sha256,
        source_commit=candidate.source.commit, source_tree=candidate.source.tree,
        provenance_sha256=hashlib.sha256(_read(provenance)).hexdigest(),
        exposed_at_unix_ns=started * 1_000_000)
    if not started <= result[1] <= ended:
        raise ValueError("installed shell report time escapes retained capture")
    return result


def _shell_pair(inputs, candidate, started, ended):
    full = Path(inputs['installed_shell_smoke_report'])
    legacy = full.with_name(full.stem + '.legacy-grid' + full.suffix)
    if Path(inputs['installed_full_surface_report']) != full or Path(inputs['installed_legacy_grid_report']) != legacy:
        raise ValueError('installed shell outputs differ from exact producer paths')
    app = Path(inputs['installed_app'])
    _bundle(app, candidate)
    first = _shell_report(full, app, candidate, started, ended, installed.FULL_SURFACE_MODE)
    second = _shell_report(legacy, app, candidate, started, ended, installed.LEGACY_GRID_MODE)
    if first[1] > second[1] or first[2] != second[2] or first[3] == second[3] or first[4] == second[4]:
        raise ValueError('installed shell renderer pair is reversed, replayed, or from different smoke markers')


def _projection(inputs):
    payload = _read(Path(inputs['install_release_artifact_root']) / begin.PROJECTION_NAME)
    value = _json(payload)
    if canonical_bytes(value) != payload:
        raise ValueError('installed begin projection is not canonical')
    return value, begin.retained_state(value)


def _begin_outputs(inputs, candidate, run, stdout, started, ended, command_digest):
    projection, retained = _projection(inputs)
    if projection['command_predecessor_observations_sha256'] != command_digest:
        raise ValueError('installed begin outer predecessor authority differs')
    artifact_root = Path(inputs['install_release_artifact_root'])
    state, actual = installed._load_pending_transaction(
        pending_state=retained.path, installed_app=Path(inputs['installed_app']),
        source_app=Path(inputs['source_release_app']), candidate_identity=Path(inputs['candidate_identity_path']),
        expected_source_commit=candidate.source.commit, qualification_run_id=run.run_id,
        qualification_run_nonce=run.nonce, retained_pending_state=retained)
    if (state['candidate_identity_sha256'] != candidate_identity_sha256(candidate)
            or state['artifact_root'] != str(artifact_root)
            or state['source_tree'] != candidate.source.tree
            or not started <= state['began_at_unix_ns'] // 1_000_000 <= state['exposed_at_unix_ns'] // 1_000_000 <= ended):
        raise ValueError('installed begin transaction escapes candidate/run/capture interval')
    begin.validate_markers(stdout, state, retained, artifact_root)
    if actual.path == retained.path:
        predecessor = Path(state['predecessor_path'])
        if state['predecessor_present']:
            observed = installer._capture_exact_bundle(predecessor)
            if not installer._snapshot_matches_record(observed, state['predecessor_identity']):
                raise ValueError('installed begin physical predecessor backup differs')
        elif installer._path_exists(predecessor):
            raise ValueError('installed begin absent predecessor has a backup')
    _bundle(Path(inputs['source_release_app']), candidate)
    _bundle(Path(inputs['installed_app']), candidate)
    authority = installer._load_source_authority(Path(inputs['candidate_identity_path']), Path(inputs['source_release_app']))
    equality = installer._collect_exact_equality(signing.collect_installed_source_equality,
        Path(inputs['source_release_app']), Path(inputs['installed_app']), authority, phase='retained begin')
    if (canonical_sha256(equality) != state['source_equality_sha256']
            or _read(artifact_root / begin.EQUALITY_NAME) != canonical_bytes(equality)):
        raise ValueError('installed begin equality output differs from actual candidate')
    if installer._pending_read_stable(actual.path.parent)[1] != actual:
        raise ValueError('installed begin actual state changed during observation')
    return equality


def retained_begin_state(admission):
    """Return the immutable original snapshot only after full BEGIN replay."""
    if not isinstance(admission, ExecutorReceiptAdmission) or admission.capture.command_id != 'install.release-to-applications':
        raise ValueError('aggregate replay requires the exact retained BEGIN admission')
    inputs = admission.capture.admission.integrated_plan_input.inputs
    path = Path(inputs['install_release_artifact_root']) / begin.PROJECTION_NAME
    original = _snapshot_file(path)
    validate_installed_outputs(admission)
    _require_unchanged_files({path: original})
    return begin.retained_state(_json(original[0]))


def _aggregate(argv, inputs, candidate, run, *, begin_admission=None):
    arguments = installed.parse_arguments(list(argv[3:]))
    if (arguments.qualification_run_id, arguments.qualification_run_nonce,
            arguments.expected_source_commit) != (run.run_id, run.nonce, candidate.source.commit):
        raise ValueError("aggregate source/run differs from retained capture authority")
    # build_report invokes the original signing, equality, pending transaction,
    # shell, native XPC, CLI/GUI/MCP and evidence validators; it writes nothing.
    if not isinstance(begin_admission, ExecutorReceiptAdmission):
        raise ValueError('aggregate requires independently replayed BEGIN capture')
    context = begin_admission.capture.admission
    if (context.candidate != candidate or context.qualification_run != run
            or context.integrated_plan_input.inputs != inputs):
        raise ValueError('aggregate and BEGIN admitted campaign authority differ')
    retained = retained_begin_state(begin_admission)
    if arguments.installation_pending_state != retained.path:
        raise ValueError('aggregate pending path differs from retained BEGIN')
    report, state, gates = installed.build_report(arguments, retained_pending_state=retained)
    _aggregate_outputs(inputs, candidate, report, state, gates)


def _aggregate_outputs(inputs, candidate, report, state, gates):
    """Verify retained aggregate/envelopes against freshly derived producer data."""
    path = Path(inputs["installed_report"])
    payload = _snapshot_file(path)[0]
    if payload != canonical_bytes(report) or report["accepted"] is not True or report["deficiencies"]:
        raise ValueError("installed aggregate differs from freshly validated physical evidence")
    if state["candidate_identity_sha256"] != candidate_identity_sha256(candidate):
        raise ValueError("aggregate pending candidate differs from independent admission")
    digest, timestamp = hashlib.sha256(payload).hexdigest(), path.stat().st_mtime_ns
    gates.update({gate: (digest, timestamp, timestamp) for gate in ("signing", "shellbroker-launchagent")})
    if tuple(sorted(gates)) != installed.REQUIRED_ACCEPTANCE_GATES:
        raise ValueError("aggregate physical gate closure is incomplete")
    for gate, name in installed_gate_output_slots():
        digest, started, ended = gates[gate]
        expected = installed.acceptance_gate_document(gate_id=gate, state=state,
            evidence_sha256=digest, started_at_unix_ns=started, ended_at_unix_ns=ended)
        if _snapshot_file(Path(inputs[name]))[0] != canonical_bytes(expected):
            raise ValueError("installed acceptance gate envelope differs from physical evidence: " + gate)


def _observe(command, admission, record, capture, streams, inputs):
    candidate = admission.capture.admission.candidate
    if command == 'install.release-to-applications':
        return _begin_outputs(inputs, candidate, admission.capture.admission.qualification_run,
            streams['stdout'], capture['intent']['started_at_unix_ms'], capture['terminal']['ended_at_unix_ms'],
            canonical_sha256([to_primitive(item) for item in admission.capture.admission.admitted_predecessors]))
    if command == "signing.strict-release":
        return _bundle(Path(inputs["source_release_app"]), candidate)
    if command == "installed.source-equality":
        return _equality(inputs, candidate, streams["stdout"])
    if command == "installed.xcuitest-preflight":
        _prepared_runner(inputs, candidate)
        _preflight(record.argv, streams["stdout"])
        return dict(run_id=admission.capture.admission.qualification_run.run_id,
                    argv_sha256=canonical_sha256(record.argv), exit_code=0)
    app_authority = dict(app_bundle_id=candidate.application.bundle_identifier,
                         app_executable_sha256=candidate.application.executable_sha256)
    if command == "installed.shell-smoke":
        _shell_pair(inputs, candidate, capture["intent"]["started_at_unix_ms"],
                    capture["terminal"]["ended_at_unix_ms"])
        return dict(app_authority, launch_exit_code=0,
                    launch_log_sha256=hashlib.sha256(streams["stdout"] + streams["stderr"]).hexdigest())
    _aggregate(record.argv, inputs, candidate, admission.capture.admission.qualification_run,
        begin_admission=getattr(admission, 'installed_begin_admission', None))
    return dict(app_authority, selector_count=len(record.scenario_ids), failed_count=0, skipped_count=0)


def validate_installed_outputs(admission: ExecutorReceiptAdmission):
    """Re-admit original capture and return derived authority/constituents only."""
    try:
        return _validate_installed_outputs(admission)
    except (installed.ReportError, preparation.PreparationReceiptError, installer.InstallationError) as error:
        raise ValueError("installed producer validation failed: " + str(error)) from error


def _final_observation(command, admission, record, capture, streams, inputs, authority, source_fence):
    observed = _observe(command, admission, record, capture, streams, inputs)
    # The physical observers can be lengthy. Source must still be sealed after
    # they finish, including when they produced unchanged semantic authority.
    source_fence()
    if canonical_bytes(observed) != canonical_bytes(authority):
        raise ValueError("installed observations changed during final fence")


def _validate_installed_outputs(admission):
    if not isinstance(admission, ExecutorReceiptAdmission):
        raise ValueError("installed outcomes require independently retained capture admission")
    from .executor_request_adapter import _capture
    admitted, capture, streams, _, _, _ = _capture(admission)
    context = admission.capture.admission
    inputs = context.integrated_plan_input.inputs
    command, record = admitted.record.command_id, admitted.resolved_command.record
    if (campaign_profile_for_inputs(inputs) is not CampaignProfile.BOOTSTRAP_VERIFIER
            or command not in COMMANDS or admission.receipt_type is not ROLES[command]):
        raise ValueError("installed capture profile/command/receipt role mismatch")
    sources = admission.owner_artifacts
    expected = {*('artifact:' + value for value in record.generated_artifacts),
                *('log:' + value for value in record.generated_logs)}
    if (len(sources) != len(expected) or {s.command_output for s in sources} != expected
            or len({s.relative_path for s in sources}) != len(sources)
            or len({s.artifact_id for s in sources}) != len(sources)):
        raise ValueError("installed output closure must be exact and unique")
    capture_path = admission.capture.capture_path
    snapshots = {capture_path: _snapshot_file(capture_path, root=admission.artifact_root)}
    if hashlib.sha256(snapshots[capture_path][0]).hexdigest() != admission.capture.capture_sha256:
        raise ValueError("installed retained capture changed before physical observation")
    for source in sources:
        path = admission.artifact_root / source.relative_path
        if path in snapshots:
            raise ValueError("installed owner output aliases retained capture")
        snapshot = _snapshot_file(path, root=admission.artifact_root)
        snapshots[path] = snapshot
        payload = snapshot[0]
        output = source.command_output
        if output.startswith('log:'):
            if payload != streams['stdout'] + streams['stderr'] or source.kind is not ArtifactKind.LAUNCH_LOG:
                raise ValueError("installed output log differs from retained capture")
        elif output.startswith('artifact:stdout-json:'):
            if payload != streams['stdout'] or source.kind is not ArtifactKind.JSON or source.media_type != 'application/json':
                raise ValueError("installed stdout JSON differs from retained capture")
        else:
            if str(path) != output.removeprefix('artifact:') or source.kind is not ArtifactKind.JSON or source.media_type != 'application/json':
                raise ValueError("installed output differs from admitted physical path/kind")
            if not capture['intent']['started_at_unix_ms'] <= path.stat().st_mtime_ns // 1_000_000 <= capture['terminal']['ended_at_unix_ms']:
                raise ValueError("installed producer output escapes captured interval")
    export, repository = Path(inputs['source_export_root']), Path(inputs['repository_root'])
    def source_fence():
        validate_source_export(context.candidate, export, inputs['integration_ref'])
        for relative in ('Scripts/check_local_signing_policy.py', 'Scripts/ws24_check_xcuitest_host.py',
                         'Scripts/ws24_emit_installed_qualification_report.py', 'Scripts/phase2/run_installed_shell_smoke.py',
                         'Scripts/reconstruction/install_release_to_applications.py',
                         'Scripts/reconstruction/native_live_preparation_receipt.py',
                         'Scripts/reconstruction/installed_matrix_receipt.py',
                         'Scripts/reconstruction_gate_f/materialize_candidate_identity.py',
                         'Scripts/reconstruction_gate_f/begin_installed_candidate.py',
                         'Scripts/reconstruction_gate_f/installed_capture_adapter.py'):
            if not _read(Path(__file__).resolve().parents[2] / relative) == _read(repository / relative) == _read(export / relative):
                raise ValueError("installed producer source differs from sealed candidate: " + relative)
    source_fence()
    authority = _observe(command, admission, record, capture, streams, inputs)
    constituents = [] if command == 'installed.xcuitest-preflight' else [dict(
        selector_id=selector, status='passed', evidence_layer=record.evidence_layer.value,
        candidate_identity_sha256=record.candidate_identity_sha256,
        artifact_ids=sorted([s.artifact_id for s in sources] + [admission.execution_report_artifact_id]))
        for selector in record.scenario_ids]
    if ((admission.authority is not None and canonical_bytes(admission.authority) != canonical_bytes(authority))
            or (admission.constituents and canonical_bytes(admission.constituents) != canonical_bytes(constituents))):
        raise ValueError("caller installed semantics differ from physical outcomes")
    _final_observation(command, admission, record, capture, streams, inputs, authority, source_fence)
    _require_unchanged_files(snapshots)
    return {'authority': authority, 'constituents': constituents}
