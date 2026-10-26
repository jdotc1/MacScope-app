from __future__ import annotations

import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/dependencies/build_ghostty_surface.sh"
VENDORED_SCRIPT = ROOT / "Scripts/dependencies/build_vendored_ghostty_surface.sh"
TREE = "de6cd65b35a423d5d6854c6af3a90be20a52d7eb"
PACKAGE_STORE_SHA256 = "13f8e6d6cc075fc5c13bb211e624c2a4311ff47cae414b44b7d509830adbf84c"
RECEIPT_SHA256 = "144602371f31096e0d8e8e556b0fc97c46686753c8fd70fb8e6a980254c1b978"


class GhosttySurfaceBuildContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.bin = self.root / "zig-0.16.0"
        self.bin.mkdir()
        self.receipt = self.root / "zig-0.16.0.receipt.json"
        self.receipt.write_text("fixture receipt\n")
        (self.source / "zig-pkg").mkdir(parents=True)
        (self.source / "zig-pkg/package.txt").write_text("fixture\n")
        (self.source / "macos/GhosttyKit.xcframework/macos-arm64/Headers").mkdir(parents=True)
        subprocess.run(["git", "init", "-q", str(self.source)], check=True)
        subprocess.run(["git", "-C", str(self.source), "config", "user.email", "fixture@example.invalid"], check=True)
        subprocess.run(["git", "-C", str(self.source), "config", "user.name", "Fixture"], check=True)
        (self.source / "tree.txt").write_text("fixture\n")
        (self.source / ".gitignore").write_text("/zig-pkg/\n/macos/*.xcframework/\n")
        subprocess.run(["git", "-C", str(self.source), "add", "tree.txt", ".gitignore"], check=True)
        subprocess.run(["git", "-C", str(self.source), "commit", "-qm", "fixture"], check=True)
        self._tool(
            "zig",
            "#!/bin/sh\n"
            "[ \"$1\" = version ] && echo 0.16.0 && exit 0\n"
            "[ \"$1\" = build ] || exit 97\n"
            "echo BUILD_INVOKED >&2\n"
            "mkdir -p macos/GhosttyKit.xcframework/macos-arm64/Headers\n"
            "printf artifact > macos/GhosttyKit.xcframework/macos-arm64/libghostty-internal.a\n"
            "printf plist > macos/GhosttyKit.xcframework/Info.plist\n"
            "printf '#define GHOSTTY_EXTERNAL_IO_ABI_VERSION 1\\n' > macos/GhosttyKit.xcframework/macos-arm64/Headers/ghostty.h\n"
            "printf module > macos/GhosttyKit.xcframework/macos-arm64/Headers/module.modulemap\n",
        )
        self._tool("git", f"#!/bin/sh\n[ \"$3\" = rev-parse ] && echo {TREE} && exit 0\nexec /usr/bin/git \"$@\"\n")
        self._tool("lipo", "#!/bin/sh\necho arm64\n")
        self._tool(
            "nm",
            "#!/bin/sh\n"
            "if [ \"$1\" = -gU ]; then\n"
            "  printf '%s\\n' '0 T _ghostty_surface_new_external' '0 T _ghostty_surface_external_feed' '0 T _ghostty_surface_external_set_process_state' '0 T _ghostty_surface_is_external_io'\n"
            "else\n"
            "  printf '%s\\n' 'archive:libghostty_zcu.o: U _bind' 'archive:libghostty_zcu.o: U _connect' 'archive:libghostty_zcu.o: U _listen' 'archive:libghostty_zcu.o: U _recvmsg' 'archive:libghostty_zcu.o: U _socket'\n"
            "fi\n",
        )
        self._tool("PlistBuddy", "#!/bin/sh\necho macos-arm64\n")
        self._tool(
            "python",
            "#!/bin/sh\n"
            "if [ \"$1\" != - ]; then\n"
            "  root=\n"
            "  receipt=\n"
            "  while [ $# -gt 0 ]; do\n"
            "    case \"$1\" in\n"
            "      --root) root=$2; shift 2 ;;\n"
            "      --receipt) receipt=$2; shift 2 ;;\n"
            "      *) shift ;;\n"
            "    esac\n"
            "  done\n"
            "  [ -f \"$receipt\" ] || exit 91\n"
            "  [ \"$(\"$root/zig\" version)\" = 0.16.0 ] || exit 92\n"
            f"  echo {RECEIPT_SHA256}\n"
            "  exit 0\n"
            "fi\n"
            f"echo {PACKAGE_STORE_SHA256}\n",
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _tool(self, name: str, payload: str) -> None:
        path = self.bin / name
        path.write_text(payload)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def _environment(self) -> dict[str, str]:
        environment = os.environ.copy()
        environment["MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR"] = str(self.source)
        environment["MACSCOPE_ZIG_ROOT"] = str(self.bin)
        environment["MACSCOPE_ZIG"] = str(self.bin / "zig")
        environment["MACSCOPE_ZIG_RECEIPT"] = str(self.receipt)
        environment["MACSCOPE_GIT"] = str(self.bin / "git")
        environment["MACSCOPE_LIPO"] = str(self.bin / "lipo")
        environment["MACSCOPE_NM"] = str(self.bin / "nm")
        environment["MACSCOPE_PLIST_BUDDY"] = str(self.bin / "PlistBuddy")
        environment["MACSCOPE_PYTHON"] = str(self.bin / "python")
        return environment

    def test_verify_only_rejects_missing_artifact_without_building(self) -> None:
        result = subprocess.run([str(SCRIPT), "--verify-only"], env=self._environment(), capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing, malformed, stale", result.stderr)
        self.assertNotIn("BUILD_INVOKED", result.stderr)

    def test_script_freezes_build_flags_exports_and_manifest_identity(self) -> None:
        text = SCRIPT.read_text()
        self.assertNotIn("/opt/homebrew/bin/zig", text)
        for value in (
            "-Demit-lib-vt=false", "-Dapp-runtime=none", "-Demit-xcframework=true",
            "-Demit-macos-app=false", "-Demit-exe=false", "-Demit-test-exe=false",
            "-Demit-docs=false", "-Demit-themes=false", "-Demit-webdata=false",
            "-Drenderer=metal", "-Dsentry=false", "-Di18n=false",
            "-Dmacscope-external-io-only=true",
            "-Dxcframework-target=native", "build macscope-xcframework -j1",
            "-Doptimize=ReleaseFast",
            '--system "${PACKAGE_STORE}"',
            "_ghostty_surface_new_external", "_ghostty_surface_external_feed",
            "_ghostty_surface_external_set_process_state", "_ghostty_surface_is_external_io",
            "archive_sha256", "header_sha256", "module_map_sha256",
            "build_profile_sha256", "package_store_sha256",
            "zig_archive_sha256", "zig_toolchain_tree_sha256",
            "zig_toolchain_receipt_sha256", "zig_toolchain_receipt.py",
            "_sentry_", "_crashpad_", "_breakpad_",
            "EXPECTED_RESIDUAL_NETWORK_IMPORTS", "_getaddrinfo", "_freeaddrinfo",
            "_getpeername", "_socketpair",
            "residual_network_imports=_bind,_connect,_listen,_recvmsg,_socket",
            "networking=disabled", "libxev_patch_sha256",
            "raw_package_store_sha256",
        ):
            self.assertIn(value, text)

    def test_rejects_wrong_zig_before_artifact_acceptance(self) -> None:
        (self.bin / "zig").write_text("#!/bin/sh\necho 0.15.2\n")
        result = subprocess.run([str(SCRIPT), "--verify-only"], env=self._environment(), capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("receipt verification failed", result.stderr)

    def test_rejects_missing_toolchain_receipt_before_artifact_acceptance(self) -> None:
        self.receipt.unlink()
        result = subprocess.run([str(SCRIPT), "--verify-only"], env=self._environment(), capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("toolchain receipt is missing", result.stderr)

    def test_rejects_unreviewed_package_store_before_artifact_acceptance(self) -> None:
        (self.bin / "python").write_text("#!/bin/sh\necho deadbeef\n")
        result = subprocess.run([str(SCRIPT), "--verify-only"], env=self._environment(), capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("package store does not match", result.stderr)

    def test_rejects_tracked_source_modification_before_artifact_acceptance(self) -> None:
        (self.source / "tree.txt").write_text("mutated\n")
        result = subprocess.run([str(SCRIPT), "--verify-only"], env=self._environment(), capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("tracked source has local modifications", result.stderr)

    def test_verify_only_rejects_network_import_growth_after_a_valid_build(self) -> None:
        built = subprocess.run([str(SCRIPT)], env=self._environment(), capture_output=True, text=True)
        self.assertEqual(built.returncode, 0, built.stderr)
        nm = self.bin / "nm"
        nm.write_text(
            nm.read_text()
            .replace(
                "'archive:libghostty_zcu.o: U _socket'",
                "'archive:libghostty_zcu.o: U _socket' 'archive:libghostty_zcu.o: U _getaddrinfo'",
            )
        )
        result = subprocess.run([str(SCRIPT), "--verify-only"], env=self._environment(), capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("missing, malformed, stale", result.stderr)


class VendoredGhosttySurfaceBuildContractTests(unittest.TestCase):
    def test_wrapper_uses_only_repository_owned_inputs_and_external_output(self) -> None:
        text = VENDORED_SCRIPT.read_text(encoding="utf-8")
        for required in (
            'ThirdParty/GhosttySurface/Source',
            'ThirdParty/GhosttySurface/zig-pkg',
            'ThirdParty/Zig/zig-0.16.0',
            'ThirdParty/Zig/zig-0.16.0.receipt.json',
            'OUTPUT_ROOT="${WORK_ROOT}/GhosttySurface"',
            'IDENTITY_FILE="${OUTPUT_ROOT}/.git/macscope-vendored-inputs"',
            'MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR="${STAGING}"',
            'GHOSTTY_SURFACE_ARTIFACT_ROOT=${OUTPUT_ROOT}/macos/GhosttyKit.xcframework',
            'refusing to replace unowned Ghostty surface output',
            '/bin/cp -R "${VENDORED_SOURCE}/." "${STAGING}"',
            '/bin/cp -R "${VENDORED_PACKAGE_STORE}/." "${STAGING}/zig-pkg"',
            '"${BUILDER}" --verify-only',
            'source "${REPO_ROOT}/Scripts/ghostty-vt-source.contract"',
        ):
            self.assertIn(required, text)
        self.assertNotIn('MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR:?', text)
        self.assertNotIn('/bin/rm -rf "${WORK_ROOT}"', text)
        self.assertNotIn('curl ', text)
        self.assertNotIn('git clone', text)

    def test_fresh_build_keeps_inner_builder_chatter_out_of_stdout(self) -> None:
        text = VENDORED_SCRIPT.read_text(encoding="utf-8")
        self.assertEqual(text.count('"${BUILDER}" >&2'), 1)
        self.assertEqual(text.count('echo "GHOSTTY_SURFACE_INPUTS_VERIFIED=1"'), 1)
        self.assertEqual(text.count('echo "GHOSTTY_SURFACE_SOURCE_DIR=${OUTPUT_ROOT}"'), 2)
        self.assertEqual(
            text.count(
                'echo "GHOSTTY_SURFACE_ARTIFACT_ROOT=${OUTPUT_ROOT}/macos/GhosttyKit.xcframework"'
            ),
            2,
        )

    def test_wrapper_rejects_relative_repository_and_root_work_paths_before_build(self) -> None:
        for work_root in ("relative", str(ROOT), "/"):
            with self.subTest(work_root=work_root):
                result = subprocess.run(
                    [str(VENDORED_SCRIPT), "--work-root", work_root, "--verify-only"],
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 2, result.stderr)

    def test_vendored_zig_receipt_binds_the_exact_repository_toolchain(self) -> None:
        zig_root = ROOT / "ThirdParty/Zig/zig-0.16.0"
        receipt_path = ROOT / "ThirdParty/Zig/zig-0.16.0.receipt.json"
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        self.assertEqual(receipt["root_basename"], zig_root.name)
        self.assertEqual(receipt["version"], "0.16.0")
        self.assertEqual(
            receipt["archive_sha256"],
            "b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489",
        )
        self.assertEqual(
            receipt["toolchain_tree_sha256"],
            "521e2ef7605386b8da70aa3d6c3d135b344ee319c4b5a280470f8c07265ace43",
        )
        self.assertEqual(receipt["schema_version"], 2)
        self.assertEqual(
            receipt["tree_algorithm"],
            "git-stable-nonempty-directories-v2",
        )
        self.assertTrue((zig_root / "zig").is_file())
        self.assertTrue(os.access(zig_root / "zig", os.X_OK))


if __name__ == "__main__":
    unittest.main()
