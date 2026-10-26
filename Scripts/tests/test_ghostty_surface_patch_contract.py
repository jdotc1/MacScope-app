from __future__ import annotations

import hashlib
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SURFACE = ROOT / "ThirdParty" / "GhosttySurface"
PATCHES = SURFACE / "patches"
MATERIALIZER = ROOT / "Scripts/dependencies/materialize_ghostty_surface.sh"

EXPECTED_GHOSTTY_PATCHES = {
    "0001-test-gst-define-external-termio-ABI-and-backend-cont.patch":
        "5163ba711bd700e233d8b4ad5bfab137dd1aaaa5f4f2362e7746e6c55e0fe2cf",
    "0002-feat-gst-add-host-fed-external-termio-backend.patch":
        "cf57e88edc48fb9edc74f02f2c3446f4fcabe9b2ef6f86aa44a7de629bc9eca2",
    "0003-test-gst-harden-external-backend-ordering-and-lifecy.patch":
        "0ce86d6ba97f679f3857c784e173f71806e7bf3896a06338196f999ecb789045",
    "0004-build-gst-add-external-I-O-only-XCFramework-step.patch":
        "191bd9acbc86fd6621b8fe9e2a6e64a53125670861a31d36d66e870b179a4c58",
    "0005-build-gst-disable-root-networking-in-external-only.patch":
        "632d6b96c68da1f0286c47c9a5d19613caa2ff485d1ccefc911ed2c6d748f2a5",
}
LIBXEV_PATCH = "libxev-networking-capability.patch"
EXPECTED_LIBXEV_PATCH_SHA256 = "f26b438413c1ec2022f5e6701daa8d00920c91bc7da9f6add5d2e80662e0ff8d"
EXPECTED_CHANGED_PATHS = {
    "include/ghostty.h",
    "build.zig",
    "src/Surface.zig",
    "src/build/Config.zig",
    "src/main_ghostty.zig",
    "src/apprt/embedded.zig",
    "src/apprt/none.zig",
    "src/termio.zig",
    "src/termio/External.zig",
    "src/termio/backend.zig",
}
EXPECTED_EXPORTS = {
    "ghostty_surface_new_external",
    "ghostty_surface_external_feed",
    "ghostty_surface_external_set_process_state",
    "ghostty_surface_is_external_io",
}
EXPECTED_RAW_PACKAGE_STORE_SHA256 = "70147cac57344d68a8dd812b7dd85b1d0eae984da531064e424128f937105d0f"
EXPECTED_PACKAGE_STORE_SHA256 = "13f8e6d6cc075fc5c13bb211e624c2a4311ff47cae414b44b7d509830adbf84c"
EXPECTED_RAW_PATCHED_TREE = "b6aad1ba32602ee4eb3ea96fd88116a49ed09e97"
EXPECTED_PATCHED_TREE = "de6cd65b35a423d5d6854c6af3a90be20a52d7eb"
EXPECTED_PATCHED_SHA256 = "ead5d48a8cda07addb59af1f35c6c9f7226bbdbd977b7330afd9714ecec6d8ab"


def length_framed_source_digest(root: pathlib.Path) -> str:
    excluded = {".git", ".zig-cache", "zig-out", "zig-pkg", ".DS_Store"}
    files = sorted(
        (
            path for path in root.rglob("*")
            if path.is_file()
            and not any(part in excluded for part in path.relative_to(root).parts)
        ),
        key=lambda path: path.relative_to(root).as_posix(),
    )
    digest = hashlib.sha256()
    for path in files:
        relative = path.relative_to(root).as_posix().encode()
        payload = path.read_bytes()
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(len(payload).to_bytes(8, "big"))
        digest.update(payload)
    return digest.hexdigest()


def length_framed_package_digest(root: pathlib.Path) -> str:
    all_paths = sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix())
    if any(path.is_symlink() for path in all_paths):
        raise AssertionError("fixture package store must not contain symbolic links")
    files = [path for path in all_paths if path.is_file()]
    digest = hashlib.sha256()
    for path in files:
        relative = path.relative_to(root).as_posix().encode()
        payload = path.read_bytes()
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(len(payload).to_bytes(8, "big"))
        digest.update(payload)
    return digest.hexdigest()


def git_output(repository: pathlib.Path, *arguments: str) -> str:
    return subprocess.check_output(
        ["/usr/bin/git", "-C", str(repository), *arguments],
        text=True,
    ).strip()


