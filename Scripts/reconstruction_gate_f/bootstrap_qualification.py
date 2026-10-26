"""Source-bound, observed bootstrap qualification; never retrospective admission.

This layer retains invocation/process evidence before a candidate exists. Normal
exit and a unique owned marker are necessary but do not admit product/test claims;
the later candidate linker must independently revalidate those physical outputs.
"""
from __future__ import annotations

from dataclasses import dataclass
import argparse
from datetime import datetime
import hashlib
import importlib
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import threading
import time
import uuid

from . import command_capture as capture
from . import command_execution as execution
from . import materialize_candidate_identity as materializer
from . import qualification_artifact_validator as qualification_validator
from Scripts.qualification import generated_project_evidence, stage_timing
from Scripts.reconstruction import native_live_preparation_receipt as preparation
from Scripts.reconstruction import validate_qualification_product_identity as products_validator
from Scripts.source_export_provenance import MAX_RECORD_BYTES, load_verified_export
from Scripts.ws24_emit_installed_qualification_report import result_bundle_sha256
from .artifact_validator import read_descriptor_relative_bytes
from .canonical_json import canonical_bytes, canonical_sha256, decode_canonical_bytes
from .receipt_validator import (QualificationRunAuthority, qualification_run_mapping,
                                validate_qualification_run_authority)
from .schema import (STABLE_ID_RE, CandidateIdentity, candidate_to_mapping,
                     parse_candidate_identity, candidate_identity_sha256)

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from work_root import work_root as macscope_work_root  # noqa: E402

_execution_transport = execution

OUTPUT_BASE = macscope_work_root()
FULL_TEST_TIMEOUT_SECONDS = 7200
POLICY_ID = "offline-development-full-test-v1"
INTENT_KIND = "gatef-bootstrap-qualification-intent"
CAPTURE_KIND = "gatef-bootstrap-qualification-capture"
MAX_PRODUCER_BYTES = 16 * 1024 * 1024
# Every directly reused producer/validator plus our own module and the qualifier.
# This fixed set is deliberately independent of caller-selected files.
PRODUCER_MANIFEST_PATHS = tuple(sorted((
    "Scripts/qualification/generated_project_evidence.py",
    "Scripts/qualification/stage_timing.py",
    "Scripts/generate_release_build_provenance.py",
    "Scripts/native-decompiler-direct/sleigh_package.py",
    "Scripts/qualify_local_private_build.sh",
    "Scripts/reconstruction/native_live_preparation_receipt.py",
    "Scripts/reconstruction/validate_qualification_product_identity.py",
    "Scripts/reconstruction_gate_f/artifact_validator.py",
    "Scripts/reconstruction_gate_f/bootstrap_cli.py",
    "Scripts/reconstruction_gate_f/bootstrap_qualification.py",
    "Scripts/reconstruction_gate_f/canonical_json.py",
    "Scripts/reconstruction_gate_f/command_capture.py",
    "Scripts/reconstruction_gate_f/command_execution.py",
    "Scripts/reconstruction_gate_f/materialize_candidate_identity.py",
    "Scripts/reconstruction_gate_f/qualification_artifact_validator.py",
    "Scripts/reconstruction_gate_f/qualification_receipt_adapter.py",
    "Scripts/reconstruction_gate_f/receipt_validator.py",
    "Scripts/reconstruction_gate_f/schema.py",
    "Scripts/source_export_provenance.py",
    "Scripts/ws24_emit_installed_qualification_report.py",
)))
INTENT_FIELDS = frozenset("schema_version record_kind bootstrap_id qualification_run source producer invocation started_at_unix_ms".split())
INVOCATION_FIELDS = frozenset("policy_id argv working_directory effective_environment dependency_cache_root qualification_work_root developer_dir".split())
CAPTURE_FIELDS = frozenset("schema_version record_kind intent_sha256 process_observation output_frames terminal".split())


class BootstrapQualificationError(ValueError):
    """Invalid source, invocation or evidence; no favorable claim is implied."""


@dataclass(frozen=True)
class BootstrapSourceAuthority:
    repository_root: Path
    integration_ref: str
    commit: str
    tree: str


@dataclass(frozen=True)
class BootstrapConfiguration:
    artifact_root: Path
    qualification_work_root: Path
    dependency_cache_root: Path
    developer_dir: Path


@dataclass(frozen=True)
class RetainedBootstrapExecution:
    source: BootstrapSourceAuthority
    qualification_run: QualificationRunAuthority
    configuration: BootstrapConfiguration
    intent_path: Path
    capture_path: Path


@dataclass(frozen=True)
class ValidatedBootstrapQualification:
    bootstrap_id: str
    qualification_run: QualificationRunAuthority
    candidate_identity_sha256: str
    admission_path: Path
    admission_sha256: str


def _stable_id(value):
    if type(value) is not str or not STABLE_ID_RE.fullmatch(value):
        raise BootstrapQualificationError("invalid stable ID")


def _absolute(value):
    capture._text(value)
    path = Path(value)
    if not path.is_absolute() or str(path) != value or os.path.normpath(value) != value:
        raise BootstrapQualificationError("path must be absolute and normalized")
    return path


def _full_ref(value):
    capture._text(value)
    if (not value.startswith("refs/") or re.fullmatch(r"refs/[A-Za-z0-9._/-]+", value) is None
            or ".." in value or "//" in value or value.endswith(("/", ".", ".lock"))):
        raise BootstrapQualificationError("integration authority must be a full Git ref")


def _argv(source, configuration):
    return ["./Scripts/qualify_local_private_build.sh", "--source-root", str(source.repository_root),
            "--work-root", str(configuration.qualification_work_root),
            "--dependency-cache-root", str(configuration.dependency_cache_root),
            "--mode", "full-test", "--signing", "development",
            "--xcode-output", "quiet",
            "--integration-ref", source.integration_ref]


