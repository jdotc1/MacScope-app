#!/usr/bin/env python3
"""Fail-closed validation for MacScope's third-party component inventory.

The inventory is stored as JSON-compatible YAML so the normal build has no YAML
parser dependency. This validator intentionally implements the closed schema in
`third_party_components.schema.json` using only the Python standard library.
"""

from __future__ import annotations

import argparse
import datetime as _datetime
import hashlib
import json
import os
import re
import stat
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
from first_party_components import FirstPartyValidationError, verified_component_roots

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'qualification'))
from qualification_manifest_inheritance import sealed_source_digest

SCHEMA_VERSION = 1
MAX_MANIFEST_BYTES = 2 * 1024 * 1024
MAX_TEXT_BYTES = 4 * 1024 * 1024
MAX_COMPONENTS = 512
MAX_TRACKED_PATHS_PER_COMPONENT = 512
MAX_DISCOVERED_FILES = 100_000
AUTHORED_FIXTURE_SPECIMENS = {
    "Scripts/parser-oracles/exception-flow/exception_cases_O1.dylib": "Scripts/parser-oracles/exception-flow/exception_cases.cpp",
    "Scripts/parser-oracles/type-atlas/mixed.dylib": "Scripts/parser-oracles/type-atlas/mixed.swift",
    "MacScope/Tests/Fixtures/UnwindLoops.dylib": "MacScope/Tests/Fixtures/UnwindLoops.S",
    "MacScope/Tests/Fixtures/CFARegister.dylib": "MacScope/Tests/Fixtures/CFARegister.S",
}
ID_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{1,63}$")
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
DATE_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}$")

TOP_LEVEL_KEYS = {"schema_version", "distribution_policy", "components"}
DISTRIBUTION_KEYS = {"status", "public_distribution_approved", "decision_record"}
COMPONENT_KEYS = {
    "id",
    "name",
    "canonical_repository",
    "approval",
    "integration_mode",
    "license_expression",
    "pin",
    "tracked_paths",
    "materialization",
    "license_paths",
    "license_sha256",
    "notice_paths",
    "patches_path",
    "targets",
    "review",
    "notes",
}
PIN_KEYS = {
    "git_revision",
    "version",
    "source_sha256",
    "source_archive_sha256",
    "source_tree_sha256",
    "selected_artifact_sha256",
}
MATERIALIZATION_KEYS = {
    "script",
    "network_allowed",
    "implicit_build_invocation",
    "expected_untracked_root",
}
REVIEW_KEYS = {"date", "status", "public_distribution_blocked", "reviewer"}
APPROVALS = {
    "shipping-approved",
    "pilot-approved",
    "tooling-oracle-approved",
    "reference-only",
}
INTEGRATION_MODES = {
    "vendored-source",
    "external-pinned-source-build",
    "linked-library",
    "swift-package",
    "generated-data-corpus",
    "developer-tool",
    "external-oracle",
}
REVIEW_STATUSES = {
    "reviewed-private-development",
    "reviewed-shipping",
    "oracle-only",
    "pending",
}
DISTRIBUTION_STATUSES = {"private-development-only", "distribution-approved"}
TOO_BROAD_TRACKED_PATHS = {
    ".",
    "MacScope",
    "Scripts",
    "docs",
    "ThirdParty",
}
REQUIRED_COMPONENT_TARGETS = {
    "sleigh-native-dcp03b4": frozenset(
        {
            "macscope_native_decompiler_contract",
            "macscope_sleigh_decomp_api_probe",
        }
    ),
}


class DuplicateJSONKey(ValueError):
    pass


class InventoryValidationError(RuntimeError):
    pass


@dataclass(frozen=True)
class ValidationSummary:
    schema_version: int
    component_ids: tuple[str, ...]
    manifest_sha256: str
    notice_sha256: str
    governed_file_count: int
    public_distribution_approved: bool

    def as_json(self) -> dict[str, object]:
        return {
            "schema_version": self.schema_version,
            "component_ids": list(self.component_ids),
            "component_count": len(self.component_ids),
            "manifest_sha256": self.manifest_sha256,
            "notice_sha256": self.notice_sha256,
            "governed_file_count": self.governed_file_count,
            "public_distribution_approved": self.public_distribution_approved,
        }


def _object_without_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateJSONKey(key)
        result[key] = value
    return result


