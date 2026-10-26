from __future__ import annotations

import os
import argparse
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))


from Scripts.reconstruction_gate_f.materialize_candidate_identity import (
    CandidateMaterializationError,
    bundle_tree_digests,
    capture_file_snapshot,
    require_single_full_test_receipt,
    validate_native_preparation_authority,
)
from Scripts.reconstruction_gate_f import materialize_candidate_identity as materializer
from Scripts.reconstruction.audit_installed_network_acquisition import load_candidate
from Scripts.reconstruction_gate_f.canonical_json import canonical_bytes
from Scripts.reconstruction_gate_f.scenario_compiler import (
    selector_catalog_identity_sha256,
)
from Scripts.reconstruction_gate_f.tests import candidate_mapping
from Scripts.tests.test_generated_project_evidence import make_project_evidence_fixture
from Scripts.tests.test_local_signing_policy import set_fixture_xattr
from Scripts.qualification import generated_project_evidence
from Scripts.qualification.restore_build_source import _generated_project_identity
import hashlib


class GateFCandidateMaterializerTests(unittest.TestCase):
    def test_app_snapshot_ctime_only_change_preserves_wire_identity_and_final_fence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve() / "MacScope.app"
            root.mkdir()
            (root / "payload").write_bytes(b"unchanged")
            original_digest = materializer.bundle_tree_digests
            calls = 0

            def digest_then_change_ctime(path):
                nonlocal calls
                result = original_digest(path)
                calls += 1
                if calls == 1:
                    before = root.stat()
                    set_fixture_xattr(root, b"during snapshot")
                    after = root.stat()
                    self.assertEqual((before.st_dev, before.st_ino, before.st_mtime_ns),
                                     (after.st_dev, after.st_ino, after.st_mtime_ns))
                    self.assertNotEqual(before.st_ctime_ns, after.st_ctime_ns)
                return result

            with mock.patch.object(materializer, "bundle_tree_digests", digest_then_change_ctime):
                snapshot = materializer.capture_bundle_snapshot(root, app_root=True)
            self.assertEqual(calls, 2)
            self.assertEqual(len(snapshot.directory_identity), 4)
            set_fixture_xattr(root, b"after snapshot")
            materializer.require_unchanged_bundle_snapshot(snapshot, phase="app-ctime-test")
            # Exact diagnostic values from the interrupted rollback: only ctime advanced.
            self.assertTrue(materializer.app_root_directory_identity_matches(
                (1, 42, 100, 1791142171523413818),
                (1, 42, 100, 1791142171467577060)))

    def test_app_snapshot_opt_in_does_not_relax_generic_or_physical_changes(self) -> None:
        for mutation in ("ctime-generic", "inode", "mode", "mtime", "content", "directory-entry"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve() / "bundle"
                root.mkdir()
                (root / "payload").write_bytes(b"unchanged")
                snapshot = materializer.capture_bundle_snapshot(root, app_root=mutation != "ctime-generic")
                if mutation == "ctime-generic":
                    set_fixture_xattr(root, b"generic still strict")
                elif mutation == "inode":
                    root.rename(root.with_name("displaced"))
                    root.mkdir()
                    (root / "payload").write_bytes(b"unchanged")
                elif mutation == "mode":
                    root.chmod(root.stat().st_mode ^ 1)
                elif mutation == "mtime":
                    observed = root.stat()
                    os.utime(root, ns=(observed.st_atime_ns, observed.st_mtime_ns + 1_000_000_000))
                elif mutation == "content":
                    (root / "payload").write_bytes(b"changed!!")
                else:
                    (root / "extra").mkdir()
                with self.assertRaises(CandidateMaterializationError):
                    materializer.require_unchanged_bundle_snapshot(snapshot, phase="strict-negative")

    def test_native_and_matrix_app_consumers_opt_in_without_relaxing_generic_trees(self) -> None:
        from Scripts.reconstruction import native_live_preparation_receipt as preparation
        from Scripts.reconstruction import installed_matrix_receipt as matrix
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve() / "MacScope.app"
            root.mkdir()
            (root / "payload").write_bytes(b"unchanged")
            original_digest = materializer.bundle_tree_digests
            count = 0

            def digest_then_churn(path):
                nonlocal count
                result = original_digest(path)
                count += 1
                set_fixture_xattr(path, str(count).encode("ascii"))
                return result

            expected = original_digest(root)
            with mock.patch.object(materializer, "bundle_tree_digests", digest_then_churn):
                self.assertEqual(preparation.closed_tree_sha256(root), expected.closed_tree_sha256)
                self.assertEqual(matrix._fenced_tree_digests(root, app_root=True), expected)
            with mock.patch.object(matrix, "bundle_tree_digests", digest_then_churn):
                with self.assertRaises(matrix.InstalledMatrixReceiptError):
                    matrix._fenced_tree_digests(root)

    def test_bundle_snapshot_accepts_completed_precapture_rename(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary).resolve()
            original = parent / "original"
            original.mkdir()
            (original / "payload").write_bytes(b"synthetic-private-payload")
            expected = materializer.capture_bundle_snapshot(original)
            renamed = parent / "renamed"
            original.rename(renamed)
            observed = materializer.capture_bundle_snapshot(renamed)
            self.assertEqual(observed.digests, expected.digests)
            self.assertEqual(observed.directory_identity[:2], expected.directory_identity[:2])

    def test_bundle_snapshot_diagnoses_in_window_changes_without_retry(self) -> None:
        for mutation in ("root_metadata", "content", "mode", "substitution"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                parent = Path(temporary).resolve()
                root = parent / "bundle"
                root.mkdir()
                payload = root / "payload"
                payload.write_bytes(b"synthetic-private-payload")
                payload.chmod(0o600)
                original_digest = materializer.bundle_tree_digests
                calls = 0

                def digest_then_mutate(path: Path):
                    nonlocal calls
                    result = original_digest(path)
                    calls += 1
                    if calls == 1:
                        if mutation == "root_metadata":
                            metadata = root.stat()
                            os.utime(root, ns=(metadata.st_atime_ns, metadata.st_mtime_ns + 1_000_000_000))
                        elif mutation == "content":
                            payload.write_bytes(b"changed-private-payload")
                        elif mutation == "mode":
                            payload.chmod(0o644)
                        else:
                            root.rename(parent / "displaced")
                            root.mkdir()
                            payload.write_bytes(b"synthetic-private-payload")
                            payload.chmod(0o600)
                    return result

                with mock.patch.object(materializer, "bundle_tree_digests", side_effect=digest_then_mutate):
                    with self.assertRaises(CandidateMaterializationError) as raised:
                        materializer.capture_bundle_snapshot(root)
                self.assertEqual(calls, 2, "a refused capture must not retry")
                message = str(raised.exception)
                self.assertNotIn("private-payload", message)
                diagnostic_text = message.split("; diagnostic=", 1)[1]
                self.assertLess(len(diagnostic_text), 1024)
                diagnostic = json.loads(diagnostic_text)
                self.assertEqual(diagnostic["root_changed"], mutation in {"root_metadata", "substitution"})
                self.assertEqual(diagnostic["content_changed"], mutation == "content")
                self.assertEqual(diagnostic["closed_tree_changed"], mutation in {"content", "mode"})
                self.assertEqual(diagnostic["root_identity_fields"], ["device", "inode", "mtime_ns", "ctime_ns"])
                self.assertEqual(len(diagnostic["root_before"]), 4)
                self.assertEqual(len(diagnostic["root_after"]), 4)
                for key in ("content_before", "content_after", "closed_tree_before", "closed_tree_after"):
                    self.assertRegex(diagnostic[key], r"^[0-9a-f]{64}$")

    def test_sleigh_inventory_package_and_source_closure_are_separately_bound(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            legacy_path = root / "ThirdParty/SleighNative/MATERIALIZATION.json"
            source_path = root / "ThirdParty/SleighNative/Source/MATERIALIZATION.json"
            source_path.parent.mkdir(parents=True)
            pin = {"git_revision": "1" * 40, "source_tree_sha256": "2" * 64,
                   "selected_artifact_sha256": "3" * 64}
            legacy = {"schemaVersion": 1, "componentId": "sleigh-native-dcp03b4",
                      "sleighGitRevision": pin["git_revision"],
                      "package": {"treeSha256": pin["source_tree_sha256"]},
                      "artifact": {"sha256": pin["selected_artifact_sha256"]}}
            source = {"schemaVersion": 1, "componentId": "sleigh-native-source-dcp03b4",
                      "sleigh": {"revision": "1" * 40, "gitTree": "4" * 40, "treeSha256": "5" * 64},
                      "ghidra": {"revision": "6" * 40, "gitTree": "7" * 40, "treeSha256": "8" * 64},
                      "patches": [{"path": "patch", "sha256": "9" * 64}]}
            legacy_path.write_bytes(canonical_bytes(legacy))
            source_path.write_bytes(canonical_bytes(source))
            build = {"sourceManifestSha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
                     "patches": source["patches"]}
            manifest = {"sourceBuild": build}
            for component in ("sleigh", "ghidra"):
                manifest[component + "GitRevision"] = source[component]["revision"]
                build[component + "GitTree"] = source[component]["gitTree"]
                build[component + "TreeSha256"] = source[component]["treeSha256"]
            snapshots = materializer._sleigh_source_pin_evidence(root, pin, manifest)
            self.assertEqual(tuple(item.path for item in snapshots), (legacy_path, source_path))
            self.assertNotEqual(pin["source_tree_sha256"], build["sleighTreeSha256"])
            for field in pin:
                changed = dict(pin)
                changed[field] = "a" * len(changed[field])
                with self.subTest(pin=field), self.assertRaises(CandidateMaterializationError):
                    materializer._sleigh_source_pin_evidence(root, changed, manifest)
            for field in build:
                changed = copy.deepcopy(manifest)
                changed["sourceBuild"][field] = [] if field == "patches" else "b" * 64
                with self.subTest(build=field), self.assertRaises(CandidateMaterializationError):
                    materializer._sleigh_source_pin_evidence(root, pin, changed)
            for component in ("sleigh", "ghidra"):
                changed = copy.deepcopy(manifest)
                changed[component + "GitRevision"] = "c" * 40
                with self.subTest(revision=component), self.assertRaises(CandidateMaterializationError):
                    materializer._sleigh_source_pin_evidence(root, pin, changed)
            # Publication retains both exact files, rather than only a clean-Git check.
            for snapshot in snapshots:
                original = snapshot.path.read_bytes()
                snapshot.path.write_bytes(original + b" ")
                with self.assertRaises(CandidateMaterializationError):
                    materializer.require_unchanged_file_snapshot(snapshot, phase="publication")
                snapshot.path.write_bytes(original)
            source_path.unlink()
            with self.assertRaises(CandidateMaterializationError):
                materializer._sleigh_source_pin_evidence(root, pin, manifest)

    def test_materializer_requires_actual_run_owned_project_not_operator_project(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run = Path(temporary).resolve()
            spec = b"name: MacScope\n"
            project = make_project_evidence_fixture(run, "1" * 40, "2" * 40, spec)
            args = dict(commit="1" * 40, tree="2" * 40, project_yml_sha256=hashlib.sha256(spec).hexdigest())
            with self.assertRaises(CandidateMaterializationError):
                materializer._qualified_generated_project_snapshots(run, **args)
            retained = generated_project_evidence.capture(run, _generated_project_identity(project, require_complete=True))
            snapshot, fences = materializer._qualified_generated_project_snapshots(run, **args)
            self.assertEqual(snapshot.path, retained)
            self.assertEqual(snapshot.sha256, hashlib.sha256(retained.read_bytes()).hexdigest())
            self.assertIn(retained, [item.path for item in fences])
            retained.write_bytes(b"stale-project")
            with self.assertRaises(CandidateMaterializationError):
                materializer._qualified_generated_project_snapshots(run, **args)

    @staticmethod
    def _clean_repository(root: Path) -> None:
        subprocess.run(
            ["/usr/bin/git", "init", "-b", "feature/candidate-source-fence"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        subprocess.run(
            ["/usr/bin/git", "config", "user.name", "Candidate Test"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        subprocess.run(
            ["/usr/bin/git", "config", "user.email", "candidate@example.invalid"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        (root / "tracked-source").write_text("source\n", encoding="utf-8")
        subprocess.run(
            ["/usr/bin/git", "add", "tracked-source"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        subprocess.run(
            ["/usr/bin/git", "commit", "-m", "fixture"],
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )

    def test_published_candidate_is_strict_canonical_and_network_audit_consumable(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="macscope-candidate-publication-",
        ) as temporary:
            output = Path(temporary).resolve() / "candidate.json"
            document = candidate_mapping()

            materializer.write_candidate_identity(output, document)

            self.assertEqual(output.read_bytes(), canonical_bytes(document))
            candidate, file_digest = load_candidate(output)
            self.assertEqual(candidate.source.commit, document["source"]["commit"])
            self.assertRegex(file_digest, r"^[0-9a-f]{64}$")
            with self.assertRaises(FileExistsError):
                materializer.write_candidate_identity(output, document)

    def test_candidate_uses_one_full_test_qualification_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            receipt = root / "QUALIFICATION_INPUTS.json"
            receipt.write_text("{}", encoding="utf-8")
            snapshot = capture_file_snapshot(receipt)
            require_single_full_test_receipt(snapshot, snapshot)

            separate = root / "separate.json"
            separate.write_text("{}", encoding="utf-8")
            with self.assertRaisesRegex(
                CandidateMaterializationError,
                "same full-test qualification receipt",
            ):
                require_single_full_test_receipt(
                    snapshot,
                    capture_file_snapshot(separate),
                )

    def test_source_fence_rejects_hidden_untracked_input_before_publication(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "repository"
            root.mkdir()
            self._clean_repository(root)
            snapshot = materializer._require_clean_source_snapshot(root)
            hidden_input = root / ".untracked-inputs/nested/generated.json"
            hidden_input.parent.mkdir(parents=True)
            hidden_input.write_text("not a candidate input\n", encoding="utf-8")
            output = Path(temporary).resolve() / "candidate.json"

            with self.assertRaisesRegex(
                CandidateMaterializationError,
                "source identity drifted",
            ):
                materializer.write_candidate_identity(
                    output,
                    candidate_mapping(),
                    repository_root=root,
                    source_snapshot=snapshot,
                )

            self.assertFalse(output.exists())

    def test_qualification_inputs_v4_is_closed_and_binds_exact_source(self) -> None:
        receipt = {
            "schema_version": 4,
            "mode": "release",
            "build_source_root": "/private/tmp/source",
            "dependency_cache_root": "/private/tmp/cache",
            "dependency_network_allowed": False,
            "dependency_network_used": False,
            "ghostty_artifact_manifest_sha256": "a" * 64,
            "ghostty_source_dir": "/private/tmp/ghostty",
            "ghostty_surface_artifact_root": "/private/tmp/ghostty-surface/artifact",
            "ghostty_surface_manifest_sha256": "c" * 64,
            "ghostty_surface_source_dir": "/private/tmp/ghostty-surface",
            "sleigh_materialization_manifest_sha256": "b" * 64,
            "sleigh_materialization_root": "/private/tmp/sleigh",
            "zig_executable": "/private/tmp/zig",
            "source_identity": {
                "canonical_integration_commit": "1" * 40,
                "canonical_integration_ref": "refs/remotes/gitfox-local/feature/candidate",
                "canonical_remote_url": "/private/tmp/macscope.git",
                "dependency_contract": {
                    "component_manifest_sha256": "3" * 64,
                    "component_pins": [
                        {
                            "id": "ghostty-vt",
                            "pin": {"git_revision": "4" * 40},
                        }
                    ],
                    "notices_sha256": "5" * 64,
                    "source_export_package": {
                        "commit_object_name": "SOURCE_COMMIT_OBJECT",
                        "commit_object_sha256": "8" * 64,
                        "commit_object_size": 123,
                        "version": 3,
                    },
                },
                "git_head_commit": "1" * 40,
                "git_head_tree": "2" * 40,
                "git_parent_commits": ["6" * 40],
                "repository_clean": True,
                "schema_version": 2,
                "source_file_count": 123,
                "source_files_sha256": "7" * 64,
            },
        }
        materializer._qualification_source(
            receipt, expected_mode="release", commit="1" * 40, tree="2" * 40
        )
        source_identity = receipt["source_identity"]
        assert isinstance(source_identity, dict)
        package = source_identity["dependency_contract"]["source_export_package"]
        for version in (3, 4, 5):
            with self.subTest(package_version=version):
                package["version"] = version
                materializer._qualification_source(
                    receipt, expected_mode="release", commit="1" * 40, tree="2" * 40
                )
        for version in (0, 1, 2, 6, True, 3.0, 4.0, 5.0, "4", "5", None):
            with self.subTest(rejected_package_version=version):
                package["version"] = version
                with self.assertRaisesRegex(CandidateMaterializationError, "source export package"):
                    materializer._qualification_source(
                        receipt, expected_mode="release", commit="1" * 40, tree="2" * 40
                    )
        package["version"] = 4
        source_identity.pop("source_files_sha256")
        with self.assertRaisesRegex(CandidateMaterializationError, "source-export schema v2"):
            materializer._qualification_source(
                receipt, expected_mode="release", commit="1" * 40, tree="2" * 40
            )
        source_identity["source_files_sha256"] = "7" * 64
        receipt["unexpected"] = "drift"
        with self.assertRaisesRegex(CandidateMaterializationError, "closed schema v4"):
            materializer._qualification_source(
                receipt, expected_mode="release", commit="1" * 40, tree="2" * 40
            )

    def test_ghostty_artifact_accepts_only_a_contained_ordinary_symlink_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            library_root = Path(temporary) / "zig-out/lib"
            library_root.mkdir(parents=True)
            versioned = library_root / "libghostty-vt.0.1.0.dylib"
            versioned.write_bytes(b"governed-ghostty")
            (library_root / "libghostty-vt.0.dylib").symlink_to(versioned.name)
            public = library_root / "libghostty-vt.dylib"
            public.symlink_to("libghostty-vt.0.dylib")

            self.assertEqual(
                materializer._canonical_dependency_artifact(public, library_root),
                versioned,
            )

            external = Path(temporary) / "external.dylib"
            external.write_bytes(b"untrusted")
            public.unlink()
            public.symlink_to(external)
            with self.assertRaisesRegex(
                CandidateMaterializationError,
                "escapes its verified dependency directory",
            ):
                materializer._canonical_dependency_artifact(public, library_root)

    def test_bundle_tree_identity_is_deterministic_and_mode_sensitive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "MacScope.app"
            executable = root / "Contents/MacOS/MacScope"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"candidate")
            executable.chmod(0o755)
            first = bundle_tree_digests(root)
            second = bundle_tree_digests(root)
            self.assertEqual(first, second)
            executable.chmod(0o700)
            changed = bundle_tree_digests(root)
            self.assertEqual(first.content_sha256, changed.content_sha256)
            self.assertNotEqual(first.closed_tree_sha256, changed.closed_tree_sha256)

    def test_bundle_tree_rejects_hardlinks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "MacScope.app"
            contents = root / "Contents"
            contents.mkdir(parents=True)
            original = contents / "a"
            original.write_bytes(b"shared")
            os.link(original, contents / "b")
            with self.assertRaisesRegex(
                CandidateMaterializationError,
                "hardlinked or multiply linked",
            ):
                bundle_tree_digests(root)

    def test_bundle_tree_rejects_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "MacScope.app"
            contents = root / "Contents"
            contents.mkdir(parents=True)
            target = Path(temporary) / "external"
            target.write_bytes(b"mutable")
            (contents / "escape").symlink_to(target)
            with self.assertRaisesRegex(
                CandidateMaterializationError,
                "symbolic link.*closed ordinary tree",
            ):
                bundle_tree_digests(root)

    def test_bundle_tree_rejects_unreadable_subtree_instead_of_omitting_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "MacScope.app"
            unreadable = root / "Contents/Unreadable"
            unreadable.mkdir(parents=True)
            (unreadable / "sealed").write_bytes(b"must-not-be-omitted")
            original_scandir = materializer.os.scandir
            unreadable_resolved = unreadable.resolve()

            def refuse_subtree(path):
                if Path(path).resolve() == unreadable_resolved:
                    raise PermissionError(13, "permission denied", str(unreadable))
                return original_scandir(path)

            with mock.patch.object(materializer.os, "scandir", side_effect=refuse_subtree):
                with self.assertRaisesRegex(
                    CandidateMaterializationError,
                    "bundle traversal failed.*Unreadable",
                ):
                    bundle_tree_digests(root)

    def test_candidate_publication_revalidates_files_and_bundles_before_create(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            temporary_root = Path(temporary)
            repository = temporary_root / "repository"
            repository.mkdir()
            self._clean_repository(repository)
            source_snapshot = materializer._require_clean_source_snapshot(repository)
            recorded_file = temporary_root / "generated-project"
            recorded_file.write_bytes(b"project-A")
            app = temporary_root / "MacScope.app"
            executable = app / "Contents/MacOS/MacScope"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"app-A")
            executable.chmod(0o755)
            fence = materializer.CandidatePublicationFence(
                repository_root=repository,
                source_snapshot=source_snapshot,
                file_snapshots=(materializer.capture_file_snapshot(recorded_file),),
                bundle_snapshots=(materializer.capture_bundle_snapshot(app),),
            )
            output = temporary_root / "candidate.json"

            recorded_file.write_bytes(b"project-B")
            with self.assertRaisesRegex(
                CandidateMaterializationError,
                "file changed before candidate identity create-only publication",
            ):
                materializer.write_candidate_identity(
                    output,
                    candidate_mapping(),
                    publication_fence=fence,
                )
            self.assertFalse(output.exists())

    def test_candidate_publication_revalidates_bundle_before_create(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            temporary_root = Path(temporary)
            repository = temporary_root / "repository"
            repository.mkdir()
            self._clean_repository(repository)
            source_snapshot = materializer._require_clean_source_snapshot(repository)
            app = temporary_root / "MacScope.app"
            executable = app / "Contents/MacOS/MacScope"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"app-A")
            executable.chmod(0o755)
            fence = materializer.CandidatePublicationFence(
                repository_root=repository,
                source_snapshot=source_snapshot,
                file_snapshots=(),
                bundle_snapshots=(materializer.capture_bundle_snapshot(app),),
            )
            output = temporary_root / "candidate.json"

            executable.write_bytes(b"app-B")
            executable.chmod(0o755)
            with self.assertRaisesRegex(
                CandidateMaterializationError,
                "bundle tree changed before candidate identity create-only publication",
            ):
                materializer.write_candidate_identity(
                    output,
                    candidate_mapping(),
                    publication_fence=fence,
                )
            self.assertFalse(output.exists())

    def test_dependency_receipt_rejects_post_qualification_manifest_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ghostty_root = root / "ghostty"
            ghostty_library = ghostty_root / "zig-out/lib"
            ghostty_manifest = ghostty_library / ".macscope-ghostty-vt-manifest"
            ghostty_artifact = ghostty_library / "libghostty-vt.0.1.0.dylib"
            surface_root = root / "ghostty-surface"
            surface_manifest = surface_root / "macos/.macscope-ghostty-surface-manifest"
            sleigh_root = root / "sleigh"
            sleigh_manifest = sleigh_root / "MATERIALIZATION.json"
            sleigh_package = sleigh_root / "package/member"
            sleigh_package.parent.mkdir(parents=True)
            for path, payload in (
                (
                    ghostty_manifest,
                    (
                        "schema=5\n"
                        f"source_revision={'3' * 40}\n"
                        f"source_tree_sha256={'4' * 64}\n"
                    ).encode(),
                ),
                (ghostty_artifact, b"ghostty-artifact-A"),
                (surface_manifest, b"surface-manifest-A\n"),
                (sleigh_manifest, b"{}\n"),
                (sleigh_package, b"sleigh-package-A"),
            ):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(payload)
            (ghostty_library / "libghostty-vt.dylib").symlink_to(
                ghostty_artifact.name
            )
            sleigh_identity = {
                "schemaVersion": 2,
                "componentId": "sleigh-native-source-dcp03b4",
                "package": {"treeSha256": "a" * 64},
            }
            qualification = {
                "build_source_root": str(root / "source"),
                "dependency_cache_root": str(root / "cache"),
                "dependency_network_allowed": False,
                "ghostty_source_dir": str(ghostty_root),
                "ghostty_surface_source_dir": str(surface_root),
                "sleigh_materialization_root": str(sleigh_root),
                "ghostty_artifact_manifest_sha256": (
                    materializer.capture_file_snapshot(ghostty_manifest).sha256
                ),
                "ghostty_surface_manifest_sha256": (
                    materializer.capture_file_snapshot(surface_manifest).sha256
                ),
                "sleigh_materialization_manifest_sha256": (
                    materializer.capture_file_snapshot(sleigh_manifest).sha256
                ),
                "source_identity": {
                    "canonical_integration_ref": "refs/remotes/local/feature/candidate"
                },
            }
            provenance = {
                "ghostty_surface_source_manifest_sha256": qualification[
                    "ghostty_surface_manifest_sha256"
                ],
                "sleigh_materialization_schema_version": 2,
                "sleigh_materialization_component_id": (
                    "sleigh-native-source-dcp03b4"
                ),
                "sleigh_materialization_manifest_sha256": qualification[
                    "sleigh_materialization_manifest_sha256"
                ],
                "sleigh_materialization_tree_sha256": "a" * 64,
            }
            with (
                mock.patch.object(
                    materializer,
                    "verified_sleigh_materialization",
                    return_value=sleigh_identity,
                ) as strict_sleigh,
                mock.patch.object(
                    materializer,
                    "validate_qualification_build",
                    return_value={},
                ) as strict_qualification,
            ):
                materializer._capture_qualification_dependency_authority(
                    repository_root=root,
                    qualification_receipt_path=root / "QUALIFICATION_INPUTS.json",
                    qualification=qualification,
                    release_app=root / "Release/MacScope.app",
                    provenance=provenance,
                    commit="1" * 40,
                    tree="2" * 40,
                )
                strict_sleigh.assert_called_once()
                strict_qualification.assert_called_once()

            ghostty_manifest.write_bytes(
                (
                    "schema=5\n"
                    f"source_revision={'9' * 40}\n"
                    f"source_tree_sha256={'4' * 64}\n"
                ).encode()
            )
            with (
                mock.patch.object(
                    materializer,
                    "verified_sleigh_materialization",
                    return_value=sleigh_identity,
                ),
                self.assertRaisesRegex(
                    CandidateMaterializationError,
                    "differ.*receipt field ghostty_artifact_manifest_sha256",
                ),
            ):
                materializer._capture_qualification_dependency_authority(
                    repository_root=root,
                    qualification_receipt_path=root / "QUALIFICATION_INPUTS.json",
                    qualification=qualification,
                    release_app=root / "Release/MacScope.app",
                    provenance=provenance,
                    commit="1" * 40,
                    tree="2" * 40,
                )

    def test_dependency_rejects_ghostty_manifest_revision_and_tree_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            dependency_file = root / "dependency"
            dependency_file.write_bytes(b"dependency")
            sleigh_root = root / "sleigh"
            (sleigh_root / "package").mkdir(parents=True)
            (sleigh_root / "MATERIALIZATION.json").write_bytes(b"{}\n")
            snapshot = materializer.capture_file_snapshot(dependency_file)
            ghostty_revision = "3" * 40
            ghostty_tree = "4" * 64
            sleigh_revision = "5" * 40
            sleigh_tree = "6" * 64
            qualification = {
                "source_identity": {
                    "dependency_contract": {
                        "component_pins": [
                            {
                                "id": "ghostty-vt",
                                "pin": {
                                    "git_revision": ghostty_revision,
                                    "source_tree_sha256": ghostty_tree,
                                },
                            },
                            {
                                "id": "sleigh-native-dcp03b4",
                                "pin": {
                                    "git_revision": sleigh_revision,
                                    "source_tree_sha256": sleigh_tree,
                                },
                            },
                        ]
                    }
                }
            }
            common = {
                "ghostty_manifest_snapshot": snapshot,
                "ghostty_artifact_snapshot": snapshot,
                "ghostty_surface_manifest_snapshot": snapshot,
                "sleigh_manifest_snapshot": snapshot,
                "sleigh_root_snapshot": materializer.capture_bundle_snapshot(
                    sleigh_root
                ),
                "sleigh_identity": {
                    "sleighGitRevision": sleigh_revision,
                    "sourceBuild": {"sleighTreeSha256": sleigh_tree},
                    "package": {"treeSha256": "7" * 64},
                },
            }
            baseline = {
                "source_revision": ghostty_revision,
                "source_tree_sha256": ghostty_tree,
            }
            for field, message in (
                ("source_revision", "source revision"),
                ("source_tree_sha256", "source tree"),
            ):
                with self.subTest(field=field):
                    mutated = dict(baseline)
                    mutated[field] = "9" * len(mutated[field])
                    authority = materializer.QualificationDependencyAuthority(
                        **common,
                        ghostty_manifest_identity=mutated,
                    )
                    with self.assertRaisesRegex(
                        CandidateMaterializationError,
                        f"qualified Ghostty {message} differs",
                    ):
                        materializer._materialization_dependency(
                            qualification,
                            ROOT,
                            authority,
                        )

    def test_publication_rejects_post_qualification_dependency_drift(self) -> None:
        for changed_dependency in ("ghostty-artifact", "sleigh-package"):
            with self.subTest(changed_dependency=changed_dependency):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    repository = root / "repository"
                    repository.mkdir()
                    self._clean_repository(repository)
                    source_snapshot = materializer._require_clean_source_snapshot(
                        repository
                    )
                    ghostty_artifact = root / "libghostty-vt.dylib"
                    ghostty_artifact.write_bytes(b"ghostty-A")
                    sleigh_root = root / "sleigh"
                    sleigh_member = sleigh_root / "package/member"
                    sleigh_member.parent.mkdir(parents=True)
                    (sleigh_root / "MATERIALIZATION.json").write_bytes(b"{}\n")
                    sleigh_member.write_bytes(b"sleigh-A")
                    fence = materializer.CandidatePublicationFence(
                        repository_root=repository,
                        source_snapshot=source_snapshot,
                        file_snapshots=(
                            materializer.capture_file_snapshot(ghostty_artifact),
                        ),
                        bundle_snapshots=(
                            materializer.capture_bundle_snapshot(sleigh_root),
                        ),
                    )
                    if changed_dependency == "ghostty-artifact":
                        ghostty_artifact.write_bytes(b"ghostty-B")
                    else:
                        sleigh_member.write_bytes(b"sleigh-B")

                    with self.assertRaisesRegex(
                        CandidateMaterializationError,
                        "file changed|bundle tree changed",
                    ):
                        materializer.write_candidate_identity(
                            root / "candidate.json",
                            candidate_mapping(),
                            publication_fence=fence,
                        )

    def test_native_preparation_validation_rejects_receipt_product_splice(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            receipt = root / "receipt.json"
            receipt.write_bytes(b"receipt-A")
            xctestrun = root / "tests.xctestrun"
            xctestrun.write_bytes(b"xctestrun-A")
            app = root / "MacScope.app"
            executable = app / "Contents/MacOS/MacScope"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"app-A")
            executable.chmod(0o755)
            helper = root / "validator.py"
            helper.write_text("# fixture\n", encoding="utf-8")
            receipt_snapshot = materializer.capture_file_snapshot(receipt)
            xctestrun_snapshot = materializer.capture_file_snapshot(xctestrun)
            app_snapshot = materializer.capture_bundle_snapshot(app)

            def validate_then_splice(*_args, **_kwargs):
                executable.write_bytes(b"app-B")
                executable.chmod(0o755)
                return subprocess.CompletedProcess([], 0, "", "")

            with mock.patch.object(materializer, "_run", side_effect=validate_then_splice):
                with self.assertRaisesRegex(
                    CandidateMaterializationError,
                    "bundle tree changed before native preparation subprocess validation",
                ):
                    materializer._validate_native_preparation_artifacts(
                        helper=helper,
                        receipt_path=receipt,
                        xctestrun=xctestrun,
                        candidate_app=app,
                        test_bundle=app,
                        receipt_snapshot=receipt_snapshot,
                        xctestrun_snapshot=xctestrun_snapshot,
                        app_snapshot=app_snapshot,
                    )

    def test_bundle_snapshot_rejects_in_place_write_before_final_fence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "MacScope.app"
            executable = root / "Contents/MacOS/MacScope"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"candidate")
            executable.chmod(0o755)

            snapshot = materializer.capture_bundle_snapshot(root)
            executable.write_bytes(b"mutated!!")

            with self.assertRaisesRegex(
                CandidateMaterializationError,
                "bundle tree changed before final-fence-test",
            ):
                materializer.require_unchanged_bundle_snapshot(
                    snapshot,
                    phase="final-fence-test",
                )

    def test_bundle_snapshot_rejects_rename_symlink_swap_before_final_fence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "MacScope.app"
            executable = root / "Contents/MacOS/MacScope"
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"candidate")
            executable.chmod(0o755)

            snapshot = materializer.capture_bundle_snapshot(root)
            replacement = executable.with_name("MacScope.original")
            executable.rename(replacement)
            executable.symlink_to(replacement.name)
            try:
                with self.assertRaisesRegex(
                    CandidateMaterializationError,
                    "symbolic link|cannot be safely read",
                ):
                    materializer.require_unchanged_bundle_snapshot(
                        snapshot,
                        phase="final-fence-test",
                    )
            finally:
                executable.unlink()
                replacement.rename(executable)

    def test_selector_definition_identity_is_stable_and_nonempty(self) -> None:
        observed = selector_catalog_identity_sha256()
        self.assertRegex(observed, r"^[0-9a-f]{64}$")
        self.assertEqual(observed, selector_catalog_identity_sha256())

    def test_compiler_schema_version_is_independent_from_candidate_schema(self) -> None:
        self.assertEqual(materializer.CANDIDATE_SCHEMA_VERSION, 3)
        self.assertEqual(materializer.GATE_F_COMPILER_SCHEMA_VERSION, 1)
        self.assertEqual(
            materializer._gate_f_compiler_schema("c" * 64),
            {
                "schema_id": "gate-f-compiler",
                "version": 1,
                "content_sha256": "c" * 64,
            },
        )

    def test_native_preparation_source_and_toolchain_are_independent_authorities(self) -> None:
        source = {
            "repository": "gitfox-local:MacScope",
            "branch_label": "feature/reconstruction-r1-task10",
            "commit": "1" * 40,
            "tree": "2" * 40,
            "dirty": False,
            "project_yml_sha256": "3" * 64,
            "generated_project_sha256": "4" * 64,
        }
        toolchain = {
            "developer_dir": "/Applications/Xcode-beta.app/Contents/Developer",
            "xcodebuild_sha256": "5" * 64,
            "xcode_version": "27.0",
            "xcode_build": "27A5252f",
            "swiftc_sha256": "6" * 64,
            "swift_version": "Apple Swift version 6.4",
            "sdk_path": "/Applications/Xcode-beta.app/SDKs/MacOSX.sdk",
            "sdk_settings_sha256": "7" * 64,
            "sdk_version": "27.0",
            "sdk_build": "26A5419a",
        }
        receipt = {"source": dict(source), "toolchain": dict(toolchain)}
        validate_native_preparation_authority(
            receipt,
            expected_source=source,
            expected_toolchain=toolchain,
        )

        receipt["source"]["tree"] = "f" * 40
        with self.assertRaisesRegex(
            CandidateMaterializationError,
            "source is not the exact clean candidate",
        ):
            validate_native_preparation_authority(
                receipt,
                expected_source=source,
                expected_toolchain=toolchain,
            )
        receipt["source"] = dict(source)
        receipt["toolchain"]["sdk_build"] = "different"
        with self.assertRaisesRegex(
            CandidateMaterializationError,
            "toolchain differs",
        ):
            validate_native_preparation_authority(
                receipt,
                expected_source=source,
                expected_toolchain=toolchain,
            )


class SemanticPrerequisiteMaterializationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="macscope-prerequisite-input-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.repository = self.root / "repository"
        self.repository.mkdir()
        GateFCandidateMaterializerTests._clean_repository(self.repository)
        self.ids = ("task-6-remediation", "task-8", "task-9", "t10a", "t10c", "task-10")
        self.entries = []
        for prerequisite_id in self.ids:
            (self.repository / "tracked-source").write_text(prerequisite_id)
            self.git("add", "tracked-source")
            self.git("commit", "-m", prerequisite_id)
            evidence = self.root / (prerequisite_id + ".json")
            # Deliberately not acceptance evidence: this seam binds identity,
            # while the downstream gates still need their actual receipts.
            evidence.write_bytes(canonical_bytes({"status": "unqualified", "id": prerequisite_id}))
            self.entries.append(dict(prerequisite_id=prerequisite_id,
                commit=self.git("rev-parse", "HEAD"), tree=self.git("rev-parse", "HEAD^{tree}"),
                evidence_path=str(evidence)))
        self.commit = self.git("rev-parse", "HEAD")
        self.manifest = self.root / "prerequisites.json"
        self.document = dict(schema_version=1, prerequisites=self.entries)
        self.publish_manifest()
        self.arguments = argparse.Namespace(task10_commit=self.commit,
            task10_evidence=Path(self.entries[-1]["evidence_path"]), semantic_prerequisites=self.manifest)

    def git(self, *arguments):
        return subprocess.run(["/usr/bin/git", *arguments], cwd=self.repository,
            check=True, capture_output=True, text=True).stdout.strip()

    def publish_manifest(self):
        self.manifest.write_bytes(canonical_bytes(self.document))

    def materialize(self):
        self.assertTrue(hasattr(materializer, "_semantic_prerequisites"),
                        "candidate materializer cannot bind the six explicit prerequisite identities")
        return materializer._semantic_prerequisites(self.arguments, self.repository, self.commit)

    def test_six_real_ancestor_identities_hash_evidence_without_acceptance_claims(self):
        records, snapshots = self.materialize()
        expected = [dict(prerequisite_id=item["prerequisite_id"], commit=item["commit"], tree=item["tree"],
            evidence_sha256=hashlib.sha256(Path(item["evidence_path"]).read_bytes()).hexdigest())
            for item in sorted(self.entries, key=lambda item: item["prerequisite_id"])]
        self.assertEqual(records, expected)
        self.assertEqual({item.path for item in snapshots},
                         {self.manifest, *(Path(item["evidence_path"]) for item in self.entries)})
        candidate = candidate_mapping()
        candidate["source"]["semantic_prerequisites"] = records
        parsed, issues = materializer.parse_candidate_identity(candidate)
        self.assertEqual(issues, ())
        self.assertEqual(len(parsed.source.semantic_prerequisites), 6)

    def test_omitted_manifest_preserves_exact_task10_only_identity(self):
        del self.arguments.semantic_prerequisites
        records, snapshots = self.materialize()
        self.assertEqual(records, [dict(prerequisite_id="task-10", commit=self.commit,
            tree=self.entries[-1]["tree"], evidence_sha256=hashlib.sha256(
                self.arguments.task10_evidence.read_bytes()).hexdigest())])
        self.assertEqual([item.path for item in snapshots], [self.arguments.task10_evidence])

    def test_optional_cli_input_leaves_legacy_arguments_required(self):
        argv = ["--repository-root", str(self.repository), "--release-app", "/fixture/Release.app",
            "--debug-app", "/fixture/Debug.app", "--native-live-preparation-receipt", "/fixture/native.json",
            "--release-qualification-inputs", "/fixture/inputs.json", "--debug-qualification-inputs", "/fixture/inputs.json",
            "--base-commit", self.commit, "--task10-commit", self.commit,
            "--task10-evidence", str(self.arguments.task10_evidence), "--output", str(self.root / "candidate.json")]
        self.assertIsNone(materializer.parse_arguments(argv).semantic_prerequisites)
        parsed = materializer.parse_arguments(argv + ["--semantic-prerequisites", str(self.manifest)])
        self.assertEqual(parsed.semantic_prerequisites, self.manifest)
        self.assertEqual(parsed.task10_commit, self.commit)

    def test_duplicate_json_fields_and_symlinked_manifest_cannot_supply_input(self):
        original = self.manifest.read_bytes()
        self.manifest.write_bytes(original.replace(b'{"prerequisites":', b'{"schema_version":1,"prerequisites":', 1))
        with self.assertRaisesRegex(CandidateMaterializationError, "duplicate"):
            self.materialize()
        self.manifest.write_bytes(original)
        alias = self.root / "manifest-alias.json"
        alias.symlink_to(self.manifest)
        self.arguments.semantic_prerequisites = alias
        with self.assertRaisesRegex(CandidateMaterializationError, "canonical"):
            self.materialize()

    def test_evidence_change_during_observation_is_not_sealed_as_identity(self):
        target = Path(self.entries[0]["evidence_path"])
        original_capture = materializer.capture_file_snapshot
        mutated = False

        def capture_then_mutate(path):
            nonlocal mutated
            snapshot = original_capture(path)
            if path == target and not mutated:
                mutated = True
                target.write_bytes(b"changed during observation")
            return snapshot

        with mock.patch.object(materializer, "capture_file_snapshot", side_effect=capture_then_mutate):
            with self.assertRaisesRegex(CandidateMaterializationError, "file changed"):
                self.materialize()

    def test_explicit_input_rejects_missing_duplicate_unknown_or_claim_fields(self):
        original = copy.deepcopy(self.document)
        for mutation in ("missing", "duplicate", "unknown", "status", "digest", "version"):
            with self.subTest(mutation=mutation):
                self.document = copy.deepcopy(original)
                entries = self.document["prerequisites"]
                if mutation == "missing":
                    entries.pop()
                elif mutation == "duplicate":
                    entries[-1] = entries[0]
                elif mutation == "unknown":
                    entries[0]["prerequisite_id"] = "other"
                elif mutation == "status":
                    entries[0]["accepted"] = True
                elif mutation == "digest":
                    entries[0]["evidence_sha256"] = "a" * 64
                else:
                    self.document["schema_version"] = True
                self.publish_manifest()
                with self.assertRaises(CandidateMaterializationError):
                    self.materialize()

    def test_git_tree_commit_type_and_ancestry_are_proven_in_actual_repository(self):
        original = copy.deepcopy(self.document)
        tree = self.entries[0]["tree"]
        unrelated = self.git("commit-tree", tree, "-m", "unrelated fixture")
        self.git("tag", "-a", "prerequisite-tag", "-m", "tag fixture", self.commit)
        tag = self.git("rev-parse", "refs/tags/prerequisite-tag")
        for commit, declared_tree in ((self.commit, tree), (tree, tree), (tag, self.entries[-1]["tree"]),
                                      (unrelated, tree), ("HEAD", self.entries[-1]["tree"])):
            with self.subTest(commit=commit, tree=declared_tree):
                self.document = copy.deepcopy(original)
                self.document["prerequisites"][0].update(commit=commit, tree=declared_tree)
                self.publish_manifest()
                with self.assertRaises(CandidateMaterializationError):
                    self.materialize()

    def test_task10_explicit_input_cannot_diverge_from_legacy_authority(self):
        original = copy.deepcopy(self.document)
        same_bytes = self.root / "task10-copy.json"
        same_bytes.write_bytes(self.arguments.task10_evidence.read_bytes())
        for change in (dict(commit=self.entries[0]["commit"], tree=self.entries[0]["tree"]),
                       dict(evidence_path=str(same_bytes))):
            with self.subTest(change=change):
                self.document = copy.deepcopy(original)
                self.document["prerequisites"][-1].update(change)
                self.publish_manifest()
                with self.assertRaisesRegex(CandidateMaterializationError, "Task 10"):
                    self.materialize()

    def test_manifest_and_all_evidence_are_rechecked_before_create_only_publication(self):
        for target in (self.manifest, *(Path(item["evidence_path"]) for item in self.entries)):
            with self.subTest(target=target):
                original = target.read_bytes()
                records, snapshots = self.materialize()
                fence = materializer.CandidatePublicationFence(self.repository,
                    materializer._require_clean_source_snapshot(self.repository), snapshots, ())
                candidate = candidate_mapping()
                candidate["source"]["semantic_prerequisites"] = records
                target.write_bytes(original + b"\n")
                output = self.root / "candidate.json"
                with self.assertRaisesRegex(CandidateMaterializationError, "file changed"):
                    materializer.write_candidate_identity(output, candidate, publication_fence=fence)
                self.assertFalse(output.exists())
                target.write_bytes(original)

    def test_explicit_evidence_paths_cannot_be_relative_symlinked_or_missing(self):
        original = copy.deepcopy(self.document)
        symlink = self.root / "evidence-link"
        symlink.symlink_to(self.entries[0]["evidence_path"])
        for path in ("relative.json", str(symlink), str(self.root / "missing")):
            with self.subTest(path=path):
                self.document = copy.deepcopy(original)
                self.document["prerequisites"][0]["evidence_path"] = path
                self.publish_manifest()
                with self.assertRaises((CandidateMaterializationError, OSError)):
                    self.materialize()

    def isolated_input_parent(self, kind):
        parent = self.root / ("input-parent-" + kind)
        parent.mkdir()
        original = self.manifest if kind == "manifest" else Path(self.entries[0]["evidence_path"])
        target = parent / original.name
        original.rename(target)
        if kind == "manifest":
            self.manifest = target
            self.arguments.semantic_prerequisites = target
        else:
            self.entries[0]["evidence_path"] = str(target)
            self.publish_manifest()
        return target, parent

    def test_parent_alias_to_same_leaf_is_rejected_before_candidate_publication(self):
        for kind in ("manifest", "evidence"):
            with self.subTest(kind=kind):
                target, parent = self.isolated_input_parent(kind)
                records, snapshots = self.materialize()
                fence = materializer.CandidatePublicationFence(self.repository,
                    materializer._require_clean_source_snapshot(self.repository), snapshots, ())
                retained = next(item for item in snapshots if item.path == target)
                moved = parent.with_name(parent.name + "-moved")
                parent.rename(moved)
                parent.symlink_to(moved, target_is_directory=True)
                try:
                    # Leaf bytes/inode/metadata are unchanged: only the formerly
                    # canonical parent path has become an alias.
                    self.assertEqual(materializer.capture_file_snapshot(target).metadata, retained.metadata)
                    candidate = candidate_mapping()
                    candidate["source"]["semantic_prerequisites"] = records
                    output = self.root / (kind + "-candidate.json")
                    with self.assertRaisesRegex(CandidateMaterializationError, "canonical"):
                        materializer.write_candidate_identity(output, candidate, publication_fence=fence)
                    self.assertFalse(output.exists())
                finally:
                    parent.unlink()
                    moved.rename(parent)

    def test_parent_alias_installed_after_recheck_read_is_rejected_at_admission(self):
        for kind in ("manifest", "evidence"):
            with self.subTest(kind=kind):
                target, parent = self.isolated_input_parent(kind)
                moved = parent.with_name(parent.name + "-moved")
                original_require = materializer.require_unchanged_file_snapshot
                original_capture = materializer.capture_file_snapshot
                checking = False
                aliased = False

                def require(snapshot, **kwargs):
                    nonlocal checking
                    checking = snapshot.path == target
                    return original_require(snapshot, **kwargs)

                def capture_then_alias(path):
                    nonlocal aliased
                    snapshot = original_capture(path)
                    if path == target and checking and not aliased:
                        parent.rename(moved)
                        parent.symlink_to(moved, target_is_directory=True)
                        aliased = True
                    return snapshot

                try:
                    with mock.patch.object(materializer, "require_unchanged_file_snapshot", side_effect=require), \
                            mock.patch.object(materializer, "capture_file_snapshot", side_effect=capture_then_alias):
                        with self.assertRaisesRegex(CandidateMaterializationError, "canonical"):
                            self.materialize()
                finally:
                    if aliased:
                        parent.unlink()
                        moved.rename(parent)


if __name__ == "__main__":
    unittest.main()
