from __future__ import annotations

import hashlib
import json
import os
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "build_ghostty_vt.sh"
CONTRACT = ROOT / "Scripts" / "ghostty-vt-source.contract"
IDENTITY_HELPER = ROOT / "Scripts" / "dependencies" / "zig_toolchain_receipt.py"
VENDORED_SOURCE = ROOT / "ThirdParty" / "GhosttyVT" / "Source"
VENDORED_PACKAGE_STORE = VENDORED_SOURCE / "zig-pkg"


class GhosttyBuildContractTests(unittest.TestCase):
    def source_digest(self, source: pathlib.Path) -> str:
        excluded = {".git", ".zig-cache", "zig-out", "zig-pkg", ".DS_Store"}
        files = sorted(
            (
                path
                for path in source.rglob("*")
                if path.is_file()
                and not any(
                    part in excluded for part in path.relative_to(source).parts
                )
            ),
            key=lambda path: path.relative_to(source).as_posix(),
        )
        digest = hashlib.sha256()
        for path in files:
            relative = path.relative_to(source).as_posix().encode()
            contents = path.read_bytes()
            digest.update(len(relative).to_bytes(8, "big"))
            digest.update(relative)
            digest.update(len(contents).to_bytes(8, "big"))
            digest.update(contents)
        return digest.hexdigest()

    def package_store_digest(self, package_store: pathlib.Path) -> str:
        files = sorted(
            (path for path in package_store.rglob("*") if path.is_file()),
            key=lambda path: path.relative_to(package_store).as_posix(),
        )
        digest = hashlib.sha256()
        for path in files:
            relative = path.relative_to(package_store).as_posix().encode()
            contents = path.read_bytes()
            digest.update(len(relative).to_bytes(8, "big"))
            digest.update(relative)
            digest.update(len(contents).to_bytes(8, "big"))
            digest.update(contents)
        return digest.hexdigest()

    def make_source(
        self, root: pathlib.Path, *, version: str = "1.3.2-dev"
    ) -> pathlib.Path:
        source = root / "fixture-source"
        source.mkdir()
        (source / "build.zig.zon").write_text(
            ".{\n"
            "    .name = .ghostty,\n"
            f'    .version = "{version}",\n'
            "    .fingerprint = 0x64407a2a0b4147e5,\n"
            '    .minimum_zig_version = "0.16.0",\n'
            "}\n",
            encoding="utf-8",
        )
        package_store = source / "zig-pkg"
        (package_store / "fixture-one").mkdir(parents=True)
        (package_store / "fixture-one" / "build.zig").write_text(
            "fixture one\n", encoding="utf-8"
        )
        (package_store / "fixture-two").mkdir()
        (package_store / "fixture-two" / "data.bin").write_bytes(
            b"fixture two\x00"
        )
        return source

    def make_zig(self, root: pathlib.Path, *, marker: bytes | None = None) -> pathlib.Path:
        zig_root = root / "zig-0.16.0"
        zig_root.mkdir(parents=True)
        zig = zig_root / "zig"
        zig.write_text(
            "#!/bin/bash\n"
            "set -eu\n"
            'if [[ "${1:-}" == "version" ]]; then echo 0.16.0; exit 0; fi\n'
            'if [[ "${1:-}" != "build" ]]; then exit 0; fi\n'
            "prefix=\n"
            "shift\n"
            'while [[ "$#" -gt 0 ]]; do\n'
            '  if [[ "$1" == "--prefix" ]]; then prefix="$2"; shift 2; continue; fi\n'
            "  shift\n"
            "done\n"
            '[[ -n "$prefix" ]]\n'
            'mkdir -p "$prefix/lib" "$prefix/include/ghostty"\n'
            "printf 'fixture dylib\\n' > \"$prefix/lib/libghostty-vt.0.1.0.dylib\"\n"
            'ln -s libghostty-vt.0.1.0.dylib "$prefix/lib/libghostty-vt.dylib"\n'
            "printf 'fixture archive\\n' > \"$prefix/lib/libghostty-vt.a\"\n"
            "printf '/* fixture */\\n' > \"$prefix/include/ghostty/vt.h\"\n",
            encoding="utf-8",
        )
        zig.chmod(0o755)
        if marker is not None:
            (zig_root / "alternate-same-version-marker").write_bytes(marker)
        return zig

    def make_receipt(self, root: pathlib.Path, zig: pathlib.Path) -> pathlib.Path:
        identity = json.loads(
            subprocess.run(
                [
                    "/usr/bin/python3",
                    "-B",
                    str(IDENTITY_HELPER),
                    "identity",
                    "--root",
                    str(zig.parent),
                ],
                text=True,
                capture_output=True,
                check=True,
            ).stdout
        )
        receipt = root / "zig-0.16.0.receipt.json"
        subprocess.run(
            [
                "/usr/bin/python3",
                "-B",
                str(IDENTITY_HELPER),
                "create",
                "--root",
                str(zig.parent),
                "--receipt",
                str(receipt),
                "--expected-version",
                "0.16.0",
                "--expected-archive-sha256",
                "a" * 64,
                "--expected-tree-sha256",
                identity["toolchain_tree_sha256"],
            ],
            text=True,
            capture_output=True,
            check=True,
        )
        return receipt

    def make_contract(
        self,
        root: pathlib.Path,
        source: pathlib.Path,
        zig: pathlib.Path,
        receipt: pathlib.Path,
    ) -> pathlib.Path:
        identity = json.loads(
            subprocess.run(
                [
                    "/usr/bin/python3",
                    "-B",
                    str(IDENTITY_HELPER),
                    "identity",
                    "--root",
                    str(zig.parent),
                ],
                text=True,
                capture_output=True,
                check=True,
            ).stdout
        )
        contract = root / "fixture.contract"
        contract.write_text(
            "EXPECTED_GHOSTTY_NAME=ghostty\n"
            "EXPECTED_GHOSTTY_VERSION=1.3.2-dev\n"
            "EXPECTED_GHOSTTY_FINGERPRINT=0x64407a2a0b4147e5\n"
            "EXPECTED_GHOSTTY_MINIMUM_ZIG_VERSION=0.16.0\n"
            "EXPECTED_GHOSTTY_SOURCE_ARCHIVE_SHA256=test\n"
            "EXPECTED_GHOSTTY_GITHUB_ARCHIVE_SHA256=test\n"
            "EXPECTED_GHOSTTY_SOURCE_REVISION=test-revision\n"
            f"EXPECTED_GHOSTTY_SOURCE_TREE_SHA256={self.source_digest(source)}\n"
            "EXPECTED_ZIG_VERSION=0.16.0\n"
            f"EXPECTED_ZIG_AARCH64_MACOS_SHA256={'a' * 64}\n"
            f"EXPECTED_ZIG_AARCH64_MACOS_TREE_SHA256={identity['toolchain_tree_sha256']}\n"
            f"EXPECTED_ZIG_TOOLCHAIN_RECEIPT_SHA256={hashlib.sha256(receipt.read_bytes()).hexdigest()}\n"
            f"EXPECTED_GHOSTTY_ZIG_PACKAGE_STORE_SHA256={self.package_store_digest(source / 'zig-pkg')}\n",
            encoding="utf-8",
        )
        return contract

    def make_binary_tools(self, root: pathlib.Path) -> dict[str, pathlib.Path]:
        tools: dict[str, pathlib.Path] = {}
        scripts = {
            "lipo": "#!/bin/sh\necho arm64\n",
            "otool": (
                "#!/bin/sh\n"
                'if [ "$1" = "-l" ]; then\n'
                '  printf "Load command 0\\n      cmd LC_UUID\\nLoad command 1\\n'
                '      cmd LC_BUILD_VERSION\\n platform 1\\n    minos %s\\n" '
                '"${MACSCOPE_GHOSTTY_FIXTURE_MINIMUM_OS-27.0}"\n'
                '  exit 0\n'
                'fi\n'
                'echo "$2:"\n'
                'echo "@rpath/libghostty-vt.dylib"\n'
            ),
            "strip": (
                "#!/bin/sh\n"
                "output=\n"
                "input=\n"
                'while [ "$#" -gt 0 ]; do\n'
                '  if [ "$1" = "-o" ]; then output="$2"; shift 2; continue; fi\n'
                '  input="$1"; shift\n'
                "done\n"
                'cp "$input" "$output"\n'
            ),
            "codesign": "#!/bin/sh\nexit 0\n",
            "ar": (
                "#!/bin/sh\n"
                'if [ "$1" = "-t" ]; then\n'
                '  printf "%s\\n" "__.SYMDEF SORTED" "libghostty-vt-static_zcu.o" "compiler_rt.o"\n'
                "  exit 0\n"
                "fi\n"
                'if [ "$1" = "-x" ]; then\n'
                '  cp "$2" libghostty-vt-static_zcu.o\n'
                '  cp "$2" compiler_rt.o\n'
                "  exit 0\n"
                "fi\n"
                'if [ "$1" = "rcs" ]; then cp "$3" "$2"; exit 0; fi\n'
                "exit 1\n"
            ),
        }
        for name, contents in scripts.items():
            path = root / name
            path.write_text(contents, encoding="utf-8")
            path.chmod(0o755)
            tools[name] = path
        return tools

    def make_environment(
        self, root: pathlib.Path, source: pathlib.Path, zig: pathlib.Path
    ) -> tuple[dict[str, str], pathlib.Path]:
        receipt = self.make_receipt(root, zig)
        work = root / "external-work"
        environment = os.environ.copy()
        environment.update(
            {
                "MACSCOPE_GHOSTTY_TEST_SEAMS": "1",
                "MACSCOPE_GHOSTTY_SOURCE_DIR": str(source),
                "MACSCOPE_GHOSTTY_CONTRACT_FILE": str(
                    self.make_contract(root, source, zig, receipt)
                ),
                "MACSCOPE_GHOSTTY_FIXTURE_WORK_ROOT": str(work),
                "MACSCOPE_ZIG_ROOT": str(zig.parent),
                "MACSCOPE_ZIG": str(zig),
                "MACSCOPE_ZIG_RECEIPT": str(receipt),
            }
        )
        tools = self.make_binary_tools(root)
        environment.update(
            {
                "MACSCOPE_LIPO": str(tools["lipo"]),
                "MACSCOPE_OTOOL": str(tools["otool"]),
                "MACSCOPE_STRIP": str(tools["strip"]),
                "MACSCOPE_CODESIGN": str(tools["codesign"]),
                "MACSCOPE_AR": str(tools["ar"]),
            }
        )
        xcrun = root / "xcrun"
        xcrun.write_text(
            "#!/bin/bash\n"
            "set -eu\n"
            'if [[ "$*" == *" clang "* || "${3:-}" == "clang" ]]; then\n'
            '  printf "%s\\n" "$@" > "$MACSCOPE_GHOSTTY_FIXTURE_WORK_ROOT/clang-arguments.txt"\n'
            "  output=\n"
            '  while [[ "$#" -gt 0 ]]; do\n'
            '    if [[ "$1" == "-o" ]]; then output="$2"; break; fi\n'
            "    shift\n"
            "  done\n"
            '  cp "$MACSCOPE_GHOSTTY_FIXTURE_WORK_ROOT/artifacts/lib/libghostty-vt.dylib" "$output"\n'
            "  exit 0\n"
            "fi\n"
            "echo /tmp/fake-sdk\n",
            encoding="utf-8",
        )
        xcrun.chmod(0o755)
        overlay = root / "overlay.py"
        overlay.write_text(
            "#!/usr/bin/env python3\nprint('{\"xcrun_shim_dir\":null}')\n",
            encoding="utf-8",
        )
        overlay.chmod(0o755)
        environment["MACSCOPE_XCRUN"] = str(xcrun)
        environment["MACSCOPE_ZIG_SDK_OVERLAY_HELPER"] = str(overlay)
        return environment, work

    def run_build_and_verify(
        self, source: pathlib.Path, zig: pathlib.Path
    ) -> tuple[subprocess.CompletedProcess[str], pathlib.Path]:
        environment, work = self.make_environment(source.parent, source, zig)
        build = subprocess.run(
            [str(SCRIPT), "--work-root", str(work)],
            cwd=ROOT,
            env=environment,
            text=True,
            capture_output=True,
        )
        if build.returncode != 0:
            return build, work
        verify = subprocess.run(
            [str(SCRIPT), "--work-root", str(work), "--verify-only"],
            cwd=ROOT,
            env=environment,
            text=True,
            capture_output=True,
        )
        return verify, work

    def test_vendored_source_and_package_store_match_frozen_contract(self) -> None:
        values = dict(
            line.split("=", 1)
            for line in CONTRACT.read_text(encoding="utf-8").splitlines()
            if line and not line.startswith("#")
        )
        source_result = subprocess.run(
            [
                "/usr/bin/python3",
                "-B",
                str(IDENTITY_HELPER),
                "ghostty-source",
                "--root",
                str(VENDORED_SOURCE),
                "--expected-sha256",
                values["EXPECTED_GHOSTTY_SOURCE_TREE_SHA256"],
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        package_result = subprocess.run(
            [
                "/usr/bin/python3",
                "-B",
                str(IDENTITY_HELPER),
                "package-store",
                "--root",
                str(VENDORED_PACKAGE_STORE),
                "--expected-sha256",
                values["EXPECTED_GHOSTTY_ZIG_PACKAGE_STORE_SHA256"],
            ],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        self.assertEqual(
            source_result.returncode, 0, source_result.stdout + source_result.stderr
        )
        self.assertEqual(
            package_result.returncode,
            0,
            package_result.stdout + package_result.stderr,
        )

    def test_vendored_package_store_excludes_finder_metadata(self) -> None:
        metadata = sorted(
            path.relative_to(VENDORED_PACKAGE_STORE).as_posix()
            for path in VENDORED_PACKAGE_STORE.rglob("*")
            if path.is_file()
            and (path.name == ".DS_Store" or path.name.startswith("._"))
        )
        self.assertEqual(metadata, [])

    def test_build_and_verify_use_external_artifact_and_cache_roots(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = self.make_source(root)
            original_source_digest = self.source_digest(source)
            result, work = self.run_build_and_verify(source, self.make_zig(root))
            manifest = (
                work / "artifacts/lib/.macscope-ghostty-vt-manifest"
            ).read_text(encoding="utf-8")
            temporary_links = list(
                (work / "artifacts/lib").glob(".macscope-reproducible-link.*")
            )

            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Ghostty VT native macOS dylib available", result.stdout)
            self.assertIn("schema=5\n", manifest)
            self.assertIn(
                "input_scope=repository-owned-source-package-store-toolchain\n",
                manifest,
            )
            self.assertIn("source_path=ThirdParty/GhosttyVT/Source\n", manifest)
            self.assertIn("toolchain_path=ThirdParty/Zig/zig-0.16.0\n", manifest)
            self.assertIn("umbrella_header=ghostty/vt.h\n", manifest)
            self.assertIn(
                "umbrella_header_sha256="
                f"{hashlib.sha256((work / 'artifacts/include/ghostty/vt.h').read_bytes()).hexdigest()}\n",
                manifest,
            )
            self.assertTrue((work / "artifacts/lib/libghostty-vt.dylib").is_symlink())
            self.assertTrue((work / "artifacts/include/ghostty/vt.h").is_file())
            self.assertTrue((work / "cache").is_dir())
            self.assertEqual(self.source_digest(source), original_source_digest)
            self.assertFalse((source / "zig-out").exists())
            self.assertFalse((source / ".zig-cache").exists())
            self.assertEqual(temporary_links, [])

    def test_missing_relative_or_repository_work_root_is_rejected_early(self) -> None:
        base_environment = os.environ.copy()
        for name in tuple(base_environment):
            if name.startswith("MACSCOPE_GHOSTTY") or name.startswith("MACSCOPE_ZIG"):
                base_environment.pop(name)

        missing = subprocess.run(
            [str(SCRIPT), "--verify-only"],
            cwd=ROOT,
            env=base_environment,
            text=True,
            capture_output=True,
        )
        relative = subprocess.run(
            [str(SCRIPT), "--work-root", "relative-work", "--verify-only"],
            cwd=ROOT,
            env=base_environment,
            text=True,
            capture_output=True,
        )
        repository = subprocess.run(
            [
                str(SCRIPT),
                "--work-root",
                str(ROOT / "forbidden-work"),
                "--verify-only",
            ],
            cwd=ROOT,
            env=base_environment,
            text=True,
            capture_output=True,
        )

        self.assertNotEqual(missing.returncode, 0)
        self.assertIn("--work-root is required", missing.stderr)
        self.assertNotEqual(relative.returncode, 0)
        self.assertIn("must be an absolute path", relative.stderr)
        self.assertNotEqual(repository.returncode, 0)
        self.assertIn("must be outside the repository", repository.stderr)
        self.assertFalse((ROOT / "forbidden-work").exists())

    def test_reproducible_relink_pins_macos_27_despite_ambient_deployment_target(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = self.make_source(root)
            zig = self.make_zig(root)
            environment, work = self.make_environment(root, source, zig)
            environment["MACOSX_DEPLOYMENT_TARGET"] = "13.0"
            result = subprocess.run(
                [str(SCRIPT), "--work-root", str(work)],
                cwd=ROOT, env=environment, text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            arguments = (work / "clang-arguments.txt").read_text().splitlines()
            self.assertEqual(arguments.count("-target"), 1)
            self.assertEqual(arguments[arguments.index("-target") + 1], "arm64-apple-macosx27.0")

    def test_cached_dylib_requires_one_exact_macos_27_minimum(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = self.make_source(root)
            zig = self.make_zig(root)
            environment, work = self.make_environment(root, source, zig)
            build = subprocess.run(
                [str(SCRIPT), "--work-root", str(work)],
                cwd=ROOT, env=environment, text=True, capture_output=True,
            )
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            for minimum in ("13.0", "27.1", "", "27.0\n    minos 27.0"):
                with self.subTest(minimum=minimum):
                    environment["MACSCOPE_GHOSTTY_FIXTURE_MINIMUM_OS"] = minimum
                    verify = subprocess.run(
                        [str(SCRIPT), "--work-root", str(work), "--verify-only"],
                        cwd=ROOT, env=environment, text=True, capture_output=True,
                    )
                    self.assertNotEqual(verify.returncode, 0)
                    self.assertIn("artifacts are missing, malformed, or stale", verify.stdout)
                    self.assertIn(f"--work-root {work.resolve()} to build it", verify.stdout)
                    self.assertNotIn("native macOS dylib available", verify.stdout)

    def test_rebuild_cannot_publish_a_dylib_with_wrong_minimum_os(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = self.make_source(root)
            zig = self.make_zig(root)
            environment, work = self.make_environment(root, source, zig)
            environment["MACSCOPE_GHOSTTY_FIXTURE_MINIMUM_OS"] = "13.0"
            build = subprocess.run(
                [str(SCRIPT), "--work-root", str(work)],
                cwd=ROOT, env=environment, text=True, capture_output=True,
            )
            self.assertNotEqual(build.returncode, 0)
            self.assertIn("require macOS 27.0", build.stdout)
            self.assertFalse((work / "artifacts/lib/.macscope-ghostty-vt-manifest").exists())

    def test_production_rejects_external_source_and_toolchain_authority(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            environment = os.environ.copy()
            environment.update(
                {
                    "MACSCOPE_GHOSTTY_SOURCE_DIR": str(root / "external-source"),
                    "MACSCOPE_ZIG_ROOT": str(root / "external-zig"),
                }
            )
            result = subprocess.run(
                [
                    str(SCRIPT),
                    "--work-root",
                    str(root / "work"),
                    "--verify-only",
                ],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("overrides are test-only", result.stdout + result.stderr)

    def test_package_store_drift_is_rejected_before_artifact_use(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = self.make_source(root)
            zig = self.make_zig(root)
            environment, work = self.make_environment(root, source, zig)
            (source / "zig-pkg/fixture-one/build.zig").write_text(
                "drifted\n", encoding="utf-8"
            )
            result = subprocess.run(
                [str(SCRIPT), "--work-root", str(work), "--verify-only"],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "closed Zig dependency package store", result.stdout + result.stderr
        )

    def test_builder_has_no_network_or_source_tree_output_path(self) -> None:
        script = SCRIPT.read_text(encoding="utf-8")
        self.assertIn('GHOSTTY_DIR="${REPO_ROOT}/ThirdParty/GhosttyVT/Source"', script)
        self.assertIn('ZIG_ROOT="${REPO_ROOT}/ThirdParty/Zig/zig-0.16.0"', script)
        self.assertIn('--system "${PACKAGE_STORE}"', script)
        self.assertIn('--cache-dir "${BUILD_CACHE_ROOT}"', script)
        self.assertIn('--prefix "${ARTIFACT_ROOT}"', script)
        self.assertIn('ZIG_GLOBAL_CACHE_DIR="${GLOBAL_CACHE_ROOT}"', script)
        self.assertIn(
            'SDK_COMPATIBILITY_ROOT="${SDK_COMPATIBILITY_ROOT_OVERRIDE:-${WORK_ROOT}/sdk-compatibility}"',
            script,
        )
        self.assertNotIn("curl ", script)
        self.assertNotIn("git clone", script)
        self.assertNotIn('DYLIB="${GHOSTTY_DIR}', script)
        self.assertNotIn('STATIC_LIBRARY="${GHOSTTY_DIR}', script)
        self.assertNotIn('HEADERS_ROOT="${GHOSTTY_DIR}', script)
        self.assertNotIn("--fetch", script)


if __name__ == "__main__":
    unittest.main()
