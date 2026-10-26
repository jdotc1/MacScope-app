"""Explicit source-bound bootstrap execution, candidate admission and replay."""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

from . import bootstrap_qualification as bootstrap
from .artifact_validator import read_descriptor_relative_bytes
from .canonical_json import decode_canonical_bytes
from .receipt_validator import QualificationRunAuthority
from .schema import parse_candidate_identity


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__, allow_abbrev=False)
    commands = value.add_subparsers(dest="operation", required=True)
    for operation in ("execute", "admit", "verify"):
        command = commands.add_parser(operation, allow_abbrev=False)
        command.add_argument("--repository-root", required=True, type=Path)
        command.add_argument("--integration-ref", required=True)
        command.add_argument("--source-commit", required=True)
        command.add_argument("--source-tree", required=True)
        command.add_argument("--qualification-run-id", required=True)
        command.add_argument("--qualification-run-nonce", required=True)
        command.add_argument("--artifact-root", required=True, type=Path)
        if operation == "execute":
            command.add_argument("--qualification-work-root", required=True, type=Path)
            command.add_argument("--dependency-cache-root", required=True, type=Path)
            command.add_argument("--developer-dir", required=True, type=Path)
        else:
            command.add_argument("--candidate-identity", required=True, type=Path)
        if operation == "admit":
            command.add_argument("--intent", required=True)
            command.add_argument("--capture", required=True)
            command.add_argument("--output", required=True, type=Path)
        if operation == "verify":
            command.add_argument("--admission", required=True)
    return value


def _candidate(path):
    if not path.is_absolute() or path.resolve(strict=True) != path:
        raise bootstrap.BootstrapQualificationError("candidate path must be canonical and absolute")
    payload = read_descriptor_relative_bytes(path.parent, path.name, maximum_bytes=bootstrap.MAX_PRODUCER_BYTES)[0]
    candidate, issues = parse_candidate_identity(decode_canonical_bytes(payload))
    if candidate is None or issues:
        raise bootstrap.BootstrapQualificationError("candidate must satisfy the existing closed identity schema")
    return candidate


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        source = bootstrap.BootstrapSourceAuthority(arguments.repository_root,
            arguments.integration_ref, arguments.source_commit, arguments.source_tree)
        run = QualificationRunAuthority(arguments.qualification_run_id, arguments.qualification_run_nonce)
        if arguments.operation == "execute":
            configuration = bootstrap.BootstrapConfiguration(arguments.artifact_root,
                arguments.qualification_work_root, arguments.dependency_cache_root, arguments.developer_dir)
            retained = bootstrap.execute_bootstrap_qualification(source, run, configuration)
            print("MACSCOPE_BOOTSTRAP_INTENT=" + str(retained.intent_path))
            print("MACSCOPE_BOOTSTRAP_CAPTURE=" + str(retained.capture_path))
        elif arguments.operation == "admit":
            bootstrap._relative(arguments.intent)
            bootstrap._relative(arguments.capture)
            intent = bootstrap.parse_bootstrap_intent(read_descriptor_relative_bytes(arguments.artifact_root,
                arguments.intent, maximum_bytes=bootstrap.capture.MAX_ENCODED_BYTES)[0])
            invocation = intent["invocation"]
            configuration = bootstrap.BootstrapConfiguration(arguments.artifact_root,
                Path(invocation["qualification_work_root"]), Path(invocation["dependency_cache_root"]),
                Path(invocation["developer_dir"]))
            retained = bootstrap.RetainedBootstrapExecution(source, run, configuration,
                arguments.artifact_root / arguments.intent, arguments.artifact_root / arguments.capture)
            validated = bootstrap.admit_bootstrap_qualification(retained, _candidate(arguments.candidate_identity), output=arguments.output)
            print("MACSCOPE_BOOTSTRAP_ADMISSION=" + str(validated.admission_path))
        else:
            validated = bootstrap.load_and_revalidate_bootstrap_qualification(
                artifact_root=arguments.artifact_root, admission_relative_path=arguments.admission,
                candidate=_candidate(arguments.candidate_identity), expected_run=run, expected_source=source)
            print("MACSCOPE_BOOTSTRAP_VERIFIED=" + str(validated.admission_path))
        return 0
    except (OSError, ValueError, TypeError, RuntimeError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