def parse_bootstrap_intent(payload: bytes) -> dict:
    """Closed structural validation only; expected authority is supplied later."""
    try:
        if type(payload) is not bytes or len(payload) > capture.MAX_ENCODED_BYTES:
            raise BootstrapQualificationError("bootstrap intent exceeds byte budget")
        value = decode_canonical_bytes(payload)
        capture._closed(value, INTENT_FIELDS)
        if type(value["schema_version"]) is not int or value["schema_version"] != 1 or value["record_kind"] != INTENT_KIND:
            raise BootstrapQualificationError("unsupported bootstrap intent schema")
        _stable_id(value["bootstrap_id"])
        capture._integer(value["started_at_unix_ms"])
        run = value["qualification_run"]
        capture._closed(run, {"run_id", "nonce"})
        _stable_id(run["run_id"])
        capture._hash(run["nonce"])
        source = value["source"]
        capture._closed(source, {"repository_root", "integration_ref", "commit", "tree", "repository_clean"})
        repository = _absolute(source["repository_root"])
        _full_ref(source["integration_ref"])
        for key in ("commit", "tree"):
            capture._hash(source[key], 40)
        if source["repository_clean"] is not True:
            raise BootstrapQualificationError("bootstrap source must be clean")
        producer = value["producer"]
        capture._closed(producer, {"source_commit", "source_tree", "file_manifest"})
        if (producer["source_commit"], producer["source_tree"]) != (source["commit"], source["tree"]):
            raise BootstrapQualificationError("producer/source identity differs")
        manifest = producer["file_manifest"]
        if type(manifest) is not list or len(manifest) != len(PRODUCER_MANIFEST_PATHS):
            raise BootstrapQualificationError("producer manifest is incomplete")
        for relative, item in zip(PRODUCER_MANIFEST_PATHS, manifest):
            capture._closed(item, {"relative_path", "sha256"})
            if item["relative_path"] != relative:
                raise BootstrapQualificationError("producer manifest paths differ")
            capture._hash(item["sha256"])
        invocation = value["invocation"]
        capture._closed(invocation, INVOCATION_FIELDS)
        for key in ("working_directory", "dependency_cache_root", "qualification_work_root", "developer_dir"):
            _absolute(invocation[key])
        configuration = BootstrapConfiguration(Path("/unused"), Path(invocation["qualification_work_root"]),
            Path(invocation["dependency_cache_root"]), Path(invocation["developer_dir"]))
        authority = BootstrapSourceAuthority(repository, source["integration_ref"], source["commit"], source["tree"])
        if (invocation["policy_id"] != POLICY_ID or invocation["argv"] != _argv(authority, configuration)
                or invocation["working_directory"] != str(repository)):
            raise BootstrapQualificationError("unapproved bootstrap invocation")
        if type(invocation["argv"]) is not list:
            raise BootstrapQualificationError("argv must be a list")
        capture._pairs(invocation["effective_environment"])
        environment = dict(invocation["effective_environment"])
        if (not set(environment) <= execution.BASE_ENVIRONMENT
                or environment.get("DEVELOPER_DIR") != invocation["developer_dir"]):
            raise BootstrapQualificationError("undeclared environment override")
        return value
    except (OSError, ValueError, TypeError, KeyError, UnicodeError, RecursionError) as exc:
        raise BootstrapQualificationError(str(exc)) from exc


def parse_bootstrap_capture(payload: bytes, *, intent: dict) -> tuple[dict, dict[str, bytes]]:
    """Validate the separate bootstrap schema and existing bounded transport."""
    try:
        parse_bootstrap_intent(canonical_bytes(intent))
        if type(payload) is not bytes or len(payload) > capture.MAX_ENCODED_BYTES:
            raise BootstrapQualificationError("bootstrap capture exceeds byte budget")
        value = decode_canonical_bytes(payload)
        capture._closed(value, CAPTURE_FIELDS)
        if (type(value["schema_version"]) is not int or value["schema_version"] != 1
                or value["record_kind"] != CAPTURE_KIND):
            raise BootstrapQualificationError("unsupported bootstrap capture schema")
        if value["intent_sha256"] != canonical_sha256(intent):
            raise BootstrapQualificationError("bootstrap intent commitment differs")
        streams = capture._validate_transport(value["output_frames"], value["process_observation"],
            value["terminal"], started_at_unix_ms=intent["started_at_unix_ms"])
        return value, streams
    except (ValueError, TypeError, KeyError, UnicodeError, RecursionError) as exc:
        raise BootstrapQualificationError(str(exc)) from exc


def _canonical_directory(path):
    if not isinstance(path, Path) or not path.is_absolute() or path.resolve(strict=True) != path or not path.is_dir():
        raise BootstrapQualificationError("directory must be canonical and existing")
    descriptor = execution._root_descriptor(path)
    os.close(descriptor)


def _under(path, root, *, strict=False):
    try:
        relative = path.relative_to(root)
    except ValueError:
        return False
    return not strict or relative != Path(".")


def _git(root, *arguments):
    result = subprocess.run(["/usr/bin/git", *arguments], cwd=root, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=True)
    if len(result.stdout) > MAX_PRODUCER_BYTES or len(result.stderr) > capture.MAX_TEXT_BYTES:
        raise BootstrapQualificationError("source observation exceeds byte budget")
    return result.stdout


def _active_producer_bytes(relative):
    active_root = Path(__file__).resolve().parents[2]
    if relative.endswith(".py") and all(part.isidentifier() for part in relative[:-3].split("/")):
        name = relative[:-3].replace("/", ".")
        module = sys.modules.get(name) or importlib.import_module(name)
        module_path = Path(module.__file__).resolve(strict=True)
        return read_descriptor_relative_bytes(module_path.parent, module_path.name, maximum_bytes=MAX_PRODUCER_BYTES)[0]
    return read_descriptor_relative_bytes(active_root, relative, maximum_bytes=MAX_PRODUCER_BYTES)[0]


def _source_manifest(source):
    if not isinstance(source, BootstrapSourceAuthority):
        raise BootstrapQualificationError("independent source authority required")
    _canonical_directory(source.repository_root)
    _full_ref(source.integration_ref)
    for value in (source.commit, source.tree):
        capture._hash(value, 40)
    root = source.repository_root
    if _git(root, "rev-parse", "--show-toplevel").decode().strip() != str(root):
        raise BootstrapQualificationError("source repository moved or is not its Git root")
    expected = (source.commit, source.tree)
    observed = tuple(_git(root, "rev-parse", "--verify", item).decode().strip()
        for item in ("HEAD", "HEAD^{tree}"))
    if observed != expected or _git(root, "rev-parse", "--verify", source.integration_ref + "^{commit}").decode().strip() != source.commit:
        raise BootstrapQualificationError("independent source/ref authority differs")
    if _git(root, "status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none"):
        raise BootstrapQualificationError("source repository must be clean")
    manifest = []
    for relative in PRODUCER_MANIFEST_PATHS:
        tree_entry = _git(root, "ls-tree", source.commit, "--", relative).decode().strip()
        if not re.fullmatch(r"100(?:644|755) blob [0-9a-f]{40}\t" + re.escape(relative), tree_entry):
            raise BootstrapQualificationError("producer must be a canonical tracked regular file")
        blob = _git(root, "show", source.commit + ":" + relative)
        observed_bytes = read_descriptor_relative_bytes(root, relative, maximum_bytes=MAX_PRODUCER_BYTES)[0]
        if blob != observed_bytes or blob != _active_producer_bytes(relative):
            raise BootstrapQualificationError("active producer differs from clean source bytes")
        manifest.append({"relative_path": relative, "sha256": hashlib.sha256(blob).hexdigest()})
    return manifest


def _reader_identity(source, intent):
    # This opt-in admission/replay seam never participates in execution creation.
    # The original producer list and records remain unmodified and independently
    # checked against their original blobs, not rewritten to the current reader.
    from . import bootstrap_reader_compatibility as reader
    if not isinstance(source, BootstrapSourceAuthority):
        raise BootstrapQualificationError("independent source authority required")
    _canonical_directory(source.repository_root)
    _full_ref(source.integration_ref)
    if Path(reader.__file__).resolve(strict=True) != source.repository_root / reader.READER_PATH:
        raise BootstrapQualificationError("active compatibility reader is not the tooling checkout")
    identity = reader.observe_reader_identity(repository_root=source.repository_root,
        original_commit=source.commit, original_tree=source.tree,
        original_manifest=intent["producer"]["file_manifest"], producer_paths=PRODUCER_MANIFEST_PATHS)
    current = {item["relative_path"]: item["sha256"] for item in identity["file_manifest"]}
    for relative in (*PRODUCER_MANIFEST_PATHS, reader.READER_PATH):
        if hashlib.sha256(_active_producer_bytes(relative)).hexdigest() != current.get(relative):
            raise BootstrapQualificationError("active reader/producer differs from current clean Git bytes")
    return identity


