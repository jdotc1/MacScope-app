from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
HELPER = ROOT / "Scripts/dependencies/zig_toolchain_receipt.py"
MATERIALIZER = ROOT / "Scripts/dependencies/materialize_zig_toolchain.sh"
SURFACE_BUILDER = ROOT / "Scripts/dependencies/build_ghostty_surface.sh"
CONTRACT = ROOT / "Scripts/ghostty-vt-source.contract"
FIXTURE_VERSION = "0.16.0"
FIXTURE_ARCHIVE_SHA256 = "a" * 64
ALTERNATE_ARCHIVE_SHA256 = "b" * 64


def load_helper():
    spec = importlib.util.spec_from_file_location("zig_toolchain_receipt", HELPER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {HELPER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


helper = load_helper()


class ZigToolchainReceiptTests(unittest.TestCase):
    def make_toolchain(
        self, parent: pathlib.Path, *, marker: bytes | None = None
    ) -> pathlib.Path:
        root = parent / "zig-0.16.0"
        (root / "lib/std").mkdir(parents=True)
        executable = root / "zig"
        executable.write_text("#!/bin/sh\necho 0.16.0\n", encoding="utf-8")
        executable.chmod(0o755)
        (root / "lib/std/std.zig").write_text("pub const fixture = true;\n")
        if marker is not None:
            (root / "alternate-marker").write_bytes(marker)
        return root

    def make_package_store(self, root: pathlib.Path) -> pathlib.Path:
        store = root / "zig-pkg"
        (store / "1220_alpha/src").mkdir(parents=True)
        (store / "1220_alpha/src/a.zig").write_bytes(b"alpha\n")
        (store / "1220_beta").mkdir()
        (store / "1220_beta/data.bin").write_bytes(b"beta\x00")
        return store

    def make_ghostty_source(self, root: pathlib.Path) -> pathlib.Path:
        source = root / "ghostty"
        (source / "src").mkdir(parents=True)
        (source / "src/main.zig").write_text("pub fn main() void {}\n")
        (source / "build.zig.zon").write_text(".{}\n")
        return source

    def package_digest_for_paths(
        self, store: pathlib.Path, relative_paths: list[pathlib.Path]
    ) -> str:
        digest = hashlib.sha256()
        for relative_path in relative_paths:
            path = store / relative_path
            relative = path.relative_to(store).as_posix().encode()
            payload = path.read_bytes()
            digest.update(len(relative).to_bytes(8, "big"))
            digest.update(relative)
            digest.update(len(payload).to_bytes(8, "big"))
            digest.update(payload)
        return digest.hexdigest()

    def independent_package_digest(self, store: pathlib.Path) -> str:
        return self.package_digest_for_paths(
            store,
            sorted(
                (path.relative_to(store) for path in store.rglob("*") if path.is_file()),
                key=lambda path: path.as_posix().encode(),
            ),
        )

    def depth_first_package_paths(self, directory: pathlib.Path) -> list[pathlib.Path]:
        paths: list[pathlib.Path] = []

        def visit(current: pathlib.Path) -> None:
            for child in sorted(current.iterdir(), key=lambda path: os.fsencode(path.name)):
                if child.is_dir():
                    visit(child)
                else:
                    paths.append(child.relative_to(directory))

        visit(directory)
        return paths

    def independent_ghostty_source_digest(self, source: pathlib.Path) -> str:
        digest = hashlib.sha256()
        excluded_roots = {".git", ".zig-cache", "zig-out", "zig-pkg"}
        files = sorted(
            (
                path
                for path in source.rglob("*")
                if path.is_file()
                and path.relative_to(source).parts[0] not in excluded_roots
            ),
            key=lambda path: os.fsencode(path.relative_to(source).as_posix()),
        )
        for path in files:
            relative = path.relative_to(source).as_posix().encode("utf-8")
            payload = path.read_bytes()
            digest.update(len(relative).to_bytes(8, "big"))
            digest.update(relative)
            digest.update(len(payload).to_bytes(8, "big"))
            digest.update(payload)
        return digest.hexdigest()

    def depth_first_ghostty_source_digest(self, source: pathlib.Path) -> str:
        digest = hashlib.sha256()

        def visit(directory: pathlib.Path) -> None:
            for path in sorted(directory.iterdir(), key=lambda candidate: os.fsencode(candidate.name)):
                if path.is_dir():
                    visit(path)
                    continue
                relative = path.relative_to(source).as_posix().encode("utf-8")
                payload = path.read_bytes()
                digest.update(len(relative).to_bytes(8, "big"))
                digest.update(relative)
                digest.update(len(payload).to_bytes(8, "big"))
                digest.update(payload)

        visit(source)
        return digest.hexdigest()

    def test_receipt_round_trip_binds_the_closed_toolchain_tree(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            parent = pathlib.Path(directory)
            root = self.make_toolchain(parent)
            tree = helper.closed_tree_identity(root)["toolchain_tree_sha256"]
            receipt = parent / "zig.receipt.json"
            written = helper.write_receipt(root, receipt, "0.16.0", "a" * 64, tree)
            observed = helper.verify_receipt(root, receipt, "0.16.0", "a" * 64, tree)

        self.assertEqual(observed, written)

    def test_command_line_create_and_verify_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            parent = pathlib.Path(directory)
            root = self.make_toolchain(parent)
            tree = helper.closed_tree_identity(root)["toolchain_tree_sha256"]
            receipt = parent / "zig.receipt.json"
            arguments = [
                "--root",
                str(root),
                "--receipt",
                str(receipt),
                "--expected-version",
                FIXTURE_VERSION,
                "--expected-archive-sha256",
                FIXTURE_ARCHIVE_SHA256,
                "--expected-tree-sha256",
                str(tree),
            ]

            created = subprocess.run(
                [sys.executable, str(HELPER), "create", *arguments],
                capture_output=True,
                text=True,
                check=False,
            )
            verified = subprocess.run(
                [sys.executable, str(HELPER), "verify", *arguments],
                capture_output=True,
                text=True,
                check=False,
            )

        self.assertEqual(created.returncode, 0, created.stderr)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        self.assertRegex(created.stdout.strip(), r"^[0-9a-f]{64}$")
        self.assertEqual(verified.stdout, created.stdout)

    def test_finder_metadata_does_not_change_toolchain_or_receipt_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            parent = pathlib.Path(directory)
            root = self.make_toolchain(parent)
            expected_identity = helper.closed_tree_identity(root)
            tree = expected_identity["toolchain_tree_sha256"]
            receipt = parent / "zig.receipt.json"
            expected_receipt = helper.write_receipt(root, receipt, FIXTURE_VERSION,
                FIXTURE_ARCHIVE_SHA256, tree)
            for folder in (root, root / "lib", root / "lib/std"):
                (folder / ".DS_Store").write_bytes(b"Finder display metadata")
                (folder / "._std.zig").write_bytes(b"AppleDouble metadata")
            self.assertEqual(helper.closed_tree_identity(root), expected_identity)
            self.assertEqual(helper.verify_receipt(root, receipt, FIXTURE_VERSION,
                FIXTURE_ARCHIVE_SHA256, tree), expected_receipt)
            # An ordinary unexpected leaf remains part of the pinned closure.
            (root / "lib/std/unexpected.zig").write_bytes(b"pub const changed = true;\n")
            with self.assertRaises(helper.ZigToolchainReceiptError):
                helper.verify_receipt(root, receipt, FIXTURE_VERSION,
                    FIXTURE_ARCHIVE_SHA256, tree)

    def test_materializer_and_surface_manifest_share_canonical_receipt_identity(self) -> None:
        contract = CONTRACT.read_text(encoding="utf-8")
        materializer = MATERIALIZER.read_text(encoding="utf-8")
        surface_builder = SURFACE_BUILDER.read_text(encoding="utf-8")

        for expected in (
            "EXPECTED_ZIG_AARCH64_MACOS_SHA256=",
            "EXPECTED_ZIG_AARCH64_MACOS_TREE_SHA256=",
            "EXPECTED_ZIG_TOOLCHAIN_RECEIPT_SHA256=",
        ):
            self.assertIn(expected, contract)
        for fragment in (
            "zig_toolchain_receipt.py",
            "--expected-archive-sha256",
            "--expected-tree-sha256",
            '"${EXPECTED_ZIG_TOOLCHAIN_RECEIPT_SHA256}"',
            "MACSCOPE_ZIG_RECEIPT=",
            "MACSCOPE_ZIG_RECEIPT_SHA256=",
        ):
            self.assertIn(fragment, materializer)
        for fragment in (
            "zig_toolchain_receipt.py",
            'ZIG_ROOT="${MACSCOPE_ZIG_ROOT:-}"',
            'ZIG_RECEIPT="${MACSCOPE_ZIG_RECEIPT:-}"',
            "zig_archive_sha256=",
            "zig_toolchain_tree_sha256=",
            "zig_toolchain_receipt_sha256=",
        ):
            self.assertIn(fragment, surface_builder)
        self.assertNotIn("/opt/homebrew/bin/zig", surface_builder)

    def test_alternate_same_version_toolchain_and_receipt_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            accepted_parent = root / "accepted"
            alternate_parent = root / "alternate"
            accepted_parent.mkdir()
            alternate_parent.mkdir()
            accepted = self.make_toolchain(accepted_parent)
            alternate = self.make_toolchain(alternate_parent, marker=b"different tree")
            accepted_tree = helper.closed_tree_identity(accepted)["toolchain_tree_sha256"]
            alternate_tree = helper.closed_tree_identity(alternate)["toolchain_tree_sha256"]
            alternate_receipt = root / "alternate.receipt.json"
            helper.write_receipt(
                alternate, alternate_receipt, "0.16.0", "a" * 64, alternate_tree
            )

            with self.assertRaisesRegex(
                helper.ZigToolchainReceiptError, "official materialization"
            ):
                helper.verify_receipt(
                    alternate,
                    alternate_receipt,
                    "0.16.0",
                    "a" * 64,
                    accepted_tree,
                )

    def test_toolchain_content_mode_and_directory_shape_drift_are_rejected(self) -> None:
        for mutation in ("content", "mode", "directory"):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                parent = pathlib.Path(directory)
                accepted = self.make_toolchain(parent / "accepted")
                expected_tree = helper.closed_tree_identity(accepted)[
                    "toolchain_tree_sha256"
                ]
                mutated_parent = parent / mutation
                mutated_parent.mkdir()
                mutated = mutated_parent / "zig-0.16.0"
                shutil.copytree(accepted, mutated)
                receipt = mutated_parent / "zig.receipt.json"
                helper.write_receipt(
                    mutated,
                    receipt,
                    FIXTURE_VERSION,
                    FIXTURE_ARCHIVE_SHA256,
                    str(expected_tree),
                )

                if mutation == "content":
                    (mutated / "lib/std/std.zig").write_text(
                        "pub const fixture = false;\n", encoding="utf-8"
                    )
                elif mutation == "mode":
                    (mutated / "lib/std/std.zig").chmod(0o600)
                else:
                    (mutated / "unexpected-empty-directory").mkdir()

                expected_error = (
                    "empty directory" if mutation == "directory" else "official materialization"
                )
                with self.assertRaisesRegex(
                    helper.ZigToolchainReceiptError, expected_error
                ):
                    helper.verify_receipt(
                        mutated,
                        receipt,
                        FIXTURE_VERSION,
                        FIXTURE_ARCHIVE_SHA256,
                        str(expected_tree),
                    )

    def test_toolchain_rejects_symbolic_and_hard_link_entries(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            parent = pathlib.Path(directory)
            symbolic = self.make_toolchain(parent / "symbolic")
            (symbolic / "lib/std/alias.zig").symlink_to("std.zig")
            with self.assertRaisesRegex(
                helper.ZigToolchainReceiptError, "symbolic link"
            ):
                helper.closed_tree_identity(symbolic)

            hard_linked = self.make_toolchain(parent / "hard-linked")
            os.link(
                hard_linked / "lib/std/std.zig",
                hard_linked / "lib/std/alias.zig",
            )
            with self.assertRaisesRegex(
                helper.ZigToolchainReceiptError, "hard-linked"
            ):
                helper.closed_tree_identity(hard_linked)

    def test_receipt_schema_and_archive_provenance_drift_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            parent = pathlib.Path(directory)
            root = self.make_toolchain(parent)
            tree = helper.closed_tree_identity(root)["toolchain_tree_sha256"]
            receipt = parent / "zig.receipt.json"
            helper.write_receipt(
                root,
                receipt,
                FIXTURE_VERSION,
                FIXTURE_ARCHIVE_SHA256,
                str(tree),
            )

            with self.assertRaisesRegex(
                helper.ZigToolchainReceiptError, "verified toolchain identity"
            ):
                helper.verify_receipt(
                    root,
                    receipt,
                    FIXTURE_VERSION,
                    ALTERNATE_ARCHIVE_SHA256,
                    str(tree),
                )

            decoded = json.loads(receipt.read_text(encoding="utf-8"))
            decoded["unreviewed"] = True
            receipt.write_text(
                json.dumps(decoded, sort_keys=True, separators=(",", ":")) + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                helper.ZigToolchainReceiptError, "unexpected schema"
            ):
                helper.verify_receipt(
                    root,
                    receipt,
                    FIXTURE_VERSION,
                    FIXTURE_ARCHIVE_SHA256,
                    str(tree),
                )

    def test_non_executable_same_version_toolchain_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = self.make_toolchain(pathlib.Path(directory))
            expected_tree = helper.closed_tree_identity(root)["toolchain_tree_sha256"]
            (root / "zig").chmod(0o644)

            with self.assertRaisesRegex(
                helper.ZigToolchainReceiptError, "ordinary executable file"
            ):
                helper.write_receipt(
                    root,
                    pathlib.Path(directory) / "zig.receipt.json",
                    FIXTURE_VERSION,
                    FIXTURE_ARCHIVE_SHA256,
                    str(expected_tree),
                )

    def test_package_store_matches_independent_path_content_digest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = self.make_package_store(pathlib.Path(directory))
            expected = self.independent_package_digest(store)

            observed = helper.verify_package_store(store, expected)

        self.assertEqual(observed, expected)

    def test_package_store_uses_global_bytewise_leaf_order_not_traversal_order(self) -> None:
        """Global record order is load-bearing for the frozen Ghostty closure.

        The directory ``a`` sorts before sibling leaf ``a.`` while the complete
        leaf path ``a.`` sorts before ``a/child`` (``.`` precedes ``/``).  This
        is therefore a real ordering distinction rather than a count-only test.
        """
        with tempfile.TemporaryDirectory() as directory:
            store = pathlib.Path(directory) / "zig-pkg"
            (store / "a").mkdir(parents=True)
            (store / "a/child.zig").write_bytes(b"nested\n")
            (store / "a.").write_bytes(b"sibling\n")

            globally_sorted = sorted(
                (path.relative_to(store) for path in store.rglob("*") if path.is_file()),
                key=lambda path: path.as_posix().encode(),
            )
            depth_first = self.depth_first_package_paths(store)
            expected = self.package_digest_for_paths(store, globally_sorted)
            depth_first_digest = self.package_digest_for_paths(store, depth_first)
            reversed_digest = self.package_digest_for_paths(
                store, list(reversed(globally_sorted))
            )

            self.assertEqual([path.as_posix() for path in globally_sorted], ["a.", "a/child.zig"])
            self.assertEqual([path.as_posix() for path in depth_first], ["a/child.zig", "a."])
            self.assertNotEqual(expected, depth_first_digest)
            self.assertNotEqual(expected, reversed_digest)
            self.assertEqual(helper.verify_package_store(store, expected), expected)

    def test_package_store_content_drift_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            store = self.make_package_store(pathlib.Path(directory))
            expected = self.independent_package_digest(store)
            (store / "1220_alpha/src/a.zig").write_bytes(b"drift\n")

            with self.assertRaisesRegex(
                helper.ZigPackageStoreError, "frozen dependency closure"
            ):
                helper.verify_package_store(store, expected)

    def test_package_store_rejects_unmodeled_entries(self) -> None:
        for entry in (
            "symlink",
            "hardlink",
            "empty-directory",
        ):
            with self.subTest(entry=entry), tempfile.TemporaryDirectory() as directory:
                store = self.make_package_store(pathlib.Path(directory))
                if entry == "symlink":
                    (store / "link").symlink_to("1220_alpha")
                elif entry == "hardlink":
                    os.link(store / "1220_beta/data.bin", store / "hardlink")
                else:
                    (store / "empty").mkdir()

                with self.assertRaises(helper.ZigPackageStoreError):
                    helper.package_store_identity(store)

    def test_metadata_is_excluded_from_all_private_input_snapshots(self) -> None:
        for kind, make_input, identity, digest_key, error_type in (
            ("toolchain", self.make_toolchain, helper.closed_tree_identity,
             "toolchain_tree_sha256", helper.ZigToolchainReceiptError),
            ("package-store", self.make_package_store, helper.package_store_identity,
             "package_store_sha256", helper.ZigPackageStoreError),
            ("ghostty-source", self.make_ghostty_source, helper.ghostty_source_identity,
             "source_tree_sha256", helper.GhosttySourceError),
        ):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                parent = pathlib.Path(directory)
                source = make_input(parent)
                expected = identity(source)
                for folder in [source, *(p for p in source.rglob("*") if p.is_dir())]:
                    (folder / ".DS_Store").write_bytes(b"Finder metadata")
                    (folder / "._metadata").write_bytes(b"AppleDouble metadata")
                self.assertEqual(identity(source), expected)
                snapshot = parent / "private-snapshot"
                helper.create_private_snapshot(kind, source, snapshot, expected[digest_key])
                observed = identity(snapshot)
                self.assertEqual({key: value for key, value in observed.items()
                                  if key != "canonical_root"},
                                 {key: value for key, value in expected.items()
                                  if key != "canonical_root"})
                self.assertFalse(any(p.name == ".DS_Store" or p.name.startswith("._")
                                     for p in snapshot.rglob("*")))
                # A similar-looking ordinary name must still participate in the pin.
                (source / ".DS_Store.backup").write_bytes(b"ordinary unexpected input")
                with self.assertRaises(error_type):
                    helper.create_private_snapshot(kind, source, parent / "bad-snapshot",
                                                   expected[digest_key])

    def test_ghostty_source_rejects_link_escape_and_snapshot_preserves_pin(self) -> None:
        for entry in ("symlink", "hardlink"):
            with self.subTest(entry=entry), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                source = self.make_ghostty_source(root)
                if entry == "symlink":
                    (source / "escape").symlink_to("/private/tmp")
                else:
                    os.link(source / "src/main.zig", source / "duplicate.zig")
                with self.assertRaises(helper.GhosttySourceError):
                    helper.ghostty_source_identity(source)

        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = self.make_ghostty_source(root)
            (source / "zig-out/lib").mkdir(parents=True)
            (source / "zig-out/lib/cache-artifact").write_bytes(b"untrusted output")
            expected = helper.ghostty_source_identity(source)["source_tree_sha256"]
            snapshot = root / "private-snapshot"
            identity = helper.create_private_snapshot(
                "ghostty-source", source, snapshot, expected
            )
            self.assertEqual(identity["source_tree_sha256"], expected)
            self.assertEqual(helper.verify_ghostty_source(snapshot, expected), expected)
            self.assertFalse((snapshot / "zig-out").exists())
            # A cache-tree mutation after the snapshot cannot alter the private
            # build input, even if the cache is restored before a later check.
            original = (source / "src/main.zig").read_bytes()
            (source / "src/main.zig").write_bytes(b"mutated\n")
            (source / "src/main.zig").write_bytes(original)
            self.assertEqual(
                (snapshot / "src/main.zig").read_bytes(), original
            )

    def test_ghostty_source_matches_global_bytewise_leaf_order_not_depth_first_order(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / "ghostty"
            (source / "a").mkdir(parents=True)
            (source / "a/inside.zig").write_bytes(b"nested leaf\n")
            (source / "a.txt").write_bytes(b"sibling leaf\n")

            expected = self.independent_ghostty_source_digest(source)
            depth_first = self.depth_first_ghostty_source_digest(source)
            observed = helper.ghostty_source_identity(source)["source_tree_sha256"]

        self.assertNotEqual(depth_first, expected)
        self.assertEqual(observed, expected)


if __name__ == "__main__":
    unittest.main()