class GhosttySurfacePatchContractTests(unittest.TestCase):
    def test_patch_set_is_closed_and_digest_pinned(self) -> None:
        observed = {path.name for path in PATCHES.iterdir() if path.is_file()}
        self.assertEqual(observed, set(EXPECTED_GHOSTTY_PATCHES) | {LIBXEV_PATCH})
        for name, expected in EXPECTED_GHOSTTY_PATCHES.items():
            payload = (PATCHES / name).read_bytes()
            self.assertEqual(hashlib.sha256(payload).hexdigest(), expected)
        self.assertEqual(
            hashlib.sha256((PATCHES / LIBXEV_PATCH).read_bytes()).hexdigest(),
            EXPECTED_LIBXEV_PATCH_SHA256,
        )

    def test_patch_set_changes_only_reviewed_upstream_paths(self) -> None:
        observed: set[str] = set()
        for name in EXPECTED_GHOSTTY_PATCHES:
            text = (PATCHES / name).read_text(encoding="utf-8")
            observed.update(re.findall(r"^diff --git a/(\S+) b/\S+$", text, re.MULTILINE))
        self.assertEqual(observed, EXPECTED_CHANGED_PATHS)

    def test_header_patch_freezes_abi_version_and_exports(self) -> None:
        text = (PATCHES / next(iter(EXPECTED_GHOSTTY_PATCHES))).read_text(encoding="utf-8")
        self.assertIn("GHOSTTY_EXTERNAL_IO_ABI_VERSION 1", text)
        for symbol in EXPECTED_EXPORTS:
            self.assertIn(symbol, text)

    def test_identity_records_bind_baseline_and_patched_tree(self) -> None:
        revision = (SURFACE / "UPSTREAM_REVISION").read_text(encoding="utf-8").strip()
        identities = (SURFACE / "SOURCE_TREE_SHA256").read_text(encoding="utf-8")
        contract = (ROOT / "Scripts/ghostty-surface-source.contract").read_text(encoding="utf-8")
        patch_record = (SURFACE / "PATCHES.md").read_text(encoding="utf-8")
        self.assertEqual(revision, "f64f4aca2c29b554d111b36c3d946a9bddd159ff")
        self.assertIn("fa514474cca4b9bdceecb168d818b12b3bab0f1c", identities)
        self.assertIn(EXPECTED_PATCHED_TREE, identities)
        self.assertIn("a9702b7a9646f86e19d1938f16ca5701d57ff91476c3121d65a1a04431e773f5", identities)
        self.assertIn(EXPECTED_PATCHED_SHA256, identities)
        self.assertIn(
            f'EXPECTED_GHOSTTY_SURFACE_RAW_PATCHED_TREE="{EXPECTED_RAW_PATCHED_TREE}"',
            contract,
        )
        self.assertIn(EXPECTED_RAW_PATCHED_TREE, patch_record)

    def test_repository_snapshot_contains_only_ordinary_entries(self) -> None:
        source = SURFACE / "Source"
        self.assertEqual([path for path in source.rglob("*") if path.is_symlink()], [])
        self.assertEqual(
            [
                path.relative_to(source).as_posix()
                for path in source.rglob("*")
                if path.name == ".DS_Store" or path.name.startswith("._")
            ],
            [],
        )
        expected = "4939dae26b5551d1aee737e4cdae126499a1051585c8e72768c0b79f0b857121"
        normalized = [path for path in source.glob("*.md")
                      if hashlib.sha256(path.read_bytes()).hexdigest() == expected]
        self.assertEqual(len(normalized), 2)
        self.assertEqual(normalized[0].read_bytes(), normalized[1].read_bytes())

    def test_repository_package_store_excludes_finder_metadata(self) -> None:
        package_store = SURFACE / "zig-pkg"
        metadata = sorted(
            path.relative_to(package_store).as_posix()
            for path in package_store.rglob("*")
            if path.is_file()
            and (path.name == ".DS_Store" or path.name.startswith("._"))
        )
        self.assertEqual(metadata, [])
        self.assertEqual(
            length_framed_package_digest(package_store),
            EXPECTED_PACKAGE_STORE_SHA256,
        )

    def test_abi_contract_is_bounded_and_host_owned(self) -> None:
        contract = (SURFACE / "ABI_CONTRACT_V1.md").read_text(encoding="utf-8")
        for required in ("1 MiB", "1024", "256 KiB", "64"):
            self.assertIn(required, contract)
        self.assertIn("validated, host-owned", contract)
        self.assertIn("Ghostty never", contract)

    def test_materializer_binds_and_copies_the_reviewed_offline_package_store(self) -> None:
        contract = (ROOT / "Scripts/ghostty-surface-source.contract").read_text(encoding="utf-8")
        materializer = (ROOT / "Scripts/dependencies/materialize_ghostty_surface.sh").read_text(encoding="utf-8")
        self.assertIn(EXPECTED_RAW_PACKAGE_STORE_SHA256, contract)
        self.assertIn(EXPECTED_PACKAGE_STORE_SHA256, contract)
        self.assertIn("EXPECTED_GHOSTTY_SURFACE_RAW_PACKAGE_STORE_SHA256", materializer)
        self.assertIn("EXPECTED_GHOSTTY_SURFACE_PACKAGE_STORE_SHA256", materializer)
        self.assertIn("EXPECTED_GHOSTTY_SURFACE_LIBXEV_PACKAGE_ID", materializer)
        self.assertIn("EXPECTED_GHOSTTY_SURFACE_LIBXEV_PATCH_SHA256", materializer)
        self.assertIn("MACSCOPE_GHOSTTY_SURFACE_PACKAGE_STORE", materializer)
        self.assertIn('/bin/cp -R "${PACKAGE_STORE_SOURCE}/."', materializer)
        self.assertIn(
            '/usr/bin/find "${SOURCE_ROOT}/zig-pkg" -type f \\( -name .DS_Store -o -name \'._*\' \\) -delete',
            materializer,
        )
        self.assertIn('/usr/bin/patch --batch --fuzz=0 -p1 -d "${LIBXEV_ROOT}"', materializer)
        self.assertNotIn("git am --3way", materializer)

    def test_materializer_normalizes_only_after_validating_the_raw_replay_tree(self) -> None:
        materializer = MATERIALIZER.read_text(encoding="utf-8")
        raw_tree_capture = materializer.index(
            'RAW_PATCHED_TREE="$(/usr/bin/git -C "${SOURCE_ROOT}" rev-parse HEAD^{tree})"'
        )
        raw_tree_check = materializer.index(
            '[[ "${RAW_PATCHED_TREE}" != "${EXPECTED_GHOSTTY_SURFACE_RAW_PATCHED_TREE}" ]]'
        )
        normalize = materializer.index('normalize_ghostty_source_alias "${SOURCE_ROOT}"')
        normalized_tree_capture = materializer.index(
            'PATCHED_TREE="$(/usr/bin/git -C "${SOURCE_ROOT}" write-tree)"'
        )
        normalized_digest = materializer.index('PATCHED_SHA256="$(digest_source "${SOURCE_ROOT}")"')
        normalized_check = materializer.index(
            '[[ "${PATCHED_TREE}" != "${EXPECTED_GHOSTTY_SURFACE_PATCHED_TREE}"'
        )
        publish = materializer.index('/usr/bin/git -C "${SOURCE_ROOT}" update-ref HEAD')
        self.assertLess(
            raw_tree_capture,
            raw_tree_check,
        )
        self.assertLess(raw_tree_check, normalize)
        self.assertLess(normalize, normalized_tree_capture)
        self.assertLess(normalized_tree_capture, normalized_digest)
        self.assertLess(normalized_digest, normalized_check)
        self.assertLess(normalized_check, publish)
        for required in (
            '[[ -z "${alias_path}" ]]',
            'target="$(/usr/bin/readlink "${alias_path}")"',
            '[[ "${target}" == */* || "${target}" != *.md ]]',
            '[[ ! -f "${target_path}" || -L "${target_path}" ]]',
            '/bin/cp -p "${target_path}" "${temporary}"',
            '/bin/mv -f "${temporary}" "${alias_path}"',
            '[[ "${NORMALIZED_PATHS}" != "${NORMALIZED_ALIAS_NAME}" ]]',
            'commit-tree "${PATCHED_TREE}"',
        ):
            self.assertIn(required, materializer)

    def test_materializer_replays_raw_tree_then_publishes_clean_normalized_tree(self) -> None:
        patch_names = list(EXPECTED_GHOSTTY_PATCHES)
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            fixture_root = root / "fixture"
            fixture_materializer = fixture_root / "Scripts/dependencies/materialize_ghostty_surface.sh"
            fixture_patch_root = fixture_root / "ThirdParty/GhosttySurface/patches"
            fixture_materializer.parent.mkdir(parents=True)
            fixture_patch_root.mkdir(parents=True)
            shutil.copy2(MATERIALIZER, fixture_materializer)

            upstream = root / "upstream"
            subprocess.run(["/usr/bin/git", "init", "--quiet", str(upstream)], check=True)
            subprocess.run(
                ["/usr/bin/git", "-C", str(upstream), "config", "user.name", "Fixture Author"],
                check=True,
            )
            subprocess.run(
                ["/usr/bin/git", "-C", str(upstream), "config", "user.email", "fixture@invalid"],
                check=True,
            )
            (upstream / ".gitignore").write_text("/zig-pkg/\n", encoding="utf-8")
            (upstream / "Instructions.md").write_text("reviewed fixture instructions\n", encoding="utf-8")
            (upstream / "Alias.md").symlink_to("Instructions.md")
            (upstream / "patch-target.txt").write_text("base\n", encoding="utf-8")
            subprocess.run(["/usr/bin/git", "-C", str(upstream), "add", "-A"], check=True)
            subprocess.run(
                [
                    "/usr/bin/git", "-C", str(upstream), "commit", "--quiet",
                    "--no-gpg-sign", "--no-verify", "-m", "fixture baseline",
                ],
                check=True,
            )
            revision = git_output(upstream, "rev-parse", "HEAD")
            base_tree = git_output(upstream, "rev-parse", "HEAD^{tree}")
            base_digest = length_framed_source_digest(upstream)

            for index, patch_name in enumerate(patch_names, start=1):
                with (upstream / "patch-target.txt").open("a", encoding="utf-8") as target:
                    target.write(f"patch {index}\n")
                subprocess.run(
                    ["/usr/bin/git", "-C", str(upstream), "add", "patch-target.txt"],
                    check=True,
                )
                subprocess.run(
                    [
                        "/usr/bin/git", "-C", str(upstream), "commit", "--quiet",
                        "--no-gpg-sign", "--no-verify", "-m", f"fixture patch {index}",
                    ],
                    check=True,
                )
                formatted = subprocess.check_output(
                    ["/usr/bin/git", "-C", str(upstream), "format-patch", "-1", "--stdout"]
                )
                (fixture_patch_root / patch_name).write_bytes(formatted)

            raw_tree = git_output(upstream, "rev-parse", "HEAD^{tree}")
            normalized = root / "normalized"
            subprocess.run(
                ["/usr/bin/git", "clone", "--quiet", str(upstream), str(normalized)],
                check=True,
            )
            (normalized / "Alias.md").unlink()
            shutil.copy2(normalized / "Instructions.md", normalized / "Alias.md")
            subprocess.run(
                ["/usr/bin/git", "-C", str(normalized), "add", "Alias.md"],
                check=True,
            )
            normalized_tree = git_output(normalized, "write-tree")
            normalized_digest = length_framed_source_digest(normalized)
            self.assertNotEqual(raw_tree, normalized_tree)
            self.assertEqual(length_framed_source_digest(upstream), normalized_digest)

            package_id = "fixture-libxev"
            package_store = root / "package-store"
            package_root = package_store / package_id
            package_root.mkdir(parents=True)
            (package_root / "xev.txt").write_text("networking enabled\n", encoding="utf-8")
            libxev_patch = fixture_patch_root / "libxev-networking-capability.patch"
            libxev_patch.write_text(
                "--- a/xev.txt\n"
                "+++ b/xev.txt\n"
                "@@ -1 +1 @@\n"
                "-networking enabled\n"
                "+networking disabled\n",
                encoding="utf-8",
            )
            raw_package_digest = length_framed_package_digest(package_store)
            patched_package_store = root / "patched-package-store"
            shutil.copytree(package_store, patched_package_store)
            subprocess.run(
                [
                    "/usr/bin/patch", "--batch", "--fuzz=0", "-p1",
                    "-d", str(patched_package_store / package_id), "-i", str(libxev_patch),
                ],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            patched_package_digest = length_framed_package_digest(patched_package_store)

            patch_digests = {
                name: hashlib.sha256((fixture_patch_root / name).read_bytes()).hexdigest()
                for name in patch_names
            }
            contract = fixture_root / "Scripts/ghostty-surface-source.contract"
            contract.write_text(
                "\n".join(
                    [
                        f'EXPECTED_GHOSTTY_SURFACE_REVISION="{revision}"',
                        f'EXPECTED_GHOSTTY_SURFACE_BASE_TREE="{base_tree}"',
                        f'EXPECTED_GHOSTTY_SURFACE_BASE_SHA256="{base_digest}"',
                        f'EXPECTED_GHOSTTY_SURFACE_RAW_PATCHED_TREE="{raw_tree}"',
                        f'EXPECTED_GHOSTTY_SURFACE_PATCHED_TREE="{normalized_tree}"',
                        f'EXPECTED_GHOSTTY_SURFACE_PATCHED_SHA256="{normalized_digest}"',
                        'EXPECTED_GHOSTTY_SURFACE_VERSION="fixture"',
                        'EXPECTED_GHOSTTY_EXTERNAL_IO_ABI_VERSION="1"',
                        f'EXPECTED_GHOSTTY_SURFACE_RAW_PACKAGE_STORE_SHA256="{raw_package_digest}"',
                        f'EXPECTED_GHOSTTY_SURFACE_PACKAGE_STORE_SHA256="{patched_package_digest}"',
                        *(
                            f'EXPECTED_GHOSTTY_SURFACE_PATCH_{index}_SHA256="{patch_digests[name]}"'
                            for index, name in enumerate(patch_names, start=1)
                        ),
                        f'EXPECTED_GHOSTTY_SURFACE_LIBXEV_PACKAGE_ID="{package_id}"',
                        "EXPECTED_GHOSTTY_SURFACE_LIBXEV_PATCH_SHA256=\""
                        f"{hashlib.sha256(libxev_patch.read_bytes()).hexdigest()}\"",
                    ]
                ) + "\n",
                encoding="utf-8",
            )

            environment = os.environ.copy()
            environment.update(
                {
                    "GIT_CONFIG_GLOBAL": "/dev/null",
                    "GIT_CONFIG_SYSTEM": "/dev/null",
                    "GIT_COMMITTER_NAME": "Fixture Committer",
                    "GIT_COMMITTER_EMAIL": "fixture@invalid",
                }
            )
            destination = root / "materialized"
            result = subprocess.run(
                [str(fixture_materializer), str(destination), str(upstream), str(package_store)],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((destination / "Alias.md").is_symlink())
            self.assertEqual(
                (destination / "Alias.md").read_bytes(),
                (destination / "Instructions.md").read_bytes(),
            )
            self.assertEqual(git_output(destination, "rev-parse", "HEAD^{tree}"), normalized_tree)
            self.assertEqual(git_output(destination, "status", "--porcelain=v1"), "")
            self.assertIn(f"GHOSTTY_SURFACE_TREE={normalized_tree}", result.stdout)

            contract.write_text(
                contract.read_text(encoding="utf-8").replace(raw_tree, "0" * 40, 1),
                encoding="utf-8",
            )
            rejected_destination = root / "rejected"
            rejected = subprocess.run(
                [
                    str(fixture_materializer), str(rejected_destination),
                    str(upstream), str(package_store),
                ],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )
            self.assertEqual(rejected.returncode, 1)
            self.assertIn("raw patched identity mismatch", rejected.stderr)
            self.assertFalse(rejected_destination.exists())

    def test_network_capability_patch_guards_the_root_and_every_libxev_socket_entrypoint(self) -> None:
        root_patch = (PATCHES / "0005-build-gst-disable-root-networking-in-external-only.patch").read_text(
            encoding="utf-8"
        )
        libxev_patch = (PATCHES / LIBXEV_PATCH).read_text(encoding="utf-8")
        for required in (
            "macscope_external_io_only",
            ".networking = !build_options.macscope_external_io_only",
            "MacScope external-I/O-only mode controls the root networking capability",
        ):
            self.assertIn(required, root_patch)
        for required in (
            "pub fn connect(",
            "pub fn getsockoptError(",
            "pub fn accept(",
            "pub fn socket(",
            "pub fn bind(",
            "pub fn listen(",
            "pub fn getsockname(",
            "pub fn sendto(",
            "pub fn sendmsg(",
            "pub fn recvfrom(",
            ".connect => |*v| action:",
            ".shutdown => |v| action:",
            "fn getsockoptError(socket:",
        ):
            self.assertIn(required, libxev_patch)
        self.assertEqual(libxev_patch.count("+    if (!std.options.networking)"), 11)
        self.assertEqual(libxev_patch.count("+                if (!std.options.networking)"), 2)


if __name__ == "__main__":
    unittest.main()
