#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from reconstruction_task10_adjudication.core import (  # type: ignore
        adjudicate_findings,
        audit_source,
        build_outputs,
        canonical_json_bytes,
        discover_attachment,
        discover_transport_root,
        select_vectors,
        verify_determinism,
        verify_full_return_attachment,
        verify_mutations,
        verify_output_bundle,
        verify_source_transport,
    )
else:
    from .core import (
        adjudicate_findings,
        audit_source,
        build_outputs,
        canonical_json_bytes,
        discover_attachment,
        discover_transport_root,
        select_vectors,
        verify_determinism,
        verify_full_return_attachment,
        verify_mutations,
        verify_output_bundle,
        verify_source_transport,
    )


def repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Verify and adjudicate the RECON-R1-T10A oracle")
    parser.add_argument(
        "command",
        choices=(
            "verify-archive",
            "audit-source",
            "adjudicate",
            "select-vectors",
            "verify-mutations",
            "build",
            "verify-bundle",
            "verify-determinism",
        ),
    )
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--transport-root", type=Path)
    parser.add_argument(
        "--output-root",
        type=Path,
        default=Path(".build-local/reconstruction/RECON-R1-T10C"),
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    root = repository_root()
    output_root = arguments.output_root
    if not output_root.is_absolute():
        output_root = root / output_root
    archive = None
    transport = None
    if arguments.command in {
        "verify-archive", "adjudicate", "select-vectors", "build", "verify-determinism"
    }:
        archive = discover_attachment(root, arguments.archive)
    if arguments.command in {"verify-archive", "build", "verify-determinism"}:
        transport = discover_transport_root(root, arguments.transport_root)

    if arguments.command == "verify-archive":
        result = {
            "attachment": verify_full_return_attachment(archive),
            "sourceTransport": verify_source_transport(transport, root),
        }
    elif arguments.command == "audit-source":
        result = audit_source(root)
    elif arguments.command == "adjudicate":
        result = adjudicate_findings(archive, audit_source(root))
    elif arguments.command == "select-vectors":
        drift = audit_source(root)
        result = select_vectors(archive, adjudicate_findings(archive, drift))
    elif arguments.command == "verify-mutations":
        result = verify_mutations()
    elif arguments.command == "build":
        result = build_outputs(root, output_root, archive, transport)
        result["outputBundle"] = verify_output_bundle(output_root)
    elif arguments.command == "verify-bundle":
        result = verify_output_bundle(output_root)
    elif arguments.command == "verify-determinism":
        result = verify_determinism(root, archive, transport)
    else:  # pragma: no cover
        raise AssertionError(arguments.command)
    sys.stdout.buffer.write(canonical_json_bytes(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