def _validate_configuration(source, configuration):
    if not isinstance(configuration, BootstrapConfiguration):
        raise BootstrapQualificationError("closed bootstrap configuration required")
    for path in (configuration.artifact_root, configuration.qualification_work_root,
                 configuration.dependency_cache_root, configuration.developer_dir):
        _canonical_directory(path)
    for path in (configuration.artifact_root, configuration.qualification_work_root, configuration.dependency_cache_root):
        if not _under(path, OUTPUT_BASE, strict=True) or _under(path, source.repository_root):
            raise BootstrapQualificationError("bootstrap outputs must live under the work root and outside the source")
    if not _under(configuration.qualification_work_root, configuration.artifact_root, strict=True):
        raise BootstrapQualificationError("qualification work must live beneath bootstrap root")
    if (_under(configuration.dependency_cache_root, source.repository_root)
            or _under(source.repository_root, configuration.artifact_root)
            or _under(source.repository_root, configuration.dependency_cache_root)):
        raise BootstrapQualificationError("bootstrap roots overlap source authority")
    tool = configuration.developer_dir / "usr/bin/xcodebuild"
    tool_bytes, _, _ = read_descriptor_relative_bytes(configuration.developer_dir, "usr/bin/xcodebuild", maximum_bytes=MAX_PRODUCER_BYTES)
    if not tool_bytes or not stat.S_ISREG(tool.stat().st_mode) or not os.access(tool, os.X_OK):
        raise BootstrapQualificationError("verified developer directory needs executable xcodebuild")
    version = subprocess.run([str(tool), "-version"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, timeout=30, check=True, env={"DEVELOPER_DIR": str(configuration.developer_dir), "PATH": "/usr/bin:/bin"})
    if (len(version.stdout) > capture.MAX_TEXT_BYTES or len(version.stderr) > capture.MAX_TEXT_BYTES
            or re.fullmatch(rb"Xcode 27(?:\.[0-9]+)*\nBuild version [A-Za-z0-9]+\n?", version.stdout) is None):
        raise BootstrapQualificationError("bootstrap requires verified Xcode 27 developer directory")


def _validate_run(run):
    if (not isinstance(run, QualificationRunAuthority)
            or validate_qualification_run_authority(qualification_run_mapping(run), expected=run, path="$.qualification_run")):
        raise BootstrapQualificationError("independently issued qualification run required")


def _spawn_qualifier(argv, **keywords):
    # Fixed private process boundary; no public CLI/API injection argument.
    return subprocess.Popen(argv, **keywords)


def _publish_document(root, root_fd, partial, final, payload):
    descriptor = os.open(partial, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=root_fd)
    try:
        execution._write_all(descriptor, payload)
        execution._publish_capture(descriptor, root_fd, root, partial, final, payload)
    finally:
        os.close(descriptor)


def execute_bootstrap_qualification(source: BootstrapSourceAuthority,
    run: QualificationRunAuthority, configuration: BootstrapConfiguration,
    *, cancellation: threading.Event | None = None) -> RetainedBootstrapExecution:
    """Observe exactly the offline full-test qualifier and retain all failures."""
    root_fd = fd = None
    try:
        _validate_run(run)
        manifest = _source_manifest(source)
        _validate_configuration(source, configuration)
        environment = {key: value for key, value in os.environ.items() if key in execution.BASE_ENVIRONMENT}
        environment["DEVELOPER_DIR"] = str(configuration.developer_dir)
        bootstrap_id = "bootstrap-" + uuid.uuid4().hex
        intent = {"schema_version": 1, "record_kind": INTENT_KIND, "bootstrap_id": bootstrap_id,
            "qualification_run": qualification_run_mapping(run),
            "source": {"repository_root": str(source.repository_root), "integration_ref": source.integration_ref,
                       "commit": source.commit, "tree": source.tree, "repository_clean": True},
            "producer": {"source_commit": source.commit, "source_tree": source.tree, "file_manifest": manifest},
            "invocation": {"policy_id": POLICY_ID, "argv": _argv(source, configuration),
                "working_directory": str(source.repository_root), "effective_environment": [list(pair) for pair in sorted(environment.items())],
                "dependency_cache_root": str(configuration.dependency_cache_root),
                "qualification_work_root": str(configuration.qualification_work_root), "developer_dir": str(configuration.developer_dir)},
            "started_at_unix_ms": time.time_ns() // 1_000_000}
        intent_bytes = canonical_bytes(intent)
        parse_bootstrap_intent(intent_bytes)
        root = configuration.artifact_root
        root_fd = execution._root_descriptor(root)
        intent_name = bootstrap_id + ".intent.json"
        _publish_document(root, root_fd, bootstrap_id + ".intent.incomplete", intent_name, intent_bytes)
        intent_digest = hashlib.sha256(intent_bytes).hexdigest()
        prefix = b'{"intent_sha256":' + canonical_bytes(intent_digest) + b',"output_frames":['
        if len(prefix) + execution.FOOTER_RESERVE_BYTES > capture.MAX_ENCODED_BYTES:
            raise BootstrapQualificationError("bootstrap intent leaves no output budget")
        partial, final = bootstrap_id + ".capture.incomplete", bootstrap_id + ".capture.json"
        fd = os.open(partial, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=root_fd)
        execution._write_all(fd, prefix)
        os.fsync(fd)
        os.fsync(root_fd)
        if cancellation is not None and cancellation.is_set():
            raise BootstrapQualificationError("cancelled before launch; incomplete evidence retained")
        if _source_manifest(source) != manifest:
            raise BootstrapQualificationError("source changed before qualifier launch")
        retained_intent = read_descriptor_relative_bytes(root, intent_name, maximum_bytes=capture.MAX_ENCODED_BYTES)[0]
        if retained_intent != intent_bytes:
            raise BootstrapQualificationError("reserved intent changed before launch")
        observation, frames, terminal = execution._capture_owned_process(_argv(source, configuration),
            working_directory=str(source.repository_root), effective=tuple(sorted(environment.items())),
            timeout_seconds=FULL_TEST_TIMEOUT_SECONDS, fd=fd, initial_encoded_bytes=len(prefix),
            cancellation=cancellation, spawn=_spawn_qualifier)
        document = {"schema_version": 1, "record_kind": CAPTURE_KIND, "intent_sha256": intent_digest,
                    "process_observation": observation, "output_frames": frames, "terminal": terminal}
        payload = canonical_bytes(document)
        parse_bootstrap_capture(payload, intent=intent)
        suffix = (b'],"process_observation":' + canonical_bytes(observation)
            + b',"record_kind":' + canonical_bytes(CAPTURE_KIND)
            + b',"schema_version":1,"terminal":' + canonical_bytes(terminal) + b'}')
        execution._write_all(fd, suffix)
        execution._publish_capture(fd, root_fd, root, partial, final, payload)
        return RetainedBootstrapExecution(source, run, configuration, root / intent_name, root / final)
    except (OSError, ValueError, TypeError, subprocess.SubprocessError) as exc:
        raise BootstrapQualificationError(str(exc)) from exc
    finally:
        if fd is not None:
            os.close(fd)
        if root_fd is not None:
            os.close(root_fd)


def bootstrap_receipt_path(execution_record: RetainedBootstrapExecution, streams: dict[str, bytes]) -> Path:
    """One final marker under the invocation's owned fresh runs directory."""
    from .qualification_receipt_adapter import captured_path
    receipt = captured_path(streams, "MACSCOPE_QUALIFICATION_RECEIPT")
    lines = streams["stdout"].decode("utf-8", errors="strict").splitlines()
    if not lines or lines[-1] != "MACSCOPE_QUALIFICATION_RECEIPT=" + str(receipt):
        raise BootstrapQualificationError("qualification receipt must be the final stdout marker")
    runs = execution_record.configuration.qualification_work_root / "runs"
    if (not _under(receipt, runs, strict=True) or receipt.name != "QUALIFICATION_INPUTS.json"
            or receipt.parent.parent != runs or not receipt.parent.name.startswith("run.")):
        raise BootstrapQualificationError("qualification marker is outside owned fresh run")
    read_descriptor_relative_bytes(execution_record.configuration.artifact_root,
        receipt.relative_to(execution_record.configuration.artifact_root).as_posix(), maximum_bytes=MAX_PRODUCER_BYTES)
    return receipt


def revalidate_bootstrap_execution(execution_record: RetainedBootstrapExecution, *,
    expected_source: BootstrapSourceAuthority, expected_run: QualificationRunAuthority,
    require_success: bool = False, allow_reader_compatibility: bool = False) -> tuple[dict, dict, dict[str, bytes]]:
    """Reobserve records under INDEPENDENT source/run; never trust self-binding."""
    try:
        if not isinstance(execution_record, RetainedBootstrapExecution):
            raise BootstrapQualificationError("retained bootstrap execution required")
        _validate_run(expected_run)
        if execution_record.source != expected_source or execution_record.qualification_run != expected_run:
            raise BootstrapQualificationError("independent bootstrap source/run differs")
        if type(allow_reader_compatibility) is not bool:
            raise BootstrapQualificationError("reader compatibility must be explicitly boolean")
        manifest = None if allow_reader_compatibility else _source_manifest(expected_source)
        configuration = execution_record.configuration
        _validate_configuration(expected_source, configuration)
        root = configuration.artifact_root
        paths = (execution_record.intent_path, execution_record.capture_path)
        if any(not isinstance(path, Path) or path.parent != root for path in paths):
            raise BootstrapQualificationError("retained records escape bootstrap root")
        intent_bytes = read_descriptor_relative_bytes(root, paths[0].name, maximum_bytes=capture.MAX_ENCODED_BYTES)[0]
        intent = parse_bootstrap_intent(intent_bytes)
        if allow_reader_compatibility:
            _reader_identity(expected_source, intent)
            manifest = intent["producer"]["file_manifest"]
        # The same repository location may now hold a newer tooling HEAD; the
        # invocation location itself remains independently bound, not recovered
        # from self-asserted intent fields.
        expected_source_mapping = {"repository_root": str(expected_source.repository_root), "integration_ref": expected_source.integration_ref,
            "commit": expected_source.commit, "tree": expected_source.tree, "repository_clean": True}
        if (intent["source"] != expected_source_mapping or intent["qualification_run"] != qualification_run_mapping(expected_run)
                or intent["producer"]["file_manifest"] != manifest or intent["invocation"]["argv"] != _argv(expected_source, configuration)
                or intent["invocation"]["developer_dir"] != str(configuration.developer_dir)):
            raise BootstrapQualificationError("bootstrap record differs from independent authority")
        if (paths[0].name != intent["bootstrap_id"] + ".intent.json"
                or paths[1].name != intent["bootstrap_id"] + ".capture.json"):
            raise BootstrapQualificationError("bootstrap ID differs from reserved record paths")
        payload = read_descriptor_relative_bytes(root, paths[1].name, maximum_bytes=capture.MAX_ENCODED_BYTES)[0]
        document, streams = parse_bootstrap_capture(payload, intent=intent)
        if require_success:
            terminal = document["terminal"]
            if terminal["termination_kind"] != "exited" or terminal["exit_code"] != 0 or terminal["signal"] is not None:
                raise BootstrapQualificationError("bootstrap did not observe normal exit zero")
            bootstrap_receipt_path(execution_record, streams)
        return intent, document, streams
    except (OSError, ValueError, TypeError, subprocess.SubprocessError) as exc:
        raise BootstrapQualificationError(str(exc)) from exc


ADMISSION_KIND = "gatef-bootstrap-qualification-admission"
ADMISSION_FIELDS = frozenset("schema_version record_kind bootstrap_id qualification_run intent capture candidate_identity_sha256 source qualification products tests execution_interval".split())
FILE_FIELDS = frozenset({"relative_path", "byte_count", "sha256"})
PRODUCT_FIELDS = frozenset("relative_path bundle_identifier bundle_sha256 closed_tree_sha256 root_mode executable_sha256 qualification_executables".split())
OBSERVATION_FIELDS = frozenset("selected_scope coverage_claim executed_selector_count passed_selector_count failed_selector_count skipped_selector_count skips selectors xcresult_bundle_sha256 skip_policy".split())


def _relative(value):
    capture._text(value)
    path = Path(value)
    if path.is_absolute() or path.as_posix() != value or any(p in {"", ".", ".."} for p in value.split("/")):
        raise BootstrapQualificationError("reference must be a normalized contained relative path")
    return value


def _file_shape(value):
    capture._closed(value, FILE_FIELDS)
    _relative(value["relative_path"])
    capture._integer(value["byte_count"])
    capture._hash(value["sha256"])


def _sorted_unique(items, key, validate):
    if type(items) is not list:
        raise BootstrapQualificationError("manifest must be a list")
    previous = None
    for item in items:
        validate(item)
        current = item[key]
        if previous is not None and previous >= current:
            raise BootstrapQualificationError("manifest is not sorted and unique")
        previous = current


def parse_bootstrap_admission(payload: bytes) -> dict:
    """Closed grammar only. Physical authority requires the independent loader."""
    try:
        if type(payload) is not bytes or len(payload) > MAX_PRODUCER_BYTES:
            raise BootstrapQualificationError("admission exceeds byte budget")
        value = decode_canonical_bytes(payload)
        if type(value) is not dict:
            raise BootstrapQualificationError("admission must be an object")
        version = value.get("schema_version")
        capture._closed(value, ADMISSION_FIELDS | ({"reader_identity"} if version == 2 else set()))
        if type(version) is not int or version not in {1, 2} or value["record_kind"] != ADMISSION_KIND:
            raise BootstrapQualificationError("unsupported bootstrap admission")
        _stable_id(value["bootstrap_id"])
        capture._closed(value["qualification_run"], {"run_id", "nonce"})
        _stable_id(value["qualification_run"]["run_id"])
        capture._hash(value["qualification_run"]["nonce"])
        capture._hash(value["candidate_identity_sha256"])
        for key in ("intent", "capture"):
            _file_shape(value[key])
        source = value["source"]
        capture._closed(source, {"commit", "tree", "integration_ref"})
        capture._hash(source["commit"], 40)
        capture._hash(source["tree"], 40)
        _full_ref(source["integration_ref"])
        if version == 2:
            from .bootstrap_reader_compatibility import validate_reader_identity_shape
            validate_reader_identity_shape(value["reader_identity"])
            if value["reader_identity"]["original_source"] != {"commit": source["commit"], "tree": source["tree"]}:
                raise BootstrapQualificationError("reader identity differs from original source")
        qualification = value["qualification"]
        capture._closed(qualification, {"receipt", "run_root", "source_provenance", "source_files", "generated_project_manifest", "dependency_manifest", "stage_timings"})
        _relative(qualification["run_root"])
        for key in set(qualification) - {"run_root"}:
            _file_shape(qualification[key])
        products = value["products"]
        capture._closed(products, {"release", "debug", "native_preparation", "installed_ui_preparation"})
        for key in ("native_preparation", "installed_ui_preparation"):
            _file_shape(products[key])
        for key in ("release", "debug"):
            product = products[key]
            capture._closed(product, PRODUCT_FIELDS)
            _relative(product["relative_path"])
            capture._text(product["bundle_identifier"])
            capture._integer(product["root_mode"])
            if product["root_mode"] > 0o7777:
                raise BootstrapQualificationError("invalid product root mode")
            for field in ("bundle_sha256", "closed_tree_sha256", "executable_sha256"):
                capture._hash(product[field])
            def executable(item):
                capture._closed(item, {"identity_id", "bundle_identifier", "sha256"})
                _stable_id(item["identity_id"])
                capture._text(item["bundle_identifier"])
                capture._hash(item["sha256"])
            _sorted_unique(product["qualification_executables"], "identity_id", executable)
        tests = value["tests"]
        capture._closed(tests, {"xcresult", "observations", "coverage"})
        capture._closed(tests["xcresult"], {"relative_path", "content_sha256"})
        _relative(tests["xcresult"]["relative_path"])
        capture._hash(tests["xcresult"]["content_sha256"])
        _file_shape(tests["coverage"])
        observations = tests["observations"]
        capture._closed(observations, OBSERVATION_FIELDS)
        if observations["selected_scope"] != "CoreTests" or observations["coverage_claim"] != "all-recorded-cases-in-selected-scope-not-source-enumeration":
            raise BootstrapQualificationError("invalid full-suite observation scope")
        for key in ("executed_selector_count", "passed_selector_count", "failed_selector_count", "skipped_selector_count"):
            capture._integer(observations[key])
        if (observations["executed_selector_count"] < 1 or observations["failed_selector_count"] != 0
                or observations["passed_selector_count"] + observations["skipped_selector_count"] != observations["executed_selector_count"]):
            raise BootstrapQualificationError("invalid full-suite counts")
        capture._hash(observations["xcresult_bundle_sha256"])
        def selector(item):
            capture._closed(item, {"test_identifier", "status"})
            capture._text(item["test_identifier"])
            if item["status"] not in {"passed", "skipped"}:
                raise BootstrapQualificationError("invalid selector status")
        def skip(item):
            capture._closed(item, {"test_identifier", "observed_reason", "reviewed_reason"})
            for entry in item.values():
                capture._text(entry)
        _sorted_unique(observations["selectors"], "test_identifier", selector)
        _sorted_unique(observations["skips"], "test_identifier", skip)
        if (len(observations["selectors"]) != observations["executed_selector_count"]
                or len(observations["skips"]) != observations["skipped_selector_count"]
                or [s["test_identifier"] for s in observations["selectors"] if s["status"] == "skipped"] != [s["test_identifier"] for s in observations["skips"]]):
            raise BootstrapQualificationError("full-suite selector closure differs")
        policy = observations["skip_policy"]
        policy_fields = {"source_commit", "source_tree", "allowlist_sha256", "counting_rule", "known_gap"}
        if "allowlist_present" in policy:
            policy_fields.add("allowlist_present")
            if type(policy["allowlist_present"]) is not bool:
                raise BootstrapQualificationError("invalid skip allowlist presence")
        capture._closed(policy, policy_fields)
        for key in ("source_commit", "source_tree"):
            capture._hash(policy[key], 40)
        if policy.get("allowlist_present", True):
            capture._hash(policy["allowlist_sha256"])
            capture._text(policy["counting_rule"])
        elif policy["allowlist_sha256"] is not None or policy["counting_rule"] is not None:
            raise BootstrapQualificationError("absent skip allowlist cannot carry catalog authority")
        capture._text(policy["known_gap"])
        interval = value["execution_interval"]
        capture._closed(interval, {"started_at_unix_ms", "ended_at_unix_ms"})
        for entry in interval.values():
            capture._integer(entry)
        if interval["ended_at_unix_ms"] < interval["started_at_unix_ms"]:
            raise BootstrapQualificationError("execution interval reversed")
        return value
    except (ValueError, TypeError, KeyError, UnicodeError, RecursionError) as exc:
        raise BootstrapQualificationError(str(exc)) from exc


def _reference(root, path, snapshots):
    relative = _relative(path.relative_to(root).as_posix())
    # The exporter's source-file ledger has its own governed 32 MiB record bound.
    maximum = MAX_RECORD_BYTES if path.name == "SOURCE_FILES.json" else MAX_PRODUCER_BYTES
    payload, _, _ = read_descriptor_relative_bytes(root, relative, maximum_bytes=maximum)
    snapshot = materializer.capture_file_snapshot(path)
    if snapshot.sha256 != hashlib.sha256(payload).hexdigest():
        raise BootstrapQualificationError("file changed during reference observation")
    snapshots.append(snapshot)
    return {"relative_path": relative, "byte_count": len(payload), "sha256": snapshot.sha256}


def _product(root, path, ids, candidate, bundles):
    snapshot = materializer.capture_bundle_snapshot(path, app_root=True)
    bundles.append(snapshot)
    identifier, executable = materializer._bundle_executable(path)
    return {"relative_path": _relative(path.relative_to(root).as_posix()),
        "bundle_identifier": identifier, "bundle_sha256": snapshot.digests.content_sha256,
        "closed_tree_sha256": snapshot.digests.closed_tree_sha256,
        "root_mode": stat.S_IMODE(path.stat().st_mode),
        "executable_sha256": materializer._sha256_file(executable),
        "qualification_executables": [dict(identity_id=item.identity_id, bundle_identifier=item.bundle_identifier, sha256=item.sha256)
            for item in sorted(candidate.application.qualification_executables, key=lambda item: item.identity_id) if item.identity_id in ids]}


def _check_timings(path, run_root, source, intent, captured):
    value = stage_timing.load_receipt(path)
    expected = stage_timing.expected_identity(argparse.Namespace(source_commit=source.commit,
        source_tree=source.tree, run_root=run_root, mode="full-test"))
    stage_timing.validate_identity(value, expected)
    if type(value["schema_version"]) is not int:
        raise BootstrapQualificationError("timing schema must be an integer")
    attempts = {}
    for stage in value["stages"]:
        capture._closed(stage, {"attempt", "duration_ns", "ended_monotonic_ns", "exit_code", "log", "name", "started_at", "started_monotonic_ns"})
        for key in ("attempt", "duration_ns", "ended_monotonic_ns", "started_monotonic_ns"):
            capture._integer(stage[key])
        if type(stage["exit_code"]) is not int or stage_timing.STAGE.fullmatch(stage["name"]) is None:
            raise BootstrapQualificationError("malformed stage observation")
        attempts[stage["name"]] = attempts.get(stage["name"], 0) + 1
        if stage["attempt"] != attempts[stage["name"]] or stage["ended_monotonic_ns"] - stage["started_monotonic_ns"] != stage["duration_ns"]:
            raise BootstrapQualificationError("stage duration/attempt differs")
        capture._text(stage["started_at"])
        started = datetime.fromisoformat(stage["started_at"].replace("Z", "+00:00"))
        if started.tzinfo is None:
            raise BootstrapQualificationError("stage time requires timezone")
        milliseconds = int(started.timestamp() * 1000)
        if not intent["started_at_unix_ms"] <= milliseconds <= captured["terminal"]["ended_at_unix_ms"]:
            raise BootstrapQualificationError("stage lies outside observed bootstrap interval")
        if stage["log"] is not None:
            log = _absolute(stage["log"])
            if not _under(log, run_root, strict=True) or log.resolve(strict=True) != log:
                raise BootstrapQualificationError("stage log escapes its run")


def _observe_qualification(execution_record, candidate, *, allow_reader_compatibility=False):
    """Derive the complete admission and publication fences from validator-owned files."""
    if not isinstance(execution_record, RetainedBootstrapExecution):
        raise BootstrapQualificationError("retained bootstrap execution required")
    root = execution_record.configuration.artifact_root
    _canonical_directory(root)
    files, bundles = [], []
    root_binding = _directory_binding(root)
    # Retain original byte/inode observations BEFORE semantic validation. Later
    # reference construction cannot adopt replacement bytes as validated input.
    _reference(root, execution_record.intent_path, files)
    _reference(root, execution_record.capture_path, files)
    intent, captured, streams = revalidate_bootstrap_execution(execution_record,
        expected_source=execution_record.source, expected_run=execution_record.qualification_run, require_success=True,
        allow_reader_compatibility=allow_reader_compatibility)
    reader_identity = _reader_identity(execution_record.source, intent) if allow_reader_compatibility else None
    if not isinstance(candidate, CandidateIdentity):
        raise BootstrapQualificationError("parsed candidate identity required")
    parsed, issues = parse_candidate_identity(candidate_to_mapping(candidate))
    if parsed != candidate or issues or candidate.source.dirty:
        raise BootstrapQualificationError("candidate identity is invalid")
    source = execution_record.source
    if (candidate.source.commit, candidate.source.tree) != (source.commit, source.tree):
        raise BootstrapQualificationError("candidate differs from independently observed source")
    receipt = bootstrap_receipt_path(execution_record, streams)
    run_root = receipt.parent
    _canonical_directory(run_root)
    # The root's children change as our derived manifests are published, but
    # its directory object and mode must remain the same throughout admission.
    bindings = {root: root_binding, run_root: _directory_binding(run_root),
        run_root / "source": _directory_binding(run_root / "source")}
    timings = run_root / "STAGE_TIMINGS.json"
    for path in (receipt, run_root / "source/SOURCE_PROVENANCE.json", run_root / "source/SOURCE_FILES.json", timings):
        _reference(root, path, files)
    project_paths = generated_project_evidence.evidence_files(run_root)
    bundles.append(materializer.capture_bundle_snapshot(run_root / generated_project_evidence.DIRECTORY))
    for path in project_paths:
        _reference(root, path, files)
    release = run_root / "DerivedData/Build/Products/Release/MacScope.app"
    debug = run_root / "DerivedData/Build/Products/Debug/MacScope.app"
    bundles.extend(materializer.capture_bundle_snapshot(path, app_root=True) for path in (release, debug))
    arguments = argparse.Namespace(receipt=receipt, run_root=run_root,
        derived_data_root=run_root / "DerivedData", build_source_root=run_root / "source",
        dependency_cache_root=execution_record.configuration.dependency_cache_root,
        expected_mode="full-test", expected_integration_ref=source.integration_ref,
        expected_integration_commit=source.commit, expected_integration_tree=source.tree,
        dependency_network_authorized=False)
    inputs = products_validator.validate_qualification_inputs(arguments)
    qualification = inputs.receipt
    load_verified_export(run_root / "source", require_closed_tree=True)
    qualification_validator.validate_qualification_products(candidate, receipt,
        integration_ref=source.integration_ref, dependency_cache_root=arguments.dependency_cache_root, mode="full-test")
    signing = materializer._codesign_identity(release)
    if any(getattr(candidate.application, key) != value for key, value in signing.items()):
        raise BootstrapQualificationError("Release signing differs from candidate")
    embedded = materializer._embedded_executables(release)
    if embedded != [dict(identity_id=i.identity_id, sha256=i.sha256) for i in candidate.application.embedded_executables]:
        raise BootstrapQualificationError("Release embedded executable closure differs")
    authority = materializer._capture_qualification_dependency_authority(repository_root=source.repository_root,
        qualification_receipt_path=receipt, qualification=qualification, release_app=release,
        provenance=materializer._read_json(release / "Contents/Resources/MacScopeBuildProvenance.json"),
        commit=source.commit, tree=source.tree)
    governed = []
    dependencies = materializer._materialization_dependency(qualification, source.repository_root, authority, governed_snapshots=governed)
    expected_dependencies = [dict(dependency_id=i.dependency_id, source_revision=i.source_revision,
        source_tree_sha256=i.source_tree_sha256, manifest_sha256=i.manifest_sha256, artifact_sha256=i.artifact_sha256) for i in candidate.dependencies]
    if sorted(dependencies, key=lambda i: i["dependency_id"]) != expected_dependencies:
        raise BootstrapQualificationError("dependency authority differs from candidate")
    if not any(i.package_id == "native-sleigh" and i.manifest_sha256 == authority.sleigh_manifest_snapshot.sha256
            and i.tree_sha256 == authority.sleigh_identity["package"]["treeSha256"] for i in candidate.packages):
        raise BootstrapQualificationError("SLEIGH package differs from candidate")
    files.extend(authority.file_snapshots)
    files.extend(governed)
    bundles.append(authority.sleigh_root_snapshot)
    products_validator.validate_products(candidate, debug, ("app", "ai-agent-worker"))
    project = generated_project_evidence.validate(run_root, commit=source.commit, tree=source.tree,
        project_yml_sha256=candidate.source.project_yml_sha256)
    if materializer._sha256_file(project) != candidate.source.generated_project_sha256:
        raise BootstrapQualificationError("generated project differs from candidate")
    project_manifest = {"schema_version": 1, "files": sorted(
        (_reference(root, path, files) for path in project_paths), key=lambda i: i["relative_path"])}
    dependency_paths = {i.path for i in inputs.dependency_files if _under(i.path, run_root / "dependencies")}
    dependency_paths.update(i.path for i in authority.file_snapshots)
    # The materializer verifies the closed SLEIGH package; retain each physical
    # regular member so its full bytes remain represented by the file manifest.
    dependency_paths.update(path for path in authority.sleigh_root_snapshot.root.rglob("*") if path.is_file() and not path.is_symlink())
    dependency_manifest = {"schema_version": 1, "files": []}
    for path in sorted(dependency_paths, key=str):
        if not (_under(path, run_root / "dependencies", strict=True) or _under(path, arguments.dependency_cache_root, strict=True)):
            raise BootstrapQualificationError("dependency reference escapes verified materialization")
        snapshot = materializer.capture_file_snapshot(path)
        files.append(snapshot)
        dependency_manifest["files"].append({"absolute_path": str(path), "byte_count": path.stat().st_size, "sha256": snapshot.sha256})
    preparation_references = {}
    expected_preparation_source = {key: getattr(candidate.source, key) for key in ("repository", "branch_label", "commit", "tree", "dirty", "project_yml_sha256", "generated_project_sha256")}
    current_toolchain = _observe_toolchain(source, execution_record.configuration.developer_dir)
    native_app = None
    for name, filename, mode in (("native_preparation", "NativeLivePreparation.receipt.json", preparation.NATIVE_LIVE_PREPARATION_MODE),
                                ("installed_ui_preparation", "InstalledUIPreparation.receipt.json", preparation.INSTALLED_UI_PREPARATION_MODE)):
        path = run_root / "candidate-artifacts" / filename
        reference = _reference(root, path, files)
        document = preparation.load_receipt(path)
        if (document["schema_version"] != 2 or document["source"] != expected_preparation_source
                or document["build"]["preparation_mode"] != mode
                or document["toolchain"] != current_toolchain):
            raise BootstrapQualificationError("preparation source/mode/toolchain differs")
        tools = {item.tool_id: item for item in candidate.tools}
        toolchain = document["toolchain"]
        for tool_id, digest_field, version in (
            ("xcode", "xcodebuild_sha256", "Xcode " + toolchain["xcode_version"] + " | Build version " + toolchain["xcode_build"]),
            ("swift", "swiftc_sha256", toolchain["swift_version"].replace("\n", " | ")),
            ("sdk", "sdk_settings_sha256", toolchain["sdk_version"])):
            if tool_id not in tools or tools[tool_id].identity_sha256 != toolchain[digest_field] or tools[tool_id].version != version:
                raise BootstrapQualificationError("preparation toolchain differs from candidate tool authority")
        artifacts = document["artifacts"]
        for item in artifacts.values():
            physical = _absolute(item["path"])
            if not _under(physical, run_root, strict=True):
                raise BootstrapQualificationError("preparation artifact escapes exact run")
            if physical.is_dir():
                bundles.append(materializer.capture_bundle_snapshot(physical, app_root=physical.suffix == ".app"))
            else:
                files.append(materializer.capture_file_snapshot(physical))
        if Path(artifacts["app"]["path"]) != release:
            raise BootstrapQualificationError("preparation is not linked to the same Release app")
        kwargs = {"test_bundle": Path(artifacts["core_tests" if name == "native_preparation" else "ui_test_bundle"]["path"])}
        if name == "installed_ui_preparation":
            kwargs["ui_runner"] = Path(artifacts["ui_runner"]["path"])
        preparation.validate_prepared_artifacts(document, Path(artifacts["xctestrun"]["path"]), release, **kwargs)
        products_validator.validate_products(candidate, release,
            ("native-live-app", "native-decompiler") if name == "native_preparation" else ("native-live-app",))
        native_app = release
        preparation_references[name] = reference
    if materializer._qualification_executables(debug, native_app) != [dict(identity_id=i.identity_id, bundle_identifier=i.bundle_identifier, sha256=i.sha256) for i in candidate.application.qualification_executables]:
        raise BootstrapQualificationError("qualification executable closure differs")
    from .qualification_receipt_adapter import captured_path
    xcresult = captured_path(streams, "MACSCOPE_TEST_RESULTS")
    coverage = captured_path(streams, "MACSCOPE_COVERAGE_JSON")
    if xcresult != run_root / "TestResults.xcresult" or coverage != run_root / "COVERAGE.json":
        raise BootstrapQualificationError("test/coverage outputs are not from the owned fresh run")
    _canonical_directory(xcresult)
    bundles.append(materializer.capture_bundle_snapshot(xcresult))
    xcresult_digest = result_bundle_sha256(xcresult)
    observations = qualification_validator.validate_full_coretests_xcresult(xcresult, candidate=candidate,
        source_root=run_root / "source", integration_ref=source.integration_ref)
    if observations["xcresult_bundle_sha256"] != xcresult_digest:
        raise BootstrapQualificationError("xcresult changed during full-suite validation")
    _check_timings(timings, run_root, source, intent, captured)
    release_product = _product(root, release, {"native-live-app", "native-decompiler"}, candidate, bundles)
    if any(release_product[k] != getattr(candidate.application, k) for k in ("bundle_identifier", "bundle_sha256", "closed_tree_sha256", "root_mode", "executable_sha256")):
        raise BootstrapQualificationError("Release physical product differs from candidate")
    document = {"schema_version": 1, "record_kind": ADMISSION_KIND, "bootstrap_id": intent["bootstrap_id"],
        "qualification_run": qualification_run_mapping(execution_record.qualification_run),
        "intent": _reference(root, execution_record.intent_path, files), "capture": _reference(root, execution_record.capture_path, files),
        "candidate_identity_sha256": candidate_identity_sha256(candidate),
        "source": {"commit": source.commit, "tree": source.tree, "integration_ref": source.integration_ref},
        "qualification": {"receipt": _reference(root, receipt, files), "run_root": run_root.relative_to(root).as_posix(),
            "source_provenance": _reference(root, run_root / "source/SOURCE_PROVENANCE.json", files),
            "source_files": _reference(root, run_root / "source/SOURCE_FILES.json", files),
            "stage_timings": _reference(root, timings, files)},
        "products": {"release": release_product, "debug": _product(root, debug, {"app", "ai-agent-worker"}, candidate, bundles), **preparation_references},
        "tests": {"xcresult": {"relative_path": xcresult.relative_to(root).as_posix(), "content_sha256": xcresult_digest},
            "observations": observations, "coverage": _reference(root, coverage, files)},
        "execution_interval": {"started_at_unix_ms": intent["started_at_unix_ms"], "ended_at_unix_ms": captured["terminal"]["ended_at_unix_ms"]}}
    if reader_identity is not None:
        document["schema_version"] = 2
        document["reader_identity"] = reader_identity
    def fence():
        for path, identity in bindings.items():
            if _directory_binding(path) != identity:
                raise BootstrapQualificationError("bootstrap directory changed before publication")
        for snapshot in files:
            materializer.require_unchanged_file_snapshot(snapshot, phase="bootstrap admission publication")
            _recheck_snapshot_path(snapshot)
        for snapshot in (inputs.receipt_file, *inputs.dependency_files):
            products_validator._require_unchanged(snapshot, label="bootstrap validated qualification input")
            payload, size, digest = read_descriptor_relative_bytes(snapshot.path.parent, snapshot.path.name,
                maximum_bytes=len(snapshot.payload))
            if payload != snapshot.payload or size != len(snapshot.payload) or digest != hashlib.sha256(snapshot.payload).hexdigest():
                raise BootstrapQualificationError("validated input path changed before publication")
        for snapshot in bundles:
            materializer.require_unchanged_bundle_snapshot(snapshot, phase="bootstrap admission publication")
        if result_bundle_sha256(xcresult) != xcresult_digest:
            raise BootstrapQualificationError("xcresult changed before publication")
        load_verified_export(run_root / "source", require_closed_tree=True)
        if reader_identity is not None:
            if _reader_identity(source, intent) != reader_identity:
                raise BootstrapQualificationError("reader identity changed before publication")
        elif _source_manifest(source) != intent["producer"]["file_manifest"]:
            raise BootstrapQualificationError("producer changed before publication")
    return document, project_manifest, dependency_manifest, fence


def _directory_binding(path):
    descriptor = execution._root_descriptor(path)
    try:
        metadata = os.fstat(descriptor)
        return metadata.st_dev, metadata.st_ino, metadata.st_mode
    finally:
        os.close(descriptor)


def _recheck_snapshot_path(snapshot):
    # A leaf-only metadata/hash comparison can miss a replaced ancestor that
    # redirects to the moved original leaf. Reopen its complete descriptor
    # chain after the metadata fence, for both owned and approved external paths.
    _, size, digest = read_descriptor_relative_bytes(snapshot.path.parent, snapshot.path.name,
        maximum_bytes=snapshot.metadata[3])
    if size != snapshot.metadata[3] or digest != snapshot.sha256:
        raise BootstrapQualificationError("snapshot path changed before publication")


def _observe_toolchain(source, developer_dir):
    """Reuse the admitted source helper in an explicit isolated environment.

    This performs version and identity reads only. It never changes the caller's
    environment or invokes a build, qualification, preparation or publication.
    """
    environment = {key: value for key, value in os.environ.items() if key in execution.BASE_ENVIRONMENT}
    environment["DEVELOPER_DIR"] = str(developer_dir)
    program = (
        "from Scripts.reconstruction.native_live_preparation_receipt import _toolchain_identity; "
        "from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes; "
        "import sys; sys.stdout.buffer.write(canonical_bytes(_toolchain_identity()))"
    )
    result = subprocess.run(["/usr/bin/python3", "-B", "-c", program], cwd=source.repository_root,
        env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        timeout=30, check=True)
    if len(result.stdout) > MAX_PRODUCER_BYTES or len(result.stderr) > capture.MAX_TEXT_BYTES:
        raise BootstrapQualificationError("toolchain observation exceeds byte budget")
    value = decode_canonical_bytes(result.stdout)
    capture._closed(value, preparation.TOOLCHAIN_FIELDS)
    for entry in value.values():
        capture._text(entry)
    for key in ("xcodebuild_sha256", "swiftc_sha256", "sdk_settings_sha256"):
        capture._hash(value[key])
    if value["developer_dir"] != str(developer_dir):
        raise BootstrapQualificationError("observed toolchain uses another developer directory")
    return value


def _manifest_reference(root, relative, value, *, publish):
    _relative(relative)
    payload = canonical_bytes(value)
    if publish:
        root_fd = execution._root_descriptor(root)
        try:
            _publish_document(root, root_fd, relative + ".incomplete", relative, payload)
        finally:
            os.close(root_fd)
    observed = read_descriptor_relative_bytes(root, relative, maximum_bytes=MAX_PRODUCER_BYTES)[0]
    if observed != payload:
        raise BootstrapQualificationError("validator-derived manifest differs from physical manifest")
    return {"relative_path": relative, "byte_count": len(payload), "sha256": hashlib.sha256(payload).hexdigest()}


def _complete_document(root, document, project_manifest, dependency_manifest, *, publish):
    prefix = document["bootstrap_id"]
    document["qualification"]["generated_project_manifest"] = _manifest_reference(root, prefix + ".generated-project.json", project_manifest, publish=publish)
    document["qualification"]["dependency_manifest"] = _manifest_reference(root, prefix + ".dependencies.json", dependency_manifest, publish=publish)
    parse_bootstrap_admission(canonical_bytes(document))
    return document


def _manifest_snapshots(root, document):
    snapshots = []
    for key in ("generated_project_manifest", "dependency_manifest"):
        reference = document["qualification"][key]
        snapshot = materializer.capture_file_snapshot(root / reference["relative_path"])
        if snapshot.sha256 != reference["sha256"] or snapshot.metadata[3] != reference["byte_count"]:
            raise BootstrapQualificationError("derived manifest changed before snapshot fence")
        snapshots.append(snapshot)
    return snapshots


def admit_bootstrap_qualification(execution: RetainedBootstrapExecution, candidate: CandidateIdentity,
    *, output: Path, allow_reader_compatibility: bool = False) -> ValidatedBootstrapQualification:
    """Publish only freshly observed same-run candidate and physical evidence."""
    try:
        if not isinstance(execution, RetainedBootstrapExecution):
            raise BootstrapQualificationError("retained bootstrap execution required")
        root = execution.configuration.artifact_root
        if not isinstance(output, Path) or output.parent != root:
            raise BootstrapQualificationError("admission must be directly beneath bootstrap root")
        _relative(output.name)
        document, project, dependencies, fence = _observe_qualification(execution, candidate,
            allow_reader_compatibility=allow_reader_compatibility)
        fence()
        _complete_document(root, document, project, dependencies, publish=True)
        manifest_snapshots = _manifest_snapshots(root, document)
        fence()
        root_fd = _execution_transport._root_descriptor(root)
        try:
            fence()
            for snapshot in manifest_snapshots:
                materializer.require_unchanged_file_snapshot(snapshot, phase="bootstrap manifest publication")
                _recheck_snapshot_path(snapshot)
            _publish_document(root, root_fd, output.name + ".incomplete", output.name, canonical_bytes(document))
        finally:
            os.close(root_fd)
        return ValidatedBootstrapQualification(document["bootstrap_id"], execution.qualification_run,
            document["candidate_identity_sha256"], output, canonical_sha256(document))
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, subprocess.SubprocessError) as exc:
        raise BootstrapQualificationError(str(exc)) from exc


def load_and_revalidate_bootstrap_qualification(*, artifact_root: Path, admission_relative_path: str,
    candidate: CandidateIdentity, expected_run: QualificationRunAuthority,
    expected_source: BootstrapSourceAuthority,
    allow_reader_compatibility: bool = False) -> ValidatedBootstrapQualification:
    """Recompute physical authority; a constructed validated DTO is never evidence."""
    try:
        _canonical_directory(artifact_root)
        _relative(admission_relative_path)
        payload = read_descriptor_relative_bytes(artifact_root, admission_relative_path, maximum_bytes=MAX_PRODUCER_BYTES)[0]
        admission_snapshot = materializer.capture_file_snapshot(artifact_root / admission_relative_path)
        document = parse_bootstrap_admission(payload)
        if document["schema_version"] == 2 and not allow_reader_compatibility:
            raise BootstrapQualificationError("amended admission requires explicit reader compatibility")
        if document["schema_version"] == 1 and allow_reader_compatibility:
            raise BootstrapQualificationError("ordinary v1 admission cannot be rebound as an amended reader")
        intent = parse_bootstrap_intent(read_descriptor_relative_bytes(artifact_root,
            document["intent"]["relative_path"], maximum_bytes=capture.MAX_ENCODED_BYTES)[0])
        invocation = intent["invocation"]
        configuration = BootstrapConfiguration(artifact_root, Path(invocation["qualification_work_root"]),
            Path(invocation["dependency_cache_root"]), Path(invocation["developer_dir"]))
        retained = RetainedBootstrapExecution(expected_source, expected_run, configuration,
            artifact_root / document["intent"]["relative_path"], artifact_root / document["capture"]["relative_path"])
        observed, project, dependencies, fence = _observe_qualification(retained, candidate,
            allow_reader_compatibility=allow_reader_compatibility)
        _complete_document(artifact_root, observed, project, dependencies, publish=False)
        manifest_snapshots = _manifest_snapshots(artifact_root, observed)
        if document != observed:
            raise BootstrapQualificationError("admission differs from independently revalidated physical authority")
        fence()
        for snapshot in manifest_snapshots:
            materializer.require_unchanged_file_snapshot(snapshot, phase="bootstrap manifest replay")
            _recheck_snapshot_path(snapshot)
        materializer.require_unchanged_file_snapshot(admission_snapshot, phase="bootstrap replay")
        _recheck_snapshot_path(admission_snapshot)
        if admission_snapshot.sha256 != hashlib.sha256(payload).hexdigest():
            raise BootstrapQualificationError("admission changed during replay")
        return ValidatedBootstrapQualification(document["bootstrap_id"], expected_run,
            document["candidate_identity_sha256"], artifact_root / admission_relative_path, hashlib.sha256(payload).hexdigest())
    except (OSError, ValueError, TypeError, KeyError, RuntimeError, subprocess.SubprocessError) as exc:
        raise BootstrapQualificationError(str(exc)) from exc
