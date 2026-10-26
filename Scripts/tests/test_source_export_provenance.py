#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import base64
import importlib.util
import json
import os
import shutil
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
TOOL = REPOSITORY_ROOT / "Scripts/source_export_provenance.py"


def load_tool_module():
    specification = importlib.util.spec_from_file_location(
        "source_export_provenance",
        TOOL,
    )
    assert specification is not None and specification.loader is not None
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def canonical_json(value: object) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=True,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        + "\n"
    ).encode("utf-8")


def git_blob_oid(payload: bytes) -> str:
    digest = hashlib.sha1()
    digest.update(f"blob {len(payload)}\0".encode("ascii"))
    digest.update(payload)
    return digest.hexdigest()


def rewrite_source_manifest(exported: Path, files: dict[str, object]) -> None:
    files_bytes = canonical_json(files)
    (exported / "SOURCE_FILES.json").write_bytes(files_bytes)
    provenance_path = exported / "SOURCE_PROVENANCE.json"
    provenance = json.loads(provenance_path.read_bytes())
    provenance["source_files_sha256"] = hashlib.sha256(files_bytes).hexdigest()
    provenance_path.write_bytes(canonical_json(provenance))


def run(*arguments: str, cwd: Path | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [*arguments],
        cwd=cwd,
        check=False,
        capture_output=True,
        text=True,
    )


class ReuseLayoutTests(unittest.TestCase):
    def test_concurrent_creation_validates_every_directory(self):
        tool = load_tool_module()
        original_mkdir = Path.mkdir
        for unsafe in (False, True):
            for target_index in range(6):
                with self.subTest(unsafe=unsafe, target_index=target_index):
                    with tempfile.TemporaryDirectory() as temporary:
                        root = Path(temporary).resolve()
                        created = []

                        def raced_mkdir(path, mode=0o777, parents=False, exist_ok=False):
                            created.append(path)
                            # Simulate another gate winning creation after the
                            # existence check, including an unsafe raced entry.
                            original_mkdir(path, mode=mode, parents=parents)
                            if unsafe and len(created) - 1 == target_index:
                                path.chmod(0o777)
                            return original_mkdir(path, mode=mode, parents=parents, exist_ok=exist_ok)

                        with mock.patch.object(Path, "mkdir", raced_mkdir):
                            if unsafe:
                                with self.assertRaisesRegex(tool.SourceExportError, "cache layout"):
                                    tool._reuse_layout(root)
                                self.assertEqual(len(created), target_index + 1)
                            else:
                                layout = tool._reuse_layout(root)
                                self.assertEqual(len(created), 6)
                                self.assertEqual(set(layout), {"entries", "locks", "temporary", "quarantine"})

    def test_existing_layout_rejects_links_files_and_writable_directories(self):
        tool = load_tool_module()
        for kind in ("symlink", "file", "writable"):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                entry = root / "source-exports"
                if kind == "symlink":
                    target = root / "target"
                    target.mkdir()
                    entry.symlink_to(target, target_is_directory=True)
                elif kind == "file":
                    entry.write_text("not a directory")
                else:
                    entry.mkdir()
                    entry.chmod(0o777)
                with self.assertRaisesRegex(tool.SourceExportError, "cache layout"):
                    tool._reuse_layout(root)


class SourceRepository:
    def __init__(self, root: Path) -> None:
        self.root = root
        run("/usr/bin/git", "init", "-b", "main", str(root))
        run("/usr/bin/git", "config", "user.email", "base02@example.invalid", cwd=root)
        run("/usr/bin/git", "config", "user.name", "BASE-02 Fixture", cwd=root)
        run(
            "/usr/bin/git",
            "remote",
            "add",
            "origin",
            "https://github.com/example/MacScope.git",
            cwd=root,
        )
        run(
            "/usr/bin/git",
            "remote",
            "add",
            "gitfox-local",
            str(root.parent / "MacScope.git"),
            cwd=root,
        )
        self.write("MacScope/App/Main.swift", "print(\"fixture\")\n")
        self.write("Scripts/tool.sh", "#!/bin/sh\nexit 0\n", executable=True)
        self.write("MacScope/App/__pycache__/Tracked.swift", "let tracked = true\n")
        self.write("MacScope/App/Tracked.pyc", "tracked bytecode fixture\n")
        self.write("THIRD_PARTY_NOTICES.md", "# Fixture notices\n")
        self.write(
            "THIRD_PARTY_COMPONENTS.yml",
            json.dumps(
                {
                    "schema_version": 1,
                    "distribution_policy": {
                        "status": "private-development-only",
                        "public_distribution_approved": False,
                        "decision_record": "docs/dependencies/LicenseDecision.md",
                    },
                    "components": [
                        {
                            "id": "fixture-dependency",
                            "pin": {
                                "version": "1.2.3",
                                "source_sha256": "a" * 64,
                            },
                        }
                    ],
                },
                sort_keys=True,
                indent=2,
            )
            + "\n",
        )
        result = run("/usr/bin/git", "add", ".", cwd=root)
        if result.returncode != 0:
            raise AssertionError(result.stderr)
        result = run(
            "/usr/bin/git",
            "commit",
            "-m",
            "fixture source",
            cwd=root,
        )
        if result.returncode != 0:
            raise AssertionError(result.stderr)
        head = self.git("rev-parse", "HEAD")
        run(
            "/usr/bin/git",
            "update-ref",
            "refs/remotes/gitfox-local/feature/task11-local-premerge-current",
            head,
            cwd=root,
        )

    def write(self, relative: str, contents: str, *, executable: bool = False) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
        if executable:
            path.chmod(0o755)

    def git(self, *arguments: str) -> str:
        result = run("/usr/bin/git", *arguments, cwd=self.root)
        if result.returncode != 0:
            raise AssertionError(result.stderr)
        return result.stdout.strip()

    def export(self, destination: Path) -> subprocess.CompletedProcess[str]:
        return run(
            "/usr/bin/python3",
            str(TOOL),
            "create",
            "--repository-root",
            str(self.root),
            "--destination",
            str(destination),
            "--integration-ref",
            "refs/remotes/gitfox-local/feature/task11-local-premerge-current",
        )


