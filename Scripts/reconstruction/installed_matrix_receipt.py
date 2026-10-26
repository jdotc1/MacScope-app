#!/usr/bin/env python3
"""Seal and revalidate the exact installed Task 10 XCUITest execution.

The receipt deliberately binds the result bundle to every product which could
otherwise be reused across candidates: the Gate F candidate identity, the
preparation receipt, prepared/execution xctestruns, installed app, UI test bundle,
and UI runner.
"""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import re
import stat
import struct
import subprocess
import sys
import zlib
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from Scripts.reconstruction_gate_f.canonical_json import (  # noqa: E402
    canonical_bytes,
    canonical_sha256,
    decode_canonical_bytes,
    load_canonical_json,
)
from Scripts.reconstruction_gate_f.materialize_candidate_identity import (  # noqa: E402
    CandidateMaterializationError,
    bundle_tree_digests,
    capture_bundle_snapshot,
)
from Scripts.reconstruction_gate_f.schema import (  # noqa: E402
    CandidateIdentity,
    candidate_identity_sha256,
    parse_candidate_identity,
)


SCHEMA_VERSION = 7
SUPPORTED_SCHEMA_VERSIONS = {2, 3, 4, 5, 6, SCHEMA_VERSION}
RECEIPT_KIND = "installed-task10-matrix"
PROOF_ARTIFACT_KIND = "installed-task10-matrix-receipt-v1"
SCHEME = "MacScopeInstalledAppUITests"
TEST_TARGET = "MacScopeInstalledAppUITests"
TEST_BUNDLE_NAME = "MacScopeInstalledAppUITests.xctest"
RUNNER_NAME = "MacScopeInstalledAppUITests-Runner.app"
DESTINATION = "platform=macOS,arch=arm64"
OPT_IN_KEY = "MACSCOPE_WS24_RUN_INSTALLED_XCUITEST"
INSTALLED_APP_KEY = "MACSCOPE_WS24_INSTALLED_APP"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
GIT_OBJECT_RE = re.compile(r"^[0-9a-f]{40}$")

TOP_FIELDS_V2_V3 = {
    "schema_version",
    "receipt_kind",
    "candidate",
    "products",
    "execution",
}
TOP_FIELDS_V4_V5 = TOP_FIELDS_V2_V3 | {"presentation_screenshots"}
TOP_FIELDS_V6_V7 = TOP_FIELDS_V4_V5 | {"accessibility_observations"}
CANDIDATE_FIELDS = {
    "identity_path",
    "identity_sha256",
    "source_commit",
    "source_tree",
    "preparation_receipt_path",
    "preparation_receipt_sha256",
}
PRODUCT_FIELDS_V2 = {
    "installed_app",
    "xctestrun",
    "test_bundle",
    "ui_runner",
    "xcresult",
}
PRODUCT_FIELDS_V3 = {
    "installed_app",
    "prepared_xctestrun",
    "execution_xctestrun",
    "test_bundle",
    "ui_runner",
    "xcresult",
}
PRESENTATION_SCREENSHOT_FIELDS = {
    "artifact_root_path",
    "manifest_path",
    "manifest_sha256",
    "attachments",
}
PRESENTATION_SCREENSHOT_ABSENT_FIELDS = {"state"}
PRESENTATION_SCREENSHOT_ATTACHMENT_FIELDS_V4_V6 = {
    "test_identifier",
    "scenario",
    "appearance",
    "window_size",
    "attachment_path",
    "sha256",
    "pixel_width",
    "pixel_height",
}
PRESENTATION_SCREENSHOT_ATTACHMENT_FIELDS_V7 = (
    PRESENTATION_SCREENSHOT_ATTACHMENT_FIELDS_V4_V6 | {"presentation_state"}
)
ACCESSIBILITY_OBSERVATION_FIELDS = {
    "artifact_root_path",
    "manifest_path",
    "manifest_sha256",
    "attachments",
    "observed_selector_projection",
    "observed_selector_projection_sha256",
}
ACCESSIBILITY_OBSERVATION_ABSENT_FIELDS = {"state"}
ACCESSIBILITY_OBSERVATION_ATTACHMENT_FIELDS = {
    "attachment_path",
    "observed_identifiers",
    "sha256",
    "test_identifier",
    "vector_id",
}
OBSERVED_SELECTOR_PROJECTION_FIELDS = {
    "observed_identifiers",
    "test_identifier",
    "vector_id",
}
BUNDLE_FIELDS = {
    "path",
    "bundle_identifier",
    "content_sha256",
    "closed_tree_sha256",
    "executable_path",
    "executable_sha256",
}
FILE_FIELDS = {"path", "sha256"}
TREE_FIELDS = {"path", "closed_tree_sha256"}
ABSENT_RESULT_FIELDS = {"state"}
EXECUTION_FIELDS_V2_V4 = {
    "argv",
    "selectors",
    "environment",
    "started_at_unix_ms",
    "ended_at_unix_ms",
    "duration_ms",
    "exit_code",
    "result",
    "failure",
    "input_snapshot_before",
    "input_snapshot_after",
}
EXECUTION_FIELDS_V5_V7 = EXECUTION_FIELDS_V2_V4 | {
    "selector_projection",
    "selector_projection_sha256",
}
SELECTOR_PROJECTION_FIELDS = {
    "required_identifiers",
    "test_identifier",
    "vector_id",
}
ACCESSIBILITY_IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
ACCESSIBILITY_OBSERVATION_ATTACHMENT_NAME = (
    "MacScope.Task10.AccessibilityObservation.v1.json"
)
ACCESSIBILITY_OBSERVATION_PAYLOAD_FIELDS = {
    "observedIdentifiers",
    "schemaVersion",
    "testIdentifier",
    "vectorID",
}
MAX_PNG_DECODED_BYTES = 512 * 1024 * 1024
ENVIRONMENT_FIELDS = {
    "DEVELOPER_DIR",
    "HOME",
    INSTALLED_APP_KEY,
    OPT_IN_KEY,
    "LOGNAME",
    "PATH",
    "TMPDIR",
    "USER",
}
SNAPSHOT_FIELDS_V2 = {
    "candidate_identity", "preparation_receipt", "installed_app", "xctestrun",
    "test_bundle", "ui_runner", "xcodebuild",
}
SNAPSHOT_FIELDS_V3 = {
    "candidate_identity", "preparation_receipt", "installed_app",
    "prepared_xctestrun", "execution_xctestrun", "test_bundle", "ui_runner", "xcodebuild",
}

# This is the authoritative current presentation-variant catalog. The installed
# producer mirrors these IDs and fixture authorities, while every required
# variant × appearance × window-size capture is derived below. These are seven
# presentations, not seven distinct durable phases: newly-created execution and
# restored active-model execution both expose genuine executingReads authority.
PRESENTATION_SCENARIO = "taskEvidenceCountsAccessible"
PRESENTATION_TEST_IDENTIFIER = (
    "WS24InstalledAppUITests/testTask10CTaskEvidenceCountsAccessible()"
)
PRESENTATION_STATES = (
    ("empty", "no-job"),
    ("created-active-execution", "no-job"),
    ("awaiting-model-paused", "paused-model-unavailable-awaiting-model"),
    ("active-model-round", "active-executing-reads"),
    ("partial-failure", "navigation-current"),
    ("completed", "terminal-completed"),
    ("reopen-resume", "active-retrieving"),
)
PRESENTATION_FORMATS = (
    ("light", "minimum", 1_080, 680),
    ("light", "wide", 1_440, 840),
    ("dark", "minimum", 1_080, 680),
    ("dark", "wide", 1_440, 840),
)
PRESENTATION_VARIANTS = tuple(
    (state_id, appearance, window_size, width, height)
    for state_id, _fixture_id in PRESENTATION_STATES
    for appearance, window_size, width, height in PRESENTATION_FORMATS
)


class InstalledMatrixReceiptError(ValueError):
    pass


def _ordinary(path: Path, *, directory: bool) -> Path:
    if not path.is_absolute():
        raise InstalledMatrixReceiptError(f"physical identity path must be absolute: {path}")
    try:
        metadata = path.lstat()
    except OSError as error:
        raise InstalledMatrixReceiptError(f"physical identity path is unavailable: {path}: {error}") from error
    expected = stat.S_ISDIR(metadata.st_mode) if directory else stat.S_ISREG(metadata.st_mode)
    if not expected or stat.S_ISLNK(metadata.st_mode):
        kind = "directory" if directory else "regular file"
        raise InstalledMatrixReceiptError(
            f"physical identity path is not a non-symlink {kind}: {path}"
        )
    resolved = path.resolve(strict=True)
    if resolved != path:
        raise InstalledMatrixReceiptError(
            f"physical identity path must already be canonical: {path}"
        )
    return resolved


