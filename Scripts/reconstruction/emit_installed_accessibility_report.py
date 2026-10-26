#!/usr/bin/env python3
"""Project one sealed installed Task 10 matrix into accessibility evidence.

This command is deliberately read-only with respect to the installed app and
the completed XCUITest execution.  It validates and reuses their sealed matrix
receipt, semantic manifest, selector catalog, and presentation attachments; it
never launches the app, XCUITest, or another GUI process.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import stat
import sys
import time
from pathlib import Path
from typing import Any, Mapping


ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from Scripts.reconstruction import installed_matrix_receipt as matrix  # noqa: E402
from Scripts.reconstruction_gate_f.canonical_json import (  # noqa: E402
    CanonicalJSONError,
    canonical_bytes,
    canonical_sha256,
    decode_canonical_bytes,
)
from Scripts.reconstruction.write_execution_report import (  # noqa: E402
    ExecutionReportError,
    document as execution_report_document,
    qualification_run_authority,
)
from Scripts.ws24_emit_installed_qualification_report import (  # noqa: E402
    ReportError,
    installed_selector_projection,
    load_installed_selector_catalog,
    result_bundle_sha256,
)


ACCESSIBILITY_REPORT_NAME = "InstalledAccessibility.accessibility-report.json"
PRESENTATION_MANIFEST_NAME = "InstalledAccessibility.presentation-manifest.json"
EXECUTION_REPORT_NAME = "InstalledAccessibility.execution-report.json"
PRESENTATION_MANIFEST_SCHEMA_VERSION = 2
EXPECTED_VARIANTS = matrix.PRESENTATION_VARIANTS
SCREENSHOT_NAMES = {
    (presentation_state, appearance, window_size): (
        "InstalledAccessibility."
        f"{presentation_state}.{appearance}.{window_size}.png"
    )
    for presentation_state, appearance, window_size, _width, _height in EXPECTED_VARIANTS
}
SEMANTIC_FIELDS = frozenset(
    {
        "schema_version",
        "candidate_identity_sha256",
        "source_xcresult",
        "selector_catalog_sha256",
        "selector_projection",
        "selector_projection_sha256",
        "observed_selector_projection",
        "observed_selector_projection_sha256",
        "expected_selector_count",
        "executed_selector_count",
        "passed_selector_count",
        "failed_selector_count",
        "skipped_selector_count",
        "selectors",
        "result",
    }
)


class InstalledAccessibilityReportError(ValueError):
    pass


def parse_arguments(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Validate and project the already-completed installed Task 10 matrix "
            "into canonical accessibility evidence."
        )
    )
    parser.add_argument("--candidate-identity", type=Path, required=True)
    parser.add_argument("--matrix-receipt", type=Path, required=True)
    parser.add_argument("--xcresult-semantic-manifest", type=Path, required=True)
    parser.add_argument("--artifact-root", type=Path, required=True)
    parser.add_argument("--qualification-run-id", required=True)
    parser.add_argument("--qualification-run-nonce", required=True)
    parser.add_argument("--predecessor-observations-sha256", required=True)
    return parser.parse_args(argv)


def _closed_mapping(value: object, fields: frozenset[str], label: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping) or set(value) != fields:
        observed = sorted(value) if isinstance(value, Mapping) else type(value).__name__
        raise InstalledAccessibilityReportError(
            f"{label} must be a closed object with fields {sorted(fields)}; found {observed}"
        )
    return value


def _canonical_regular_file(path: Path, label: str) -> Path:
    if not path.is_absolute():
        raise InstalledAccessibilityReportError(f"{label} must be an absolute path")
    try:
        supplied_parent = path.parent
        parent = supplied_parent.resolve(strict=True)
        if parent != supplied_parent:
            raise InstalledAccessibilityReportError(
                f"{label} must not traverse symlinked ancestors"
            )
        candidate = parent / path.name
        metadata = candidate.lstat()
    except OSError as error:
        raise InstalledAccessibilityReportError(f"{label} is unavailable: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        raise InstalledAccessibilityReportError(f"{label} must be a non-symlink regular file")
    if candidate.resolve(strict=True) != candidate:
        raise InstalledAccessibilityReportError(f"{label} must already be canonical")
    return candidate


def _load_canonical_file(path: Path, label: str) -> tuple[Any, str]:
    path = _canonical_regular_file(path, label)
    try:
        payload, _ = matrix._stable_file_bytes(path)
        value = decode_canonical_bytes(payload)
    except (OSError, CanonicalJSONError, matrix.InstalledMatrixReceiptError) as error:
        raise InstalledAccessibilityReportError(f"{label} is not canonical JSON: {error}") from error
    return value, hashlib.sha256(payload).hexdigest()


def _catalog_projection() -> list[dict[str, Any]]:
    try:
        catalog = load_installed_selector_catalog()
    except ReportError as error:
        raise InstalledAccessibilityReportError(str(error)) from error
    projection = installed_selector_projection(catalog)
    if len(projection) != 22:
        raise InstalledAccessibilityReportError(
            "installed selector projection must contain exactly 22 vectors"
        )
    return projection


def validate_semantic_manifest(
    value: object,
    *,
    candidate_identity_sha256: str,
    receipt: Mapping[str, Any],
    catalog: list[dict[str, Any]],
    xcresult_bundle_sha256: str,
) -> dict[str, Any]:
    semantic = _closed_mapping(value, SEMANTIC_FIELDS, "xcresult semantic manifest")
    source = _closed_mapping(
        semantic["source_xcresult"],
        frozenset({"bundle_sha256", "closed_tree_sha256"}),
        "xcresult semantic source",
    )
    raw_selectors = semantic["selectors"]
    if not isinstance(raw_selectors, list):
        raise InstalledAccessibilityReportError("xcresult semantic selectors must be an array")
    selectors: list[dict[str, Any]] = []
    for index, item in enumerate(raw_selectors):
        selectors.append(
            dict(
                _closed_mapping(
                    item,
                    frozenset({"test_identifier", "status"}),
                    f"xcresult semantic selector {index}",
                )
            )
        )
    raw_projection = semantic["selector_projection"]
    if not isinstance(raw_projection, list):
        raise InstalledAccessibilityReportError(
            "xcresult semantic selector projection must be an array"
        )
    semantic_projection = [
        dict(
            _closed_mapping(
                item,
                frozenset({"required_identifiers", "test_identifier", "vector_id"}),
                f"xcresult semantic selector projection {index}",
            )
        )
        for index, item in enumerate(raw_projection)
    ]
    raw_observed_projection = semantic["observed_selector_projection"]
    if not isinstance(raw_observed_projection, list):
        raise InstalledAccessibilityReportError(
            "xcresult semantic observed selector projection must be an array"
        )
    observed_projection = [
        dict(
            _closed_mapping(
                item,
                frozenset({"observed_identifiers", "test_identifier", "vector_id"}),
                f"xcresult semantic observed selector projection {index}",
            )
        )
        for index, item in enumerate(raw_observed_projection)
    ]
    expected_observed_projection = [
        {
            "observed_identifiers": sorted(item["required_identifiers"]),
            "test_identifier": item["test_identifier"],
            "vector_id": item["vector_id"],
        }
        for item in catalog
    ]
    expected_identifiers = [item["test_identifier"] for item in catalog]
    expected_selectors = [
        {"test_identifier": identifier, "status": "passed"}
        for identifier in expected_identifiers
    ]
    xcresult = receipt["products"]["xcresult"]
    if (
        semantic["schema_version"] != 3
        or semantic["candidate_identity_sha256"] != candidate_identity_sha256
        or source["bundle_sha256"] != xcresult_bundle_sha256
        or source["closed_tree_sha256"] != xcresult["closed_tree_sha256"]
        or semantic["selector_catalog_sha256"] != canonical_sha256(expected_identifiers)
        or semantic_projection != catalog
        or semantic["selector_projection_sha256"] != canonical_sha256(catalog)
        or observed_projection != expected_observed_projection
        or semantic["observed_selector_projection_sha256"]
        != canonical_sha256(expected_observed_projection)
        or receipt["execution"]["selector_projection"] != catalog
        or receipt["execution"]["selector_projection_sha256"] != canonical_sha256(catalog)
        or receipt["accessibility_observations"]["observed_selector_projection"]
        != expected_observed_projection
        or receipt["accessibility_observations"][
            "observed_selector_projection_sha256"
        ]
        != canonical_sha256(expected_observed_projection)
        or semantic["expected_selector_count"] != 22
        or semantic["executed_selector_count"] != 22
        or semantic["passed_selector_count"] != 22
        or semantic["failed_selector_count"] != 0
        or semantic["skipped_selector_count"] != 0
        or selectors != expected_selectors
        or semantic["result"] != "passed"
    ):
        raise InstalledAccessibilityReportError(
            "xcresult semantic manifest did not exactly execute and pass the canonical 22-vector catalog"
        )
    return dict(semantic)


def _prepare_artifact_root(path: Path) -> tuple[Path, int]:
    if not path.is_absolute() or path.exists() or path.is_symlink():
        raise InstalledAccessibilityReportError(
            "artifact root must be an absent absolute path"
        )
    try:
        supplied_parent = path.parent
        parent = supplied_parent.resolve(strict=True)
        if parent != supplied_parent:
            raise InstalledAccessibilityReportError(
                "artifact root parent must not traverse symlinked ancestors"
            )
        metadata = parent.lstat()
    except OSError as error:
        raise InstalledAccessibilityReportError(
            f"artifact root parent is unavailable: {error}"
        ) from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise InstalledAccessibilityReportError(
            "artifact root parent must be a non-symlink directory"
        )
    root = parent / path.name
    try:
        os.mkdir(root, 0o700)
        descriptor = os.open(
            root,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
    except OSError as error:
        raise InstalledAccessibilityReportError(
            f"cannot create artifact root: {error}"
        ) from error
    return root, descriptor


def _write_relative_create_only(root_descriptor: int, name: str, payload: bytes) -> None:
    if Path(name).name != name or name in {"", ".", ".."}:
        raise InstalledAccessibilityReportError("artifact closure contains an unsafe name")
    try:
        descriptor = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=root_descriptor,
        )
    except OSError as error:
        raise InstalledAccessibilityReportError(
            f"cannot create descriptor-relative artifact {name}: {error}"
        ) from error
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
    finally:
        os.close(descriptor)


def _copy_presentations(
    receipt: Mapping[str, Any], root_descriptor: int
) -> list[dict[str, Any]]:
    raw_attachments = receipt["presentation_screenshots"]["attachments"]
    by_variant = {
        (
            item["presentation_state"],
            item["appearance"],
            item["window_size"],
        ): item
        for item in raw_attachments
    }
    expected_variants = {
        (presentation_state, appearance, window_size)
        for presentation_state, appearance, window_size, _width, _height
        in EXPECTED_VARIANTS
    }
    if (
        set(by_variant) != expected_variants
        or len(by_variant) != len(raw_attachments)
        or len(raw_attachments) != len(EXPECTED_VARIANTS)
    ):
        raise InstalledAccessibilityReportError(
            "matrix receipt does not carry the exact seven-state presentation closure"
        )
    copied: list[dict[str, Any]] = []
    copied_hashes: set[str] = set()
    for presentation_state, appearance, window_size, _width, _height in EXPECTED_VARIANTS:
        source = by_variant[(presentation_state, appearance, window_size)]
        source_path = _canonical_regular_file(
            Path(source["attachment_path"]), "matrix presentation attachment"
        )
        try:
            payload, _ = matrix._stable_file_bytes(source_path)
        except matrix.InstalledMatrixReceiptError as error:
            raise InstalledAccessibilityReportError(str(error)) from error
        digest = hashlib.sha256(payload).hexdigest()
        if digest != source["sha256"]:
            raise InstalledAccessibilityReportError(
                "matrix presentation attachment changed after receipt validation"
            )
        try:
            width, height = matrix.decode_png_dimensions(payload)
        except matrix.InstalledMatrixReceiptError as error:
            raise InstalledAccessibilityReportError(str(error)) from error
        if width != source["pixel_width"] or height != source["pixel_height"]:
            raise InstalledAccessibilityReportError(
                "matrix presentation dimensions differ from decoded PNG pixels"
            )
        destination_name = SCREENSHOT_NAMES[
            (presentation_state, appearance, window_size)
        ]
        _write_relative_create_only(root_descriptor, destination_name, payload)
        copied_hashes.add(digest)
        copied.append(
            {
                "appearance": appearance,
                "byte_count": len(payload),
                "pixel_height": height,
                "pixel_width": width,
                "presentation_state": presentation_state,
                "relative_path": destination_name,
                "sha256": digest,
                "window_size": window_size,
            }
        )
    if len(copied_hashes) != len(EXPECTED_VARIANTS):
        raise InstalledAccessibilityReportError(
            "the seven-state presentation screenshots must have distinct physical content"
        )
    return copied


def emit(arguments: argparse.Namespace) -> dict[str, Path]:
    started_at_unix_ms = int(time.time() * 1000)
    run_authority = qualification_run_authority(arguments)
    candidate_identity = _canonical_regular_file(
        arguments.candidate_identity, "candidate identity"
    )
    matrix_receipt_path = _canonical_regular_file(
        arguments.matrix_receipt, "matrix receipt"
    )
    semantic_manifest_path = _canonical_regular_file(
        arguments.xcresult_semantic_manifest, "xcresult semantic manifest"
    )
    try:
        receipt, receipt_sha256 = matrix.load_receipt_with_sha256(matrix_receipt_path)
    except matrix.InstalledMatrixReceiptError as error:
        raise InstalledAccessibilityReportError(str(error)) from error
    catalog = _catalog_projection()
    installed_app = Path(receipt["products"]["installed_app"]["path"])
    try:
        validated_receipt_sha256 = matrix.validate_receipt(
            receipt,
            candidate_identity_path=candidate_identity,
            installed_app=installed_app,
            expected_selector_projection=catalog,
        )
    except matrix.InstalledMatrixReceiptError as error:
        raise InstalledAccessibilityReportError(str(error)) from error
    if validated_receipt_sha256 != receipt_sha256:
        raise InstalledAccessibilityReportError(
            "matrix receipt canonical and physical digests disagree"
        )
    semantic_value, semantic_sha256 = _load_canonical_file(
        semantic_manifest_path, "xcresult semantic manifest"
    )
    xcresult_path = Path(receipt["products"]["xcresult"]["path"])
    try:
        bundle_sha256 = result_bundle_sha256(xcresult_path)
    except ReportError as error:
        raise InstalledAccessibilityReportError(str(error)) from error
    candidate_sha256 = receipt["candidate"]["identity_sha256"]
    semantic = validate_semantic_manifest(
        semantic_value,
        candidate_identity_sha256=candidate_sha256,
        receipt=receipt,
        catalog=catalog,
        xcresult_bundle_sha256=bundle_sha256,
    )

    artifact_root, root_descriptor = _prepare_artifact_root(arguments.artifact_root)
    try:
        screenshots = _copy_presentations(receipt, root_descriptor)
        presentation_manifest = {
            "candidate_identity_sha256": candidate_sha256,
            "matrix_receipt_sha256": receipt_sha256,
            "report_kind": "installed-accessibility-presentation",
            "result": "passed",
            "schema_version": PRESENTATION_MANIFEST_SCHEMA_VERSION,
            "screenshots": screenshots,
            "source_xcresult": dict(semantic["source_xcresult"]),
            "test_identifier": matrix.PRESENTATION_TEST_IDENTIFIER,
        }
        presentation_payload = canonical_bytes(presentation_manifest)
        _write_relative_create_only(
            root_descriptor, PRESENTATION_MANIFEST_NAME, presentation_payload
        )
        presentation_sha256 = hashlib.sha256(presentation_payload).hexdigest()

        accessibility_report = {
            "candidate_identity_sha256": candidate_sha256,
            "counts": {
                "executed": 22,
                "expected": 22,
                "failed": 0,
                "passed": 22,
                "skipped": 0,
            },
            "matrix_receipt": {
                "schema_version": matrix.SCHEMA_VERSION,
                "sha256": receipt_sha256,
            },
            "presentation_manifest_sha256": presentation_sha256,
            "report_kind": "installed-accessibility",
            "result": "passed",
            "schema_version": 2,
            "selector_catalog_sha256": semantic["selector_catalog_sha256"],
            "selector_projection_sha256": canonical_sha256(catalog),
            "observed_selector_projection_sha256": semantic[
                "observed_selector_projection_sha256"
            ],
            "selectors": [
                {
                    **item,
                    "observed_identifiers": sorted(item["required_identifiers"]),
                    "status": "passed",
                }
                for item in catalog
            ],
            "xcresult_semantic_manifest_sha256": semantic_sha256,
        }
        _write_relative_create_only(
            root_descriptor,
            ACCESSIBILITY_REPORT_NAME,
            canonical_bytes(accessibility_report),
        )

        ended_at_unix_ms = max(started_at_unix_ms, int(time.time() * 1000))
        execution_report = execution_report_document(
            argparse.Namespace(
                ended_at_unix_ms=ended_at_unix_ms,
                exit_code=0,
                result="passed",
                started_at_unix_ms=started_at_unix_ms,
            ),
            qualification_run=run_authority,
            predecessor_observations_sha256=(
                arguments.predecessor_observations_sha256
            ),
        )
        _write_relative_create_only(
            root_descriptor, EXECUTION_REPORT_NAME, canonical_bytes(execution_report)
        )
        os.fsync(root_descriptor)
    finally:
        os.close(root_descriptor)

    outputs = {
        "REPORT": artifact_root / ACCESSIBILITY_REPORT_NAME,
        "PRESENTATION_MANIFEST": artifact_root / PRESENTATION_MANIFEST_NAME,
        "EXECUTION_REPORT": artifact_root / EXECUTION_REPORT_NAME,
    }
    for presentation_state, appearance, window_size, _width, _height in EXPECTED_VARIANTS:
        output_id = "SCREENSHOT_" + "_".join(
            part.upper().replace("-", "_")
            for part in (presentation_state, appearance, window_size)
        )
        outputs[output_id] = (
            artifact_root / SCREENSHOT_NAMES[(presentation_state, appearance, window_size)]
        )
    return outputs


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        outputs = emit(arguments)
    except (OSError, InstalledAccessibilityReportError, ExecutionReportError) as error:
        print(f"ERROR: installed accessibility projection failed: {error}", file=sys.stderr)
        return 2
    for key, path in outputs.items():
        print(f"MACSCOPE_INSTALLED_ACCESSIBILITY_{key}={path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