class GitStageTests(unittest.TestCase):
    """D1: Git-identity admission and one directory clone, no re-verification."""

    REF = "refs/remotes/gitfox-local/feature/task11-local-premerge-current"

    def stage(self, source: "SourceRepository", destination: Path, cache: Path, *extra: str):
        return run("/usr/bin/python3", str(TOOL), "git-stage", "--repository-root", str(source.root),
                   "--destination", str(destination), "--integration-ref", self.REF,
                   "--record-cache", str(cache), *extra)

    def test_stage_matches_the_canonical_export_records(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            source = SourceRepository(base / "source")
            (source.root / "ignored.log").write_text("ignored\n")
            source.write(".gitignore", "*.log\n")
            source.git("add", ".gitignore")
            source.git("commit", "-m", "ignore logs")
            source.git("update-ref", self.REF, "HEAD")
            staged = base / "staged"
            result = self.stage(source, staged, base / "cache")
            self.assertEqual(result.returncode, 0, result.stderr)
            exported = base / "export"
            self.assertEqual(source.export(exported).returncode, 0)
            for name in ("SOURCE_FILES.json", "SOURCE_PROVENANCE.json", "SOURCE_COMMIT_OBJECT"):
                self.assertEqual((staged / name).read_bytes(), (exported / name).read_bytes(), name)
            self.assertFalse((staged / ".git").exists())
            self.assertFalse((staged / "ignored.log").exists())
            self.assertTrue(os.access(staged / "Scripts/tool.sh", os.X_OK))

    def test_stage_requires_clean_head_at_the_expected_commit(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            source = SourceRepository(base / "source")
            wrong = self.stage(source, base / "wrong", base / "cache", "--expected-commit", "0" * 40)
            self.assertNotEqual(wrong.returncode, 0)
            self.assertIn("expected integration commit", wrong.stderr)
            source.write("untracked.txt", "dirty\n")
            dirty = self.stage(source, base / "dirty", base / "cache")
            self.assertNotEqual(dirty.returncode, 0)
            self.assertIn("clean Git worktree", dirty.stderr)
            self.assertFalse((base / "dirty").exists())

    def test_sha256_is_computed_once_per_blob_and_trusted_by_key(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            source = SourceRepository(base / "source")
            cache = base / "cache"
            self.assertEqual(self.stage(source, base / "one", cache).returncode, 0)
            memo_path = cache / "git-blob-sha256.v1.json"
            memo = json.loads(memo_path.read_bytes())
            oid = source.git("rev-parse", "HEAD:MacScope/App/Main.swift")
            memo["blobs"][oid][0] = "f" * 64
            memo_path.write_text(json.dumps(memo))
            self.assertEqual(self.stage(source, base / "two", cache).returncode, 0)
            records = {record["path"]: record for record in
                       json.loads((base / "two/SOURCE_FILES.json").read_bytes())["files"]}
            self.assertEqual(records["MacScope/App/Main.swift"]["sha256"], "f" * 64)


class SourceExportProvenanceTests(unittest.TestCase):
    def submodule_fixture(self, base: Path):
        source = SourceRepository(base / "source")
        dependency = SourceRepository(base / "dependency")
        dependency.write(".gitattributes", "*.txt text eol=crlf\n")
        dependency.write("Canonical.txt", "one\ntwo\n")
        dependency.git("add", ".")
        dependency.git("commit", "-m", "canonical submodule fixture")
        source.git("-c", "protocol.file.allow=always", "submodule", "add",
                   str(dependency.root), "ThirdParty/Fixture/Source")
        # The tracked canonical URL is authority, not the local materialization remote.
        source.git("config", "-f", ".gitmodules", "submodule.ThirdParty/Fixture/Source.url",
                   "https://github.com/example/Fixture.git")
        source.git("add", ".")
        source.git("commit", "-m", "pin first-level submodule")
        source.git("update-ref", "refs/remotes/gitfox-local/feature/task11-local-premerge-current", "HEAD")
        return source, source.root / "ThirdParty/Fixture/Source", dependency

    def test_submodule_export_binds_canonical_blobs_and_verifies_without_git(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            source, materialized, dependency = self.submodule_fixture(base)
            self.assertEqual((materialized / "Canonical.txt").read_bytes(), b"one\r\ntwo\r\n")
            exported = base / "export"
            result = source.export(exported)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((exported / "ThirdParty/Fixture/Source/Canonical.txt").read_bytes(), b"one\ntwo\n")
            manifest = json.loads((exported / "SOURCE_FILES.json").read_bytes())
            submodule = manifest["submodules"][0]
            self.assertEqual(submodule["path"], "ThirdParty/Fixture/Source")
            self.assertEqual(submodule["url"], "https://github.com/example/Fixture.git")
            self.assertEqual(submodule["commit_oid"], dependency.git("rev-parse", "HEAD"))
            self.assertEqual(submodule["tree_oid"], dependency.git("rev-parse", "HEAD^{tree}"))
            commit_bytes = base64.b64decode(submodule["commit_object_base64"], validate=True)
            self.assertEqual(commit_bytes.decode(), dependency.git("cat-file", "commit", "HEAD") + "\n")
            module = load_tool_module()
            with mock.patch.object(module.subprocess, "run", side_effect=AssertionError("verification must not invoke Git")):
                provenance, records = module.load_verified_export(exported)
            self.assertIn("ThirdParty/Fixture/Source/Canonical.txt", records)
            self.assertEqual(provenance["dependency_contract"]["source_export_package"]["version"], 5)
            self.assertEqual(provenance["git_head_tree"], source.git("rev-parse", "HEAD^{tree}"))
            self.assertFalse((exported / "ThirdParty/Fixture/Source/.git").exists())
            again = base / "again"
            self.assertEqual(source.export(again).returncode, 0)
            self.assertEqual((again / "SOURCE_FILES.json").read_bytes(), (exported / "SOURCE_FILES.json").read_bytes())

    def test_canonical_git_file_entries_flattens_pinned_submodule_without_checkout_writes(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            source, materialized, dependency = self.submodule_fixture(base)
            module = load_tool_module()
            before = (materialized / "Canonical.txt").read_bytes()
            entries = module.canonical_git_file_entries(source.root)
            self.assertEqual(entries["ThirdParty/Fixture/Source/Canonical.txt"],
                             ("100644", dependency.git("rev-parse", "HEAD:Canonical.txt")))
            self.assertNotIn("ThirdParty/Fixture/Source", entries)
            self.assertEqual((materialized / "Canonical.txt").read_bytes(), before)
            self.assertEqual(source.git("status", "--porcelain"), "")
            (materialized / "Canonical.txt").write_bytes(b"dirty\n")
            with self.assertRaises(module.SourceExportError):
                module.canonical_git_file_entries(source.root)
            self.assertEqual(run("/usr/bin/git", "restore", "--", "Canonical.txt", cwd=materialized).returncode, 0)
            self.assertEqual(run("/usr/bin/git", "checkout", "--detach", "HEAD^", cwd=materialized).returncode, 0)
            with self.assertRaises(module.SourceExportError):
                module.canonical_git_file_entries(source.root)

    def test_gitmodule_parser_rejects_values_with_ambiguous_git_syntax(self):
        module = load_tool_module()
        cases = [
            ("https://example.com/repo.git#comment", "https://example.com/repo.git"),
            ("https://example.com/repo.git;comment", "https://example.com/repo.git"),
            ('https://example.com/"repo".git', "https://example.com/repo.git"),
            (r'"https://example.com/repo\/name.git"', None),
            (r'"https://example.com/\u0072epo.git"', None),
        ]
        for value, git_value in cases:
            with self.subTest(value=value):
                payload = ('[submodule "fixture"]\npath = ThirdParty/Fixture\nurl = ' + value + '\n').encode()
                oracle = subprocess.run(["/usr/bin/git", "config", "--file", "-", "--get", "submodule.fixture.url"],
                                        input=payload, capture_output=True)
                if git_value is None:
                    self.assertNotEqual(oracle.returncode, 0)
                else:
                    self.assertEqual(oracle.returncode, 0)
                    self.assertEqual(oracle.stdout.decode().strip(), git_value)
                with self.assertRaises(module.SourceExportError):
                    module._parse_gitmodule_mapping(payload)

    def test_gitmodule_parser_accepts_canonical_quoted_values_without_git(self):
        module = load_tool_module()
        payload = b'[submodule "fixture"]\npath = "ThirdParty/Fixture"\nurl = "https://example.com/repo.git#literal;literal"\n'
        oracle = subprocess.run(["/usr/bin/git", "config", "--file", "-", "--get", "submodule.fixture.url"],
                                input=payload, capture_output=True)
        self.assertEqual(oracle.returncode, 0)
        with mock.patch.object(module.subprocess, "run", side_effect=AssertionError("parser must not invoke Git")):
            self.assertEqual(module._parse_gitmodule_mapping(payload),
                             {"ThirdParty/Fixture": oracle.stdout.decode().strip()})

    def test_submodule_mapping_read_must_match_manifest_blob_before_parsing(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            source, _materialized, _dependency = self.submodule_fixture(base)
            exported = base / "exported"
            self.assertEqual(source.export(exported).returncode, 0)
            manifest = json.loads((exported / "SOURCE_FILES.json").read_bytes())
            manifest["submodules"][0]["url"] = "https://github.com/example/Forged.git"
            rewrite_source_manifest(exported, manifest)
            module = load_tool_module()
            original_read = module._read_stable_bounded_file
            substituted = False

            def transient_mapping(path, *args, **kwargs):
                nonlocal substituted
                payload = original_read(path, *args, **kwargs)
                if path.name == ".gitmodules" and not substituted:
                    substituted = True
                    return payload.replace(b"Fixture.git", b"Forged.git")
                return payload

            with mock.patch.object(module, "_read_stable_bounded_file", side_effect=transient_mapping):
                with self.assertRaises(module.SourceExportError):
                    module.verify_export(exported)
            self.assertTrue(substituted)

    def test_submodule_inventory_allows_unrelated_parent_changes_but_not_mapping_or_gitlinks(self):
        for mutation in ("unrelated", "mapping-working", "mapping-index", "gitlink-index"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary).resolve()
                source, materialized, dependency = self.submodule_fixture(base)
                module = load_tool_module()
                if mutation == "unrelated":
                    source.write("MacScope/App/Main.swift", "print(\"development edit\")\n")
                    groups = module.canonical_git_submodule_inventory(source.root)
                    self.assertEqual(len(groups), 1)
                    module_root, entries, metadata = groups[0]
                    self.assertEqual(module_root, materialized)
                    self.assertIn(("Canonical.txt", "100644", dependency.git("rev-parse", "HEAD:Canonical.txt")), entries)
                    self.assertEqual(metadata["commit_oid"], dependency.git("rev-parse", "HEAD"))
                else:
                    if mutation.startswith("mapping"):
                        source.git("config", "-f", ".gitmodules", "submodule.ThirdParty/Fixture/Source.url", "https://example.invalid/changed.git")
                        if mutation == "mapping-index":
                            source.git("add", ".gitmodules")
                            # A matching HEAD worktree must not hide a distinct staged mapping.
                            (source.root / ".gitmodules").write_text(source.git("show", "HEAD:.gitmodules") + "\n")
                    else:
                        source.git("update-index", "--cacheinfo", "160000," + dependency.git("rev-parse", "HEAD^") + ",ThirdParty/Fixture/Source")
                    with self.assertRaises(module.SourceExportError):
                        module.canonical_git_submodule_inventory(source.root)
    def test_submodule_export_rejects_unmaterialized_dirty_wrong_pin_and_unsafe_files(self):
        for mutation in ("missing", "dirty", "wrong-pin", "root-symlink", "file-symlink", "hardlink", "fifo"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary).resolve()
                source, materialized, dependency = self.submodule_fixture(base)
                # Even local configuration asking Git to ignore module dirt cannot waive checks.
                source.git("config", "submodule.ThirdParty/Fixture/Source.ignore", "all")
                path = materialized / "Canonical.txt"
                if mutation == "missing":
                    shutil.rmtree(materialized)
                    materialized.mkdir()
                elif mutation == "dirty":
                    path.write_bytes(b"dirty\n")
                elif mutation == "wrong-pin":
                    self.assertEqual(run("/usr/bin/git", "checkout", "--detach", "HEAD^", cwd=materialized).returncode, 0)
                elif mutation == "root-symlink":
                    shutil.rmtree(materialized)
                    materialized.symlink_to(dependency.root, target_is_directory=True)
                else:
                    # Hide status changes to specifically exercise physical-file safety checks.
                    self.assertEqual(run("/usr/bin/git", "update-index", "--assume-unchanged", "Canonical.txt", cwd=materialized).returncode, 0)
                    path.unlink()
                    if mutation == "file-symlink":
                        path.symlink_to(dependency.root / "Canonical.txt")
                    elif mutation == "hardlink":
                        os.link(dependency.root / "Canonical.txt", path)
                    else:
                        os.mkfifo(path)
                result = source.export(base / "export")
                self.assertNotEqual(result.returncode, 0, mutation)

    def test_submodule_export_rejects_nested_gitlinks_and_gitmodules_mapping_drift(self):
        for mutation in ("nested", "missing-map", "extra-map", "duplicate-map", "unsafe-path"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary).resolve()
                source, materialized, dependency = self.submodule_fixture(base)
                if mutation == "nested":
                    for args in [
                        ("config", "user.email", "fixture@example.invalid"),
                        ("config", "user.name", "Fixture"),
                        ("update-index", "--add", "--cacheinfo", "160000," + dependency.git("rev-parse", "HEAD") + ",nested"),
                        ("commit", "-m", "nested gitlink"),
                    ]:
                        result = run("/usr/bin/git", *args, cwd=materialized)
                        self.assertEqual(result.returncode, 0, result.stderr)
                elif mutation == "missing-map":
                    source.git("rm", ".gitmodules")
                elif mutation == "extra-map":
                    with (source.root / ".gitmodules").open("a") as stream:
                        stream.write('[submodule "extra"]\n\tpath = ThirdParty/Extra\n\turl = https://example.invalid/extra.git\n')
                elif mutation == "duplicate-map":
                    with (source.root / ".gitmodules").open("a") as stream:
                        stream.write('[submodule "duplicate"]\n\tpath = ThirdParty/Fixture/Source\n\turl = https://example.invalid/other.git\n')
                else:
                    source.git("config", "-f", ".gitmodules", "submodule.ThirdParty/Fixture/Source.path", "../escape")
                source.git("add", "-A")
                source.git("commit", "-m", "malformed submodule fixture")
                source.git("update-ref", "refs/remotes/gitfox-local/feature/task11-local-premerge-current", "HEAD")
                result = source.export(base / "export")
                self.assertNotEqual(result.returncode, 0, mutation)

    def test_submodule_export_rejects_rebound_file_commit_tree_gitlink_and_url(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            source, _materialized, _dependency = self.submodule_fixture(base)
            sealed = base / "sealed"
            result = source.export(sealed)
            self.assertEqual(result.returncode, 0, result.stderr)
            module = load_tool_module()
            for mutation in ("file", "commit", "tree", "gitlink", "url", "removed", "duplicate", "overlap", "path", "gitmodules"):
                with self.subTest(mutation=mutation):
                    exported = base / mutation
                    shutil.copytree(sealed, exported)
                    manifest = json.loads((exported / "SOURCE_FILES.json").read_bytes())
                    submodule = manifest["submodules"][0]
                    if mutation in {"file", "gitmodules"}:
                        relative = "ThirdParty/Fixture/Source/Canonical.txt" if mutation == "file" else ".gitmodules"
                        path = exported / relative
                        payload = b"rebound bytes\n" if mutation == "file" else path.read_bytes().replace(b"Fixture.git", b"Other.git")
                        path.write_bytes(payload)
                        entry = next(entry for entry in manifest["files"] if entry["path"] == relative)
                        entry.update(size=len(payload), sha256=hashlib.sha256(payload).hexdigest(), blob_oid=git_blob_oid(payload))
                        if mutation == "gitmodules":
                            submodule["url"] = "https://github.com/example/Other.git"
                    elif mutation == "commit":
                        raw = base64.b64decode(submodule["commit_object_base64"]) + b"forged message\n"
                        submodule["commit_object_base64"] = base64.b64encode(raw).decode()
                    elif mutation == "tree":
                        submodule["tree_oid"] = "0" * 40
                    elif mutation == "gitlink":
                        # Self-consistent replacement commit and subtree still cannot change the parent's gitlink.
                        raw = base64.b64decode(submodule["commit_object_base64"]) + b"replacement message\n"
                        submodule["commit_object_base64"] = base64.b64encode(raw).decode()
                        submodule["commit_oid"] = hashlib.sha1(f"commit {len(raw)}\0".encode() + raw).hexdigest()
                    elif mutation == "url":
                        submodule["url"] = "https://example.invalid/other.git"
                    elif mutation == "removed":
                        del manifest["submodules"]
                    elif mutation == "duplicate":
                        manifest["submodules"].append(dict(submodule))
                    elif mutation == "overlap":
                        manifest["submodules"].append({**submodule, "path": submodule["path"] + "/nested"})
                    else:
                        submodule["path"] = "../escape"
                    rewrite_source_manifest(exported, manifest)
                    with self.assertRaises(module.SourceExportError):
                        module.verify_export(exported)

    def test_submodule_exports_reject_payload_links_and_special_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            source, _materialized, _dependency = self.submodule_fixture(base)
            sealed = base / "sealed"
            self.assertEqual(source.export(sealed).returncode, 0)
            module = load_tool_module()
            for mutation in ("missing", "symlink", "hardlink", "fifo", "ancestor", "extra"):
                with self.subTest(mutation=mutation):
                    exported = base / mutation
                    shutil.copytree(sealed, exported)
                    path = exported / "ThirdParty/Fixture/Source/Canonical.txt"
                    if mutation == "extra":
                        (path.parent / "unmanifested").write_text("unexpected")
                    elif mutation == "ancestor":
                        old = path.parent
                        moved = base / "moved-submodule"
                        old.rename(moved)
                        old.symlink_to(moved, target_is_directory=True)
                    else:
                        path.unlink()
                        if mutation == "symlink": path.symlink_to(sealed / "ThirdParty/Fixture/Source/Canonical.txt")
                        elif mutation == "hardlink": os.link(sealed / "ThirdParty/Fixture/Source/Canonical.txt", path)
                        elif mutation == "fifo": os.mkfifo(path)
                    with self.assertRaises((module.SourceExportError, OSError)):
                        module.verify_export(exported)

    def test_submodule_bounds_include_parent_and_module_payloads(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            source, _materialized, _dependency = self.submodule_fixture(base)
            sealed = base / "sealed"
            self.assertEqual(source.export(sealed).returncode, 0)
            manifest = json.loads((sealed / "SOURCE_FILES.json").read_bytes())
            total_bytes = sum(record["size"] for record in manifest["files"])
            module = load_tool_module()
            for key, bound in (("MAX_FILES", len(manifest["files"])),
                               ("MAX_TOTAL_BYTES", total_bytes - 1),
                               ("MAX_SUBMODULE_COMMIT_BYTES", 1),
                               ("MAX_SUBMODULES", 0)):
                with self.subTest(bound=key), mock.patch.object(module, key, bound):
                    with self.assertRaises(module.SourceExportError):
                        module.create_export(source.root, base / key, "refs/remotes/gitfox-local/feature/task11-local-premerge-current")
                    with self.assertRaises(module.SourceExportError):
                        module.verify_export(sealed)


    def lfs_fixture(self, root, relative, payload=b"offline materialized payload", pointer=None):
        module = load_tool_module()
        source = SourceRepository(root)
        pointer = pointer if pointer is not None else module._lfs_pointer(hashlib.sha256(payload).hexdigest(), len(payload))
        source.write(relative, pointer.decode("ascii"), executable=relative.endswith("/zig"))
        source.git("add", relative)
        source.git("commit", "-m", "pointer fixture")
        source.git("update-ref", "refs/remotes/gitfox-local/feature/task11-local-premerge-current", "HEAD")
        # Model a clean, already-materialized checkout without installing filters or
        # invoking git-lfs. Payload admission still must prove the committed hash.
        source.git("update-index", "--assume-unchanged", relative)
        (root / relative).write_bytes(payload)
        return module, source, pointer

    def test_allowlisted_lfs_payloads_preserve_git_identity_and_verify_without_git(self):
        for relative in sorted(load_tool_module().LFS_PATHS):
            with self.subTest(path=relative), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary).resolve()
                module, source, pointer = self.lfs_fixture(base / "repo", relative)
                exported = base / "export"
                self.assertEqual(source.export(exported).returncode, 0)
                provenance, records = module.load_verified_export(exported)
                record = records[relative]
                self.assertEqual(record["blob_oid"], git_blob_oid(pointer))
                self.assertEqual(record["size"], len(b"offline materialized payload"))
                self.assertEqual(provenance["git_head_tree"], source.git("rev-parse", "HEAD^{tree}"))
                self.assertEqual(provenance["dependency_contract"]["source_export_package"]["version"], 4)
                clone = base / "clone"
                shutil.copytree(exported, clone)
                self.assertEqual(module.verify_export(clone), provenance)
                (exported / relative).write_bytes(b"wrong materialized payload")
                with self.assertRaises(module.SourceExportError):
                    module.verify_export(exported)

    def test_lfs_rejects_unknown_and_noncanonical_pointers(self):
        module = load_tool_module()
        canonical = module._lfs_pointer(hashlib.sha256(b"payload").hexdigest(), 7)
        for relative, pointer in [
            ("ThirdParty/Unknown/tool", canonical),
            ("ThirdParty/Zig/zig-0.16.0/zig", canonical.replace(b"\n", b"\r\n")),
            ("ThirdParty/Zig/zig-0.16.0/zig", canonical + b"\n"),
            ("ThirdParty/Zig/zig-0.16.0/zig", canonical + b"ext-0-custom value\n"),
        ]:
            with self.subTest(pointer=pointer), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary).resolve()
                _, source, _ = self.lfs_fixture(base / "repo", relative, b"payload", pointer)
                self.assertNotEqual(source.export(base / "export").returncode, 0)

    def test_verifier_rejects_raw_pointer_even_when_its_physical_blob_matches_manifest(self):
        module = load_tool_module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            relative = "ThirdParty/Zig/zig-0.16.0/zig"
            path = root / relative
            path.parent.mkdir(parents=True)
            pointer = module._lfs_pointer(hashlib.sha256(b"payload").hexdigest(), 7)
            path.write_bytes(pointer)
            path.chmod(0o755)
            record = {"path": relative, "mode": "100755", "blob_oid": git_blob_oid(pointer),
                      "sha256": hashlib.sha256(pointer).hexdigest(), "size": len(pointer)}
            with self.assertRaisesRegex(module.SourceExportError, "unmaterialized"):
                module._verify_exported_records(root, [record])

    def test_lfs_manifest_payload_digest_or_size_cannot_change_committed_pointer_authority(self):
        for field in ("sha256", "size", "blob_oid"):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary).resolve()
                relative = "ThirdParty/Zig/zig-0.16.0/zig"
                module, source, _ = self.lfs_fixture(base / "repo", relative)
                exported = base / "export"
                self.assertEqual(source.export(exported).returncode, 0)
                manifest = json.loads((exported / "SOURCE_FILES.json").read_bytes())
                record = next(record for record in manifest["files"] if record["path"] == relative)
                record[field] = record[field] + 1 if field == "size" else "0" * len(record[field])
                rewrite_source_manifest(exported, manifest)
                with self.assertRaises(module.SourceExportError):
                    module.verify_export(exported)

    def test_lfs_rejects_unmaterialized_wrong_missing_linked_and_wrong_mode_inputs(self):
        relative = "ThirdParty/Zig/zig-0.16.0/zig"
        for mutation in ("pointer", "digest", "size", "missing", "symlink", "hardlink", "mode", "ancestor"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary).resolve()
                _, source, pointer = self.lfs_fixture(base / "repo", relative)
                path = source.root / relative
                if mutation == "pointer": path.write_bytes(pointer)
                elif mutation == "digest": path.write_bytes(b"x" * path.stat().st_size)
                elif mutation == "size": path.write_bytes(b"short")
                elif mutation == "missing": path.unlink()
                elif mutation == "mode": path.chmod(0o644)
                elif mutation == "hardlink": os.link(path, base / "linked")
                elif mutation == "ancestor":
                    moved = base / "moved"
                    path.parent.rename(moved)
                    path.parent.symlink_to(moved, target_is_directory=True)
                else:
                    real = base / "real"
                    path.rename(real)
                    path.symlink_to(real)
                self.assertNotEqual(source.export(base / "export").returncode, 0)

    def test_lfs_payload_mutation_during_copy_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            relative = "ThirdParty/Zig/zig-0.16.0/zig"
            module, source, _ = self.lfs_fixture(base / "repo", relative)
            output = base / "output"
            output.touch()
            actual_read = os.read
            mutated = False
            def changing_read(descriptor, count):
                nonlocal mutated
                result = actual_read(descriptor, count)
                if not mutated:
                    mutated = True
                    (source.root / relative).write_bytes(b"offline materialized payload")
                return result
            with output.open("wb") as target, mock.patch.object(module.os, "read", side_effect=changing_read):
                with self.assertRaisesRegex(module.SourceExportError, "changed"):
                    module._copy_lfs_payload(source.root, relative, target.fileno(), "100755",
                        hashlib.sha256(b"offline materialized payload").hexdigest(), 28)

    def test_lfs_physical_payloads_count_toward_aggregate_export_bound(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            paths = sorted(load_tool_module().LFS_PATHS)
            payload = b"x" * 256
            module, source, pointer = self.lfs_fixture(base / "repo", paths[0], payload)
            source.write(paths[1], pointer.decode("ascii"), executable=paths[1].endswith("/zig"))
            source.git("add", paths[1])
            source.git("commit", "-m", "second pointer")
            source.git("update-index", "--assume-unchanged", paths[1])
            (source.root / paths[1]).write_bytes(payload)
            entries = [entry for entry in module._tracked_entries(source.root, "HEAD") if entry[0] in paths]
            output = base / "export"
            output.mkdir()
            # Both individual payloads fit; together their physical bytes do not.
            with mock.patch.object(module, "MAX_TOTAL_BYTES", 400):
                with self.assertRaisesRegex(module.SourceExportError, "aggregate-size"):
                    module._copy_git_blobs(source.root, output, entries)

    def test_lfs_copy_does_not_reopen_swapped_output_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            relative = "ThirdParty/Zig/zig-0.16.0/zig"
            module, source, _ = self.lfs_fixture(base / "repo", relative)
            output = base / "export"
            outside = base / "outside"
            outside.write_bytes(b"preserve outside bytes")
            original_copy = module._copy_lfs_payload
            def swapped_copy(root, relative, target, mode, digest, size):
                path = output / relative
                path.rename(base / "original-output")
                os.link(outside, path)
                return original_copy(root, relative, target, mode, digest, size)
            with mock.patch.object(module, "_copy_lfs_payload", side_effect=swapped_copy):
                with self.assertRaisesRegex(module.SourceExportError, "output changed"):
                    module.create_export(source.root, output,
                        "refs/remotes/gitfox-local/feature/task11-local-premerge-current")
            self.assertEqual(outside.read_bytes(), b"preserve outside bytes")
            self.assertEqual(outside.stat().st_mode & 0o777, 0o644)

    def test_pre_lfs_ordinary_blob_at_allowlisted_path_still_exports(self):
        for contents in ("ordinary tool\n", ""):
            with self.subTest(contents=contents), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary).resolve()
                source = SourceRepository(base / "repo")
                relative = "ThirdParty/Zig/zig-0.16.0/zig"
                source.write(relative, contents, executable=True)
                source.git("add", relative)
                source.git("commit", "-m", "ordinary tool")
                source.git("update-ref", "refs/remotes/gitfox-local/feature/task11-local-premerge-current", "HEAD")
                self.assertEqual(source.export(base / "export").returncode, 0)

    def test_create_requires_an_explicit_fully_qualified_remote_ref(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = SourceRepository(root / "source")
            missing = run(
                "/usr/bin/python3",
                str(TOOL),
                "create",
                "--repository-root",
                str(source.root),
                "--destination",
                str(root / "missing"),
            )
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("--integration-ref", missing.stderr)

            abbreviated = run(
                "/usr/bin/python3",
                str(TOOL),
                "create",
                "--repository-root",
                str(source.root),
                "--destination",
                str(root / "abbreviated"),
                "--integration-ref",
                "origin/main",
            )
            self.assertNotEqual(abbreviated.returncode, 0)
            self.assertIn("fully-qualified refs/remotes", abbreviated.stderr)

            expression = run(
                "/usr/bin/python3",
                str(TOOL),
                "create",
                "--repository-root",
                str(source.root),
                "--destination",
                str(root / "expression"),
                "--integration-ref",
                "refs/remotes/gitfox-local/feature/task11-local-premerge-current~0",
            )
            self.assertNotEqual(expression.returncode, 0)
            self.assertIn("canonical Git", expression.stderr)

    def test_create_is_deterministic_and_verify_accepts_exact_export(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = SourceRepository(root / "source")
            first = root / "first"
            second = root / "second"

            first_result = source.export(first)
            second_result = source.export(second)
            self.assertEqual(first_result.returncode, 0, first_result.stderr)
            self.assertEqual(second_result.returncode, 0, second_result.stderr)
            self.assertFalse((first / ".git").exists())
            self.assertEqual(
                (first / "SOURCE_FILES.json").read_bytes(),
                (second / "SOURCE_FILES.json").read_bytes(),
            )
            self.assertEqual(
                (first / "SOURCE_PROVENANCE.json").read_bytes(),
                (second / "SOURCE_PROVENANCE.json").read_bytes(),
            )
            self.assertEqual(
                (first / "SOURCE_COMMIT_OBJECT").read_bytes(),
                (second / "SOURCE_COMMIT_OBJECT").read_bytes(),
            )
            verify = run(
                "/usr/bin/python3",
                str(TOOL),
                "verify",
                "--source-root",
                str(first),
            )
            self.assertEqual(verify.returncode, 0, verify.stderr)

            files = json.loads((first / "SOURCE_FILES.json").read_text())
            records = {record["path"]: record for record in files["files"]}
            self.assertIn("MacScope/App/__pycache__/Tracked.swift", records)
            self.assertIn("MacScope/App/Tracked.pyc", records)
            self.assertEqual(records["Scripts/tool.sh"]["mode"], "100755")
            self.assertEqual(
                records["Scripts/tool.sh"]["blob_oid"],
                source.git("rev-parse", "HEAD:Scripts/tool.sh"),
            )
            self.assertTrue(os.access(first / "Scripts/tool.sh", os.X_OK))

            provenance_bytes = (first / "SOURCE_PROVENANCE.json").read_bytes()
            provenance = json.loads(provenance_bytes)
            commit_object = subprocess.run(
                ["/usr/bin/git", "cat-file", "commit", provenance["git_head_commit"]],
                cwd=source.root,
                check=True,
                capture_output=True,
            ).stdout
            self.assertEqual(provenance["schema_version"], 2)
            self.assertEqual(
                provenance["dependency_contract"]["source_export_package"],
                {
                    "commit_object_name": "SOURCE_COMMIT_OBJECT",
                    "commit_object_sha256": hashlib.sha256(commit_object).hexdigest(),
                    "commit_object_size": len(commit_object),
                    "version": 4,
                },
            )
            self.assertEqual(provenance["git_head_commit"], source.git("rev-parse", "HEAD"))
            self.assertEqual(provenance["git_head_tree"], source.git("rev-parse", "HEAD^{tree}"))
            self.assertEqual(
                provenance["canonical_integration_commit"],
                source.git(
                    "rev-parse",
                    "refs/remotes/gitfox-local/feature/task11-local-premerge-current",
                ),
            )
            self.assertEqual(
                provenance["canonical_integration_ref"],
                "refs/remotes/gitfox-local/feature/task11-local-premerge-current",
            )
            self.assertEqual(
                provenance["canonical_remote_url"],
                str(source.root.parent / "MacScope.git"),
            )
            self.assertEqual(
                provenance["source_files_sha256"],
                hashlib.sha256((first / "SOURCE_FILES.json").read_bytes()).hexdigest(),
            )
            self.assertEqual(
                provenance["dependency_contract"]["component_pins"],
                [
                    {
                        "id": "fixture-dependency",
                        "pin": {"source_sha256": "a" * 64, "version": "1.2.3"},
                    }
                ],
            )
            self.assertEqual((first / "SOURCE_COMMIT_OBJECT").read_bytes(), commit_object)

    def test_create_exports_canonical_git_blob_instead_of_checkout_materialization(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = SourceRepository(root / "source")
            source.write(".gitattributes", "*.txt text eol=crlf\n")
            source.write("MacScope/App/Canonical.txt", "one\ntwo\n")
            source.git("add", ".gitattributes", "MacScope/App/Canonical.txt")
            source.git("commit", "-m", "add transformed fixture")
            source.git(
                "update-ref",
                "refs/remotes/gitfox-local/feature/task11-local-premerge-current",
                source.git("rev-parse", "HEAD"),
            )

            transformed = source.root / "MacScope/App/Canonical.txt"
            source.git("config", "core.autocrlf", "true")
            transformed.unlink()
            source.git("restore", "--", "MacScope/App/Canonical.txt")
            self.assertEqual(transformed.read_bytes(), b"one\r\ntwo\r\n")
            self.assertEqual(source.git("status", "--porcelain"), "")

            exported = root / "exported"
            result = source.export(exported)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                (exported / "MacScope/App/Canonical.txt").read_bytes(),
                b"one\ntwo\n",
            )
            files = json.loads((exported / "SOURCE_FILES.json").read_bytes())
            record = next(
                item
                for item in files["files"]
                if item["path"] == "MacScope/App/Canonical.txt"
            )
            self.assertEqual(
                record["blob_oid"],
                source.git("rev-parse", "HEAD:MacScope/App/Canonical.txt"),
            )

    def test_create_requires_head_to_match_integration_authority(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = SourceRepository(root / "source")
            source.write("MacScope/App/Later.swift", "let later = true\n")
            source.git("add", "MacScope/App/Later.swift")
            source.git("commit", "-m", "advance local head")

            result = source.export(root / "exported")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("authorized integration ref", result.stderr)

    def test_verify_rejects_mutation_and_unmanifested_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = SourceRepository(root / "source")
            exported = root / "exported"
            self.assertEqual(source.export(exported).returncode, 0)

            (exported / "MacScope/App/Main.swift").write_text("tampered\n")
            mutated = run(
                "/usr/bin/python3",
                str(TOOL),
                "verify",
                "--source-root",
                str(exported),
            )
            self.assertNotEqual(mutated.returncode, 0)
            self.assertIn("does not match", mutated.stderr)

            self.assertEqual(source.export(root / "clean-export").returncode, 0)
            clean_export = root / "clean-export"
            (clean_export / "MacScope/App/Injected.swift").write_text("injected\n")
            unmanifested = run(
                "/usr/bin/python3",
                str(TOOL),
                "verify",
                "--source-root",
                str(clean_export),
            )
            self.assertNotEqual(unmanifested.returncode, 0)
            self.assertIn("unmanifested", unmanifested.stderr)

    def test_verify_rejects_mutation_after_an_earlier_file_hash(self) -> None:
        module = load_tool_module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = SourceRepository(root / "source")
            exported = root / "exported"
            self.assertEqual(source.export(exported).returncode, 0)
            victim = exported / "MacScope/App/Main.swift"
            original_identity = module._ordinary_file_identity
            mutated = False

            def mutate_after_later_hash(path: Path):
                nonlocal mutated
                result = original_identity(path)
                if not mutated and path.name == "tool.sh":
                    victim.write_bytes(b"mutated after its earlier hash\n")
                    mutated = True
                return result

            with mock.patch.object(
                module,
                "_ordinary_file_identity",
                side_effect=mutate_after_later_hash,
            ):
                with self.assertRaisesRegex(
                    module.SourceExportError,
                    "does not match|changed",
                ):
                    module.verify_export(exported)

            self.assertTrue(mutated)

    def test_verify_rejects_manifest_rebound_to_mutated_file_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = SourceRepository(root / "source")
            exported = root / "exported"
            self.assertEqual(source.export(exported).returncode, 0)

            mutated_path = exported / "MacScope/App/Main.swift"
            mutated_payload = b"print(\"mutated\")\n"
            mutated_path.write_bytes(mutated_payload)
            files = json.loads((exported / "SOURCE_FILES.json").read_bytes())
            record = next(
                item
                for item in files["files"]
                if item["path"] == "MacScope/App/Main.swift"
            )
            record["sha256"] = hashlib.sha256(mutated_payload).hexdigest()
            record["size"] = len(mutated_payload)
            rewrite_source_manifest(exported, files)

            result = run(
                "/usr/bin/python3",
                str(TOOL),
                "verify",
                "--source-root",
                str(exported),
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not match", result.stderr)

    def test_verify_rejects_self_consistent_blob_rewrite_outside_recorded_tree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = SourceRepository(root / "source")
            exported = root / "exported"
            self.assertEqual(source.export(exported).returncode, 0)

            mutated_path = exported / "MacScope/App/Main.swift"
            mutated_payload = b"print(\"mutated and rebound\")\n"
            mutated_path.write_bytes(mutated_payload)
            files = json.loads((exported / "SOURCE_FILES.json").read_bytes())
            record = next(
                item
                for item in files["files"]
                if item["path"] == "MacScope/App/Main.swift"
            )
            record["blob_oid"] = git_blob_oid(mutated_payload)
            record["sha256"] = hashlib.sha256(mutated_payload).hexdigest()
            record["size"] = len(mutated_payload)
            rewrite_source_manifest(exported, files)

            result = run(
                "/usr/bin/python3",
                str(TOOL),
                "verify",
                "--source-root",
                str(exported),
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("recorded Git tree", result.stderr)

    def test_verify_rejects_mode_and_path_rebinding_outside_recorded_tree(self) -> None:
        for mutation in ("mode", "path"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                source = SourceRepository(root / "source")
                exported = root / "exported"
                self.assertEqual(source.export(exported).returncode, 0)
                files = json.loads((exported / "SOURCE_FILES.json").read_bytes())
                record = next(
                    item
                    for item in files["files"]
                    if item["path"] == "MacScope/App/Main.swift"
                )
                if mutation == "mode":
                    (exported / record["path"]).chmod(0o755)
                    record["mode"] = "100755"
                else:
                    original = exported / record["path"]
                    replacement = exported / "MacScope/App/Renamed.swift"
                    original.rename(replacement)
                    record["path"] = "MacScope/App/Renamed.swift"
                    files["files"].sort(key=lambda item: os.fsencode(item["path"]))
                rewrite_source_manifest(exported, files)

                result = run(
                    "/usr/bin/python3",
                    str(TOOL),
                    "verify",
                    "--source-root",
                    str(exported),
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("recorded Git tree", result.stderr)

    def test_verify_rejects_forged_recorded_tree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = SourceRepository(root / "source")
            exported = root / "exported"
            self.assertEqual(source.export(exported).returncode, 0)
            provenance_path = exported / "SOURCE_PROVENANCE.json"
            provenance = json.loads(provenance_path.read_bytes())
            provenance["git_head_tree"] = "0" * 40
            provenance_path.write_bytes(canonical_json(provenance))

            result = run(
                "/usr/bin/python3",
                str(TOOL),
                "verify",
                "--source-root",
                str(exported),
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("commit object", result.stderr)

    def test_verify_rejects_self_consistent_tree_rebound_away_from_recorded_commit(self) -> None:
        module = load_tool_module()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = SourceRepository(root / "source")
            exported = root / "exported"
            self.assertEqual(source.export(exported).returncode, 0)

            mutated_path = exported / "MacScope/App/Main.swift"
            mutated_payload = b'print("forged candidate tree")\n'
            mutated_path.write_bytes(mutated_payload)
            files = json.loads((exported / "SOURCE_FILES.json").read_bytes())
            record = next(
                item
                for item in files["files"]
                if item["path"] == "MacScope/App/Main.swift"
            )
            record["blob_oid"] = git_blob_oid(mutated_payload)
            record["sha256"] = hashlib.sha256(mutated_payload).hexdigest()
            record["size"] = len(mutated_payload)
            rewrite_source_manifest(exported, files)
            provenance_path = exported / "SOURCE_PROVENANCE.json"
            provenance = json.loads(provenance_path.read_bytes())
            provenance["git_head_tree"] = module._reconstructed_tree_oid(files["files"])
            provenance_path.write_bytes(canonical_json(provenance))

            result = run(
                "/usr/bin/python3",
                str(TOOL),
                "verify",
                "--source-root",
                str(exported),
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("commit object", result.stderr)

    def test_verify_rejects_missing_or_mutated_commit_object_and_identity_aliases(self) -> None:
        for mutation in (
            "missing-object",
            "mutated-object",
            "commit-alias",
            "ref-expression",
            "old-package-contract",
        ):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                source = SourceRepository(root / "source")
                exported = root / "exported"
                self.assertEqual(source.export(exported).returncode, 0)
                provenance_path = exported / "SOURCE_PROVENANCE.json"
                provenance = json.loads(provenance_path.read_bytes())
                if mutation == "missing-object":
                    (exported / "SOURCE_COMMIT_OBJECT").unlink()
                elif mutation == "mutated-object":
                    (exported / "SOURCE_COMMIT_OBJECT").write_bytes(b"forged commit\n")
                elif mutation == "commit-alias":
                    provenance["canonical_integration_commit"] = "0" * 40
                    provenance_path.write_bytes(canonical_json(provenance))
                elif mutation == "ref-expression":
                    provenance["canonical_integration_ref"] += "~0"
                    provenance_path.write_bytes(canonical_json(provenance))
                else:
                    del provenance["dependency_contract"]["source_export_package"]
                    provenance_path.write_bytes(canonical_json(provenance))

                result = run(
                    "/usr/bin/python3",
                    str(TOOL),
                    "verify",
                    "--source-root",
                    str(exported),
                )
                self.assertNotEqual(result.returncode, 0)

    def test_create_rejects_dirty_source_and_tracked_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dirty = SourceRepository(root / "dirty")
            dirty.write("MacScope/App/Dirty.swift", "dirty\n")
            dirty_result = dirty.export(root / "dirty-export")
            self.assertNotEqual(dirty_result.returncode, 0)
            self.assertIn("clean", dirty_result.stderr)

            linked = SourceRepository(root / "linked")
            os.symlink("Main.swift", linked.root / "MacScope/App/Alias.swift")
            linked.git("add", "MacScope/App/Alias.swift")
            linked.git("commit", "-m", "tracked link")
            linked.git(
                "update-ref",
                "refs/remotes/gitfox-local/feature/task11-local-premerge-current",
                linked.git("rev-parse", "HEAD"),
            )
            linked_result = linked.export(root / "linked-export")
            self.assertNotEqual(linked_result.returncode, 0)
            self.assertIn("ordinary", linked_result.stderr)


if __name__ == "__main__":
    unittest.main()
