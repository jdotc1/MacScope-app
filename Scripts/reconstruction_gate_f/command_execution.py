"""One admitted Gate F command, owned child, bounded immutable capture.

No scheduler or receipt authentication. Orchestration supplies independent
admission inputs; consumers must re-admit and inspect terminal/report outcomes.
"""
from __future__ import annotations

import base64
import hashlib
import os
from pathlib import Path
import selectors
import signal
import stat
import subprocess
import threading
import time
import uuid
from dataclasses import dataclass

from . import command_capture as capture
from .artifact_validator import _open_root_without_symlinks
from .canonical_json import canonical_bytes, canonical_sha256, to_primitive
from .command_catalog import CampaignProfile, CommandExecutionMode
from .command_compiler import CommandRecord, EXTERNAL_PREREQUISITE_IDS
from .runtime_resolution import ResolvedCommand, resolve_command_record
from .prerequisite_dag import (LaneCIntegratedCommandPlanInput, ValidatedLaneCCommandPlan,
                               validate_integrated_lane_c_command_plan)
from .receipt_validator import (CommandPrerequisiteExpectation, QualificationRunAuthority,
                                qualification_run_mapping, validate_qualification_run_authority)
from .schema import CandidateIdentity, SHA256_RE, STABLE_ID_RE

BASE_ENVIRONMENT = frozenset({"HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "LANG", "LC_ALL", "DEVELOPER_DIR"})
TERM_GRACE_SECONDS = 5.0
KILL_GRACE_SECONDS = 5.0
FINAL_DRAIN_SECONDS = 2.0
POLL_SECONDS = 0.05
FOOTER_RESERVE_BYTES = 8192
MAX_PREDECESSOR_FILE_BYTES = 1024 * 1024


class ExecutionError(ValueError):
    """No favorable execution evidence may be inferred from this failure."""


@dataclass(frozen=True)
class ExecutionAdmission:
    candidate: CandidateIdentity
    integrated_plan_input: LaneCIntegratedCommandPlanInput
    qualification_run: QualificationRunAuthority
    producer_source_commit: str
    producer_source_tree: str
    admitted_predecessors: tuple[CommandPrerequisiteExpectation, ...]


@dataclass(frozen=True)
class AdmittedCommand:
    validated_plan: ValidatedLaneCCommandPlan
    record: CommandRecord
    resolved_command: ResolvedCommand


@dataclass(frozen=True)
class ExecutionCapture:
    admission: ExecutionAdmission
    command_id: str
    scenario_id: str
    capture_id: str
    effective_environment: tuple[tuple[str, str], ...]
    capture_path: Path
    capture_sha256: str


def admit_command(admission: ExecutionAdmission, command_id: str, scenario_id: str,
                  *, profile: CampaignProfile = CampaignProfile.EXISTING) -> AdmittedCommand:
    """Recompile on EVERY call; never accept a validated-looking flag/hash."""
    if not isinstance(admission, ExecutionAdmission):
        raise ExecutionError("coordinator admission required")
    validated, issues = validate_integrated_lane_c_command_plan(
        admission.integrated_plan_input, candidate=admission.candidate, profile=profile)
    if validated is None or issues:
        raise ExecutionError("full command-plan admission failed: " + "; ".join(item.code for item in issues))
    records = [record for record in admission.integrated_plan_input.plan.commands if record.command_id == command_id]
    if len(records) != 1:
        raise ExecutionError("command is absent or ambiguous")
    record = records[0]
    allowed_scenarios = record.scenario_ids or (record.command_id,)
    if record.execution_mode != CommandExecutionMode.RUNNABLE or not record.argv or scenario_id not in allowed_scenarios:
        raise ExecutionError("command is not runnable for scenario")
    run = admission.qualification_run
    if not isinstance(run, QualificationRunAuthority) or validate_qualification_run_authority(
            qualification_run_mapping(run), expected=run, path="$.run"):
        raise ExecutionError("invalid coordinator run")
    inputs = admission.integrated_plan_input.inputs
    if (inputs.get("qualification_run_id"), inputs.get("qualification_run_nonce")) != (run.run_id, run.nonce):
        raise ExecutionError("compiled run differs from coordinator run")
    source = admission.candidate.source
    if (admission.producer_source_commit, admission.producer_source_tree) != (source.commit, source.tree):
        raise ExecutionError("producer source differs from admitted candidate")
    module = Path(__file__).resolve()
    corresponding = admission.integrated_plan_input.repository_root / "Scripts/reconstruction_gate_f/command_execution.py"
    if module.read_bytes() != corresponding.read_bytes():
        raise ExecutionError("executing producer differs from clean candidate source")
    predecessors = admission.admitted_predecessors
    if type(predecessors) is not tuple or any(not isinstance(item, CommandPrerequisiteExpectation) for item in predecessors):
        raise ExecutionError("invalid prerequisite inputs")
    if sorted(item.command_id for item in predecessors) != sorted(set(record.prerequisite_ids) - EXTERNAL_PREREQUISITE_IDS):
        raise ExecutionError("prerequisite set differs from command")
    if len({item.receipt_id for item in predecessors}) != len(predecessors):
        raise ExecutionError("duplicate prerequisite receipts")
    for item in predecessors:
        if (type(item.canonical_sha256) is not str or not SHA256_RE.fullmatch(item.canonical_sha256)
                or type(item.receipt_id) is not str or not STABLE_ID_RE.fullmatch(item.receipt_id)
                or (item.qualification_run_id, item.qualification_run_nonce) != (run.run_id, run.nonce)):
            raise ExecutionError("prerequisite receipt/run mismatch")
    try:
        resolved = resolve_command_record(record, prerequisite_receipts=predecessors,
                                          qualification_run=run, profile=profile)
    except ValueError as exc:
        raise ExecutionError("runtime predecessor resolution failed: " + str(exc)) from exc
    return AdmittedCommand(validated, record, resolved)


def _write_all(fd: int, payload: bytes):
    view = memoryview(payload)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            raise ExecutionError("capture write made no progress")
        view = view[written:]


def _root_descriptor(root: Path) -> int:
    if not root.is_absolute() or root.resolve(strict=True) != root or root.is_symlink():
        raise ExecutionError("capture root must be canonical and existing")
    before = root.stat()
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    after = os.fstat(fd)
    if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
        os.close(fd)
        raise ExecutionError("capture root changed")
    return fd


def _signal_owned(process, sig):
    # A live/unreaped leader prevents numeric PID/PGID reuse. Once poll reaps it,
    # the handle no longer proves group ownership: never signal that number.
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, sig)
    except ProcessLookupError:
        pass


def _cleanup(process):
    if process is None:
        return
    try:
        if process.poll() is None:
            _signal_owned(process, signal.SIGTERM)
            try:
                process.wait(timeout=TERM_GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                _signal_owned(process, signal.SIGKILL)
                try:
                    process.wait(timeout=KILL_GRACE_SECONDS)
                except subprocess.TimeoutExpired as exc:
                    raise ExecutionError("owned child reap deadline exceeded") from exc
    finally:
        for pipe in (process.stdout, process.stderr):
            if pipe is not None:
                pipe.close()


def _observe_os_start(process) -> dict:
    # No imputed wall-clock timestamp: Popen exposes no OS start-time query.
    # The parent-owned handle and immediate monotonic observation remain primary.
    return {"state": "unavailable", "reason": "Popen does not expose an OS process start-time observation"}


def _validate_stress_predecessor_file(admission, record):
    """Observe the STATIC stress input path immediately before dispatch.

    The runtime digest slots never select paths. Exact admitted full predecessor
    mappings must already exist as bounded canonical bytes at the static path.
    """
    if record.command_id != "stress.reconstruction-authority-races":
        return
    raw_path = admission.integrated_plan_input.inputs.get("authority_stress_predecessor_observations")
    if type(raw_path) is not str:
        raise ExecutionError("stress predecessor path is absent from static inputs")
    path = Path(raw_path)
    indexes = [index for index, value in enumerate(record.argv) if value == "--predecessor-observations"]
    if len(indexes) != 1 or indexes[0] + 1 >= len(record.argv) or record.argv[indexes[0] + 1] != raw_path:
        raise ExecutionError("stress argv differs from static predecessor path")
    expected = canonical_bytes([vars(item) for item in admission.admitted_predecessors])
    if len(expected) > MAX_PREDECESSOR_FILE_BYTES:
        raise ExecutionError("stress predecessor mapping exceeds byte budget")
    descriptors = []
    try:
        if not path.is_absolute() or path.resolve(strict=True) != path:
            raise ExecutionError("stress predecessor path is not canonical")
        parent_fd = _open_root_without_symlinks(path.parent, descriptors)
        before_name = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
        descriptors.append(fd)
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > MAX_PREDECESSOR_FILE_BYTES
                or (before.st_dev, before.st_ino) != (before_name.st_dev, before_name.st_ino)):
            raise ExecutionError("stress predecessor file must be bounded singly-linked regular bytes")
        chunks = []
        count = 0
        while count <= MAX_PREDECESSOR_FILE_BYTES:
            chunk = os.read(fd, min(65536, MAX_PREDECESSOR_FILE_BYTES + 1 - count))
            if not chunk:
                break
            chunks.append(chunk)
            count += len(chunk)
        after = os.fstat(fd)
        after_name = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        parent = os.fstat(parent_fd)
        parent_name = path.parent.stat()
        fields = lambda info: (info.st_dev, info.st_ino, info.st_mode, info.st_nlink,
                               info.st_size, info.st_mtime_ns, info.st_ctime_ns)
        if (b"".join(chunks) != expected or fields(before) != fields(after)
                or fields(after) != fields(after_name)
                or path.parent.resolve(strict=True) != path.parent
                or (parent.st_dev, parent.st_ino) != (parent_name.st_dev, parent_name.st_ino)):
            raise ExecutionError("stress predecessor bytes differ from admitted receipt mappings")
    except OSError as exc:
        raise ExecutionError("stress predecessor input unavailable: " + str(exc)) from exc
    finally:
        for fd in reversed(descriptors):
            os.close(fd)


def _capture_owned_process(argv, *, working_directory, effective, timeout_seconds, fd,
                           initial_encoded_bytes, cancellation=None, spawn=None):
    """Narrow bounded process transport; caller owns intent/schema/publication."""
    process = None
    selector = selectors.DefaultSelector()
    try:
        frames = []
        lengths = {"stdout": 0, "stderr": 0}
        hashes = {key: hashlib.sha256() for key in lengths}
        encoded_count = initial_encoded_bytes
        observation = {"state": "not-launched"}
        cause = None
        try:
            process = (spawn or subprocess.Popen)(argv, cwd=working_directory, env=dict(effective),
                                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       shell=False, start_new_session=True)
        except OSError:
            cause = "launch-failed"
        if process is not None:
            spawn_ns = time.monotonic_ns()
            observation = dict(state="launched", pid=process.pid, spawn_observed_monotonic_ns=spawn_ns,
                               os_start_time=_observe_os_start(process))
            for stream, pipe in (("stdout", process.stdout), ("stderr", process.stderr)):
                os.set_blocking(pipe.fileno(), False)
                selector.register(pipe, selectors.EVENT_READ, stream)
            deadline = time.monotonic() + timeout_seconds
            stop_at = None
            killed_at = None
            exited_at = None
            while selector.get_map() or process.poll() is None:
                now = time.monotonic()
                status = process.poll()
                if status is not None and exited_at is None:
                    exited_at = now
                if cause is None and cancellation is not None and cancellation.is_set():
                    cause = "cancelled"
                if cause is None and now >= deadline:
                    cause = "timed-out"
                if cause is None and exited_at is not None and now - exited_at >= FINAL_DRAIN_SECONDS and selector.get_map():
                    # The leader has been reaped; inherited FDs do not prove
                    # ownership of a now-reusable group number. Close locally,
                    # retain incomplete evidence, and never claim child cleanup.
                    raise ExecutionError("reaped leader left inherited pipes open; descendant cleanup unproven")
                if exited_at is not None and now - exited_at >= FINAL_DRAIN_SECONDS and selector.get_map():
                    raise ExecutionError("post-stop inherited pipe drain incomplete; descendant cleanup unproven")
                if cause is not None and stop_at is None:
                    _signal_owned(process, signal.SIGTERM)
                    stop_at = now
                if stop_at is not None and killed_at is None and now - stop_at >= TERM_GRACE_SECONDS:
                    _signal_owned(process, signal.SIGKILL)
                    killed_at = now
                if killed_at is not None and now - killed_at >= KILL_GRACE_SECONDS + FINAL_DRAIN_SECONDS:
                    raise ExecutionError("owned child/drain cleanup deadline exceeded")
                for key, _ in selector.select(POLL_SECONDS):
                    try:
                        raw = os.read(key.fd, capture.MAX_FRAME_BYTES)
                    except BlockingIOError:
                        continue
                    if not raw:
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
                        continue
                    frame = dict(sequence=len(frames), stream=key.data,
                                 data_base64=base64.b64encode(raw).decode("ascii"), raw_length=len(raw),
                                 raw_sha256=hashlib.sha256(raw).hexdigest())
                    frame_bytes = (b"," if frames else b"") + canonical_bytes(frame)
                    if (len(frames) >= capture.MAX_FRAMES or sum(lengths.values()) + len(raw) > capture.MAX_DECODED_BYTES
                            or encoded_count + len(frame_bytes) + FOOTER_RESERVE_BYTES > capture.MAX_ENCODED_BYTES):
                        cause = cause or "output-limit"
                        continue  # Drain/discard only after latching unsuccessful stop cause.
                    if cause == "output-limit":
                        continue
                    _write_all(fd, frame_bytes)
                    encoded_count += len(frame_bytes)
                    frames.append(frame)
                    lengths[key.data] += len(raw)
                    hashes[key.data].update(raw)
            process.wait(timeout=KILL_GRACE_SECONDS)
        status = None if process is None else process.returncode
        cause = cause or ("signaled" if status < 0 else "exited")
        terminal = dict(frames_sha256=canonical_sha256(frames),
                        ended_at_unix_ms=time.time_ns() // 1_000_000, termination_kind=cause,
                        exit_code=status if status is not None and status >= 0 else None,
                        signal=-status if status is not None and status < 0 else None)
        for stream in lengths:
            terminal[stream + "_length"] = lengths[stream]
            terminal[stream + "_sha256"] = hashes[stream].hexdigest()
        return observation, frames, terminal
    finally:
        try:
            _cleanup(process)
        finally:
            selector.close()


def _publish_capture(fd, root_fd, capture_root, partial, final, payload):
    """Create-only publication with descriptor, byte and post-sync root fences."""
    os.fsync(fd)
    metadata = os.fstat(fd)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or metadata.st_size != len(payload):
        raise ExecutionError("capture inode/size changed")
    if os.pread(fd, len(payload) + 1, 0) != payload:
        raise ExecutionError("capture bytes changed")
    root_now = capture_root.stat()
    root_open = os.fstat(root_fd)
    if capture_root.resolve(strict=True) != capture_root or (root_now.st_dev, root_now.st_ino) != (root_open.st_dev, root_open.st_ino):
        raise ExecutionError("publication root changed")
    name_stat = os.stat(partial, dir_fd=root_fd, follow_symlinks=False)
    if (name_stat.st_dev, name_stat.st_ino) != (metadata.st_dev, metadata.st_ino):
        raise ExecutionError("capture pathname changed")
    os.link(partial, final, src_dir_fd=root_fd, dst_dir_fd=root_fd, follow_symlinks=False)
    published_fd = os.open(final, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=root_fd)
    try:
        published = os.fstat(published_fd)
        if (not stat.S_ISREG(published.st_mode) or published.st_nlink != 2
                or (published.st_dev, published.st_ino) != (metadata.st_dev, metadata.st_ino)
                or os.pread(published_fd, len(payload) + 1, 0) != payload):
            raise ExecutionError("publication substituted capture inode or bytes")
    finally:
        os.close(published_fd)
    os.unlink(partial, dir_fd=root_fd)
    os.fsync(root_fd)
    final_stat = os.stat(final, dir_fd=root_fd, follow_symlinks=False)
    if (final_stat.st_dev, final_stat.st_ino, final_stat.st_nlink) != (metadata.st_dev, metadata.st_ino, 1):
        raise ExecutionError("published capture identity changed")
    # Directory synchronization is another observable check/use boundary.
    # Reopen the published name and recheck bytes/root after it, not only
    # the original descriptor's inode number before publication.
    final_fd = os.open(final, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=root_fd)
    try:
        observed = os.fstat(final_fd)
        root_final = capture_root.stat()
        observed_bytes = os.pread(final_fd, len(payload) + 1, 0)
        after_read = os.fstat(final_fd)
        if (not stat.S_ISREG(observed.st_mode)
                or (observed.st_dev, observed.st_ino, observed.st_nlink) != (metadata.st_dev, metadata.st_ino, 1)
                or observed_bytes != payload
                or (observed.st_dev, observed.st_ino, observed.st_size, observed.st_mtime_ns, observed.st_ctime_ns, observed.st_nlink)
                != (after_read.st_dev, after_read.st_ino, after_read.st_size, after_read.st_mtime_ns, after_read.st_ctime_ns, after_read.st_nlink)
                or capture_root.resolve(strict=True) != capture_root
                or (root_final.st_dev, root_final.st_ino) != (root_open.st_dev, root_open.st_ino)):
            raise ExecutionError("published capture bytes or root changed after synchronization")
    finally:
        os.close(final_fd)


def execute_admitted_command(admission: ExecutionAdmission, command_id: str, scenario_id: str,
                             *, capture_root: Path, cancellation: threading.Event | None = None,
                             profile: CampaignProfile = CampaignProfile.EXISTING) -> ExecutionCapture:
    """Dispatch exactly one recompiled record; retain failures, never call them passed."""
    admitted = admit_command(admission, command_id, scenario_id, profile=profile)
    record = admitted.resolved_command.record
    _validate_stress_predecessor_file(admission, record)
    environment = {key: value for key, value in os.environ.items() if key in BASE_ENVIRONMENT}
    environment.update(dict(record.environment))
    effective = tuple(sorted(environment.items()))
    capture_id = "capture-" + uuid.uuid4().hex
    intent = dict(capture_id=capture_id, run_id=admission.qualification_run.run_id,
                  nonce=admission.qualification_run.nonce,
                  candidate_identity_sha256=record.candidate_identity_sha256,
                  command_plan_sha256=admitted.validated_plan.command_plan_sha256,
                  command_record_sha256=admitted.resolved_command.static_record_sha256, command_id=command_id,
                  scenario_id=scenario_id, producer_source_commit=admission.producer_source_commit,
                  producer_source_tree=admission.producer_source_tree, argv=list(record.argv),
                  working_directory=record.working_directory, environment=[list(pair) for pair in record.environment],
                  environment_policy_id="gatef-host-environment-v1", effective_environment=[list(pair) for pair in effective],
                  prerequisite_receipts=sorted([[item.command_id, item.canonical_sha256] for item in admission.admitted_predecessors]),
                  started_at_unix_ms=time.time_ns() // 1_000_000)
    prefix = capture.intent_prefix(intent)
    if len(prefix) + FOOTER_RESERVE_BYTES > capture.MAX_ENCODED_BYTES:
        raise ExecutionError("intent leaves no bounded output/terminal budget")
    try:
        root_fd = _root_descriptor(capture_root)
    except OSError as exc:
        raise ExecutionError(str(exc)) from exc
    fd = None
    partial = capture_id + ".incomplete"
    final = capture_id + ".json"
    try:
        try:
            os.stat(final, dir_fd=root_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise ExecutionError("capture publication target already exists")
        fd = os.open(partial, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=root_fd)
        _write_all(fd, prefix)
        os.fsync(fd)
        os.fsync(root_fd)
        if cancellation is not None and cancellation.is_set():
            raise ExecutionError("cancelled before launch; incomplete intent retained")
        # Reobserve after durable-prefix I/O; do not reopen a stale precheck as
        # authority when the static file changed while persistence completed.
        _validate_stress_predecessor_file(admission, record)
        observation, frames, terminal = _capture_owned_process(record.argv,
            working_directory=record.working_directory, effective=effective,
            timeout_seconds=record.timeout_seconds, fd=fd,
            initial_encoded_bytes=len(prefix), cancellation=cancellation)
        terminal["intent_sha256"] = canonical_sha256(intent)
        runtime_resolution = to_primitive(admitted.resolved_command.runtime_resolution)
        document = dict(intent=intent, output_frames=frames, process_observation=observation,
                        runtime_resolution=runtime_resolution, schema_version=2, terminal=terminal)
        payload = capture.serialize_capture(document)
        suffix = (b'],"process_observation":' + canonical_bytes(observation)
                  + b',"runtime_resolution":' + canonical_bytes(runtime_resolution)
                  + b',"schema_version":2,"terminal":' + canonical_bytes(terminal) + b'}')
        _write_all(fd, suffix)
        _publish_capture(fd, root_fd, capture_root, partial, final, payload)
        return ExecutionCapture(admission, command_id, scenario_id, capture_id, effective,
                                capture_root / final, hashlib.sha256(payload).hexdigest())
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        raise ExecutionError(str(exc)) from exc
    finally:
        if fd is not None:
            os.close(fd)
        os.close(root_fd)
