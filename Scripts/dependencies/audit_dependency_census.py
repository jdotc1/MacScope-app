#!/usr/bin/env python3
"""Validate repository dependency authority against normal product surfaces."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
if str(REPOSITORY_ROOT) not in sys.path:
    sys.path.insert(0, str(REPOSITORY_ROOT))

from Scripts.dependencies.validate_third_party_components import validate_inventory


LEGACY_RESOLUTIONS = {"MACSCOPE_GHOSTTY_SOURCE_DIR", "command -v/xcodegen"}
REQUIRED_BOOTSTRAP_INPUTS = {
    "ghostty-vt": ("source-dependency", "ThirdParty/GhosttyVT/Source"),
    "ghostty-surface": ("build-source", "dependencies/build_vendored_ghostty_surface.sh"),
    "sleigh-native-dcp03b4": ("source-dependency", "ThirdParty/SleighNative"),
    "machokit-v2": ("source-dependency", "ThirdParty/MachOKit/materialization"),
    "xcodegen-tool": ("build-tool", "ThirdParty/XcodeGen/bin/xcodegen"),
}
REQUIRED_FINDINGS = {
    "DEP-REPOSITORY-SOURCE-AUTHORITY": "closed",
    "DEP-XCODEGEN-REPOSITORY-TOOL": "closed",
    "DEP-PLATFORM-TOOLCHAIN": "accepted-platform-input",
    "DEP-LM-STUDIO-SERVICE": "accepted-local-service-input",
}


class DependencyCensusError(RuntimeError):
    pass


def _load(root: Path) -> dict[str, Any]:
    path = root / "docs/dependencies/DEPENDENCY_CENSUS.md"
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise DependencyCensusError(f"census is not valid JSON-compatible YAML: {error}") from error
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        raise DependencyCensusError("census schema_version must be 1")
    return value


def _validated_blockers(census: dict[str, Any]) -> list[dict[str, Any]]:
    blockers = census.get("ordered_blockers")
    if not isinstance(blockers, list):
        raise DependencyCensusError("ordered_blockers must be an array")
    blocker_priorities: list[int] = []
    blocker_findings: dict[str, Any] = {}
    for blocker in blockers:
        if (
            not isinstance(blocker, dict)
            or not isinstance(blocker.get("id"), str)
            or not blocker["id"]
            or not isinstance(blocker.get("priority"), int)
            or not isinstance(blocker.get("detail"), str)
            or not blocker["detail"]
        ):
            raise DependencyCensusError("each blocker needs an id, integer priority, and detail")
        blocker_id = blocker["id"]
        if blocker_id in blocker_findings:
            raise DependencyCensusError(f"ordered_blockers has duplicate id {blocker_id}")
        blocker_priorities.append(blocker["priority"])
        blocker_findings[blocker_id] = blocker.get("status")
    if blocker_priorities != sorted(blocker_priorities):
        raise DependencyCensusError("ordered_blockers must be priority-sorted")
    if blocker_findings != REQUIRED_FINDINGS:
        raise DependencyCensusError("dependency findings do not record current authorities")
    return blockers


def audit_dependency_census(root: Path) -> dict[str, Any]:
    root = root.resolve(strict=True)
    census = _load(root)
    surfaces = census.get("surfaces")
    if not isinstance(surfaces, list) or not surfaces:
        raise DependencyCensusError("census surfaces must be a non-empty array")

    seen: set[str] = set()
    repository_components: set[str] = set()
    source_components: set[str] = set()
    external_inputs: set[str] = set()
    bootstrap_inputs: dict[str, tuple[str, str]] | None = None
    for index, surface in enumerate(surfaces):
        if not isinstance(surface, dict):
            raise DependencyCensusError(f"surfaces[{index}] must be an object")
        surface_id, relative = surface.get("id"), surface.get("path")
        if not isinstance(surface_id, str) or surface_id in seen:
            raise DependencyCensusError(f"surface id is missing or duplicated: {surface_id}")
        seen.add(surface_id)
        if not isinstance(relative, str) or Path(relative).is_absolute() or ".." in Path(relative).parts:
            raise DependencyCensusError(f"{surface_id}.path must be repository-relative")
        path = root / relative
        if not path.is_file():
            raise DependencyCensusError(f"{surface_id} path does not exist: {relative}")
        text = path.read_text(encoding="utf-8")
        inputs = surface.get("inputs")
        if not isinstance(inputs, list) or not inputs:
            raise DependencyCensusError(f"{surface_id}.inputs must be a non-empty array")

        input_ids: set[str] = set()
        for item in inputs:
            if not isinstance(item, dict) or not isinstance(item.get("id"), str):
                raise DependencyCensusError(f"{surface_id} has malformed input")
            input_id = item["id"]
            if input_id in input_ids:
                raise DependencyCensusError(f"{surface_id} has duplicate input id {input_id}")
            input_ids.add(input_id)
            resolution = item.get("resolution")
            if not isinstance(resolution, str) or not resolution:
                raise DependencyCensusError(f"{surface_id} has an unrecorded resolution")
            if resolution in LEGACY_RESOLUTIONS:
                raise DependencyCensusError(
                    f"{surface_id} retains legacy dependency authority {resolution}"
                )
            if resolution not in text:
                raise DependencyCensusError(f"{surface_id} does not evidence resolution {resolution}")

            authority = item.get("authority")
            component = item.get("manifest_component")
            if authority == "repository":
                if item.get("class") == "repository-entrypoint":
                    if component is not None:
                        raise DependencyCensusError(
                            f"{surface_id}.{input_id} entrypoint cannot claim a component"
                        )
                    continue
                if not isinstance(component, str) or not component:
                    raise DependencyCensusError(
                        f"{surface_id}.{input_id} repository input lacks manifest_component"
                    )
                repository_components.add(component)
                if item.get("class") == "source-dependency":
                    source_components.add(component)
            elif authority == "external":
                if component is not None:
                    raise DependencyCensusError(
                        f"{surface_id}.{input_id} external input cannot claim a component"
                    )
                external_inputs.add(input_id)
            else:
                raise DependencyCensusError(f"{surface_id}.{input_id} has invalid authority")

        if surface_id == "normal-bootstrap":
            bootstrap_inputs = {}
            for item in inputs:
                component = item.get("manifest_component")
                if item.get("authority") != "repository" or component is None:
                    continue
                if component in bootstrap_inputs:
                    raise DependencyCensusError(
                        f"normal-bootstrap has duplicate manifest_component {component}"
                    )
                bootstrap_inputs[component] = (item.get("class"), item.get("resolution"))

    if bootstrap_inputs != REQUIRED_BOOTSTRAP_INPUTS:
        raise DependencyCensusError(
            "normal-bootstrap does not declare the governed repository inputs"
        )

    blockers = _validated_blockers(census)

    declared = census.get("approved_source_components")
    if not isinstance(declared, list) or any(not isinstance(item, str) for item in declared):
        raise DependencyCensusError("approved_source_components must be a string array")
    if len(declared) != len(set(declared)):
        raise DependencyCensusError("approved_source_components contains duplicates")
    missing = sorted(repository_components - set(declared))
    if missing:
        raise DependencyCensusError(
            "repository inputs absent from census allowlist: " + ", ".join(missing)
        )

    inventory = validate_inventory(root)
    declared_components = set(declared)
    inventory_components = set(inventory.component_ids)
    if declared_components != inventory_components:
        missing_records = sorted(declared_components - inventory_components)
        missing_declarations = sorted(inventory_components - declared_components)
        detail: list[str] = []
        if missing_records:
            detail.append("absent from THIRD_PARTY_COMPONENTS.yml: " + ", ".join(missing_records))
        if missing_declarations:
            detail.append("absent from census allowlist: " + ", ".join(missing_declarations))
        raise DependencyCensusError("component inventory mismatch; " + "; ".join(detail))

    return {
        "surface_count": len(surfaces),
        "repository_input_count": len(repository_components),
        "source_dependency_count": len(source_components),
        "external_input_count": len(external_inputs),
        "component_count": len(inventory.component_ids),
        "blockers": blockers,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args(argv)
    try:
        result = audit_dependency_census(args.repo_root)
    except (DependencyCensusError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
