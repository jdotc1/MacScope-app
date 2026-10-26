"""Fresh, command-owned verification of separately retained bootstrap evidence.

No qualification work runs here. The admitted original remains read-only; these
reports describe only the fresh verification interval.
"""
from __future__ import annotations

import argparse
import hashlib
import os
from pathlib import Path
import stat
import sys
import time
from typing import Literal

from . import bootstrap_qualification as bootstrap
from .artifact_validator import read_descriptor_relative_bytes, safe_relative_artifact_path
from .canonical_json import canonical_bytes, decode_canonical_bytes
from .command_execution import _root_descriptor, _write_all
from .receipt_validator import QualificationRunAuthority
from .schema import CandidateIdentity, candidate_identity_sha256, is_sha256, parse_candidate_identity

COMMANDS = {"fullsuite": "qualification.verify-bootstrap-fullsuite",
            "products": "qualification.verify-bootstrap-products"}
MAX_REPORT_BYTES = 16 * 1024 * 1024


def output_contract(kind):
    if kind not in COMMANDS:
        raise ValueError("unknown bootstrap verifier kind")
    prefix = "BootstrapFullsuite" if kind == "fullsuite" else "BootstrapProducts"
    suffix = "xcresult" if kind == "fullsuite" else "app"
    markers = ("EXECUTION_REPORT", "SEMANTIC_REPORT",
               "XCRESULT_PROJECTION" if kind == "fullsuite" else "APP_PROJECTION")
    names = (prefix + ".execution-report.json", prefix + ".semantic-report.json",
             prefix + "." + suffix + "-projection.json")
    return tuple(zip(names, ("MACSCOPE_BOOTSTRAP_" + kind.upper() + "_" + m for m in markers)))


def _directory(path):
    if not isinstance(path, Path) or not path.is_absolute() or path.resolve(strict=True) != path or not path.is_dir():
        raise ValueError("verifier root must be a canonical physical directory")
    fd = _root_descriptor(path)
    os.close(fd)


def _overlap(first, second):
    return first == second or first in second.parents or second in first.parents


