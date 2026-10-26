"""Narrow first-party ownership, separate from the external license inventory.

This is a read-only consumer of canonical Git/submodule or source-export identity.
It never materializes a dependency and never hashes unrelated parent payloads.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import stat
import sys

DECLARATION = "FIRST_PARTY_COMPONENTS.json"
LUMEN_MATERIALIZER = "Scripts/dependencies/materialize_lumen_submodule.py"
ACQUISITION_SCRIPTS = frozenset({LUMEN_MATERIALIZER})
COMPONENT_KEYS = {"id", "path", "canonical_repository", "git_revision", "materialization_script"}


class FirstPartyValidationError(RuntimeError):
    pass


def _exporter():
    # Resolve our implementation, never a module supplied by the inspected repository.
    scripts = str(Path(__file__).resolve().parents[1])
    if scripts not in sys.path:
        sys.path.insert(0, scripts)
    import source_export_provenance
    return source_export_provenance


def declared_components(root: Path) -> list[dict[str, str]]:
    path = root / DECLARATION
    if not path.exists() and not path.is_symlink():
        return []
    exporter = _exporter()
    try:
        if path.lstat().st_size > 16 * 1024:
            raise FirstPartyValidationError("first-party declaration exceeds its size bound")
        value, _payload = exporter._load_canonical_json(path)
        if (set(value) != {"schema_version", "components"}
                or type(value["schema_version"]) is not int or value["schema_version"] != 1
                or not isinstance(value["components"], list) or len(value["components"]) != 1):
            raise FirstPartyValidationError("first-party declaration has an unsupported schema")
        component = value["components"][0]
        expected = {
            "id": "lumen", "path": "ThirdParty/Lumen",
            "canonical_repository": "https://github.com/jdotc1/Lumen.git",
            "materialization_script": LUMEN_MATERIALIZER,
        }
        if (not isinstance(component, dict) or set(component) != COMPONENT_KEYS
                or any(component.get(key) != item for key, item in expected.items())
                or not isinstance(component["git_revision"], str)
                or re.fullmatch(r"[0-9a-f]{40}", component["git_revision"]) is None):
            raise FirstPartyValidationError("first-party declaration is not the reviewed Lumen boundary")
        return [component]
    except (exporter.SourceExportError, OSError) as error:
        raise FirstPartyValidationError(str(error)) from error


def _check_modules(components: list[dict[str, str]], modules: list[dict[str, str]]) -> None:
    expected = {(item["path"], item["canonical_repository"], item["git_revision"]) for item in components}
    observed = {(item["path"], item["url"], item["commit_oid"]) for item in modules}
    if observed != expected or len(modules) != len(components):
        raise FirstPartyValidationError("canonical submodules do not match the first-party declaration")


def verified_component_roots(root: Path) -> frozenset[str]:
    components = declared_components(root)
    if not components:
        return frozenset()
    exporter = _exporter()
    try:
        if (root / ".git").exists():
            # The declaration itself must be tracked and unchanged; unrelated development
            # edits are allowed. Submodule authority is checked independently by the exporter.
            canonical = exporter._git(root, "show", f"HEAD:{DECLARATION}")
            staged = exporter._git(root, "diff", "--cached", "--quiet", "HEAD", "--", DECLARATION)
            if (canonical.returncode or staged.returncode
                    or canonical.stdout != exporter._read_stable_bounded_file(root / DECLARATION, 16 * 1024, DECLARATION)):
                raise FirstPartyValidationError("first-party declaration must match HEAD and index")
            groups = exporter.canonical_git_submodule_inventory(root)
            _check_modules(components, [metadata for _path, _entries, metadata in groups])
            # Git status alone can be blinded by assume-unchanged/skip-worktree.
            # Hash only this small first-party closure, never the large vendor trees.
            for module_root, entries, metadata in groups:
                for relative, mode, blob in entries:
                    _digest, _size, actual_blob, binding = exporter._ordinary_file_identity(
                        exporter._require_safe_relative_file(module_root, relative))
                    permissions = 0o755 if mode == "100755" else 0o644
                    actual_permissions = stat.S_IMODE(binding[2])
                    # Name the attribute: byte-identical files with a umask-made
                    # 0600 mode must not read like a content change.
                    differences = []
                    if actual_blob != blob:
                        differences.append("content differs")
                    if actual_permissions != permissions:
                        differences.append(f"mode is {actual_permissions:04o}, pinned {mode} requires {permissions:04o}"
                                           + ("" if differences else " (content matches)"))
                    if differences:
                        raise FirstPartyValidationError(
                            f"first-party payload differs from its pinned Git blob: "
                            f"{metadata['path']}/{relative}: {'; '.join(differences)}")
        else:
            manifest, manifest_bytes = exporter._load_canonical_json(root / exporter.FILES_NAME)
            records = exporter._validated_file_records(manifest)
            modules = exporter.validated_submodules(manifest)
            _check_modules(components, modules)
            parent_records = exporter._parent_tree_records(root, records, modules)
            provenance, _ = exporter._load_canonical_json(root / exporter.PROVENANCE_NAME)
            commit = exporter._read_exported_commit_object(root / exporter.COMMIT_OBJECT_NAME)
            tree, parents = exporter._commit_object_identity(commit)
            if (provenance.get("git_head_commit") != exporter._commit_object_oid(commit)
                    or provenance.get("canonical_integration_commit") != provenance.get("git_head_commit")
                    or provenance.get("git_head_tree") != tree
                    or provenance.get("git_parent_commits") != parents
                    or provenance.get("repository_clean") is not True
                    or provenance.get("source_file_count") != len(records)
                    or provenance.get("source_files_sha256") != hashlib.sha256(manifest_bytes).hexdigest()
                    or exporter._reconstructed_tree_oid(parent_records) != tree):
                raise FirstPartyValidationError("first-party export metadata does not bind its parent commit")
            roots = tuple(item["path"] + "/" for item in components)
            selected = [item for item in records if item["path"] == DECLARATION or str(item["path"]).startswith(roots)]
            if not any(item["path"] == DECLARATION for item in selected):
                raise FirstPartyValidationError("first-party declaration is absent from the source manifest")
            exporter._verify_exported_records(root, selected)
            expected_files = {str(item["path"]) for item in selected if item["path"] != DECLARATION}
            observed_files: set[str] = set()
            for component in components:
                for directory, directories, files in os.walk(root / component["path"], followlinks=False):
                    for name in directories + files:
                        candidate = Path(directory) / name
                        mode = candidate.lstat().st_mode
                        if stat.S_ISREG(mode):
                            observed_files.add(candidate.relative_to(root).as_posix())
                        elif not stat.S_ISDIR(mode):
                            raise FirstPartyValidationError("first-party export contains a nonordinary path")
            if observed_files != expected_files:
                raise FirstPartyValidationError("first-party export contains an unmanifested or missing file")
        return frozenset(item["path"] for item in components)
    except (exporter.SourceExportError, OSError, ValueError, KeyError) as error:
        raise FirstPartyValidationError(str(error)) from error
