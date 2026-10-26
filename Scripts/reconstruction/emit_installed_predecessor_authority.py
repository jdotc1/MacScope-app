#!/usr/bin/env python3
"""Publish the exact current predecessor authority for installer ``begin``."""

from __future__ import annotations

import argparse
import stat
import sys
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from Scripts.reconstruction import install_release_to_applications as installer  # noqa: E402
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes  # noqa: E402


SCHEMA_VERSION = 1
AUTHORITY_KIND = "macscope-installed-predecessor-observation"
MAX_AUTHORITY_BYTES = 64 * 1024


def _canonical_output(path: Path) -> Path:
    if (
        not path.is_absolute()
        or not path.name
        or path.name in {".", ".."}
        or "\x00" in path.name
    ):
        raise installer.InstallationError(
            "output must be an absolute canonical file path"
        )
    parent = installer._canonical_existing(
        path.parent, directory=True, label="output parent"
    )
    canonical = parent / path.name
    if canonical != path:
        raise installer.InstallationError("output path must be canonical")
    if installer._path_exists(path):
        raise installer.InstallationError("output path must be absent")
    return canonical


def emit(*, installed_app: Path, output: Path) -> str:
    installed_app = installer._canonical_destination(installed_app)
    output = _canonical_output(output)
    observation = installer.capture_predecessor_observation(installed_app)
    document = {
        "schema_version": SCHEMA_VERSION,
        "authority_kind": AUTHORITY_KIND,
        "installed_app_path": str(observation.installed_app),
        "observation": dict(observation.document),
        "predecessor_observations_sha256": observation.sha256,
    }
    payload = canonical_bytes(document)
    if len(payload) > MAX_AUTHORITY_BYTES:
        raise installer.InstallationError(
            "predecessor authority exceeds its size bound"
        )
    installer._write_create_only(output, document)
    installer._fsync_regular_file(output)
    installer._fsync_directory(output.parent)
    metadata = output.lstat()
    if (
        not stat.S_ISREG(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_nlink != 1
        or output.resolve(strict=True) != output
        or output.read_bytes() != payload
    ):
        raise installer.InstallationError(
            "published predecessor authority is not exact and private"
        )
    return observation.sha256


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Publish the exact current /Applications/MacScope.app predecessor "
            "authority consumed by installer begin."
        )
    )
    parser.add_argument("--installed-app", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser


def main(
    argv: list[str] | None = None,
    *,
    _allow_test_destination: bool = False,
) -> int:
    arguments = _parser().parse_args(argv)
    try:
        if (
            not _allow_test_destination
            and arguments.installed_app != installer.PRODUCTION_DESTINATION
        ):
            raise installer.InstallationError(
                "production installed app must be exactly "
                f"{installer.PRODUCTION_DESTINATION}"
            )
        digest = emit(
            installed_app=arguments.installed_app,
            output=arguments.output,
        )
    except (installer.InstallationError, OSError) as error:
        print(f"ERROR: predecessor authority refused: {error}", file=sys.stderr)
        return 1
    print(digest)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