def _owned_bytes(root, relative):
    if not safe_relative_artifact_path(relative):
        raise ValueError("unsafe verifier file reference")
    path = root / relative
    before = path.lstat()
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise ValueError("verifier outputs must be ordinary single-link files")
    payload, size, digest = read_descriptor_relative_bytes(root, relative, maximum_bytes=MAX_REPORT_BYTES)
    after = path.lstat()
    fields = ("st_dev", "st_ino", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
    if any(getattr(before, k) != getattr(after, k) for k in fields):
        raise ValueError("verifier output changed while reading")
    return payload, {"relative_path": relative, "byte_count": size, "sha256": digest}


def revalidated_evidence(*, kind, candidate, expected_source, bootstrap_root,
                         admission_relative_path, qualification_run):
    """The loader recomputes the entire proof before any assertions are consumed."""
    if kind not in COMMANDS:
        raise ValueError("unknown bootstrap verifier kind")
    validated = bootstrap.load_and_revalidate_bootstrap_qualification(
        artifact_root=bootstrap_root, admission_relative_path=admission_relative_path,
        candidate=candidate, expected_run=qualification_run, expected_source=expected_source)
    payload, size, digest = read_descriptor_relative_bytes(bootstrap_root, admission_relative_path,
                                                          maximum_bytes=MAX_REPORT_BYTES)
    if digest != validated.admission_sha256:
        raise ValueError("bootstrap admission changed after physical validation")
    document = bootstrap.parse_bootstrap_admission(payload)
    if kind == "fullsuite":
        from Scripts.ws24_emit_installed_qualification_report import result_bundle_sha256
        directory = bootstrap_root / document["tests"]["xcresult"]["relative_path"]
        identity = {"content_sha256": result_bundle_sha256(directory)}
        if identity["content_sha256"] != document["tests"]["xcresult"]["content_sha256"]:
            raise ValueError("original xcresult changed after validation")
        extra = {"test_observations": document["tests"]["observations"],
                 "coverage": document["tests"]["coverage"]}
        artifact_kind = "xcresult"
    else:
        from Scripts.reconstruction.installed_matrix_receipt import _bundle_identity
        directory = bootstrap_root / document["products"]["release"]["relative_path"]
        identity = _bundle_identity(directory, directory / "Contents/MacOS/MacScope")
        product = document["products"]["release"]
        if (identity["content_sha256"], identity["closed_tree_sha256"], identity["executable_sha256"]) != (
                product["bundle_sha256"], product["closed_tree_sha256"], product["executable_sha256"]):
            raise ValueError("original Release product changed after validation")
        extra = {"products": document["products"]}
        artifact_kind = "app-bundle"
    proof = {"root": str(bootstrap_root),
             "admission": {"relative_path": admission_relative_path, "byte_count": size, "sha256": digest},
             "intent_sha256": document["intent"]["sha256"], "capture_sha256": document["capture"]["sha256"],
             "original_execution_interval": document["execution_interval"]}
    projection = {"schema_version": 1, "command_id": COMMANDS[kind],
                  "candidate_identity_sha256": candidate_identity_sha256(candidate),
                  "bootstrap_admission_sha256": digest, "artifact_kind": artifact_kind,
                  "directory_path": str(directory), "identity": identity}
    return proof, extra, projection


def semantic_document(*, kind, candidate, qualification_run, predecessor, proof,
                      extra, interval, projection_reference):
    return {"schema_version": 1, "report_kind": "gatef-bootstrap-" + kind + "-verification",
            "command_id": COMMANDS[kind], "candidate_identity_sha256": candidate_identity_sha256(candidate),
            "qualification_run": {"run_id": qualification_run.run_id, "nonce": qualification_run.nonce},
            "predecessor_observations_sha256": predecessor, "bootstrap": proof,
            "verification_interval": interval, "projection": projection_reference, **extra}


def run_bootstrap_verifier(*, kind: Literal["fullsuite", "products"],
    candidate: CandidateIdentity, expected_source: bootstrap.BootstrapSourceAuthority,
    bootstrap_root: Path, admission_relative_path: str, artifact_root: Path,
    qualification_run: QualificationRunAuthority,
    predecessor_observations_sha256: str) -> tuple[Path, Path, Path]:
    started = time.time_ns() // 1_000_000
    contract = output_contract(kind)
    if not is_sha256(predecessor_observations_sha256):
        raise ValueError("invalid predecessor observations digest")
    _directory(bootstrap_root)
    if (not artifact_root.is_absolute() or artifact_root.resolve() != artifact_root
            or _overlap(artifact_root, bootstrap_root)
            or _overlap(artifact_root, expected_source.repository_root)
            or not bootstrap._under(artifact_root, bootstrap.OUTPUT_BASE, strict=True)):
        raise ValueError("verifier outputs must be outside original evidence and source")
    proof, extra, projection = revalidated_evidence(kind=kind, candidate=candidate,
        expected_source=expected_source, bootstrap_root=bootstrap_root,
        admission_relative_path=admission_relative_path, qualification_run=qualification_run)
    if proof["original_execution_interval"]["ended_at_unix_ms"] > started:
        raise ValueError("original qualification ends after fresh verification starts")
    artifact_root.mkdir(parents=True, exist_ok=True)
    _directory(artifact_root)
    root_fd = _root_descriptor(artifact_root)
    try:
        # Reservation covers both kinds; a campaign root cannot be reused by
        # another verifier, including an interrupted publication.
        os.mkdir(".bootstrap-verifier-publication", mode=0o700, dir_fd=root_fd)
        projection_payload = canonical_bytes(projection)
        projection_ref = {"relative_path": contract[2][0], "byte_count": len(projection_payload),
                          "sha256": hashlib.sha256(projection_payload).hexdigest()}
        ended = time.time_ns() // 1_000_000
        interval = {"started_at_unix_ms": started, "ended_at_unix_ms": ended}
        semantic = semantic_document(kind=kind, candidate=candidate, qualification_run=qualification_run,
            predecessor=predecessor_observations_sha256, proof=proof, extra=extra,
            interval=interval, projection_reference=projection_ref)
        execution = {"schema_version": 2, "qualification_run": semantic["qualification_run"],
            "predecessor_observations_sha256": predecessor_observations_sha256, **interval,
            "result": "passed", "exit_code": 0, "stress": None}
        # Execution success publishes last; failed/partial publication retains
        # its reservation and cannot manufacture a complete passed output set.
        payloads = (canonical_bytes(execution), canonical_bytes(semantic), projection_payload)
        for index in (2, 1, 0):
            fd = os.open(contract[index][0], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=root_fd)
            try:
                _write_all(fd, payloads[index])
                os.fsync(fd)
            finally:
                os.close(fd)
        os.fsync(root_fd)
    finally:
        os.close(root_fd)
    paths = tuple(artifact_root / name for name, _ in contract)
    for path, (_, marker) in zip(paths, contract):
        _owned_bytes(artifact_root, path.name)
        print(marker + "=" + str(path), flush=True)
    return paths


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    parser.add_argument("kind", choices=tuple(COMMANDS))
    for option in ("candidate-identity", "repository-root", "integration-ref", "bootstrap-root",
                   "bootstrap-admission", "artifact-root", "qualification-run-id",
                   "qualification-run-nonce", "predecessor-observations-sha256"):
        parser.add_argument("--" + option, required=True)
    arguments = list(sys.argv[1:] if argv is None else argv)
    options = [value.split("=", 1)[0] for value in arguments if value.startswith("--")]
    if len(options) != len(set(options)):
        parser.error("duplicate verifier options")
    args = parser.parse_args(arguments)
    try:
        candidate_path = Path(args.candidate_identity)
        candidate, issues = parse_candidate_identity(decode_canonical_bytes(
            read_descriptor_relative_bytes(candidate_path.parent, candidate_path.name,
                                           maximum_bytes=MAX_REPORT_BYTES)[0]))
        if candidate is None or issues:
            raise ValueError("invalid candidate identity")
        root = Path(args.bootstrap_root)
        admission_relative = Path(args.bootstrap_admission).relative_to(root).as_posix()
        source = bootstrap.BootstrapSourceAuthority(Path(args.repository_root), args.integration_ref,
                                                    candidate.source.commit, candidate.source.tree)
        run_bootstrap_verifier(kind=args.kind, candidate=candidate, expected_source=source,
            bootstrap_root=root, admission_relative_path=admission_relative,
            artifact_root=Path(args.artifact_root), qualification_run=QualificationRunAuthority(
                args.qualification_run_id, args.qualification_run_nonce),
            predecessor_observations_sha256=args.predecessor_observations_sha256)
        return 0
    except (OSError, ValueError, RuntimeError, TypeError) as error:
        print("bootstrap verifier invalid: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
