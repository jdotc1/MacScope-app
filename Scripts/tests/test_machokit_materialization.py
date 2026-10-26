from __future__ import annotations

import argparse
import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "dependencies" / "materialize_machokit.py"
IDENTITY_SCRIPT = ROOT / "Scripts" / "machokit_source_identity.py"


def load_module(name: str, path: Path):
    specification = importlib.util.spec_from_file_location(name, path)
    assert specification is not None and specification.loader is not None
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


MODULE = load_module("materialize_machokit_test", SCRIPT)


class MachOKitMaterializationTests(unittest.TestCase):
    component_names = (
        "MachOKit",
        "swift-fileio",
        "swift-fileio-extra",
        "swift-binary-parse-support",
    )

    def make_component_tree(self, root: Path, *, marker: str = "same") -> None:
        for name in self.component_names:
            component = root / name
            component.mkdir(parents=True)
            (component / "Package.swift").write_text(
                f"// {name} local package\n", encoding="utf-8"
            )
            (component / "Sources.swift").write_text(
                f"// deterministic {marker}\n", encoding="utf-8"
            )
        MODULE._write_local_manifests(root)
        MODULE._write_compiled_build_identity(root)

    def write_manifest(self, root: Path) -> dict[str, object]:
        records = [
            {
                "name": component.name,
                "repository": component.repository,
                "revision": component.revision,
                "git_tree": component.git_tree,
                "acquisition": "local-clean-git-checkout",
                "tree_sha256": MODULE._tree_digest(root / component.name),
            }
            for component in MODULE.COMPONENTS
        ]
        manifest = MODULE._canonical_manifest(root, records)
        (root / "MATERIALIZATION.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        return manifest

    def test_safe_extract_rejects_parent_traversal_and_duplicate_entries(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            traversal = root / "traversal.zip"
            with zipfile.ZipFile(traversal, "w") as archive:
                archive.writestr("MachOKit/../../escape", b"bad")
            with self.assertRaisesRegex(MODULE.MaterializationError, "unsafe archive path"):
                MODULE._safe_extract_zip(traversal, root / "out-traversal")

            duplicate = root / "duplicate.zip"
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                with zipfile.ZipFile(duplicate, "w") as archive:
                    archive.writestr("MachOKit/Package.swift", b"one")
                    archive.writestr("MachOKit/Package.swift", b"two")
            with self.assertRaisesRegex(MODULE.MaterializationError, "duplicate archive entry"):
                MODULE._safe_extract_zip(duplicate, root / "out-duplicate")

    def test_safe_extract_omits_links_without_materializing_them(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive_path = root / "source.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("MachOKit/Package.swift", "// package\n")
                link = zipfile.ZipInfo("MachOKit/Alias.md")
                link.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(link, "README.md")
            extracted = MODULE._safe_extract_zip(archive_path, root / "out")
            self.assertTrue((extracted / "Package.swift").is_file())
            self.assertFalse((extracted / "Alias.md").exists())

    def test_local_manifests_are_direct_source_only_and_narrow(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_component_tree(root)
            machokit = (root / "MachOKit" / "Package.swift").read_text(encoding="utf-8")
            extra = (root / "swift-fileio-extra" / "Package.swift").read_text(
                encoding="utf-8"
            )
            self.assertIn('.library(name: "MachOKit", targets: ["MachOKit"])', machokit)
            self.assertNotIn("MachOArchiveKit", machokit)
            self.assertNotIn(".binaryTarget", machokit)
            self.assertNotIn(".xcframework", machokit.lower())
            self.assertNotIn("http://", machokit)
            self.assertNotIn("https://", machokit)
            self.assertIn('.package(path: "../swift-binary-parse-support")', extra)
            self.assertNotIn(b"\r\n", (root / "MachOKit" / "Package.swift").read_bytes())

    def test_nested_package_manifest_is_rejected_or_omitted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_component_tree(root)
            benchmark = root / "MachOKit" / "Benchmarks"
            benchmark.mkdir()
            (benchmark / "Package.swift").write_text(
                'import PackageDescription\n'
                'let package = Package(name: "Benchmarks", dependencies: ['
                '.package(url: "https://example.invalid/benchmark", from: "1.0.0")])\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                MODULE.MaterializationError, "unadmitted MachOKit subtree"
            ):
                MODULE._validate_admitted_source_shape(root)
            MODULE._omit_unadmitted_source_subtrees(root)
            MODULE._validate_admitted_source_shape(root)
            self.assertFalse(benchmark.exists())

    def test_recursive_package_validation_rejects_unreviewed_url_and_binary_targets(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_component_tree(root)
            nested = root / "swift-fileio" / "Examples"
            nested.mkdir()
            manifest = nested / "Package.swift"
            manifest.write_text(
                '.package(url: "https://example.invalid/dependency", from: "1.0.0")\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(MODULE.MaterializationError, "unreviewed URL"):
                MODULE._validate_admitted_source_shape(root)
            manifest.write_text(
                '.binaryTarget(name: "Opaque", path: "Opaque.xcframework")\n',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(MODULE.MaterializationError, "binary package"):
                MODULE._validate_admitted_source_shape(root)

    def test_deterministic_writer_is_compatible_with_python_3_9(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "receipt.txt"
            MODULE._write_text(output, "first\nsecond\n")
            self.assertEqual(output.read_bytes(), b"first\nsecond\n")

    def test_verify_rejects_tamper_extra_component_xcframework_and_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_component_tree(root)
            self.write_manifest(root)
            MODULE._verify_root(root, quiet=True, enforce_reviewed_digests=False)

            tamper = root / "swift-fileio" / "Sources.swift"
            original = tamper.read_text(encoding="utf-8")
            tamper.write_text("tamper\n", encoding="utf-8")
            with self.assertRaisesRegex(
                MODULE.MaterializationError,
                "governed MachOKit source identity mismatch|tree checksum mismatch",
            ):
                MODULE._verify_root(root, quiet=True, enforce_reviewed_digests=False)
            tamper.write_text(original, encoding="utf-8")

            extra = root / "unexpected-component"
            extra.mkdir()
            with self.assertRaisesRegex(MODULE.MaterializationError, "unexpected root entry"):
                MODULE._verify_root(root, quiet=True, enforce_reviewed_digests=False)
            extra.rmdir()

            xcframework = root / "MachOKit" / "MachOKit.xcframework"
            xcframework.mkdir()
            with self.assertRaisesRegex(MODULE.MaterializationError, "XCFramework"):
                MODULE._verify_root(root, quiet=True, enforce_reviewed_digests=False)
            xcframework.rmdir()

            link = root / "MachOKit" / "unsafe-link"
            link.symlink_to("Package.swift")
            with self.assertRaisesRegex(MODULE.MaterializationError, "symbolic link"):
                MODULE._verify_root(root, quiet=True, enforce_reviewed_digests=False)

    def test_verify_rejects_multiply_linked_source_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_component_tree(root)
            self.write_manifest(root)
            MODULE._freeze_tree(root)
            source = root / "MachOKit" / "Sources.swift"
            alias = root / "MachOKit" / "Sources.alias.swift"
            (root / "MachOKit").chmod(0o755)
            os.link(source, alias)
            (root / "MachOKit").chmod(0o555)
            with self.assertRaisesRegex(MODULE.MaterializationError, "multiply linked"):
                MODULE._verify_root(
                    root,
                    quiet=True,
                    enforce_reviewed_digests=False,
                    enforce_read_only=True,
                )

    def test_manifest_is_deterministic_across_equivalent_roots(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            outer = Path(temporary)
            left = outer / "left"
            right = outer / "right"
            left.mkdir()
            right.mkdir()
            self.make_component_tree(left)
            self.make_component_tree(right)
            left_manifest = self.write_manifest(left)
            right_manifest = self.write_manifest(right)
            self.assertEqual(left_manifest, right_manifest)
            self.assertEqual(
                (left / "MATERIALIZATION.json").read_bytes(),
                (right / "MATERIALIZATION.json").read_bytes(),
            )
            self.assertEqual(
                MODULE._governed_source_identity(left),
                MODULE._governed_source_identity(right),
            )
            self.assertEqual(
                (left / MODULE.BUILD_IDENTITY_RELATIVE_PATH).read_bytes(),
                (right / MODULE.BUILD_IDENTITY_RELATIVE_PATH).read_bytes(),
            )

    def test_compiled_build_marker_is_exact_and_rejects_missing_or_drift(self) -> None:
        verifier = load_module("machokit_source_identity_marker_test", IDENTITY_SCRIPT)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_component_tree(root)
            manifest = self.write_manifest(root)
            expected_identity = MODULE._governed_source_identity(root)
            expected_marker = MODULE._compiled_build_marker(expected_identity)
            marker_path = root / MODULE.BUILD_IDENTITY_RELATIVE_PATH
            self.assertEqual(
                MODULE.BUILD_IDENTITY_PREFIX, "MACSCOPE_MACHOKIT_BUILD_ID"
            )
            self.assertTrue(
                expected_marker.startswith("MACSCOPE_MACHOKIT_BUILD_ID:")
            )
            self.assertEqual(manifest["governed_source_identity"], expected_identity)
            self.assertEqual(manifest["compiled_build_marker"], expected_marker)
            self.assertEqual(
                marker_path.read_text(encoding="utf-8").count(expected_marker), 1
            )
            MODULE._verify_compiled_build_identity(
                root, manifest, enforce_reviewed_digest=False
            )
            verifier.verify_compiled_build_identity(
                root, manifest, enforce_reviewed_digest=False
            )

            source = marker_path.read_text(encoding="utf-8")
            marker_path.write_text(source.replace(expected_marker, "drifted-marker"), encoding="utf-8")
            with self.assertRaisesRegex(MODULE.MaterializationError, "source drifted"):
                MODULE._verify_compiled_build_identity(
                    root, manifest, enforce_reviewed_digest=False
                )
            with self.assertRaisesRegex(
                verifier.MachOKitSourceIdentityError, "source drifted"
            ):
                verifier.verify_compiled_build_identity(
                    root, manifest, enforce_reviewed_digest=False
                )
            marker_path.write_text(source, encoding="utf-8")
            marker_path.unlink()
            with self.assertRaisesRegex(MODULE.MaterializationError, "missing or unsafe"):
                MODULE._verify_compiled_build_identity(
                    root, manifest, enforce_reviewed_digest=False
                )

    def test_freeze_publishes_read_only_shape_without_changing_identity(self) -> None:
        verifier = load_module("machokit_source_identity_readonly_test", IDENTITY_SCRIPT)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "materialization"
            root.mkdir()
            self.make_component_tree(root)
            self.write_manifest(root)
            before = MODULE._tree_digest(root)
            MODULE._freeze_tree(root)
            MODULE._verify_read_only_shape(root)
            verifier.verify_read_only_shape(root)
            self.assertEqual(MODULE._tree_digest(root), before)
            for path in [root, *root.rglob("*")]:
                self.assertEqual(path.lstat().st_mode & 0o222, 0, path)

            source = root / "MachOKit" / "Sources.swift"
            source.chmod(0o644)
            source.write_text("// frozen-content-drift\n", encoding="utf-8")
            source.chmod(0o444)
            with self.assertRaisesRegex(
                MODULE.MaterializationError, "governed MachOKit source identity mismatch"
            ):
                MODULE._verify_root(
                    root,
                    quiet=True,
                    enforce_reviewed_digests=False,
                    enforce_read_only=True,
                )

    def test_repository_closure_publishes_reusable_external_read_only_view(self) -> None:
        verifier = load_module("machokit_source_identity_publisher_test", IDENTITY_SCRIPT)
        source = ROOT / "ThirdParty" / "MachOKit" / "materialization"
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary).resolve() / "external-view"
            published = verifier.publish_read_only_view(source, work, quiet=True)
            self.assertEqual(verifier.verify_root(published, quiet=True), published)
            self.assertEqual(
                verifier.publish_read_only_view(source, work, quiet=True),
                published,
            )
            self.assertIn(work, published.parents)
            self.assertNotIn(ROOT, published.parents)
            for path in [published, *published.rglob("*")]:
                self.assertEqual(path.lstat().st_mode & 0o222, 0, path)

    def test_repository_view_publisher_rejects_in_repository_work_root(self) -> None:
        verifier = load_module("machokit_source_identity_containment_test", IDENTITY_SCRIPT)
        source = ROOT / "ThirdParty" / "MachOKit" / "materialization"
        with self.assertRaisesRegex(
            verifier.MachOKitSourceIdentityError,
            "outside the repository",
        ):
            verifier.publish_read_only_view(
                source,
                ROOT / ".forbidden-machokit-view",
                quiet=True,
            )

    def test_failed_replacement_preserves_prior_accepted_tree(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            accepted = root / "accepted"
            accepted.mkdir()
            self.make_component_tree(accepted)
            self.write_manifest(accepted)
            before = MODULE._tree_digest(accepted)
            arguments = argparse.Namespace(
                output_root=accepted,
                machokit_archive=root / "not-consulted.zip",
                local_source=[],
            )
            with self.assertRaisesRegex(MODULE.MaterializationError, "destination already exists"):
                MODULE.materialize(arguments)
            self.assertEqual(MODULE._tree_digest(accepted), before)
            MODULE._verify_root(accepted, quiet=True, enforce_reviewed_digests=False)

    def test_manifest_rejects_malformed_and_mismatched_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_component_tree(root)
            manifest = self.write_manifest(root)
            manifest["provider"] = {"id": "different-provider"}
            (root / "MATERIALIZATION.json").write_text(
                json.dumps(manifest), encoding="utf-8"
            )
            with self.assertRaisesRegex(MODULE.MaterializationError, "provider identity"):
                MODULE._verify_root(root, quiet=True, enforce_reviewed_digests=False)

    def test_offline_identity_verifier_matches_materializer_contract(self) -> None:
        verifier = load_module("machokit_source_identity_test", IDENTITY_SCRIPT)
        self.assertEqual(verifier.SCHEMA_VERSION, MODULE.SCHEMA_VERSION)
        self.assertEqual(verifier.MACHOKIT_VERSION, MODULE.MACHOKIT_VERSION)
        self.assertEqual(verifier.MACHOKIT_REVISION, MODULE.MACHOKIT_REVISION)
        self.assertEqual(verifier.MACHOKIT_ARCHIVE_SHA256, MODULE.MACHOKIT_ARCHIVE_SHA256)
        self.assertEqual(verifier.MACHOKIT_UPSTREAM_TREE_SHA256, MODULE.MACHOKIT_UPSTREAM_TREE_SHA256)
        self.assertEqual(
            [
                (item.name, item.repository, item.revision, item.git_tree, item.materialized_tree_sha256)
                for item in verifier.COMPONENTS
            ],
            [
                (item.name, item.repository, item.revision, item.git_tree, item.materialized_tree_sha256)
                for item in MODULE.COMPONENTS
            ],
        )
        self.assertEqual(verifier.MATERIALIZATION_TREE_SHA256, MODULE.MATERIALIZATION_TREE_SHA256)
        self.assertEqual(verifier.GOVERNED_SOURCE_IDENTITY, MODULE.GOVERNED_SOURCE_IDENTITY)
        self.assertEqual(
            verifier.BUILD_IDENTITY_RELATIVE_PATH,
            MODULE.BUILD_IDENTITY_RELATIVE_PATH,
        )
        verifier_source = IDENTITY_SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn("subprocess", verifier_source)
        self.assertNotIn("urlopen", verifier_source)
        self.assertNotIn("git fetch", verifier_source)

    def test_materializer_exposes_no_network_acquisition_path(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        for prohibited in (
            "--allow-network",
            '["git", "fetch"',
            '["git", "clone"',
            "urlopen(",
            "curl ",
        ):
            self.assertNotIn(prohibited, source)
        self.assertIn("never acquires source from a network", source)
        self.assertIn("already exist locally", source)

    def test_identity_link_replaces_dangling_link_and_refuses_unverified_target(self) -> None:
        identity = load_module("machokit_source_identity_link_test", IDENTITY_SCRIPT)
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            macscope = base / "Repository" / "MacScope"
            macscope.mkdir(parents=True)
            (macscope / "project.yml").write_text("name: MacScope\n", encoding="utf-8")
            view = base / "DevLoop.noindex" / "MachOKit" / "view"
            view.mkdir(parents=True)
            link = macscope / "LocalPackages"
            link.symlink_to(base / "wiped-tmpdir" / "view", target_is_directory=True)
            original = identity.verify_root

            def fake_verify(root, quiet=False):
                if Path(root).resolve() != view:
                    raise identity.MachOKitSourceIdentityError("not a view")
                return view

            identity.verify_root = fake_verify
            try:
                identity.link_root(view, macscope, quiet=True)
                self.assertEqual(link.resolve(strict=True), view)
                other = base / "unrelated"
                other.mkdir()
                link.unlink()
                link.symlink_to(other, target_is_directory=True)
                with self.assertRaisesRegex(
                    identity.MachOKitSourceIdentityError, "targets another root"
                ):
                    identity.link_root(view, macscope, quiet=True)
            finally:
                identity.verify_root = original

    def test_bootstrap_default_work_root_survives_restart(self) -> None:
        bootstrap = (ROOT / "Scripts/bootstrap.sh").read_text(encoding="utf-8")
        self.assertIn(
            'MACHOKIT_WORK_ROOT="${MACSCOPE_MACHOKIT_MATERIALIZATION_WORK_ROOT:-'
            '${MACSCOPE_DEV_LOOP_ROOT:-$(macscope_work_root)/MacScopeDevLoop.noindex}/MachOKit}"',
            bootstrap,
        )
        self.assertNotIn("${TMPDIR:-/tmp}/MacScope/MachOKit", bootstrap)

    def test_link_refuses_materialization_inside_repository(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary) / "Repository"
            macscope = repository / "MacScope"
            materialization = repository / "dependencies"
            macscope.mkdir(parents=True)
            materialization.mkdir()
            (macscope / "project.yml").write_text("name: MacScope\n", encoding="utf-8")
            original = MODULE.verify_root
            MODULE.verify_root = lambda _root, quiet=False: materialization
            try:
                with self.assertRaisesRegex(MODULE.MaterializationError, "outside the repository"):
                    MODULE.link_root(materialization, macscope, quiet=True)
            finally:
                MODULE.verify_root = original

    def test_runtime_entrypoints_require_verify_link_and_forward_machokit_root(self) -> None:
        bootstrap = (ROOT / "Scripts/bootstrap.sh").read_text(encoding="utf-8")
        tests = (ROOT / "Scripts/test.sh").read_text(encoding="utf-8")
        qualifier = (ROOT / "Scripts/qualify_local_private_build.sh").read_text(
            encoding="utf-8"
        )
        xcconfig = (ROOT / "MacScope/DependencyRoots.xcconfig").read_text(
            encoding="utf-8"
        )
        ignore = (ROOT / ".gitignore").read_text(encoding="utf-8")

        self.assertIn("MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT", xcconfig)
        self.assertIn("MacScope/LocalPackages", ignore)
        self.assertIn(
            'MACHOKIT_ROOT="${MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT:-}"', bootstrap
        )
        self.assertIn("machokit_source_identity.py", bootstrap)
        self.assertIn("--materialization-root \"${MACHOKIT_ROOT}\"", bootstrap)
        self.assertIn("--macscope-directory \"${MACSCOPE_DIR}\"", bootstrap)
        self.assertIn(
            'MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT = ${MACHOKIT_ROOT}', bootstrap
        )
        self.assertIn(
            'MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT="${MACHOKIT_ROOT}"', bootstrap
        )
        self.assertIn("publish-read-only", bootstrap)
        self.assertIn("publish-read-only", tests)
        self.assertIn(
            '--source-root "${REPO_ROOT}/ThirdParty/MachOKit/materialization"',
            tests,
        )
        self.assertIn(
            'XCODEBUILD_INPUT_SETTINGS+=("MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT=${MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT}")',
            tests,
        )
        self.assertIn(
            'MACHOKIT_INPUT_ROOT="${MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT}"',
            qualifier,
        )
        self.assertIn('PRIVATE_MACHOKIT_ROOT="${RUN_ROOT}/private-machokit-input"', qualifier)
        self.assertIn('MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT="${PRIVATE_MACHOKIT_ROOT}"', qualifier)
        self.assertNotIn("materialize_machokit.py", bootstrap)
        self.assertNotIn("materialize_machokit.py", tests)
        self.assertNotIn("materialize_machokit.py", qualifier)


if __name__ == "__main__":
    unittest.main()