def _stable_metadata(metadata: os.stat_result) -> tuple[int, int, int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        stat.S_IMODE(metadata.st_mode),
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _stable_file_bytes(path: Path) -> tuple[bytes, tuple[int, int, int, int, int, int]]:
    """Read an ordinary file once through a no-follow FD and fence in-place writes."""
    path = _ordinary(path, directory=False)
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise InstalledMatrixReceiptError(
                f"physical identity file is not an unlinked ordinary file: {path}"
            )
        chunks: list[bytes] = []
        while True:
            block = os.read(descriptor, 1024 * 1024)
            if not block:
                break
            chunks.append(block)
        after = os.fstat(descriptor)
        if _stable_metadata(before) != _stable_metadata(after):
            raise InstalledMatrixReceiptError(
                f"physical identity file changed while it was read: {path}"
            )
        return b"".join(chunks), _stable_metadata(before)
    finally:
        os.close(descriptor)


def file_sha256(path: Path) -> str:
    payload, _ = _stable_file_bytes(path)
    return hashlib.sha256(payload).hexdigest()


def _presentation_artifact_root(xcresult: Path) -> Path:
    """Return the sole persisted export root associated with one xcresult."""
    xcresult = _ordinary(xcresult, directory=True)
    return xcresult.parent / presentation_artifact_handoff_name(xcresult)


def presentation_artifact_handoff_name(xcresult: Path) -> str:
    """Return the fixed sibling bundle name used for descriptor-relative Gate F handoff."""
    name = xcresult.name
    if (
        not name
        or name in {".", ".."}
        or Path(name).name != name
        or not name.endswith(".xcresult")
    ):
        raise InstalledMatrixReceiptError(
            "xcresult basename cannot define the presentation artifact handoff"
        )
    return f"{name}.presentation-screenshots"


def decode_png_dimensions(payload: bytes) -> tuple[int, int]:
    """Fully validate and decode one bounded, non-interlaced PNG image."""

    if payload[:8] != b"\x89PNG\r\n\x1a\n":
        raise InstalledMatrixReceiptError("presentation attachment is not a PNG")
    offset = 8
    ihdr: bytes | None = None
    compressed = bytearray()
    saw_idat = False
    saw_iend = False
    saw_plte = False
    idat_closed = False
    while offset < len(payload):
        if len(payload) - offset < 12:
            raise InstalledMatrixReceiptError("presentation PNG contains a truncated chunk")
        length = int.from_bytes(payload[offset : offset + 4], "big")
        chunk_type = payload[offset + 4 : offset + 8]
        chunk_end = offset + 12 + length
        if chunk_end > len(payload):
            raise InstalledMatrixReceiptError("presentation PNG contains a truncated chunk")
        chunk = payload[offset + 8 : offset + 8 + length]
        recorded_crc = int.from_bytes(payload[offset + 8 + length : chunk_end], "big")
        if zlib.crc32(chunk_type + chunk) & 0xFFFFFFFF != recorded_crc:
            raise InstalledMatrixReceiptError("presentation PNG contains a corrupt chunk CRC")
        if ihdr is None and chunk_type != b"IHDR":
            raise InstalledMatrixReceiptError("presentation PNG does not begin with IHDR")
        if chunk_type == b"IHDR":
            if ihdr is not None or length != 13:
                raise InstalledMatrixReceiptError("presentation PNG has an invalid IHDR")
            ihdr = chunk
        elif chunk_type == b"PLTE":
            if saw_idat or length == 0 or length % 3 != 0 or length > 768:
                raise InstalledMatrixReceiptError("presentation PNG has an invalid palette")
            saw_plte = True
        elif chunk_type == b"IDAT":
            if idat_closed:
                raise InstalledMatrixReceiptError("presentation PNG has nonconsecutive IDAT chunks")
            saw_idat = True
            compressed.extend(chunk)
        elif chunk_type == b"IEND":
            if length != 0 or saw_iend or not saw_idat:
                raise InstalledMatrixReceiptError("presentation PNG has an invalid IEND")
            saw_iend = True
            offset = chunk_end
            if offset != len(payload):
                raise InstalledMatrixReceiptError("presentation PNG has bytes after IEND")
            break
        else:
            if saw_idat:
                idat_closed = True
            if chunk_type and 65 <= chunk_type[0] <= 90:
                raise InstalledMatrixReceiptError("presentation PNG has an unknown critical chunk")
        offset = chunk_end
    if ihdr is None or not saw_idat or not saw_iend:
        raise InstalledMatrixReceiptError("presentation PNG lacks IHDR, IDAT, or IEND")

    width, height, bit_depth, color_type, compression, filtering, interlace = struct.unpack(
        ">IIBBBBB", ihdr
    )
    allowed_depths = {
        0: {1, 2, 4, 8, 16},
        2: {8, 16},
        3: {1, 2, 4, 8},
        4: {8, 16},
        6: {8, 16},
    }
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(color_type)
    if width < 1 or height < 1:
        raise InstalledMatrixReceiptError("presentation PNG has invalid dimensions")
    if (
        channels is None
        or bit_depth not in allowed_depths[color_type]
        or compression != 0
        or filtering != 0
        or interlace != 0
        or (color_type == 3 and not saw_plte)
    ):
        raise InstalledMatrixReceiptError("presentation PNG uses an unsupported image encoding")
    row_bytes = (width * channels * bit_depth + 7) // 8
    expected_decoded_bytes = height * (row_bytes + 1)
    if expected_decoded_bytes > MAX_PNG_DECODED_BYTES:
        raise InstalledMatrixReceiptError("presentation PNG decoded image is unbounded")
    decoder = zlib.decompressobj()
    try:
        decoded = decoder.decompress(bytes(compressed), expected_decoded_bytes + 1)
        if decoder.unconsumed_tail or len(decoded) > expected_decoded_bytes:
            raise InstalledMatrixReceiptError("presentation PNG expands beyond its dimensions")
        decoded += decoder.flush()
    except zlib.error as error:
        raise InstalledMatrixReceiptError(
            f"presentation PNG pixel stream cannot be decoded: {error}"
        ) from error
    if not decoder.eof or decoder.unused_data or len(decoded) != expected_decoded_bytes:
        raise InstalledMatrixReceiptError("presentation PNG pixel stream is truncated or malformed")

    cursor = 0
    for _ in range(height):
        filter_type = decoded[cursor]
        if filter_type > 4:
            raise InstalledMatrixReceiptError("presentation PNG uses an invalid row filter")
        # Filter reversal is total for filter values 0...4. Once zlib has
        # produced every dimension-derived row byte and each row declares a
        # valid filter, the complete pixel stream is decodable.
        cursor += row_bytes + 1
    return width, height


def _png_dimensions(path: Path) -> tuple[int, int]:
    payload, _ = _stable_file_bytes(path)
    try:
        return decode_png_dimensions(payload)
    except InstalledMatrixReceiptError as error:
        raise InstalledMatrixReceiptError(f"{error}: {path}") from error


def expected_presentation_attachment_name(
    candidate: CandidateIdentity,
    presentation_state: str,
    appearance: str,
    window_size: str,
) -> str:
    return (
        f"{PRESENTATION_SCENARIO}-{presentation_state}-{appearance}-{window_size}-"
        f"{candidate.source.commit}-{candidate.application.executable_sha256}"
    )


# Retain the private spelling for the focused receipt fixtures while Gate F
# consumes the public, candidate-bound naming contract above.
_expected_presentation_attachment_name = expected_presentation_attachment_name


def _manifest_attachment_rows(
    manifest_path: Path,
    *,
    artifact_root: Path,
    candidate: CandidateIdentity,
) -> list[dict[str, Any]]:
    """Parse the Xcode manifest as the closed seven-variant Cartesian contract."""
    try:
        payload, _ = _stable_file_bytes(manifest_path)
        value = json.loads(payload.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError, OSError, InstalledMatrixReceiptError) as error:
        raise InstalledMatrixReceiptError(
            f"cannot decode exported presentation attachment manifest: {error}"
        ) from error
    if not isinstance(value, list):
        raise InstalledMatrixReceiptError("exported presentation attachment manifest must be an array")
    expected_by_name = {
        expected_presentation_attachment_name(
            candidate, presentation_state, appearance, window_size
        ):
        (presentation_state, appearance, window_size, minimum_width, minimum_height)
        for presentation_state, appearance, window_size, minimum_width, minimum_height
        in PRESENTATION_VARIANTS
    }
    rows: list[dict[str, Any]] = []
    for entry in value:
        if not isinstance(entry, dict) or set(entry) - {"testIdentifier", "testIdentifierURL", "attachments"}:
            raise InstalledMatrixReceiptError("exported presentation attachment manifest has unknown fields")
        # A complete 22-selector result normally carries Xcode-generated videos,
        # UI snapshots, hierarchies, and diagnostics for many selectors.  They
        # are not governed presentation evidence and must not make the exact
        # four-image contract depend on Xcode's incidental attachment surface.
        if entry.get("testIdentifier") != PRESENTATION_TEST_IDENTIFIER:
            continue
        attachments = entry.get("attachments")
        if not isinstance(attachments, list):
            raise InstalledMatrixReceiptError("exported presentation attachment list is invalid")
        for attachment in attachments:
            if not isinstance(attachment, dict):
                raise InstalledMatrixReceiptError("exported presentation attachment is invalid")
            human_name = attachment.get("suggestedHumanReadableName")
            if not isinstance(human_name, str) or not human_name.startswith(
                f"{PRESENTATION_SCENARIO}-"
            ):
                # Ignore Xcode's automatic snapshots, recordings, hierarchies,
                # and diagnostics even when they belong to the governed test.
                continue
            exported_name = attachment.get("exportedFileName")
            if not isinstance(exported_name, str) or not exported_name or Path(exported_name).name != exported_name:
                raise InstalledMatrixReceiptError("exported presentation attachment filename is unsafe")
            if human_name not in expected_by_name:
                raise InstalledMatrixReceiptError(
                    "exported presentation attachment has an unexpected scenario, appearance, width, or candidate"
                )
            if attachment.get("isAssociatedWithFailure") is not False:
                raise InstalledMatrixReceiptError("presentation screenshot attachment must not be failure-associated")
            (
                presentation_state,
                appearance,
                window_size,
                minimum_width,
                minimum_height,
            ) = expected_by_name[human_name]
            attachment_path = _ordinary(artifact_root / exported_name, directory=False)
            try:
                attachment_path.relative_to(artifact_root)
            except ValueError as error:
                raise InstalledMatrixReceiptError("presentation attachment escaped its export root") from error
            pixel_width, pixel_height = _png_dimensions(attachment_path)
            if pixel_width < minimum_width or pixel_height < minimum_height:
                raise InstalledMatrixReceiptError(
                    "presentation screenshot dimensions are below the governed window size"
                )
            rows.append(
                {
                    "test_identifier": PRESENTATION_TEST_IDENTIFIER,
                    "scenario": PRESENTATION_SCENARIO,
                    "presentation_state": presentation_state,
                    "appearance": appearance,
                    "window_size": window_size,
                    "attachment_path": str(attachment_path),
                    "sha256": file_sha256(attachment_path),
                    "pixel_width": pixel_width,
                    "pixel_height": pixel_height,
                }
            )
    expected_variants = {(item[0], item[1], item[2]) for item in PRESENTATION_VARIANTS}
    observed_variants = {
        (row["presentation_state"], row["appearance"], row["window_size"])
        for row in rows
    }
    if len(rows) != len(PRESENTATION_VARIANTS) or observed_variants != expected_variants:
        raise InstalledMatrixReceiptError(
            "exported presentation attachments must contain exactly the governed seven-variant appearance-width Cartesian closure"
        )
    if len({row["attachment_path"] for row in rows}) != len(rows):
        raise InstalledMatrixReceiptError("exported presentation attachments contain a duplicate physical file")
    if len({row["sha256"] for row in rows}) != len(rows):
        raise InstalledMatrixReceiptError(
            "exported presentation attachments must have distinct physical content hashes for the full Cartesian closure"
        )

    expected_geometry = {
        (appearance, window_size): (logical_width, logical_height)
        for appearance, window_size, logical_width, logical_height in PRESENTATION_FORMATS
    }
    backing_scales: set[int] = set()
    for row in rows:
        logical_width, logical_height = expected_geometry[
            (str(row["appearance"]), str(row["window_size"]))
        ]
        pixel_width = int(row["pixel_width"])
        pixel_height = int(row["pixel_height"])
        if (
            pixel_width % logical_width != 0
            or pixel_height % logical_height != 0
            or pixel_width // logical_width != pixel_height // logical_height
        ):
            raise InstalledMatrixReceiptError(
                "presentation screenshot dimensions do not match the governed window size at one backing scale"
            )
        backing_scale = pixel_width // logical_width
        if backing_scale not in {1, 2}:
            raise InstalledMatrixReceiptError(
                "presentation screenshot has an unsupported macOS backing scale"
            )
        backing_scales.add(backing_scale)
    if len(backing_scales) != 1:
        raise InstalledMatrixReceiptError(
            "presentation screenshots do not share one backing scale"
        )
    return sorted(
        rows,
        key=lambda row: (
            str(row["presentation_state"]),
            str(row["appearance"]),
            str(row["window_size"]),
        ),
    )


def export_presentation_screenshots(
    xcresult: Path,
    candidate: CandidateIdentity,
    developer_dir: Path,
) -> dict[str, Any]:
    """Export and bind the matrix's 28 governed full-window PNGs.

    ``xcresulttool`` is the only producer of this evidence.  The receipt never
    accepts handwritten screenshot paths or a source-level assertion that the
    XCTest happened to call ``add(attachment)``.
    """
    xcresult = _ordinary(xcresult, directory=True)
    developer_dir = _ordinary(developer_dir, directory=True)
    artifact_root = _presentation_artifact_root(xcresult)
    if artifact_root.exists() or artifact_root.is_symlink():
        raise InstalledMatrixReceiptError("presentation screenshot export root must be absent")
    command = [
        "/usr/bin/xcrun", "xcresulttool", "export", "attachments",
        "--path", str(xcresult), "--output-path", str(artifact_root),
    ]
    environment = {"DEVELOPER_DIR": str(developer_dir), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
    try:
        completed = subprocess.run(
            command, env=environment, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, check=False, timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise InstalledMatrixReceiptError(f"cannot export presentation screenshots: {error}") from error
    if completed.returncode != 0:
        raise InstalledMatrixReceiptError(
            "cannot export presentation screenshots: " + completed.stderr[-2048:]
        )
    artifact_root = _ordinary(artifact_root, directory=True)
    manifest_path = _ordinary(artifact_root / "manifest.json", directory=False)
    rows = _manifest_attachment_rows(
        manifest_path, artifact_root=artifact_root, candidate=candidate
    )
    return {
        "artifact_root_path": str(artifact_root),
        "manifest_path": str(manifest_path),
        "manifest_sha256": file_sha256(manifest_path),
        "attachments": rows,
    }


def _accessibility_observation_artifact_root(xcresult: Path) -> Path:
    xcresult = _ordinary(xcresult, directory=True)
    return xcresult.parent / f"{xcresult.name}.accessibility-observations"


def _manifest_accessibility_observation_rows(
    manifest_path: Path,
    *,
    artifact_root: Path,
    selector_projection: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Parse exactly one physical observation attachment for every selector."""

    normalized_projection = _selector_projection(
        selector_projection, "installed accessibility observation projection"
    )
    expected = {item["test_identifier"]: item for item in normalized_projection}
    try:
        payload, _ = _stable_file_bytes(manifest_path)
        value = json.loads(payload.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError, OSError, InstalledMatrixReceiptError) as error:
        raise InstalledMatrixReceiptError(
            f"cannot decode exported accessibility observation manifest: {error}"
        ) from error
    if not isinstance(value, list):
        raise InstalledMatrixReceiptError(
            "exported accessibility observation manifest must be an array"
        )
    observed_by_selector: dict[str, dict[str, Any]] = {}
    for entry in value:
        if not isinstance(entry, dict) or set(entry) - {
            "testIdentifier", "testIdentifierURL", "attachments"
        }:
            raise InstalledMatrixReceiptError(
                "exported accessibility observation manifest has unknown fields"
            )
        attachments = entry.get("attachments")
        if not isinstance(attachments, list):
            raise InstalledMatrixReceiptError(
                "exported accessibility observation attachment list is invalid"
            )
        parent_identifier = entry.get("testIdentifier")
        for attachment in attachments:
            if not isinstance(attachment, dict):
                raise InstalledMatrixReceiptError(
                    "exported accessibility observation attachment is invalid"
                )
            if attachment.get("suggestedHumanReadableName") != (
                ACCESSIBILITY_OBSERVATION_ATTACHMENT_NAME
            ):
                continue
            if parent_identifier not in expected:
                raise InstalledMatrixReceiptError(
                    "accessibility observation attachment belongs to an unexpected selector"
                )
            if parent_identifier in observed_by_selector:
                raise InstalledMatrixReceiptError(
                    "installed selector has duplicate accessibility observation attachments"
                )
            if attachment.get("isAssociatedWithFailure") is not False:
                raise InstalledMatrixReceiptError(
                    "accessibility observation attachment must not be failure-associated"
                )
            exported_name = attachment.get("exportedFileName")
            if (
                not isinstance(exported_name, str)
                or not exported_name
                or Path(exported_name).name != exported_name
            ):
                raise InstalledMatrixReceiptError(
                    "exported accessibility observation filename is unsafe"
                )
            attachment_path = _ordinary(artifact_root / exported_name, directory=False)
            try:
                attachment_path.relative_to(artifact_root)
            except ValueError as error:
                raise InstalledMatrixReceiptError(
                    "accessibility observation attachment escaped its export root"
                ) from error
            try:
                attachment_payload, _ = _stable_file_bytes(attachment_path)
                document = decode_canonical_bytes(attachment_payload)
            except (UnicodeError, ValueError, OSError, InstalledMatrixReceiptError) as error:
                raise InstalledMatrixReceiptError(
                    f"accessibility observation attachment is not canonical JSON: {error}"
                ) from error
            document = _closed(
                document,
                ACCESSIBILITY_OBSERVATION_PAYLOAD_FIELDS,
                f"accessibility observation {parent_identifier}",
            )
            expected_row = expected[parent_identifier]
            observed_identifiers = document["observedIdentifiers"]
            if (
                not isinstance(observed_identifiers, list)
                or not observed_identifiers
                or any(
                    not isinstance(identifier, str)
                    or ACCESSIBILITY_IDENTIFIER_RE.fullmatch(identifier) is None
                    for identifier in observed_identifiers
                )
                or observed_identifiers != sorted(set(observed_identifiers))
                or observed_identifiers
                != sorted(expected_row["required_identifiers"])
                or document["schemaVersion"] != 1
                or document["vectorID"] != expected_row["vector_id"]
                or document["testIdentifier"] != parent_identifier
            ):
                raise InstalledMatrixReceiptError(
                    "accessibility observation does not equal the frozen selector identifiers"
                )
            observed_by_selector[parent_identifier] = {
                "attachment_path": str(attachment_path),
                "observed_identifiers": observed_identifiers,
                "sha256": hashlib.sha256(attachment_payload).hexdigest(),
                "test_identifier": parent_identifier,
                "vector_id": expected_row["vector_id"],
            }
    if set(observed_by_selector) != set(expected):
        raise InstalledMatrixReceiptError(
            "accessibility observations do not cover the exact installed selector catalog"
        )
    attachments = [
        observed_by_selector[item["test_identifier"]]
        for item in normalized_projection
    ]
    if len({item["attachment_path"] for item in attachments}) != len(attachments):
        raise InstalledMatrixReceiptError(
            "accessibility observations reuse a physical attachment"
        )
    if len({item["sha256"] for item in attachments}) != len(attachments):
        raise InstalledMatrixReceiptError(
            "accessibility observations do not carry distinct structured payloads"
        )
    observed_projection = [
        {
            "observed_identifiers": item["observed_identifiers"],
            "test_identifier": item["test_identifier"],
            "vector_id": item["vector_id"],
        }
        for item in attachments
    ]
    return attachments, observed_projection


def export_accessibility_observations(
    xcresult: Path,
    selector_projection: list[dict[str, Any]],
    developer_dir: Path,
) -> dict[str, Any]:
    """Export and seal the identifier observations emitted by all 22 selectors."""

    xcresult = _ordinary(xcresult, directory=True)
    developer_dir = _ordinary(developer_dir, directory=True)
    artifact_root = _accessibility_observation_artifact_root(xcresult)
    if artifact_root.exists() or artifact_root.is_symlink():
        raise InstalledMatrixReceiptError(
            "accessibility observation export root must be absent"
        )
    command = [
        "/usr/bin/xcrun", "xcresulttool", "export", "attachments",
        "--path", str(xcresult), "--output-path", str(artifact_root),
    ]
    environment = {
        "DEVELOPER_DIR": str(developer_dir),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    }
    try:
        completed = subprocess.run(
            command,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=120,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise InstalledMatrixReceiptError(
            f"cannot export accessibility observations: {error}"
        ) from error
    if completed.returncode != 0:
        raise InstalledMatrixReceiptError(
            "cannot export accessibility observations: " + completed.stderr[-2048:]
        )
    artifact_root = _ordinary(artifact_root, directory=True)
    manifest_path = _ordinary(artifact_root / "manifest.json", directory=False)
    attachments, observed_projection = _manifest_accessibility_observation_rows(
        manifest_path,
        artifact_root=artifact_root,
        selector_projection=selector_projection,
    )
    return {
        "artifact_root_path": str(artifact_root),
        "manifest_path": str(manifest_path),
        "manifest_sha256": file_sha256(manifest_path),
        "attachments": attachments,
        "observed_selector_projection": observed_projection,
        "observed_selector_projection_sha256": canonical_sha256(observed_projection),
    }


def validate_accessibility_observations(
    value: Any,
    *,
    xcresult: Path,
    selector_projection: list[dict[str, Any]],
) -> dict[str, Any]:
    record = _closed(
        value,
        ACCESSIBILITY_OBSERVATION_FIELDS,
        "$.accessibility_observations",
    )
    artifact_root = _ordinary(
        _absolute(
            record["artifact_root_path"],
            "$.accessibility_observations.artifact_root_path",
        ),
        directory=True,
    )
    if artifact_root != _accessibility_observation_artifact_root(xcresult):
        raise InstalledMatrixReceiptError(
            "accessibility observation export root differs from exact xcresult"
        )
    manifest_path = _ordinary(
        _absolute(
            record["manifest_path"],
            "$.accessibility_observations.manifest_path",
        ),
        directory=False,
    )
    if manifest_path != artifact_root / "manifest.json":
        raise InstalledMatrixReceiptError(
            "accessibility observation manifest is not the exact export manifest"
        )
    if record["manifest_sha256"] != file_sha256(manifest_path):
        raise InstalledMatrixReceiptError(
            "accessibility observation manifest physical identity differs from receipt"
        )
    attachments, observed_projection = _manifest_accessibility_observation_rows(
        manifest_path,
        artifact_root=artifact_root,
        selector_projection=selector_projection,
    )
    if (
        record["attachments"] != attachments
        or record["observed_selector_projection"] != observed_projection
        or record["observed_selector_projection_sha256"]
        != canonical_sha256(observed_projection)
    ):
        raise InstalledMatrixReceiptError(
            "accessibility observation physical identity differs from receipt"
        )
    return record


def validate_presentation_screenshots(
    value: Any,
    *,
    xcresult: Path,
    candidate: CandidateIdentity,
) -> dict[str, Any]:
    record = _closed(value, PRESENTATION_SCREENSHOT_FIELDS, "$.presentation_screenshots")
    artifact_root = _ordinary(_absolute(record["artifact_root_path"], "$.presentation_screenshots.artifact_root_path"), directory=True)
    expected_root = _presentation_artifact_root(xcresult)
    if artifact_root != expected_root:
        raise InstalledMatrixReceiptError("presentation screenshot export root differs from exact xcresult")
    manifest_path = _ordinary(_absolute(record["manifest_path"], "$.presentation_screenshots.manifest_path"), directory=False)
    if manifest_path != artifact_root / "manifest.json":
        raise InstalledMatrixReceiptError("presentation screenshot manifest is not the exact export manifest")
    if record["manifest_sha256"] != file_sha256(manifest_path):
        raise InstalledMatrixReceiptError("presentation screenshot manifest physical identity differs from receipt")
    observed = _manifest_attachment_rows(manifest_path, artifact_root=artifact_root, candidate=candidate)
    if record["attachments"] != observed:
        raise InstalledMatrixReceiptError("presentation screenshot physical identity differs from receipt")
    return record


def _file_descriptor_identity(path: Path) -> dict[str, Any]:
    """Hash one input through an O_NOFOLLOW descriptor and retain its inode."""
    path = _ordinary(path, directory=False)
    payload, metadata = _stable_file_bytes(path)
    return {
            "path": str(path),
            "sha256": hashlib.sha256(payload).hexdigest(),
            "device": metadata[0],
            "inode": metadata[1],
            "mode": metadata[2],
            "size": metadata[3],
            "mtime_ns": metadata[4],
            "ctime_ns": metadata[5],
        }


def _bundle_identifier(bundle: Path) -> str:
    plist = _ordinary(bundle / "Contents/Info.plist", directory=False)
    try:
        payload, _ = _stable_file_bytes(plist)
        document = plistlib.loads(payload)
    except (OSError, plistlib.InvalidFileException, ValueError, InstalledMatrixReceiptError) as error:
        raise InstalledMatrixReceiptError(
            f"cannot decode bundle physical identity: {plist}: {error}"
        ) from error
    identifier = document.get("CFBundleIdentifier") if isinstance(document, dict) else None
    if not isinstance(identifier, str) or not identifier:
        raise InstalledMatrixReceiptError(
            f"bundle physical identity has no CFBundleIdentifier: {bundle}"
        )
    return identifier


def _directory_descriptor_identity(path: Path) -> tuple[int, int, int, int]:
    """Return a no-follow directory descriptor fence for a tree hash pass."""
    path = _ordinary(path, directory=True)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISDIR(metadata.st_mode):
            raise InstalledMatrixReceiptError(f"physical identity path is not a directory: {path}")
        return (metadata.st_dev, metadata.st_ino, metadata.st_mtime_ns, metadata.st_ctime_ns)
    finally:
        os.close(descriptor)


def _fenced_tree_digests(path: Path, *, app_root: bool = False):
    """Use descriptor fences and identical double reads; fail rather than claim a stable tree."""
    if app_root:
        return capture_bundle_snapshot(path, app_root=True).digests
    before = _directory_descriptor_identity(path)
    try:
        first = bundle_tree_digests(path)
        second = bundle_tree_digests(path)
    except CandidateMaterializationError as error:
        raise InstalledMatrixReceiptError(
            f"bundle physical identity is not a closed contained tree: {path}: {error}"
        ) from error
    after = _directory_descriptor_identity(path)
    if before != after or first != second:
        raise InstalledMatrixReceiptError(
            f"bundle physical identity tree changed during descriptor-fenced snapshot: {path}"
        )
    return first


def _bundle_identity(bundle: Path, executable: Path) -> dict[str, str]:
    bundle = _ordinary(bundle, directory=True)
    executable = _ordinary(executable, directory=False)
    try:
        executable.relative_to(bundle)
        digests = _fenced_tree_digests(bundle, app_root=bundle.suffix == ".app")
    except (ValueError, CandidateMaterializationError, InstalledMatrixReceiptError) as error:
        raise InstalledMatrixReceiptError(
            f"bundle physical identity is not a closed contained tree: {bundle}: {error}"
        ) from error
    return {
        "path": str(bundle),
        "bundle_identifier": _bundle_identifier(bundle),
        "content_sha256": digests.content_sha256,
        "closed_tree_sha256": digests.closed_tree_sha256,
        "executable_path": str(executable),
        "executable_sha256": file_sha256(executable),
    }


def _assert_installed_application_identity(
    candidate: CandidateIdentity,
    observed: dict[str, str],
) -> None:
    """Bind installed bytes to the exact signed Release application identity.

    Candidate qualification executable ``app`` is a separately materialized
    Debug product.  The Release application record is the shipping authority:
    its full content and closed-tree digests retain the code-signature bytes,
    while its executable digest and bundle identifier bind the launch product.
    """
    expected = {
        "bundle_identifier": candidate.application.bundle_identifier,
        "content_sha256": candidate.application.bundle_sha256,
        "closed_tree_sha256": candidate.application.closed_tree_sha256,
        "executable_sha256": candidate.application.executable_sha256,
    }
    if {key: observed.get(key) for key in expected} != expected:
        raise InstalledMatrixReceiptError(
            "installed app physical identity does not match the exact candidate"
        )


def _tree_identity(path: Path) -> dict[str, str]:
    path = _ordinary(path, directory=True)
    try:
        digest = _fenced_tree_digests(path).closed_tree_sha256
    except CandidateMaterializationError as error:
        raise InstalledMatrixReceiptError(
            f"tree physical identity is not closed: {path}: {error}"
        ) from error
    return {"path": str(path), "closed_tree_sha256": digest}


def _candidate(path: Path) -> tuple[CandidateIdentity, str]:
    path = _ordinary(path, directory=False)
    try:
        payload, _ = _stable_file_bytes(path)
        value = decode_canonical_bytes(payload)
    except (OSError, UnicodeError, ValueError, InstalledMatrixReceiptError) as error:
        raise InstalledMatrixReceiptError(
            f"candidate identity physical identity is invalid: {error}"
        ) from error
    candidate, issues = parse_candidate_identity(value)
    if candidate is None or issues:
        detail = "; ".join(
            f"{issue.code} at {issue.path}: {issue.message}" for issue in issues
        )
        raise InstalledMatrixReceiptError(
            "candidate identity physical identity is invalid"
            + (f": {detail}" if detail else "")
        )
    return candidate, candidate_identity_sha256(candidate)


def _preparation(
    path: Path,
    candidate_identity_path: Path,
    *,
    test_bundle: Path | None = None,
    ui_runner: Path | None = None,
) -> tuple[dict[str, Any], str]:
    from Scripts.reconstruction import native_live_preparation_receipt as preparation

    path = _ordinary(path, directory=False)
    before = _file_descriptor_identity(path)
    try:
        receipt = preparation.load_receipt(path)
        artifacts = receipt["artifacts"]
        digest = preparation.validate_prepared(
            receipt,
            Path(artifacts["xctestrun"]["path"]),
            Path(artifacts["app"]["path"]),
            candidate_identity_path,
            test_bundle=test_bundle,
            ui_runner=ui_runner,
        )
    except (OSError, UnicodeError, ValueError, preparation.PreparationReceiptError) as error:
        raise InstalledMatrixReceiptError(
            f"preparation receipt physical identity is invalid: {error}"
        ) from error
    if before != _file_descriptor_identity(path):
        raise InstalledMatrixReceiptError(
            "preparation receipt physical identity changed while semantic validation read it"
        )
    return receipt, digest


def _resolve_xctestrun_path(value: Any, *, test_root: Path, test_host: Path, field: str) -> Path:
    """Resolve only the two Xcode macros the sealed test contract permits."""
    if not isinstance(value, str) or not value or "\x00" in value:
        raise InstalledMatrixReceiptError(f"xctestrun {field} must be nonempty text")
    macro, separator, remainder = value.partition("/")
    roots = {"__TESTROOT__": test_root, "__TESTHOST__": test_host}
    if not separator or macro not in roots:
        raise InstalledMatrixReceiptError(
            f"xctestrun {field} must start with exactly __TESTROOT__/ or __TESTHOST__/: {value!r}"
        )
    relative = Path(remainder)
    if relative.is_absolute() or any(component in {"", ".", ".."} for component in relative.parts):
        raise InstalledMatrixReceiptError(f"xctestrun {field} has traversal or an invalid relative path")
    resolved = roots[macro] / relative
    # Product inputs are deliberately not resolved through a symlink; expected
    # paths are compared lexically before the no-follow identity check.
    return resolved


def _xctestrun_contract(
    path: Path,
    *,
    test_bundle: Path | None = None,
    ui_runner: Path | None = None,
    installed_app: Path | None = None,
    prepared_app: Path | None = None,
) -> None:
    path = _ordinary(path, directory=False)
    try:
        payload, _ = _stable_file_bytes(path)
        document = plistlib.loads(payload)
    except (OSError, plistlib.InvalidFileException, ValueError, InstalledMatrixReceiptError) as error:
        raise InstalledMatrixReceiptError(
            f"xctestrun physical identity cannot be decoded: {error}"
        ) from error
    if not isinstance(document, dict):
        raise InstalledMatrixReceiptError("xctestrun physical identity is not an object")
    metadata = document.get("__xctestrun_metadata__")
    if not isinstance(metadata, dict) or metadata.get("ContainerInfo", {}).get("SchemeName") != SCHEME:
        raise InstalledMatrixReceiptError(
            "xctestrun physical identity is not the MacScopeInstalledAppUITests scheme"
        )
    suites = [
        value
        for key, value in document.items()
        if key != "__xctestrun_metadata__"
        and isinstance(value, dict)
        and value.get("BlueprintName") == TEST_TARGET
    ]
    if len(suites) != 1:
        raise InstalledMatrixReceiptError(
            "xctestrun physical identity must contain exactly one installed UI test target"
        )
    suite = suites[0]
    if test_bundle is None or ui_runner is None or installed_app is None or prepared_app is None:
        # A schema parser may only establish that this is the right scheme. The
        # receipt creator and validator always take the strict binding branch.
        return
    from Scripts.reconstruction import native_live_preparation_receipt as preparation

    test_root = path.parent
    test_host = _resolve_xctestrun_path(
        suite.get("TestHostPath"),
        test_root=test_root,
        test_host=ui_runner,
        field="TestHostPath",
    )
    if test_host != ui_runner:
        raise InstalledMatrixReceiptError(
            "xctestrun TestHostPath does not bind the sealed UI runner"
        )
    test_bundle_path = _resolve_xctestrun_path(
        suite.get("TestBundlePath"), test_root=test_root, test_host=test_host, field="TestBundlePath"
    )
    target_app_path = _resolve_xctestrun_path(
        suite.get("UITargetAppPath"), test_root=test_root, test_host=test_host, field="UITargetAppPath"
    )
    if test_bundle_path != test_bundle:
        raise InstalledMatrixReceiptError(
            "xctestrun TestBundlePath does not bind the sealed UI test bundle"
        )
    # The UI suite is built in Debug, while the preparation receipt may bind
    # the Release candidate app used for installation. XCTest therefore names
    # the exact Debug test host placeholder; the execution overlay independently
    # retargets launches to the installed candidate.
    prepared_debug_app = test_root / "Debug/MacScope.app"
    if prepared_app.parent.name != "Release":
        prepared_debug_app = prepared_app
    if target_app_path not in {ui_runner, prepared_debug_app}:
        raise InstalledMatrixReceiptError(
            "xctestrun UITargetAppPath does not bind a sealed prepared product"
        )
    dependencies = suite.get("DependentProductPaths", [])
    if not isinstance(dependencies, list) or not all(isinstance(item, str) for item in dependencies):
        raise InstalledMatrixReceiptError("xctestrun DependentProductPaths must be a text array")
    resolved_dependencies = {
        _resolve_xctestrun_path(item, test_root=test_root, test_host=test_host, field="DependentProductPaths")
        for item in dependencies
    }
    allowed = {test_bundle, ui_runner, prepared_debug_app}
    for dependency in resolved_dependencies - allowed:
        try:
            relative = dependency.relative_to(test_root)
        except ValueError as error:
            raise InstalledMatrixReceiptError(
                "xctestrun dependent product path does not bind a sealed product"
            ) from error
        duplicate_contract = preparation.INSTALLED_UI_DUPLICATE_PRODUCTS.get(relative)
        if duplicate_contract is None:
            raise InstalledMatrixReceiptError(
                "xctestrun dependent product path does not bind a sealed product"
            )
        kind, embedded_relative = duplicate_contract
        try:
            preparation._require_duplicate_product_identity(
                dependency,
                prepared_debug_app / embedded_relative,
                kind=kind,
            )
        except preparation.PreparationReceiptError as error:
            raise InstalledMatrixReceiptError(
                f"xctestrun duplicate product does not match its sealed prepared product: {error}"
            ) from error


def _xctestrun_document(path: Path) -> dict[str, Any]:
    path = _ordinary(path, directory=False)
    try:
        payload, _ = _stable_file_bytes(path)
        document = plistlib.loads(payload)
    except (OSError, plistlib.InvalidFileException, ValueError, InstalledMatrixReceiptError) as error:
        raise InstalledMatrixReceiptError(
            f"xctestrun physical identity cannot be decoded: {error}"
        ) from error
    if not isinstance(document, dict):
        raise InstalledMatrixReceiptError("xctestrun physical identity is not an object")
    return document


def _installed_ui_suite(document: dict[str, Any]) -> dict[str, Any]:
    suites = [
        value
        for key, value in document.items()
        if key != "__xctestrun_metadata__"
        and isinstance(value, dict)
        and value.get("BlueprintName") == TEST_TARGET
    ]
    if len(suites) != 1:
        raise InstalledMatrixReceiptError(
            "xctestrun physical identity must contain exactly one installed UI test target"
        )
    return suites[0]


def _expected_execution_xctestrun_document(
    prepared_xctestrun: Path,
    installed_app: Path,
) -> dict[str, Any]:
    document = _xctestrun_document(prepared_xctestrun)
    suite = _installed_ui_suite(document)
    for field in ("EnvironmentVariables", "TestingEnvironmentVariables"):
        environment = suite.get(field)
        if not isinstance(environment, dict) or not all(
            isinstance(key, str) and isinstance(value, str)
            for key, value in environment.items()
        ):
            raise InstalledMatrixReceiptError(
                f"prepared xctestrun {field} must be a string dictionary"
            )
        if OPT_IN_KEY in environment or INSTALLED_APP_KEY in environment:
            raise InstalledMatrixReceiptError(
                f"prepared xctestrun {field} already carries installed-matrix opt-in state"
            )
        environment[OPT_IN_KEY] = "1"
        environment[INSTALLED_APP_KEY] = str(installed_app)
    return document


def validate_execution_xctestrun_overlay(
    prepared_xctestrun: Path,
    execution_xctestrun: Path,
    installed_app: Path,
) -> None:
    prepared_xctestrun = _ordinary(prepared_xctestrun, directory=False)
    execution_xctestrun = _ordinary(execution_xctestrun, directory=False)
    installed_app = _ordinary(installed_app, directory=True)
    if execution_xctestrun == prepared_xctestrun:
        raise InstalledMatrixReceiptError(
            "execution xctestrun must be distinct from the immutable prepared xctestrun"
        )
    if execution_xctestrun.parent != prepared_xctestrun.parent:
        raise InstalledMatrixReceiptError(
            "execution xctestrun must share the prepared xctestrun product root"
        )
    expected = _expected_execution_xctestrun_document(prepared_xctestrun, installed_app)
    observed = _xctestrun_document(execution_xctestrun)
    if observed != expected:
        raise InstalledMatrixReceiptError(
            "execution xctestrun differs from the exact installed opt-in overlay"
        )


def write_execution_xctestrun_create_only(
    prepared_xctestrun: Path,
    execution_xctestrun: Path,
    installed_app: Path,
) -> str:
    prepared_xctestrun = _ordinary(prepared_xctestrun, directory=False)
    installed_app = _ordinary(installed_app, directory=True)
    if not execution_xctestrun.is_absolute() or execution_xctestrun.exists() or execution_xctestrun.is_symlink():
        raise InstalledMatrixReceiptError(
            "execution xctestrun output must be an absent absolute path"
        )
    parent = _ordinary(execution_xctestrun.parent, directory=True)
    if parent != prepared_xctestrun.parent:
        raise InstalledMatrixReceiptError(
            "execution xctestrun output must share the prepared product root"
        )
    document = _expected_execution_xctestrun_document(prepared_xctestrun, installed_app)
    payload = plistlib.dumps(document, fmt=plistlib.FMT_XML, sort_keys=True)
    descriptor = os.open(
        parent / execution_xctestrun.name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o644,
    )
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
    finally:
        os.close(descriptor)
    validate_execution_xctestrun_overlay(
        prepared_xctestrun,
        parent / execution_xctestrun.name,
        installed_app,
    )
    return hashlib.sha256(payload).hexdigest()


def expected_argv(
    xcodebuild: Path,
    xctestrun: Path,
    xcresult: Path,
    selectors: list[str],
) -> list[str]:
    argv = [
        str(xcodebuild),
        "test-without-building",
        "-xctestrun",
        str(xctestrun),
        "-destination",
        DESTINATION,
        "-resultBundlePath",
        str(xcresult),
    ]
    argv.extend(
        f"-only-testing:{TEST_TARGET}/{identifier.removesuffix('()')}"
        for identifier in selectors
    )
    return argv


def expected_environment(
    developer_dir: Path,
    installed_app: Path,
    inherited: dict[str, str] | None = None,
) -> dict[str, str]:
    source = os.environ if inherited is None else inherited
    return {
        "DEVELOPER_DIR": str(developer_dir),
        "HOME": source.get("HOME", "/var/empty"),
        INSTALLED_APP_KEY: str(installed_app),
        OPT_IN_KEY: "1",
        "LOGNAME": source.get("LOGNAME", "nobody"),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": source.get("TMPDIR", "/private/tmp"),
        "USER": source.get("USER", "nobody"),
    }


def _product_paths(test_bundle: Path, ui_runner: Path) -> tuple[Path, Path]:
    test_executable = test_bundle / "Contents/MacOS/MacScopeInstalledAppUITests"
    runner_executable = ui_runner / "Contents/MacOS/MacScopeInstalledAppUITests-Runner"
    return test_executable, runner_executable


def capture_input_snapshot(
    *,
    candidate_identity_path: Path,
    preparation_receipt_path: Path,
    installed_app: Path,
    prepared_xctestrun: Path,
    execution_xctestrun: Path,
    test_bundle: Path,
    ui_runner: Path,
    xcodebuild: Path,
) -> dict[str, Any]:
    """Capture every pre/post execution input through closed, no-link identities."""
    test_executable, runner_executable = _product_paths(test_bundle, ui_runner)
    return {
        "candidate_identity": _file_descriptor_identity(candidate_identity_path),
        "preparation_receipt": _file_descriptor_identity(preparation_receipt_path),
        "installed_app": _bundle_identity(installed_app, installed_app / "Contents/MacOS/MacScope"),
        "prepared_xctestrun": _file_descriptor_identity(prepared_xctestrun),
        "execution_xctestrun": _file_descriptor_identity(execution_xctestrun),
        "test_bundle": _bundle_identity(test_bundle, test_executable),
        "ui_runner": _bundle_identity(ui_runner, runner_executable),
        "xcodebuild": _file_descriptor_identity(xcodebuild),
    }


def assert_input_snapshot_equal(before: dict[str, Any], after: dict[str, Any]) -> None:
    if before != after:
        changed = sorted(
            key for key in set(before) | set(after) if before.get(key) != after.get(key)
        )
        raise InstalledMatrixReceiptError(
            "installed matrix input physical identity changed during execution: "
            + ", ".join(changed)
        )


def preflight_execution(
    *,
    candidate_identity_path: Path,
    preparation_receipt_path: Path,
    installed_app: Path,
    prepared_xctestrun: Path,
    execution_xctestrun: Path,
    test_bundle: Path,
    ui_runner: Path,
    xcodebuild: Path,
    expected_xcresult: Path,
    argv: list[str],
    selectors: list[str],
    selector_projection: list[dict[str, Any]],
    environment: dict[str, str],
) -> dict[str, Any]:
    """Validate the complete semantic contract before a subprocess may spawn."""
    candidate_identity_path = _ordinary(candidate_identity_path, directory=False)
    preparation_receipt_path = _ordinary(preparation_receipt_path, directory=False)
    installed_app = _ordinary(installed_app, directory=True)
    prepared_xctestrun = _ordinary(prepared_xctestrun, directory=False)
    execution_xctestrun = _ordinary(execution_xctestrun, directory=False)
    test_bundle = _ordinary(test_bundle, directory=True)
    ui_runner = _ordinary(ui_runner, directory=True)
    xcodebuild = _ordinary(xcodebuild, directory=False)
    candidate, _ = _candidate(candidate_identity_path)
    prepared, _ = _preparation(
        preparation_receipt_path,
        candidate_identity_path,
        test_bundle=test_bundle,
        ui_runner=ui_runner,
    )
    if prepared["source"]["commit"] != candidate.source.commit:
        raise InstalledMatrixReceiptError("preparation receipt source commit differs from candidate physical identity")
    artifacts = prepared.get("artifacts")
    if not isinstance(artifacts, dict) or not isinstance(artifacts.get("app"), dict):
        raise InstalledMatrixReceiptError("preparation receipt lacks the sealed prepared app")
    prepared_app = _ordinary(Path(artifacts["app"].get("path", "")), directory=True)
    if Path(artifacts.get("xctestrun", {}).get("path", "")) != prepared_xctestrun:
        raise InstalledMatrixReceiptError("preparation receipt xctestrun does not match matrix xctestrun")
    _validate_product_layout(prepared_xctestrun, test_bundle, ui_runner)
    _xctestrun_contract(
        prepared_xctestrun, test_bundle=test_bundle, ui_runner=ui_runner,
        installed_app=installed_app, prepared_app=prepared_app,
    )
    validate_execution_xctestrun_overlay(
        prepared_xctestrun, execution_xctestrun, installed_app
    )
    _xctestrun_contract(
        execution_xctestrun, test_bundle=test_bundle, ui_runner=ui_runner,
        installed_app=installed_app, prepared_app=prepared_app,
    )
    _validate_execution_contract(
        prepared, installed_app, execution_xctestrun, expected_xcresult, argv,
        selectors, selector_projection, environment
    )
    observed = _bundle_identity(installed_app, installed_app / "Contents/MacOS/MacScope")
    _assert_installed_application_identity(candidate, observed)
    return capture_input_snapshot(
        candidate_identity_path=candidate_identity_path,
        preparation_receipt_path=preparation_receipt_path,
        installed_app=installed_app,
        prepared_xctestrun=prepared_xctestrun,
        execution_xctestrun=execution_xctestrun,
        test_bundle=test_bundle,
        ui_runner=ui_runner,
        xcodebuild=xcodebuild,
    )
def create_document(
    *,
    candidate_identity_path: Path,
    preparation_receipt_path: Path,
    installed_app: Path,
    prepared_xctestrun: Path,
    execution_xctestrun: Path,
    test_bundle: Path,
    ui_runner: Path,
    xcresult: Path | None,
    argv: list[str],
    selectors: list[str],
    selector_projection: list[dict[str, Any]],
    environment: dict[str, str],
    started_at_unix_ms: int,
    ended_at_unix_ms: int,
    exit_code: int,
    failure: str | None = None,
    input_snapshot_before: dict[str, Any] | None = None,
    input_snapshot_after: dict[str, Any] | None = None,
) -> dict[str, Any]:
    candidate_identity_path = _ordinary(candidate_identity_path, directory=False)
    preparation_receipt_path = _ordinary(preparation_receipt_path, directory=False)
    installed_app = _ordinary(installed_app, directory=True)
    prepared_xctestrun = _ordinary(prepared_xctestrun, directory=False)
    execution_xctestrun = _ordinary(execution_xctestrun, directory=False)
    test_bundle = _ordinary(test_bundle, directory=True)
    ui_runner = _ordinary(ui_runner, directory=True)
    if xcresult is not None:
        xcresult = _ordinary(xcresult, directory=True)
    candidate, candidate_digest = _candidate(candidate_identity_path)
    preparation_receipt, preparation_digest = _preparation(
        preparation_receipt_path,
        candidate_identity_path,
        test_bundle=test_bundle,
        ui_runner=ui_runner,
    )
    if preparation_receipt["source"]["commit"] != candidate.source.commit:
        raise InstalledMatrixReceiptError(
            "preparation receipt source commit differs from candidate physical identity"
        )
    artifacts = preparation_receipt.get("artifacts")
    if not isinstance(artifacts, dict) or not isinstance(artifacts.get("app"), dict):
        raise InstalledMatrixReceiptError("preparation receipt lacks the sealed prepared app")
    prepared_app = _ordinary(Path(artifacts["app"].get("path", "")), directory=True)
    if Path(artifacts.get("xctestrun", {}).get("path", "")) != prepared_xctestrun:
        raise InstalledMatrixReceiptError("preparation receipt xctestrun does not match matrix xctestrun")
    _xctestrun_contract(
        prepared_xctestrun,
        test_bundle=test_bundle,
        ui_runner=ui_runner,
        installed_app=installed_app,
        prepared_app=prepared_app,
    )
    _validate_product_layout(prepared_xctestrun, test_bundle, ui_runner)
    validate_execution_xctestrun_overlay(
        prepared_xctestrun, execution_xctestrun, installed_app
    )
    _xctestrun_contract(
        execution_xctestrun,
        test_bundle=test_bundle,
        ui_runner=ui_runner,
        installed_app=installed_app,
        prepared_app=prepared_app,
    )
    _validate_execution_contract(
        preparation_receipt,
        installed_app,
        execution_xctestrun,
        xcresult,
        argv,
        selectors,
        selector_projection,
        environment,
    )
    installed = _bundle_identity(
        installed_app, installed_app / "Contents/MacOS/MacScope"
    )
    _assert_installed_application_identity(candidate, installed)
    test_executable, runner_executable = _product_paths(test_bundle, ui_runner)
    result = "passed" if exit_code == 0 and xcresult is not None else ("failed" if xcresult is not None else "infrastructure")
    if result == "infrastructure" and (not isinstance(failure, str) or not failure):
        raise InstalledMatrixReceiptError("infrastructure receipt requires a bounded failure explanation")
    if input_snapshot_before is None or input_snapshot_after is None:
        input_snapshot_before = capture_input_snapshot(
            candidate_identity_path=candidate_identity_path, preparation_receipt_path=preparation_receipt_path,
            installed_app=installed_app,
            prepared_xctestrun=prepared_xctestrun,
            execution_xctestrun=execution_xctestrun,
            test_bundle=test_bundle, ui_runner=ui_runner,
            xcodebuild=Path(argv[0]),
        )
        input_snapshot_after = input_snapshot_before
    assert_input_snapshot_equal(input_snapshot_before, input_snapshot_after)
    presentation_screenshots: dict[str, Any] = {"state": "absent"}
    accessibility_observations: dict[str, Any] = {"state": "absent"}
    if result == "passed" and xcresult is not None:
        accessibility_observations = export_accessibility_observations(
            xcresult, selector_projection, Path(environment["DEVELOPER_DIR"])
        )
        presentation_screenshots = export_presentation_screenshots(
            xcresult, candidate, Path(environment["DEVELOPER_DIR"])
        )
    document = {
        "schema_version": SCHEMA_VERSION,
        "receipt_kind": RECEIPT_KIND,
        "accessibility_observations": accessibility_observations,
        "candidate": {
            "identity_path": str(candidate_identity_path),
            "identity_sha256": candidate_digest,
            "source_commit": candidate.source.commit,
            "source_tree": candidate.source.tree,
            "preparation_receipt_path": str(preparation_receipt_path),
            "preparation_receipt_sha256": preparation_digest,
        },
        "products": {
            "installed_app": installed,
            "prepared_xctestrun": {
                "path": str(prepared_xctestrun),
                "sha256": file_sha256(prepared_xctestrun),
            },
            "execution_xctestrun": {
                "path": str(execution_xctestrun),
                "sha256": file_sha256(execution_xctestrun),
            },
            "test_bundle": _bundle_identity(test_bundle, test_executable),
            "ui_runner": _bundle_identity(ui_runner, runner_executable),
            "xcresult": _tree_identity(xcresult) if xcresult is not None else {"state": "absent"},
        },
        "execution": {
            "argv": argv,
            "selectors": selectors,
            "selector_projection": selector_projection,
            "selector_projection_sha256": canonical_sha256(selector_projection),
            "environment": environment,
            "started_at_unix_ms": started_at_unix_ms,
            "ended_at_unix_ms": ended_at_unix_ms,
            "duration_ms": ended_at_unix_ms - started_at_unix_ms,
            "exit_code": exit_code,
            "result": result,
            "failure": failure,
            "input_snapshot_before": input_snapshot_before,
            "input_snapshot_after": input_snapshot_after,
        },
    }
    document["presentation_screenshots"] = presentation_screenshots
    return parse_document(document)


def _closed(value: Any, fields: set[str], path: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != fields:
        raise InstalledMatrixReceiptError(f"{path} does not satisfy its closed field set")
    return value


def _text(value: Any, path: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value or len(value.encode()) > 8192:
        raise InstalledMatrixReceiptError(f"{path} must be nonempty bounded text")
    return value


def _selector_projection(value: Any, path: str) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not value:
        raise InstalledMatrixReceiptError(f"{path} must be a nonempty array")
    projection: list[dict[str, Any]] = []
    for index, raw_item in enumerate(value):
        item = _closed(raw_item, SELECTOR_PROJECTION_FIELDS, f"{path}[{index}]")
        vector_id = _text(item["vector_id"], f"{path}[{index}].vector_id")
        test_identifier = _text(
            item["test_identifier"], f"{path}[{index}].test_identifier"
        )
        required = item["required_identifiers"]
        if not isinstance(required, list) or not required:
            raise InstalledMatrixReceiptError(
                f"{path}[{index}].required_identifiers must be a nonempty array"
            )
        identifiers: list[str] = []
        for identifier_index, raw_identifier in enumerate(required):
            identifier = _text(
                raw_identifier,
                f"{path}[{index}].required_identifiers[{identifier_index}]",
            )
            if (
                identifier != identifier.strip()
                or ACCESSIBILITY_IDENTIFIER_RE.fullmatch(identifier) is None
            ):
                raise InstalledMatrixReceiptError(
                    f"{path}[{index}].required_identifiers[{identifier_index}] "
                    "must use the stable accessibility identifier grammar"
                )
            identifiers.append(identifier)
        if len(identifiers) != len(set(identifiers)):
            raise InstalledMatrixReceiptError(
                f"{path}[{index}].required_identifiers contains duplicates"
            )
        projection.append(
            {
                "required_identifiers": identifiers,
                "test_identifier": test_identifier,
                "vector_id": vector_id,
            }
        )
    for field in ("test_identifier", "vector_id"):
        values = [item[field] for item in projection]
        if len(values) != len(set(values)):
            raise InstalledMatrixReceiptError(f"{path} contains duplicate {field} values")
    return projection


def _observed_identifier_list(value: Any, path: str) -> list[str]:
    if not isinstance(value, list) or not value:
        raise InstalledMatrixReceiptError(f"{path} must be a nonempty array")
    identifiers: list[str] = []
    for index, raw_identifier in enumerate(value):
        identifier = _text(raw_identifier, f"{path}[{index}]")
        if (
            identifier != identifier.strip()
            or ACCESSIBILITY_IDENTIFIER_RE.fullmatch(identifier) is None
        ):
            raise InstalledMatrixReceiptError(
                f"{path}[{index}] must use the stable accessibility identifier grammar"
            )
        identifiers.append(identifier)
    if identifiers != sorted(set(identifiers)):
        raise InstalledMatrixReceiptError(f"{path} must be sorted and unique")
    return identifiers


def _observed_selector_projection(value: Any, path: str) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not value:
        raise InstalledMatrixReceiptError(f"{path} must be a nonempty array")
    projection: list[dict[str, Any]] = []
    for index, raw_item in enumerate(value):
        item = _closed(
            raw_item, OBSERVED_SELECTOR_PROJECTION_FIELDS, f"{path}[{index}]"
        )
        projection.append(
            {
                "observed_identifiers": _observed_identifier_list(
                    item["observed_identifiers"],
                    f"{path}[{index}].observed_identifiers",
                ),
                "test_identifier": _text(
                    item["test_identifier"], f"{path}[{index}].test_identifier"
                ),
                "vector_id": _text(item["vector_id"], f"{path}[{index}].vector_id"),
            }
        )
    for field in ("test_identifier", "vector_id"):
        values = [item[field] for item in projection]
        if len(values) != len(set(values)):
            raise InstalledMatrixReceiptError(f"{path} contains duplicate {field} values")
    return projection


def _digest(value: Any, path: str) -> str:
    value = _text(value, path)
    if SHA256_RE.fullmatch(value) is None:
        raise InstalledMatrixReceiptError(f"{path} must be lowercase SHA-256")
    return value


def _absolute(value: Any, path: str) -> Path:
    result = Path(_text(value, path))
    if not result.is_absolute():
        raise InstalledMatrixReceiptError(f"{path} must be absolute")
    return result


def _validate_product_layout(
    xctestrun: Path,
    test_bundle: Path,
    ui_runner: Path,
) -> None:
    expected_runner = xctestrun.parent / "Debug" / RUNNER_NAME
    expected_test_bundle = expected_runner / "Contents/PlugIns" / TEST_BUNDLE_NAME
    if ui_runner != expected_runner:
        raise InstalledMatrixReceiptError(
            "UI runner physical path is not the xctestrun's exact Debug product"
        )
    if test_bundle != expected_test_bundle:
        raise InstalledMatrixReceiptError(
            "UI test bundle physical path is not the xctestrun runner's embedded test bundle"
        )


def _validate_execution_contract(
    preparation_receipt: dict[str, Any],
    installed_app: Path,
    xctestrun: Path,
    xcresult: Path | None,
    argv: list[str],
    selectors: list[str],
    selector_projection: list[dict[str, Any]],
    environment: dict[str, str],
) -> None:
    if not selectors or len(selectors) != len(set(selectors)):
        raise InstalledMatrixReceiptError(
            "installed matrix selectors must be a nonempty unique catalog sequence"
        )
    normalized_projection = _selector_projection(
        selector_projection, "installed matrix selector projection"
    )
    if [item["test_identifier"] for item in normalized_projection] != selectors:
        raise InstalledMatrixReceiptError(
            "installed matrix selector projection differs from the selector invocation"
        )
    if set(environment) != ENVIRONMENT_FIELDS:
        raise InstalledMatrixReceiptError(
            "installed matrix environment is not the exact closed environment"
        )
    developer_dir = Path(environment["DEVELOPER_DIR"])
    if environment[OPT_IN_KEY] != "1" or environment[INSTALLED_APP_KEY] != str(installed_app):
        raise InstalledMatrixReceiptError(
            "installed matrix environment does not bind the opt-in installed candidate"
        )
    if environment["PATH"] != "/usr/bin:/bin:/usr/sbin:/sbin":
        raise InstalledMatrixReceiptError("installed matrix environment PATH is not closed")
    for field in ("HOME", "TMPDIR"):
        if not Path(environment[field]).is_absolute():
            raise InstalledMatrixReceiptError(
                f"installed matrix environment {field} must be absolute"
            )
    toolchain = preparation_receipt.get("toolchain")
    if not isinstance(toolchain, dict):
        raise InstalledMatrixReceiptError(
            "preparation receipt has no exact toolchain physical identity"
        )
    if toolchain.get("developer_dir") != str(developer_dir):
        raise InstalledMatrixReceiptError(
            "installed matrix developer directory differs from preparation receipt"
        )
    xcodebuild = _ordinary(developer_dir / "usr/bin/xcodebuild", directory=False)
    if file_sha256(xcodebuild) != toolchain.get("xcodebuild_sha256"):
        raise InstalledMatrixReceiptError(
            "installed matrix xcodebuild physical identity differs from preparation receipt"
        )
    if xcresult is None:
        # The runner records a closed infrastructure receipt when xcodebuild
        # fails before it can create a result bundle. Its argv remains the
        # requested invocation, but it cannot be used as passing UI evidence.
        return
    if argv != expected_argv(xcodebuild, xctestrun, xcresult, selectors):
        raise InstalledMatrixReceiptError(
            "installed matrix command differs from the exact selector invocation"
        )


def parse_document(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise InstalledMatrixReceiptError("$ does not satisfy its closed field set")
    schema_version = value.get("schema_version")
    expected_top_fields = (
        TOP_FIELDS_V6_V7
        if schema_version in {6, SCHEMA_VERSION}
        else TOP_FIELDS_V4_V5
        if schema_version in {4, 5}
        else TOP_FIELDS_V2_V3
    )
    record = _closed(value, expected_top_fields, "$")
    if schema_version not in SUPPORTED_SCHEMA_VERSIONS or record["receipt_kind"] != RECEIPT_KIND:
        raise InstalledMatrixReceiptError("installed matrix receipt schema is unsupported")
    candidate = _closed(record["candidate"], CANDIDATE_FIELDS, "$.candidate")
    for field in ("identity_path", "preparation_receipt_path"):
        _absolute(candidate[field], f"$.candidate.{field}")
    for field in ("identity_sha256", "preparation_receipt_sha256"):
        _digest(candidate[field], f"$.candidate.{field}")
    for field in ("source_commit", "source_tree"):
        if GIT_OBJECT_RE.fullmatch(_text(candidate[field], f"$.candidate.{field}")) is None:
            raise InstalledMatrixReceiptError(f"$.candidate.{field} must be a full Git object")
    products = _closed(
        record["products"],
        PRODUCT_FIELDS_V2 if schema_version == 2 else PRODUCT_FIELDS_V3,
        "$.products",
    )
    if schema_version in {4, 5, 6, SCHEMA_VERSION}:
        raw_presentation = record["presentation_screenshots"]
        if isinstance(raw_presentation, dict) and set(raw_presentation) == PRESENTATION_SCREENSHOT_ABSENT_FIELDS:
            if raw_presentation.get("state") != "absent":
                raise InstalledMatrixReceiptError("$.presentation_screenshots absent state is invalid")
            presentation = None
        else:
            presentation = _closed(
                raw_presentation,
                PRESENTATION_SCREENSHOT_FIELDS,
                "$.presentation_screenshots",
            )
        if presentation is not None:
            _absolute(presentation["artifact_root_path"], "$.presentation_screenshots.artifact_root_path")
            _absolute(presentation["manifest_path"], "$.presentation_screenshots.manifest_path")
            _digest(presentation["manifest_sha256"], "$.presentation_screenshots.manifest_sha256")
            attachments = presentation["attachments"]
            if not isinstance(attachments, list):
                raise InstalledMatrixReceiptError("$.presentation_screenshots.attachments must be an array")
            for index, attachment in enumerate(attachments):
                attachment = _closed(
                    attachment,
                    PRESENTATION_SCREENSHOT_ATTACHMENT_FIELDS_V7
                    if schema_version == SCHEMA_VERSION
                    else PRESENTATION_SCREENSHOT_ATTACHMENT_FIELDS_V4_V6,
                    f"$.presentation_screenshots.attachments[{index}]",
                )
                text_fields = ["test_identifier", "scenario", "appearance", "window_size"]
                if schema_version == SCHEMA_VERSION:
                    text_fields.append("presentation_state")
                for field in text_fields:
                    _text(attachment[field], f"$.presentation_screenshots.attachments[{index}].{field}")
                _absolute(attachment["attachment_path"], f"$.presentation_screenshots.attachments[{index}].attachment_path")
                _digest(attachment["sha256"], f"$.presentation_screenshots.attachments[{index}].sha256")
                for field in ("pixel_width", "pixel_height"):
                    if type(attachment[field]) is not int or attachment[field] <= 0:
                        raise InstalledMatrixReceiptError(
                            f"$.presentation_screenshots.attachments[{index}].{field} must be a positive integer"
                        )
    if schema_version in {6, SCHEMA_VERSION}:
        raw_observations = record["accessibility_observations"]
        if (
            isinstance(raw_observations, dict)
            and set(raw_observations) == ACCESSIBILITY_OBSERVATION_ABSENT_FIELDS
        ):
            if raw_observations.get("state") != "absent":
                raise InstalledMatrixReceiptError(
                    "$.accessibility_observations absent state is invalid"
                )
        else:
            observations = _closed(
                raw_observations,
                ACCESSIBILITY_OBSERVATION_FIELDS,
                "$.accessibility_observations",
            )
            _absolute(
                observations["artifact_root_path"],
                "$.accessibility_observations.artifact_root_path",
            )
            _absolute(
                observations["manifest_path"],
                "$.accessibility_observations.manifest_path",
            )
            _digest(
                observations["manifest_sha256"],
                "$.accessibility_observations.manifest_sha256",
            )
            raw_attachments = observations["attachments"]
            if not isinstance(raw_attachments, list) or not raw_attachments:
                raise InstalledMatrixReceiptError(
                    "$.accessibility_observations.attachments must be a nonempty array"
                )
            for index, raw_attachment in enumerate(raw_attachments):
                attachment = _closed(
                    raw_attachment,
                    ACCESSIBILITY_OBSERVATION_ATTACHMENT_FIELDS,
                    f"$.accessibility_observations.attachments[{index}]",
                )
                _absolute(
                    attachment["attachment_path"],
                    f"$.accessibility_observations.attachments[{index}].attachment_path",
                )
                _digest(
                    attachment["sha256"],
                    f"$.accessibility_observations.attachments[{index}].sha256",
                )
                for field in ("test_identifier", "vector_id"):
                    _text(
                        attachment[field],
                        f"$.accessibility_observations.attachments[{index}].{field}",
                    )
                _observed_identifier_list(
                    attachment["observed_identifiers"],
                    f"$.accessibility_observations.attachments[{index}].observed_identifiers",
                )
            observed_projection = _observed_selector_projection(
                observations["observed_selector_projection"],
                "$.accessibility_observations.observed_selector_projection",
            )
            _digest(
                observations["observed_selector_projection_sha256"],
                "$.accessibility_observations.observed_selector_projection_sha256",
            )
            if observations["observed_selector_projection_sha256"] != canonical_sha256(
                observed_projection
            ):
                raise InstalledMatrixReceiptError(
                    "$.accessibility_observations observed projection digest differs"
                )
    for product_id in ("installed_app", "test_bundle", "ui_runner"):
        product = _closed(products[product_id], BUNDLE_FIELDS, f"$.products.{product_id}")
        _absolute(product["path"], f"$.products.{product_id}.path")
        _absolute(product["executable_path"], f"$.products.{product_id}.executable_path")
        _text(product["bundle_identifier"], f"$.products.{product_id}.bundle_identifier")
        for field in ("content_sha256", "closed_tree_sha256", "executable_sha256"):
            _digest(product[field], f"$.products.{product_id}.{field}")
    xctestrun_ids = (
        ("xctestrun",) if schema_version == 2
        else ("prepared_xctestrun", "execution_xctestrun")
    )
    for product_id in xctestrun_ids:
        xctestrun = _closed(products[product_id], FILE_FIELDS, f"$.products.{product_id}")
        _absolute(xctestrun["path"], f"$.products.{product_id}.path")
        _digest(xctestrun["sha256"], f"$.products.{product_id}.sha256")
    if isinstance(products["xcresult"], dict) and set(products["xcresult"]) == ABSENT_RESULT_FIELDS:
        if products["xcresult"].get("state") != "absent":
            raise InstalledMatrixReceiptError("$.products.xcresult absent state is invalid")
    else:
        xcresult = _closed(products["xcresult"], TREE_FIELDS, "$.products.xcresult")
        _absolute(xcresult["path"], "$.products.xcresult.path")
        _digest(xcresult["closed_tree_sha256"], "$.products.xcresult.closed_tree_sha256")
    execution = _closed(
        record["execution"],
        EXECUTION_FIELDS_V5_V7
        if schema_version in {5, 6, SCHEMA_VERSION}
        else EXECUTION_FIELDS_V2_V4,
        "$.execution",
    )
    if not isinstance(execution["argv"], list) or not execution["argv"]:
        raise InstalledMatrixReceiptError("$.execution.argv must be a nonempty array")
    if not isinstance(execution["selectors"], list) or not execution["selectors"]:
        raise InstalledMatrixReceiptError("$.execution.selectors must be a nonempty array")
    for field in ("argv", "selectors"):
        for index, item in enumerate(execution[field]):
            _text(item, f"$.execution.{field}[{index}]")
    if schema_version in {5, 6, SCHEMA_VERSION}:
        projection = _selector_projection(
            execution["selector_projection"], "$.execution.selector_projection"
        )
        _digest(
            execution["selector_projection_sha256"],
            "$.execution.selector_projection_sha256",
        )
        if execution["selector_projection_sha256"] != canonical_sha256(projection):
            raise InstalledMatrixReceiptError(
                "$.execution.selector_projection_sha256 does not bind the exact projection"
            )
        if [item["test_identifier"] for item in projection] != execution["selectors"]:
            raise InstalledMatrixReceiptError(
                "$.execution.selector_projection differs from $.execution.selectors"
            )
    environment = _closed(execution["environment"], ENVIRONMENT_FIELDS, "$.execution.environment")
    for key, value in environment.items():
        _text(value, f"$.execution.environment.{key}")
    for field in ("started_at_unix_ms", "ended_at_unix_ms", "duration_ms", "exit_code"):
        if not isinstance(execution[field], int) or isinstance(execution[field], bool):
            raise InstalledMatrixReceiptError(f"$.execution.{field} must be an integer")
    if execution["started_at_unix_ms"] < 0 or execution["ended_at_unix_ms"] < execution["started_at_unix_ms"]:
        raise InstalledMatrixReceiptError("installed matrix receipt has invalid execution timing")
    if execution["duration_ms"] != execution["ended_at_unix_ms"] - execution["started_at_unix_ms"]:
        raise InstalledMatrixReceiptError("installed matrix receipt duration does not match timing")
    if execution["result"] not in {"passed", "failed", "infrastructure"}:
        raise InstalledMatrixReceiptError("installed matrix receipt result is invalid")
    if execution["result"] in {"passed", "failed"} and (execution["exit_code"] == 0) != (execution["result"] == "passed"):
        raise InstalledMatrixReceiptError("installed matrix receipt result disagrees with exit code")
    failure = execution["failure"]
    if failure is not None and (not isinstance(failure, str) or not failure or len(failure.encode()) > 2048):
        raise InstalledMatrixReceiptError("installed matrix receipt failure must be null or bounded text")
    if execution["result"] == "infrastructure":
        if failure is None or products["xcresult"] != {"state": "absent"}:
            raise InstalledMatrixReceiptError("infrastructure receipt must name an absent xcresult and failure")
    elif failure is not None:
        raise InstalledMatrixReceiptError("completed receipt must not carry infrastructure failure text")
    for snapshot_name in ("input_snapshot_before", "input_snapshot_after"):
        snapshot = execution[snapshot_name]
        expected_snapshot_fields = (
            SNAPSHOT_FIELDS_V2 if schema_version == 2 else SNAPSHOT_FIELDS_V3
        )
        if not isinstance(snapshot, dict) or set(snapshot) != expected_snapshot_fields:
            raise InstalledMatrixReceiptError(f"$.execution.{snapshot_name} has invalid closed fields")
    return record


def load_receipt(path: Path) -> dict[str, Any]:
    receipt, _ = load_receipt_with_sha256(path)
    return receipt


def load_receipt_with_sha256(path: Path) -> tuple[dict[str, Any], str]:
    """Decode one descriptor-fenced receipt stream and return its exact byte hash."""
    if not path.is_absolute():
        raise InstalledMatrixReceiptError("installed matrix receipt path must be absolute")
    try:
        parent = path.parent.resolve(strict=True)
    except OSError as error:
        raise InstalledMatrixReceiptError(f"installed matrix receipt is unavailable: {error}") from error
    if parent != path.parent:
        raise InstalledMatrixReceiptError(
            "installed matrix receipt path must not traverse symlinked ancestors"
        )
    try:
        payload, _ = _stable_file_bytes(path)
        value = decode_canonical_bytes(payload)
    except (OSError, UnicodeError, ValueError, InstalledMatrixReceiptError) as error:
        raise InstalledMatrixReceiptError(f"installed matrix receipt is not canonical JSON: {error}") from error
    return parse_document(value), hashlib.sha256(payload).hexdigest()


def validate_receipt(
    receipt: dict[str, Any],
    *,
    candidate_identity_path: Path,
    installed_app: Path,
    expected_selector_projection: list[dict[str, Any]],
) -> str:
    receipt = parse_document(receipt)
    if receipt["execution"]["result"] != "passed":
        raise InstalledMatrixReceiptError(
            "installed matrix receipt is not a passing complete selector execution: "
            f"{receipt['execution']['result']}"
        )
    if receipt["schema_version"] != SCHEMA_VERSION:
        raise InstalledMatrixReceiptError(
            "installed matrix receipt predates the required physical presentation screenshot "
            "contract, selector-projection contract, or observed-identifier attachment contract"
        )
    candidate_identity_path = _ordinary(candidate_identity_path, directory=False)
    installed_app = _ordinary(installed_app, directory=True)
    candidate, candidate_digest = _candidate(candidate_identity_path)
    sealed_candidate = receipt["candidate"]
    if Path(sealed_candidate["identity_path"]) != candidate_identity_path:
        raise InstalledMatrixReceiptError(
            "candidate identity physical path differs from installed matrix receipt"
        )
    if sealed_candidate["identity_sha256"] != candidate_digest:
        raise InstalledMatrixReceiptError(
            "candidate identity physical identity differs from installed matrix receipt"
        )
    if (
        sealed_candidate["source_commit"] != candidate.source.commit
        or sealed_candidate["source_tree"] != candidate.source.tree
    ):
        raise InstalledMatrixReceiptError(
            "candidate source physical identity differs from installed matrix receipt"
        )
    preparation_path = Path(sealed_candidate["preparation_receipt_path"])
    preparation_receipt, preparation_digest = _preparation(
        preparation_path,
        candidate_identity_path,
        test_bundle=Path(receipt["products"]["test_bundle"]["path"]),
        ui_runner=Path(receipt["products"]["ui_runner"]["path"]),
    )
    if sealed_candidate["preparation_receipt_sha256"] != preparation_digest:
        raise InstalledMatrixReceiptError(
            "preparation receipt physical identity differs from installed matrix receipt"
        )
    products = receipt["products"]
    schema_version = receipt["schema_version"]
    product_paths = {
        "installed_app": installed_app,
        "test_bundle": Path(products["test_bundle"]["path"]),
        "ui_runner": Path(products["ui_runner"]["path"]),
    }
    test_executable, runner_executable = _product_paths(
        product_paths["test_bundle"], product_paths["ui_runner"]
    )
    if schema_version == 2:
        prepared_xctestrun_path = Path(products["xctestrun"]["path"])
        execution_xctestrun_path = prepared_xctestrun_path
    else:
        prepared_xctestrun_path = Path(products["prepared_xctestrun"]["path"])
        execution_xctestrun_path = Path(products["execution_xctestrun"]["path"])
    xcresult_path = Path(products["xcresult"]["path"])
    _validate_product_layout(
        prepared_xctestrun_path,
        product_paths["test_bundle"],
        product_paths["ui_runner"],
    )
    observed_bundles = {
        "installed_app": _bundle_identity(
            installed_app, installed_app / "Contents/MacOS/MacScope"
        ),
        "test_bundle": _bundle_identity(product_paths["test_bundle"], test_executable),
        "ui_runner": _bundle_identity(product_paths["ui_runner"], runner_executable),
    }
    for product_id, observed in observed_bundles.items():
        if products[product_id] != observed:
            raise InstalledMatrixReceiptError(
                f"{product_id.replace('_', ' ')} physical identity differs from installed matrix receipt"
            )
    _assert_installed_application_identity(candidate, observed_bundles["installed_app"])
    prepared_artifacts = preparation_receipt.get("artifacts", {})
    prepared_app_record = prepared_artifacts.get("app") if isinstance(prepared_artifacts, dict) else None
    if not isinstance(prepared_app_record, dict) or not isinstance(prepared_app_record.get("path"), str):
        raise InstalledMatrixReceiptError("preparation receipt lacks the sealed prepared app")
    _xctestrun_contract(
        prepared_xctestrun_path,
        test_bundle=product_paths["test_bundle"],
        ui_runner=product_paths["ui_runner"],
        installed_app=installed_app,
        prepared_app=_ordinary(Path(prepared_app_record["path"]), directory=True),
    )
    if schema_version == 2:
        if products["xctestrun"] != {
            "path": str(prepared_xctestrun_path),
            "sha256": file_sha256(prepared_xctestrun_path),
        }:
            raise InstalledMatrixReceiptError(
                "xctestrun physical identity differs from installed matrix receipt"
            )
    else:
        validate_execution_xctestrun_overlay(
            prepared_xctestrun_path, execution_xctestrun_path, installed_app
        )
        _xctestrun_contract(
            execution_xctestrun_path,
            test_bundle=product_paths["test_bundle"],
            ui_runner=product_paths["ui_runner"],
            installed_app=installed_app,
            prepared_app=_ordinary(Path(prepared_app_record["path"]), directory=True),
        )
        if products["prepared_xctestrun"] != {
            "path": str(prepared_xctestrun_path),
            "sha256": file_sha256(prepared_xctestrun_path),
        }:
            raise InstalledMatrixReceiptError(
                "prepared xctestrun physical identity differs from installed matrix receipt"
            )
        if products["execution_xctestrun"] != {
            "path": str(execution_xctestrun_path),
            "sha256": file_sha256(execution_xctestrun_path),
        }:
            raise InstalledMatrixReceiptError(
                "execution xctestrun physical identity differs from installed matrix receipt"
            )
    if products["xcresult"] != _tree_identity(xcresult_path):
        raise InstalledMatrixReceiptError(
            "xcresult physical identity differs from installed matrix receipt"
        )
    validate_presentation_screenshots(
        receipt["presentation_screenshots"],
        xcresult=xcresult_path,
        candidate=candidate,
    )
    execution = receipt["execution"]
    expected_projection = _selector_projection(
        expected_selector_projection, "canonical selector projection"
    )
    expected_selectors = [item["test_identifier"] for item in expected_projection]
    if (
        execution["selectors"] != expected_selectors
        or execution["selector_projection"] != expected_projection
        or execution["selector_projection_sha256"] != canonical_sha256(expected_projection)
    ):
        raise InstalledMatrixReceiptError(
            "installed matrix receipt selector projection differs from the canonical selector catalog"
        )
    validate_accessibility_observations(
        receipt["accessibility_observations"],
        xcresult=xcresult_path,
        selector_projection=expected_projection,
    )
    _validate_execution_contract(
        preparation_receipt,
        installed_app,
        execution_xctestrun_path,
        xcresult_path,
        execution["argv"],
        execution["selectors"],
        execution["selector_projection"],
        execution["environment"],
    )
    if schema_version == 2:
        test_executable, runner_executable = _product_paths(
            product_paths["test_bundle"], product_paths["ui_runner"]
        )
        observed_snapshot = {
            "candidate_identity": _file_descriptor_identity(candidate_identity_path),
            "preparation_receipt": _file_descriptor_identity(preparation_path),
            "installed_app": _bundle_identity(
                installed_app, installed_app / "Contents/MacOS/MacScope"
            ),
            "xctestrun": _file_descriptor_identity(prepared_xctestrun_path),
            "test_bundle": _bundle_identity(product_paths["test_bundle"], test_executable),
            "ui_runner": _bundle_identity(product_paths["ui_runner"], runner_executable),
            "xcodebuild": _file_descriptor_identity(Path(execution["argv"][0])),
        }
    else:
        observed_snapshot = capture_input_snapshot(
            candidate_identity_path=candidate_identity_path,
            preparation_receipt_path=preparation_path,
            installed_app=installed_app,
            prepared_xctestrun=prepared_xctestrun_path,
            execution_xctestrun=execution_xctestrun_path,
            test_bundle=product_paths["test_bundle"],
            ui_runner=product_paths["ui_runner"],
            xcodebuild=Path(execution["argv"][0]),
        )
    if (
        execution["input_snapshot_before"] != execution["input_snapshot_after"]
        or execution["input_snapshot_after"] != observed_snapshot
    ):
        raise InstalledMatrixReceiptError(
            "installed matrix input physical identity snapshot differs before, after, or at validation"
        )
    return canonical_sha256(receipt)


def write_create_only(path: Path, document: dict[str, Any]) -> str:
    if not path.is_absolute() or path.exists() or path.is_symlink():
        raise InstalledMatrixReceiptError("receipt output must be an absent absolute path")
    parent = _ordinary(path.parent, directory=True)
    destination = parent / path.name
    descriptor = -1
    temporary: Path | None = None
    for attempt in range(16):
        candidate = parent / f".{path.name}.tmp.{os.getpid()}.{os.urandom(16).hex()}"
        try:
            descriptor = os.open(
                candidate,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
                0o600,
            )
            temporary = candidate
            break
        except FileExistsError:
            continue
    if descriptor < 0 or temporary is None:
        raise InstalledMatrixReceiptError("cannot allocate a collision-safe receipt temporary file")
    try:
        with os.fdopen(descriptor, "wb", closefd=False) as stream:
            stream.write(canonical_bytes(document))
            stream.flush()
            os.fsync(stream.fileno())
        try:
            os.link(temporary, destination, follow_symlinks=False)
        except FileExistsError as error:
            raise InstalledMatrixReceiptError(
                "receipt output appeared before atomic publication"
            ) from error
        parent_descriptor = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(parent_descriptor)
        finally:
            os.close(parent_descriptor)
    finally:
        os.close(descriptor)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
    return file_sha256(destination)