def _read_regular_bytes(path: Path, maximum: int, label: str) -> bytes:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise InventoryValidationError(f"{label} is missing or inaccessible: {error}")
    if not stat.S_ISREG(metadata.st_mode):
        raise InventoryValidationError(f"{label} must be a regular file, not a symlink")
    if metadata.st_size > maximum:
        raise InventoryValidationError(f"{label} exceeds the fixed size bound")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "rb") as stream:
        payload = stream.read(maximum + 1)
    if len(payload) > maximum:
        raise InventoryValidationError(f"{label} grew beyond the fixed size bound")
    return payload


def _read_text(path: Path, label: str) -> str:
    payload = _read_regular_bytes(path, MAX_TEXT_BYTES, label)
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise InventoryValidationError(f"{label} must be UTF-8: {error}")


def _require_exact_keys(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise InventoryValidationError(f"{label} must be an object")
    observed = set(value)
    missing = sorted(expected - observed)
    unknown = sorted(observed - expected)
    if missing:
        raise InventoryValidationError(f"{label} is missing keys: {', '.join(missing)}")
    if unknown:
        raise InventoryValidationError(f"{label} has unknown keys: {', '.join(unknown)}")
    return value


def _require_string(value: Any, label: str, *, maximum: int = 2000) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise InventoryValidationError(f"{label} must be non-empty bounded text")
    if any(character in value for character in "\x00\r\n"):
        raise InventoryValidationError(f"{label} contains unsupported control text")
    return value


def _require_bool(value: Any, label: str) -> bool:
    if type(value) is not bool:
        raise InventoryValidationError(f"{label} must be a boolean")
    return value


def _normalize_relative_path(value: Any, label: str) -> str:
    text = _require_string(value, label, maximum=512)
    path = Path(text)
    if path.is_absolute() or ".." in path.parts or text.startswith("~"):
        raise InventoryValidationError(f"{label} must be a repository-relative path")
    normalized = path.as_posix().rstrip("/") or "."
    if normalized != text.rstrip("/"):
        raise InventoryValidationError(f"{label} must use canonical POSIX separators")
    return normalized


def _require_path(root: Path, relative: str, label: str) -> Path:
    candidate = root / relative
    try:
        metadata = candidate.lstat()
    except OSError as error:
        raise InventoryValidationError(f"{label} does not exist: {relative}: {error}")
    if stat.S_ISLNK(metadata.st_mode):
        raise InventoryValidationError(f"{label} must not be a symlink: {relative}")
    return candidate


def _validate_repository_url(value: Any, label: str) -> str:
    text = _require_string(value, label, maximum=512)
    parsed = urlsplit(text)
    if (
        parsed.scheme != "https"
        or not parsed.netloc
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise InventoryValidationError(f"{label} must be a canonical HTTPS repository URL")
    return text.rstrip("/")


def _validate_date(value: Any, label: str) -> str:
    text = _require_string(value, label, maximum=10)
    if DATE_PATTERN.fullmatch(text) is None:
        raise InventoryValidationError(f"{label} must use YYYY-MM-DD")
    try:
        _datetime.date.fromisoformat(text)
    except ValueError as error:
        raise InventoryValidationError(f"{label} is not a valid date: {error}")
    return text


def _validate_string_list(
    value: Any,
    label: str,
    *,
    minimum: int = 0,
    maximum: int = MAX_TRACKED_PATHS_PER_COMPONENT,
) -> list[str]:
    if not isinstance(value, list) or not (minimum <= len(value) <= maximum):
        raise InventoryValidationError(
            f"{label} must be an array containing {minimum}..{maximum} entries"
        )
    observed: set[str] = set()
    result: list[str] = []
    for index, item in enumerate(value):
        text = _require_string(item, f"{label}[{index}]", maximum=512)
        if text in observed:
            raise InventoryValidationError(f"{label} contains duplicate entry: {text}")
        observed.add(text)
        result.append(text)
    return result


def _sha256(path: Path) -> str:
    admitted_digest = sealed_source_digest(path)
    if admitted_digest is not None:
        return admitted_digest
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _manifest_payload(path: Path) -> tuple[dict[str, Any], bytes]:
    payload = _read_regular_bytes(path, MAX_MANIFEST_BYTES, "THIRD_PARTY_COMPONENTS.yml")
    try:
        decoded = json.loads(payload, object_pairs_hook=_object_without_duplicate_keys)
    except DuplicateJSONKey as error:
        raise InventoryValidationError(f"manifest contains duplicate JSON key: {error.args[0]}")
    except json.JSONDecodeError as error:
        raise InventoryValidationError(
            "THIRD_PARTY_COMPONENTS.yml must remain JSON-compatible YAML: "
            f"line {error.lineno}, column {error.colno}: {error.msg}"
        )
    return _require_exact_keys(decoded, TOP_LEVEL_KEYS, "manifest"), payload


def _tracked_files(root: Path, path: Path, relative: str) -> set[str]:
    metadata = path.lstat()
    if stat.S_ISREG(metadata.st_mode):
        return {relative}
    if not stat.S_ISDIR(metadata.st_mode):
        raise InventoryValidationError(f"tracked path must be a regular file or directory: {relative}")
    result: set[str] = set()
    for child in sorted(path.rglob("*"), key=lambda item: os.fsencode(item.as_posix())):
        child_metadata = child.lstat()
        if stat.S_ISLNK(child_metadata.st_mode):
            raise InventoryValidationError(
                f"tracked dependency path contains a symlink: {child.relative_to(root).as_posix()}"
            )
        if stat.S_ISREG(child_metadata.st_mode):
            result.add(child.relative_to(root).as_posix())
            if len(result) > MAX_DISCOVERED_FILES:
                raise InventoryValidationError("tracked dependency file count exceeds fixed bound")
    return result


def _discover_governed_files(root: Path) -> set[str]:
    """Discover paths that must be owned by exactly one component record."""

    try:
        first_party_roots = verified_component_roots(root)
    except FirstPartyValidationError as error:
        raise InventoryValidationError(str(error)) from error

    def ordinary_walk(directory: Path):
        # Prune the verified module itself, including its local Git administration
        # and ignored build debris, without hiding other ThirdParty contents.
        for parent, directories, files in os.walk(directory, followlinks=False):
            directories[:] = [name for name in directories
                              if (Path(parent) / name).relative_to(root).as_posix() not in first_party_roots
                              and (Path(parent) / name) != root / ".git"]
            for name in sorted(directories + files, key=os.fsencode):
                # Finder metadata is globally ignored by Git and is never a dependency
                # input. Do not let a local .DS_Store turn a clean governed inventory red.
                if name == ".DS_Store":
                    continue
                yield Path(parent) / name

    discovered: set[str] = set()
    roots = [root / "ThirdParty", root / "Vendor", root / "Dependencies"]
    for directory in roots:
        if not directory.exists():
            continue
        if directory.is_symlink() or not directory.is_dir():
            raise InventoryValidationError(
                f"third-party root must be an ordinary directory: {directory.relative_to(root)}"
            )
        for child in ordinary_walk(directory):
            metadata = child.lstat()
            if stat.S_ISLNK(metadata.st_mode):
                raise InventoryValidationError(
                    f"third-party root contains a symlink: {child.relative_to(root).as_posix()}"
                )
            if stat.S_ISREG(metadata.st_mode):
                discovered.add(child.relative_to(root).as_posix())

    function_signatures = root / "Scripts" / "function-signatures"
    if function_signatures.is_dir():
        for child in function_signatures.rglob("*"):
            if child.is_file() and (
                child.name.startswith("LICENSE")
                or child.name.startswith("compiler_rt_")
                or child.name == "README.md"
                or child.name == "generate_compiler_rt_signatures.py"
            ):
                discovered.add(child.relative_to(root).as_posix())

    for candidate in ordinary_walk(root):
        if len(discovered) > MAX_DISCOVERED_FILES:
            raise InventoryValidationError("governed dependency file count exceeds fixed bound")
        if not candidate.is_file() or candidate.is_symlink():
            continue
        relative = candidate.relative_to(root).as_posix()
        if relative == ".gitmodules" and first_party_roots:
            continue  # Its exact mapping was bound to the verified first-party gitlinks.
        if relative.startswith((
            ".git/", ".build/", "MacScope/.build/", "MacScope/build/",
            "MacScope/DerivedData",
        )):
            continue
        if candidate.name in {"Package.resolved", ".gitmodules"}:
            discovered.add(relative)
        if candidate.suffix in {".xcframework", ".framework", ".a", ".dylib"}:
            # Exact authored specimens are inspected as data. Unknown binaries
            # and specimens without an ordinary source stay governed.
            source_relative = AUTHORED_FIXTURE_SPECIMENS.get(relative)
            if source_relative is not None:
                source = root / source_relative
                if source.is_file() and not source.is_symlink():
                    continue
            discovered.add(relative)
    return discovered


def _validate_pin(value: Any, component_id: str) -> None:
    if not isinstance(value, dict):
        raise InventoryValidationError(f"{component_id}.pin must be an object")
    pin = value
    if not pin:
        raise InventoryValidationError(f"{component_id}.pin must contain at least one immutable pin")
    unknown = sorted(set(pin) - PIN_KEYS)
    if unknown:
        raise InventoryValidationError(f"{component_id}.pin has unknown keys: {', '.join(unknown)}")
    if "git_revision" in pin and (
        not isinstance(pin["git_revision"], str)
        or HEX40.fullmatch(pin["git_revision"]) is None
    ):
        raise InventoryValidationError(f"{component_id}.pin.git_revision must be 40 lowercase hex")
    if "version" in pin:
        _require_string(pin["version"], f"{component_id}.pin.version", maximum=80)
        if any(token in pin["version"].lower() for token in ("latest", "main", "master", "*", ">", "<", "~", "^")):
            raise InventoryValidationError(f"{component_id}.pin.version must be exact")
    for key in PIN_KEYS - {"git_revision", "version"}:
        if key in pin and (
            not isinstance(pin[key], str) or HEX64.fullmatch(pin[key]) is None
        ):
            raise InventoryValidationError(f"{component_id}.pin.{key} must be 64 lowercase hex")
    immutable_keys = set(pin) & (PIN_KEYS - {"version"})
    if not immutable_keys:
        raise InventoryValidationError(
            f"{component_id}.pin requires a Git revision or SHA-256 in addition to version text"
        )


def validate_inventory(root: Path) -> ValidationSummary:
    root = root.resolve(strict=True)
    manifest_path = root / "THIRD_PARTY_COMPONENTS.yml"
    notice_path = root / "THIRD_PARTY_NOTICES.md"
    schema_path = root / "Scripts/dependencies/third_party_components.schema.json"

    manifest, manifest_bytes = _manifest_payload(manifest_path)
    _read_regular_bytes(schema_path, MAX_MANIFEST_BYTES, "third-party schema")
    notices = _read_text(notice_path, "THIRD_PARTY_NOTICES.md")
    if manifest["schema_version"] != SCHEMA_VERSION:
        raise InventoryValidationError(
            f"unsupported manifest schema_version: {manifest['schema_version']!r}"
        )

    distribution = _require_exact_keys(
        manifest["distribution_policy"], DISTRIBUTION_KEYS, "distribution_policy"
    )
    status = _require_string(distribution["status"], "distribution_policy.status")
    if status not in DISTRIBUTION_STATUSES:
        raise InventoryValidationError(f"unsupported distribution policy status: {status}")
    public_distribution = _require_bool(
        distribution["public_distribution_approved"],
        "distribution_policy.public_distribution_approved",
    )
    decision_record = _normalize_relative_path(
        distribution["decision_record"], "distribution_policy.decision_record"
    )
    decision_text = _read_text(
        _require_path(root, decision_record, "distribution decision record"),
        "distribution decision record",
    )
    if public_distribution != (status == "distribution-approved"):
        raise InventoryValidationError(
            "distribution status and public_distribution_approved disagree"
        )
    if public_distribution and "unresolved" in decision_text.lower():
        raise InventoryValidationError(
            "manifest cannot approve public distribution while the decision record is unresolved"
        )
    if not public_distribution and "unresolved" not in decision_text.lower():
        raise InventoryValidationError(
            "private-development-only status requires an explicit unresolved distribution decision"
        )

    components = manifest["components"]
    if not isinstance(components, list) or not (1 <= len(components) <= MAX_COMPONENTS):
        raise InventoryValidationError("components must contain 1..512 entries")

    component_ids: set[str] = set()
    owner_by_file: dict[str, str] = {}
    for index, raw_component in enumerate(components):
        component = _require_exact_keys(raw_component, COMPONENT_KEYS, f"components[{index}]")
        component_id = _require_string(component["id"], f"components[{index}].id", maximum=64)
        if ID_PATTERN.fullmatch(component_id) is None:
            raise InventoryValidationError(f"component id is malformed: {component_id}")
        if component_id in component_ids:
            raise InventoryValidationError(f"duplicate component id: {component_id}")
        component_ids.add(component_id)

        name = _require_string(component["name"], f"{component_id}.name", maximum=160)
        repository = _validate_repository_url(
            component["canonical_repository"], f"{component_id}.canonical_repository"
        )
        approval = _require_string(component["approval"], f"{component_id}.approval")
        if approval not in APPROVALS:
            raise InventoryValidationError(f"unsupported approval for {component_id}: {approval}")
        integration_mode = _require_string(
            component["integration_mode"], f"{component_id}.integration_mode"
        )
        if integration_mode not in INTEGRATION_MODES:
            raise InventoryValidationError(
                f"unsupported integration_mode for {component_id}: {integration_mode}"
            )
        # Owner decision 2026-10-11: license type does not restrict integration
        # mode; copyleft components are approved like any other component.
        _require_string(
            component["license_expression"], f"{component_id}.license_expression", maximum=160
        )
        if approval == "reference-only" and component["targets"]:
            raise InventoryValidationError(
                f"reference-only component must not name build targets: {component_id}"
            )

        _validate_pin(component["pin"], component_id)

        tracked_paths = _validate_string_list(
            component["tracked_paths"], f"{component_id}.tracked_paths", minimum=1
        )
        component_files: set[str] = set()
        for path_index, raw_path in enumerate(tracked_paths):
            relative = _normalize_relative_path(
                raw_path, f"{component_id}.tracked_paths[{path_index}]"
            )
            if relative in TOO_BROAD_TRACKED_PATHS:
                raise InventoryValidationError(
                    f"tracked path is too broad to establish ownership: {component_id}: {relative}"
                )
            path = _require_path(root, relative, f"{component_id} tracked path")
            component_files.update(_tracked_files(root, path, relative))

        materialization = _require_exact_keys(
            component["materialization"], MATERIALIZATION_KEYS, f"{component_id}.materialization"
        )
        script = materialization["script"]
        if script is not None:
            script_relative = _normalize_relative_path(script, f"{component_id}.materialization.script")
            script_path = _require_path(root, script_relative, f"{component_id} materialization script")
            if not script_path.is_file():
                raise InventoryValidationError(
                    f"materialization script must be a regular file: {component_id}"
                )
            component_files.add(script_relative)
            if _require_bool(
                materialization["network_allowed"],
                f"{component_id}.materialization.network_allowed",
            ) and not script_relative.startswith("Scripts/dependencies/materialize_"):
                raise InventoryValidationError(
                    f"networked materializer must live under Scripts/dependencies: {component_id}"
                )
        else:
            _require_bool(
                materialization["network_allowed"],
                f"{component_id}.materialization.network_allowed",
            )
            if materialization["network_allowed"]:
                raise InventoryValidationError(
                    f"network_allowed requires a materialization script: {component_id}"
                )
        if _require_bool(
            materialization["implicit_build_invocation"],
            f"{component_id}.materialization.implicit_build_invocation",
        ):
            raise InventoryValidationError(
                f"materialization may not be invoked implicitly: {component_id}"
            )
        expected_root = materialization["expected_untracked_root"]
        if expected_root is not None:
            expected_root = _normalize_relative_path(
                expected_root, f"{component_id}.materialization.expected_untracked_root"
            )
            if "/" in expected_root:
                raise InventoryValidationError(
                    f"expected_untracked_root must be one top-level directory: {component_id}"
                )
            gitignore = _read_text(root / ".gitignore", ".gitignore")
            if f"/{expected_root}/" not in gitignore:
                raise InventoryValidationError(
                    f"materialized root is not explicitly gitignored: {component_id}: {expected_root}"
                )

        license_paths = _validate_string_list(
            component["license_paths"], f"{component_id}.license_paths", minimum=1
        )
        normalized_license_paths: list[str] = []
        for path_index, raw_path in enumerate(license_paths):
            relative = _normalize_relative_path(raw_path, f"{component_id}.license_paths[{path_index}]")
            path = _require_path(root, relative, f"{component_id} license path")
            if not path.is_file():
                raise InventoryValidationError(f"license path must be a file: {component_id}: {relative}")
            _read_regular_bytes(path, MAX_TEXT_BYTES, f"{component_id} license")
            normalized_license_paths.append(relative)
            component_files.add(relative)
        expected_license_sha = _require_string(
            component["license_sha256"], f"{component_id}.license_sha256", maximum=64
        )
        if HEX64.fullmatch(expected_license_sha) is None:
            raise InventoryValidationError(f"license_sha256 must be 64 lowercase hex: {component_id}")
        actual_license_sha = _sha256(root / normalized_license_paths[0])
        if actual_license_sha != expected_license_sha:
            raise InventoryValidationError(
                f"primary license checksum mismatch for {component_id}: "
                f"expected {expected_license_sha}, found {actual_license_sha}"
            )

        notice_paths = _validate_string_list(
            component["notice_paths"], f"{component_id}.notice_paths", minimum=1
        )
        for path_index, raw_path in enumerate(notice_paths):
            relative = _normalize_relative_path(raw_path, f"{component_id}.notice_paths[{path_index}]")
            path = _require_path(root, relative, f"{component_id} notice path")
            if not path.is_file():
                raise InventoryValidationError(f"notice path must be a file: {component_id}: {relative}")
            component_files.add(relative)
        marker = f"<!-- component:{component_id} -->"
        if marker not in notices:
            raise InventoryValidationError(f"notice marker is missing for component: {component_id}")

        patches_relative = _normalize_relative_path(
            component["patches_path"], f"{component_id}.patches_path"
        )
        patches_path = _require_path(root, patches_relative, f"{component_id} patches path")
        patches_text = _read_text(patches_path, f"{component_id} patches path")
        if "patch" not in patches_text.lower():
            raise InventoryValidationError(f"patch ledger is not descriptive: {component_id}")
        component_files.add(patches_relative)

        targets = _validate_string_list(
            component["targets"], f"{component_id}.targets", maximum=128
        )
        missing_targets = sorted(
            REQUIRED_COMPONENT_TARGETS.get(component_id, frozenset()) - set(targets)
        )
        if missing_targets:
            raise InventoryValidationError(
                f"{component_id}.targets is missing required consumer(s): "
                + ", ".join(missing_targets)
            )
        review = _require_exact_keys(component["review"], REVIEW_KEYS, f"{component_id}.review")
        _validate_date(review["date"], f"{component_id}.review.date")
        review_status = _require_string(review["status"], f"{component_id}.review.status")
        if review_status not in REVIEW_STATUSES:
            raise InventoryValidationError(
                f"unsupported review status for {component_id}: {review_status}"
            )
        public_blocked = _require_bool(
            review["public_distribution_blocked"],
            f"{component_id}.review.public_distribution_blocked",
        )
        _require_string(review["reviewer"], f"{component_id}.review.reviewer", maximum=160)
        _require_string(component["notes"], f"{component_id}.notes", maximum=2000)
        if not public_distribution and not public_blocked:
            raise InventoryValidationError(
                f"component must block public distribution while repository policy is unresolved: {component_id}"
            )
        if public_distribution and review_status != "reviewed-shipping":
            raise InventoryValidationError(
                f"distribution-approved inventory requires reviewed-shipping components: {component_id}"
            )

        for relative in sorted(component_files, key=os.fsencode):
            if relative == "THIRD_PARTY_NOTICES.md":
                continue
            previous = owner_by_file.get(relative)
            if previous is not None and previous != component_id:
                raise InventoryValidationError(
                    f"tracked dependency file has multiple owners: {relative}: {previous}, {component_id}"
                )
            owner_by_file[relative] = component_id
    discovered = _discover_governed_files(root)
    uncovered = sorted(discovered - set(owner_by_file), key=os.fsencode)
    if uncovered:
        preview = ", ".join(uncovered[:20])
        suffix = "" if len(uncovered) <= 20 else f" (+{len(uncovered) - 20} more)"
        raise InventoryValidationError(f"ungoverned third-party paths: {preview}{suffix}")

    return ValidationSummary(
        schema_version=SCHEMA_VERSION,
        component_ids=tuple(sorted(component_ids)),
        manifest_sha256=(sealed_source_digest(manifest_path) or hashlib.sha256(manifest_bytes).hexdigest()),
        notice_sha256=_sha256(notice_path),
        governed_file_count=len(discovered),
        public_distribution_approved=public_distribution,
    )


def parse_arguments(argv: Iterable[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
    )
    parser.add_argument("--json", action="store_true", dest="emit_json")
    return parser.parse_args(argv)


def main(argv: Iterable[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    try:
        summary = validate_inventory(arguments.repo_root)
    except (InventoryValidationError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    if arguments.emit_json:
        print(json.dumps(summary.as_json(), sort_keys=True, separators=(",", ":")))
    else:
        print(
            "Third-party inventory valid: "
            f"{len(summary.component_ids)} component(s), "
            f"{summary.governed_file_count} governed file(s), "
            f"manifest {summary.manifest_sha256}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
