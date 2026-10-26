#!/usr/bin/env python3
"""Validate that MacScope's dependency and capability contracts agree."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shlex
import stat
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'qualification'))
from qualification_manifest_inheritance import sealed_source_digest

MAX_POLICY_BYTES = 2 * 1024 * 1024
POLICY_DATE = "2026-07-20"
DECISION_ID = "DEP-2026-07-20"

MACHOKIT_DIRECT_SOURCE_PIN = {
    "git_revision": "773e10797abc53914b94c2ee8c6f40f5da0b06eb",
    "version": "0.52.2",
    "source_archive_sha256": "2e6d429f248ac3f01b896379c3c77518858a2213ef3da0d89939d112de9fd945",
    "source_tree_sha256": "0a0bdc104b7f20c3f34ef595e113152cfc78ec496e96e14cb4957cf4d81dd038",
}
SWIFT_ASSEMBLY_DIRECT_SOURCE_PIN = {
    "git_revision": "b6798dbd0081ec989d25b5a0676ab8cbd36bd9b1",
    "source_sha256": "063a49e06b080a9f3488b5ba4c4f496eabc7778e6dbe09ce91a3de25c30f4afa",
    "source_tree_sha256": "05235d94e3b47c2ba1e0163ad0cb596078420e1590345a281ba94088d981e24c",
}
GHOSTTY_SURFACE_TARGETS = [
    "gst01-ghostty-surface-materializer",
    "gst01-ghostty-surface-builder",
]
GHOSTTY_SURFACE_MATERIALIZATION = {
    "script": "Scripts/dependencies/materialize_ghostty_surface.sh",
    "network_allowed": True,
    "implicit_build_invocation": False,
    "expected_untracked_root": "ghostty-surface-f64f4aca",
}
MACHOKIT_LICENSE_EXPRESSION = (
    "MIT AND APSL-2.0 AND BSD-4-Clause AND BSD-3-Clause AND LicenseRef-CMU-Mach"
)
MACHOKIT_LICENSE_PATHS = [
    "ThirdParty/MachOKit/LICENSE.txt",
    "ThirdParty/MachOKit/LICENSE.swift-fileio.txt",
    "ThirdParty/MachOKit/LICENSE.swift-fileio-extra.txt",
    "ThirdParty/MachOKit/LICENSE.swift-binary-parse-support.txt",
    "ThirdParty/MachOKit/LICENSE.APSL-2.0.txt",
    "ThirdParty/MachOKit/LICENSE.BSD-4-Clause-UCB.txt",
    "ThirdParty/MachOKit/LICENSE.BSD-3-Clause-Demetriou.txt",
    "ThirdParty/MachOKit/LICENSE.CMU-Mach.txt",
]
MACHOKIT_NOTICE_PATHS = [
    "THIRD_PARTY_NOTICES.md",
    "ThirdParty/MachOKit/NOTICE.Apple-Original-Code.txt",
    "ThirdParty/MachOKit/NOTICE.Apple-OSReference.txt",
]
MACHOKIT_RECORD_SHA256 = {
    "MachOKit APSL-2.0 license": "2d0c12edaaf8d31fec6796fef99291b12e833b6bef28100975120a53d209e06d",
    "MachOKit BSD-4-Clause license": "4652a99800bc1729cb0704fa7b78be569358c9a018bac358c42176d5f2d4307c",
    "MachOKit BSD-3-Clause license": "36b17891f61d3233a2cb03f77c067aac7a2e0ce63f640049bfe9b5d95529bc04",
    "MachOKit CMU license": "2a2bbab247550666dd6df5f1b65b09988724b4df10914977f534e4cf1fc9311d",
    "MachOKit Apple Original Code notice": "9ec95f45982c774e03dbc46cfabda9e592593cce7700745cd1bbfe1ae68d7557",
    "MachOKit Apple OSReference notice": "ee02537b2e54f9473602a68fb5108181a543fa1f073bafe5ba5d1bec83f1b162",
}


class PolicyConsistencyError(RuntimeError):
    pass


class DuplicatePolicyJSONKey(ValueError):
    pass


def _object_without_duplicate_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise DuplicatePolicyJSONKey(key)
        result[key] = value
    return result


@dataclass(frozen=True)
class PolicyConsistencySummary:
    policy_date: str
    decision_id: str
    file_sha256: dict[str, str]

    def as_json(self) -> dict[str, object]:
        return {
            "policy_date": self.policy_date,
            "decision_id": self.decision_id,
            "file_sha256": dict(sorted(self.file_sha256.items())),
        }


def _read_regular_text(path: Path, label: str) -> tuple[str, str]:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise PolicyConsistencyError(f"{label} is missing or inaccessible: {error}")
    if not stat.S_ISREG(metadata.st_mode):
        raise PolicyConsistencyError(f"{label} must be a regular file, not a symlink")
    if metadata.st_size > MAX_POLICY_BYTES:
        raise PolicyConsistencyError(f"{label} exceeds the fixed size bound")
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(descriptor, "rb") as stream:
        payload = stream.read(MAX_POLICY_BYTES + 1)
    if len(payload) > MAX_POLICY_BYTES:
        raise PolicyConsistencyError(f"{label} grew beyond the fixed size bound")
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise PolicyConsistencyError(f"{label} must be UTF-8: {error}")
    admitted_digest = sealed_source_digest(path)
    return text, admitted_digest if admitted_digest is not None else hashlib.sha256(payload).hexdigest()


def _require(text: str, phrase: str, label: str) -> None:
    if phrase not in text:
        raise PolicyConsistencyError(f"{label} is missing required policy text: {phrase!r}")


def _forbid(text: str, phrase: str, label: str) -> None:
    if phrase in text:
        raise PolicyConsistencyError(f"{label} contains superseded policy text: {phrase!r}")


def _parse_build_contract(text: str, label: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise PolicyConsistencyError(
                f"{label} contains an invalid entry "
                f"at line {line_number}"
            )
        key, value = line.split("=", 1)
        if not key or key in values:
            raise PolicyConsistencyError(
                f"{label} contains a duplicate or empty key "
                f"at line {line_number}"
            )
        try:
            tokens = shlex.split(value, comments=False, posix=True)
        except ValueError as error:
            raise PolicyConsistencyError(
                f"{label} contains malformed value at line {line_number}: {error}"
            ) from error
        if len(tokens) != 1:
            raise PolicyConsistencyError(
                f"{label} must contain one scalar value at line {line_number}"
            )
        values[key] = tokens[0]
    return values


def validate_policy_consistency(root: Path) -> PolicyConsistencySummary:
    root = root.resolve(strict=True)
    paths = {
        "MacScope/PARITY_CONTRACT.md": root / "MacScope/PARITY_CONTRACT.md",
        "THIRD_PARTY_COMPONENTS.yml": root / "THIRD_PARTY_COMPONENTS.yml",
        "THIRD_PARTY_NOTICES.md": root / "THIRD_PARTY_NOTICES.md",
        "Scripts/ghostty-vt-source.contract": root
        / "Scripts/ghostty-vt-source.contract",
        "Scripts/ghostty-surface-source.contract": root
        / "Scripts/ghostty-surface-source.contract",
        "docs/dependencies/LicenseDecision.md": root / "docs/dependencies/LicenseDecision.md",
        "MachOKit APSL-2.0 license": root / "ThirdParty/MachOKit/LICENSE.APSL-2.0.txt",
        "MachOKit BSD-4-Clause license": root / "ThirdParty/MachOKit/LICENSE.BSD-4-Clause-UCB.txt",
        "MachOKit BSD-3-Clause license": root / "ThirdParty/MachOKit/LICENSE.BSD-3-Clause-Demetriou.txt",
        "MachOKit CMU license": root / "ThirdParty/MachOKit/LICENSE.CMU-Mach.txt",
        "MachOKit Apple Original Code notice": root / "ThirdParty/MachOKit/NOTICE.Apple-Original-Code.txt",
        "MachOKit Apple OSReference notice": root / "ThirdParty/MachOKit/NOTICE.Apple-OSReference.txt",
    }
    texts: dict[str, str] = {}
    hashes: dict[str, str] = {}
    for label, path in paths.items():
        if any(parent.is_symlink() for parent in path.parents if parent != root and root in parent.parents):
            raise PolicyConsistencyError(f"{label} parent must not be a symlink")
        texts[label], hashes[label] = _read_regular_text(path, label)
    for label, expected_sha256 in MACHOKIT_RECORD_SHA256.items():
        if hashes[label] != expected_sha256:
            raise PolicyConsistencyError(
                f"{label} checksum drift: expected {expected_sha256}, found {hashes[label]}"
            )

    parity = texts["MacScope/PARITY_CONTRACT.md"]
    manifest = texts["THIRD_PARTY_COMPONENTS.yml"]
    notices = texts["THIRD_PARTY_NOTICES.md"]
    build_contract = _parse_build_contract(
        texts["Scripts/ghostty-vt-source.contract"],
        "Scripts/ghostty-vt-source.contract",
    )
    surface_contract = _parse_build_contract(
        texts["Scripts/ghostty-surface-source.contract"],
        "Scripts/ghostty-surface-source.contract",
    )
    license_decision = texts["docs/dependencies/LicenseDecision.md"]

    _require(
        parity,
        f"Approved open-source reuse (binding, {POLICY_DATE})",
        "MacScope/PARITY_CONTRACT.md",
    )
    _require(parity, "`THIRD_PARTY_COMPONENTS.yml`", "MacScope/PARITY_CONTRACT.md")
    _require(parity, "Proprietary, non-public, unapproved", "MacScope/PARITY_CONTRACT.md")


    _require(manifest, '"schema_version": 1', "THIRD_PARTY_COMPONENTS.yml")
    try:
        manifest_value = json.loads(
            manifest, object_pairs_hook=_object_without_duplicate_keys
        )
    except DuplicatePolicyJSONKey as error:
        raise PolicyConsistencyError(
            f"THIRD_PARTY_COMPONENTS.yml contains duplicate key: {error.args[0]}"
        )
    except json.JSONDecodeError as error:
        raise PolicyConsistencyError(
            "THIRD_PARTY_COMPONENTS.yml must remain JSON-compatible YAML: "
            f"line {error.lineno}, column {error.colno}: {error.msg}"
        )
    if not isinstance(manifest_value, dict):
        raise PolicyConsistencyError("THIRD_PARTY_COMPONENTS.yml must be an object")
    distribution = manifest_value.get("distribution_policy")
    if not isinstance(distribution, dict):
        raise PolicyConsistencyError("manifest distribution policy is missing")
    if (
        distribution.get("status") != "private-development-only"
        or distribution.get("public_distribution_approved") is not False
    ):
        raise PolicyConsistencyError(
            "public distribution must remain disabled while the license decision is unresolved"
        )
    components = manifest_value.get("components")
    if not isinstance(components, list):
        raise PolicyConsistencyError("manifest component inventory is missing")
    components_by_id = {
        component.get("id"): component
        for component in components
        if isinstance(component, dict) and isinstance(component.get("id"), str)
    }
    ghostty = components_by_id.get("ghostty-vt")
    ghostty_pin = ghostty.get("pin") if isinstance(ghostty, dict) else None
    if not isinstance(ghostty_pin, dict) or ghostty_pin != {
        "git_revision": build_contract.get("EXPECTED_GHOSTTY_SOURCE_REVISION"),
        "version": build_contract.get("EXPECTED_GHOSTTY_VERSION"),
        "source_archive_sha256": build_contract.get(
            "EXPECTED_GHOSTTY_SOURCE_ARCHIVE_SHA256"
        ),
        "source_tree_sha256": build_contract.get(
            "EXPECTED_GHOSTTY_SOURCE_TREE_SHA256"
        ),
    }:
        raise PolicyConsistencyError(
            "Ghostty build contract disagrees with THIRD_PARTY_COMPONENTS.yml"
        )
    zig = components_by_id.get("zig-toolchain")
    zig_pin = zig.get("pin") if isinstance(zig, dict) else None
    if not isinstance(zig_pin, dict) or zig_pin != {
        "version": build_contract.get("EXPECTED_ZIG_VERSION"),
        "selected_artifact_sha256": build_contract.get(
            "EXPECTED_ZIG_AARCH64_MACOS_SHA256"
        ),
        "source_tree_sha256": build_contract.get(
            "EXPECTED_ZIG_AARCH64_MACOS_TREE_SHA256"
        ),
    }:
        raise PolicyConsistencyError(
            "Zig build contract disagrees with THIRD_PARTY_COMPONENTS.yml"
        )
    ghostty_surface = components_by_id.get("ghostty-surface")
    if not isinstance(ghostty_surface, dict) or (
        ghostty_surface.get("approval") != "shipping-approved"
        or ghostty_surface.get("integration_mode") != "vendored-source"
        or ghostty_surface.get("pin")
        != {
            "git_revision": surface_contract.get("EXPECTED_GHOSTTY_SURFACE_REVISION"),
            "version": surface_contract.get("EXPECTED_GHOSTTY_SURFACE_VERSION"),
            "source_sha256": surface_contract.get("EXPECTED_GHOSTTY_SURFACE_BASE_SHA256"),
            "source_tree_sha256": surface_contract.get("EXPECTED_GHOSTTY_SURFACE_PATCHED_SHA256"),
        }
        or ghostty_surface.get("targets") != GHOSTTY_SURFACE_TARGETS
        or ghostty_surface.get("materialization") != GHOSTTY_SURFACE_MATERIALIZATION
    ):
        raise PolicyConsistencyError(
            "Ghostty surface contract disagrees with THIRD_PARTY_COMPONENTS.yml"
        )
    machokit = components_by_id.get("machokit-v2")
    if not isinstance(machokit, dict) or (
        machokit.get("approval") != "shipping-approved"
        or machokit.get("integration_mode") != "swift-package"
        or machokit.get("pin") != MACHOKIT_DIRECT_SOURCE_PIN
        or machokit.get("targets") != ["AnalysisWorkerXPCService"]
        or machokit.get("license_expression") != MACHOKIT_LICENSE_EXPRESSION
        or machokit.get("license_paths") != MACHOKIT_LICENSE_PATHS
        or machokit.get("notice_paths") != MACHOKIT_NOTICE_PATHS
        or machokit.get("materialization")
        != {
            "script": "Scripts/dependencies/materialize_machokit.py",
            "network_allowed": False,
            "implicit_build_invocation": False,
            "expected_untracked_root": None,
        }
    ):
        raise PolicyConsistencyError(
            "MachOKit direct-source contract disagrees with THIRD_PARTY_COMPONENTS.yml"
        )
    swift_assembly = components_by_id.get("swift-assembly-vendor")
    if not isinstance(swift_assembly, dict) or (
        swift_assembly.get("approval") != "shipping-approved"
        or swift_assembly.get("integration_mode") != "vendored-source"
        or swift_assembly.get("pin") != SWIFT_ASSEMBLY_DIRECT_SOURCE_PIN
        or swift_assembly.get("targets") != ["SwiftAssemblyVendor", "MacScopeApp"]
        or swift_assembly.get("materialization")
        != {
            "script": "Scripts/dependencies/materialize_swift_assembly.py",
            "network_allowed": False,
            "implicit_build_invocation": False,
            "expected_untracked_root": None,
        }
    ):
        raise PolicyConsistencyError(
            "swift-assembly direct-source contract disagrees with THIRD_PARTY_COMPONENTS.yml"
        )
    native_components = [
        component
        for component in components
        if isinstance(component, dict)
        and component.get("id") == "sleigh-native-dcp03b4"
    ]
    if len(native_components) != 1 or (
        native_components[0].get("approval") != "shipping-approved"
        or native_components[0].get("integration_mode") != "linked-library"
    ):
        raise PolicyConsistencyError(
            "default native product authority requires one shipping-approved linked-library component"
        )
    _require(notices, "default-on private product runtime", "THIRD_PARTY_NOTICES.md")
    _require(notices, "machine-readable authority", "THIRD_PARTY_NOTICES.md")
    _require(notices, "Apple Public Source License", "THIRD_PARTY_NOTICES.md")
    _require(notices, "four-clause", "THIRD_PARTY_NOTICES.md")
    _require(notices, "University of", "THIRD_PARTY_NOTICES.md")
    _require(notices, "California BSD terms", "THIRD_PARTY_NOTICES.md")
    _require(notices, "Carnegie Mellon Mach", "THIRD_PARTY_NOTICES.md")
    _require(
        texts["MachOKit APSL-2.0 license"],
        "APPLE PUBLIC SOURCE LICENSE",
        "MachOKit APSL-2.0 license",
    )
    _require(
        texts["MachOKit BSD-4-Clause license"],
        "All advertising materials mentioning features or use of this software",
        "MachOKit BSD-4-Clause license",
    )
    _require(
        texts["MachOKit BSD-3-Clause license"],
        "Copyright (c) 1993 Christopher G. Demetriou",
        "MachOKit BSD-3-Clause license",
    )
    _require(
        texts["MachOKit CMU license"],
        "Carnegie Mellon requests users of this software to return to",
        "MachOKit CMU license",
    )
    _require(
        texts["MachOKit Apple Original Code notice"],
        "@APPLE_LICENSE_HEADER_START@",
        "MachOKit Apple Original Code notice",
    )
    _require(
        texts["MachOKit Apple Original Code notice"],
        "MachOKitC/include/dyld_cache_format.h",
        "MachOKit Apple Original Code notice",
    )
    _require(
        texts["MachOKit Apple OSReference notice"],
        "@APPLE_OSREFERENCE_LICENSE_HEADER_START@",
        "MachOKit Apple OSReference notice",
    )
    _require(license_decision, "unresolved for public distribution", "LicenseDecision.md")

    superseded_phrases = (
        "every line of MacScope is written from scratch",
        "Never copy any third-party tool's implementation code",
        "No external package managers. Do not add SwiftPM",
        "Clean-room implementation (binding)",
    )
    for phrase in superseded_phrases:
        _forbid(parity, phrase, "MacScope/PARITY_CONTRACT.md")

    if license_decision.count(POLICY_DATE) < 1 or parity.count(POLICY_DATE) < 1:
        raise PolicyConsistencyError("policy effective date is not synchronized")
    return PolicyConsistencySummary(
        policy_date=POLICY_DATE,
        decision_id=DECISION_ID,
        file_sha256=hashes,
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
        summary = validate_policy_consistency(arguments.repo_root)
    except (PolicyConsistencyError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    if arguments.emit_json:
        print(json.dumps(summary.as_json(), sort_keys=True, separators=(",", ":")))
    else:
        print(
            "Dependency policy contracts agree: "
            f"{summary.decision_id}, effective {summary.policy_date}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
