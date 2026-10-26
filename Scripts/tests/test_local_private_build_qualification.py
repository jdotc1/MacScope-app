#!/usr/bin/env python3

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import re
import stat
from pathlib import Path
import subprocess
import tempfile
import unittest


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
QUALIFIER = REPOSITORY_ROOT / "Scripts/qualify_local_private_build.sh"
SOURCE_EXPORT = REPOSITORY_ROOT / "Scripts/source_export_provenance.py"
PRODUCT_IDENTITY_VALIDATOR = (
    REPOSITORY_ROOT
    / "Scripts/reconstruction/validate_qualification_product_identity.py"
)
GATE_F_PACKAGE = REPOSITORY_ROOT / "Scripts/reconstruction_gate_f"
DEPENDENCY_CACHE_TOOL = REPOSITORY_ROOT / "Scripts/qualification/dependency_cache.py"
STAGE_TIMING_TOOL = REPOSITORY_ROOT / "Scripts/qualification/stage_timing.py"
HEAVY_GATE_LOCK_TOOL = REPOSITORY_ROOT / "Scripts/qualification/heavy_gate_lock.py"
BOOTSTRAP_REUSE_TOOL = REPOSITORY_ROOT / "Scripts/qualification/bootstrap_reuse.py"
PROJECT_FRESHNESS_TOOL = REPOSITORY_ROOT / "Scripts/project_freshness.py"
BUILD_SOURCE_RESTORE_TOOL = (
    REPOSITORY_ROOT / "Scripts/qualification/restore_build_source.py"
)
RESTORE_SPEC = importlib.util.spec_from_file_location(
    "qualification_restore_build_source", BUILD_SOURCE_RESTORE_TOOL
)
assert RESTORE_SPEC is not None and RESTORE_SPEC.loader is not None
RESTORE_MODULE = importlib.util.module_from_spec(RESTORE_SPEC)
RESTORE_SPEC.loader.exec_module(RESTORE_MODULE)
QUALIFICATION_V4_FIELDS = {
    "build_source_root",
    "dependency_cache_root",
    "dependency_network_allowed",
    "dependency_network_used",
    "ghostty_artifact_manifest_sha256",
    "ghostty_source_dir",
    "ghostty_surface_artifact_root",
    "ghostty_surface_manifest_sha256",
    "ghostty_surface_source_dir",
    "mode",
    "schema_version",
    "sleigh_materialization_manifest_sha256",
    "sleigh_materialization_root",
    "source_identity",
    "zig_executable",
}


class QualificationFixture:
    integration_ref = "refs/remotes/gitfox-local/feature/qualification-fixture"

    def __init__(self, root: Path) -> None:
        self.root = root
        self.log = root.parent / "commands.log"
        self.external_machokit = root.parent / "external-machokit"

        self._write("Scripts/source_export_provenance.py", SOURCE_EXPORT.read_bytes())
        # Dependency artifacts are synthetic here; their external toolchain
        # identities must be synthetic too. Keep the real cache implementation,
        # but never hash the host's unchanged Xcode/system tools in this fixture.
        cache_source = DEPENDENCY_CACHE_TOOL.read_text(encoding="utf-8")
        entrypoint = '\nif __name__ == "__main__":'
        assert cache_source.count(entrypoint) == 1
        fixture_identity = '''
def external_file_identity(raw):
    name, requested = named_value(raw, "external-file identity")
    return {"name": name, "path": requested,
            "sha256": hashlib.sha256(raw.encode()).hexdigest(), "size": 0}
'''
        self._write("Scripts/qualification/dependency_cache.py",
                    cache_source.replace(entrypoint, fixture_identity + entrypoint))
        self._write("Scripts/qualification/stage_timing.py", STAGE_TIMING_TOOL.read_bytes())
        self._write("Scripts/qualification/heavy_gate_lock.py", HEAVY_GATE_LOCK_TOOL.read_bytes())
        self._write("Scripts/qualification/bootstrap_reuse.py", BOOTSTRAP_REUSE_TOOL.read_bytes())
        # bootstrap_reuse delegates freshness to the canonical stamp contract.
        self._write("Scripts/project_freshness.py", PROJECT_FRESHNESS_TOOL.read_bytes())
        self._write(
            "Scripts/qualification/restore_build_source.py",
            BUILD_SOURCE_RESTORE_TOOL.read_bytes(),
        )
        self._write(
            "Scripts/reconstruction/validate_qualification_product_identity.py",
            PRODUCT_IDENTITY_VALIDATOR.read_bytes(),
        )
        for name in ("__init__.py", "canonical_json.py", "schema.py"):
            self._write(
                f"Scripts/reconstruction_gate_f/{name}",
                (GATE_F_PACKAGE / name).read_bytes(),
            )
        self._write_executable(
            "Scripts/build_ghostty_vt.sh",
            r'''#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd -P)"
test -d "$repo/ThirdParty/GhosttyVT/Source"
test -x "$repo/ThirdParty/Zig/zig-0.16.0/zig"
work=""
verify=0
while (($#)); do
  case "$1" in
    --work-root) work="$2"; shift 2 ;;
    --verify-only) verify=1; shift ;;
    *) exit 2 ;;
  esac
done
test "${work:-}" = "$(cd "$(dirname "$work")" && pwd -P)/$(basename "$work")"
artifact="$work/artifacts/lib/libghostty-vt.dylib"
versioned_artifact="$work/artifacts/lib/libghostty-vt.0.1.0.dylib"
manifest="$work/artifacts/lib/.macscope-ghostty-vt-manifest"
header="$work/artifacts/include/ghostty/vt.h"
module="$work/artifacts/include/module.modulemap"
if [[ "$verify" == 1 ]]; then
  test -L "$artifact" -a "$(readlink "$artifact")" = libghostty-vt.0.1.0.dylib
  test -f "$versioned_artifact" -a -f "$header" -a -f "$module"
  grep -Fxq 'schema=5' "$manifest"
  grep -Fxq "dylib_sha256=$(/usr/bin/shasum -a 256 "$artifact" | awk '{print $1}')" "$manifest"
  grep -Fxq "umbrella_header_sha256=$(/usr/bin/shasum -a 256 "$header" | awk '{print $1}')" "$manifest"
  grep -Fxq "module_map_sha256=$(/usr/bin/shasum -a 256 "$module" | awk '{print $1}')" "$manifest"
  echo verify-ghostty-vt >> "$MACSCOPE_QUALIFICATION_TEST_LOG"
else
  mkdir -p "$(dirname "$artifact")" "$(dirname "$header")"
  printf 'repository vt artifact\n' > "$versioned_artifact"
  ln -s libghostty-vt.0.1.0.dylib "$artifact"
  printf 'fixture header\n' > "$header"
  printf 'fixture module map\n' > "$module"
  {
    echo 'schema=5'
    echo "dylib_sha256=$(/usr/bin/shasum -a 256 "$artifact" | awk '{print $1}')"
    echo "umbrella_header_sha256=$(/usr/bin/shasum -a 256 "$header" | awk '{print $1}')"
    echo "module_map_sha256=$(/usr/bin/shasum -a 256 "$module" | awk '{print $1}')"
  } > "$manifest"
  echo build-ghostty-vt >> "$MACSCOPE_QUALIFICATION_TEST_LOG"
fi
''',
        )
        self._write_executable(
            "Scripts/dependencies/build_vendored_ghostty_surface.sh",
            r'''#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd -P)"
test -d "$repo/ThirdParty/GhosttySurface/Source"
test -d "$repo/ThirdParty/GhosttySurface/zig-pkg"
test -x "$repo/ThirdParty/Zig/zig-0.16.0/zig"
work=""
verify=0
while (($#)); do
  case "$1" in
    --work-root) work="$2"; shift 2 ;;
    --verify-only) verify=1; shift ;;
    *) exit 2 ;;
  esac
done
test "${work:-}" = "$(cd "$(dirname "$work")" && pwd -P)/$(basename "$work")"
source_root="$work/GhosttySurface"
artifact="$source_root/macos/GhosttyKit.xcframework/macos-arm64/libghostty-internal.a"
manifest="$source_root/macos/.macscope-ghostty-surface-manifest"
if [[ "$verify" == 1 ]]; then
  test -f "$artifact"
  grep -Fxq 'schema=fixture-repository-surface' "$manifest"
  echo verify-ghostty-surface >> "$MACSCOPE_QUALIFICATION_TEST_LOG"
else
  mkdir -p "$(dirname "$artifact")" "$(dirname "$manifest")"
  printf 'repository surface artifact\n' > "$artifact"
  printf 'schema=fixture-repository-surface\n' > "$manifest"
  echo build-ghostty-surface >> "$MACSCOPE_QUALIFICATION_TEST_LOG"
fi
if [[ "${MACSCOPE_QUALIFICATION_FIXTURE_BAD_SURFACE_OUTPUT:-0}" == 1 ]]; then
  echo "unexpected-output"
else
  echo "GHOSTTY_SURFACE_SOURCE_DIR=$source_root"
  echo "GHOSTTY_SURFACE_ARTIFACT_ROOT=$source_root/macos/GhosttyKit.xcframework"
fi
''',
        )
        self._write_executable(
            "Scripts/dependencies/build_vendored_sleigh_native_source.sh",
            r'''#!/bin/bash
set -euo pipefail
test "$1" = --work-root
work="$2"
test "$work" = "$(cd "$(dirname "$work")" && pwd -P)/$(basename "$work")"
repo="$(cd "$(dirname "$0")/../.." && pwd -P)"
test -f "$repo/ThirdParty/SleighNative/Source/MATERIALIZATION.json"
source_build="$work/SleighNativeSource"
materialization="$source_build/materialization"
manifest="$materialization/MATERIALIZATION.json"
archive="$materialization/package/lib/libdecomp.a"
if [[ -e "$source_build" ]]; then
  grep -Fxq '{"fixture":"source-built-native"}' "$manifest"
  test -f "$archive"
  test -f "$materialization/package/lib/libsla.a"
  echo reuse-sleigh-source-build >> "$MACSCOPE_QUALIFICATION_TEST_LOG"
else
  mkdir -p "$(dirname "$archive")"
  printf '{"fixture":"source-built-native"}\n' > "$manifest"
  printf 'source-built decompiler archive\n' > "$archive"
  printf 'source-built sleigh archive\n' > "$materialization/package/lib/libsla.a"
  printf '{"fixture":"source-build-receipt"}\n' > "$source_build/SOURCE_BUILD_MATERIALIZATION.json"
  echo build-sleigh-source >> "$MACSCOPE_QUALIFICATION_TEST_LOG"
fi
if [[ "${MACSCOPE_QUALIFICATION_FIXTURE_BAD_SLEIGH_OUTPUT:-0}" == 1 ]]; then
  echo "unexpected-output"
else
  echo "MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT=$source_build"
  echo "MACSCOPE_SLEIGH_MATERIALIZATION_ROOT=$materialization"
fi
''',
        )
        # The qualifier describes the verified VT/surface views for bootstrap
        # and Xcode. The real describers require genuine Ghostty artifacts, so
        # the fixture binds its synthetic views the same way: one descriptor
        # file plus its printed SHA-256.
        describe_stub = r'''#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--describe", action="store_true", required=True)
parser.add_argument("--source-root", type=Path)
parser.add_argument("--artifact-root", type=Path)
parser.add_argument("--descriptor", type=Path, required=True)
arguments = parser.parse_args()
root = (arguments.source_root or arguments.artifact_root).resolve(strict=True)
files = sorted(str(path.relative_to(root)) for path in root.rglob("*") if path.is_file())
payload = (json.dumps({"files": files, "root": str(root)}, sort_keys=True) + "\n").encode()
if arguments.descriptor.exists():
    if arguments.descriptor.read_bytes() != payload:
        raise SystemExit("existing fixture descriptor differs")
else:
    arguments.descriptor.write_bytes(payload)
    arguments.descriptor.chmod(0o444)
print(hashlib.sha256(payload).hexdigest())
'''
        for relative in (
            "Scripts/dependencies/verified_ghostty_surface_admission.py",
            "Scripts/dependencies/stage_verified_ghostty_vt.py",
        ):
            self._write_executable(relative, describe_stub)
        for relative in (
            "Scripts/ghostty-vt-source.contract",
            "Scripts/ghostty-surface-source.contract",
            "Scripts/prepare_zig_macos_sdk_overlay.py",
            "Scripts/dependencies/zig_toolchain_receipt.py",
            "Scripts/dependencies/build_ghostty_surface.sh",
            "Scripts/dependencies/verify_vendored_sleigh_source.py",
            "Scripts/native-decompiler-direct/sleigh_package.py",
            "Scripts/native-decompiler-direct/verify_sleigh_package.py",
        ):
            self._write(relative, f"fixture cache-key input: {relative}\n")
        self._write_executable(
            "Scripts/machokit_source_identity.py",
            r'''#!/usr/bin/env python3
import argparse
from pathlib import Path
import os

parser = argparse.ArgumentParser()
commands = parser.add_subparsers(dest="command", required=True)
verify = commands.add_parser("verify")
verify.add_argument("--materialization-root", required=True)
verify.add_argument("--quiet", action="store_true")
arguments = parser.parse_args()
root = Path(arguments.materialization_root).resolve(strict=True)
if not root.is_dir() or not (root / "MATERIALIZATION.json").is_file():
    raise SystemExit("unsafe fixture MachOKit root")
for path in [root, *root.rglob("*")]:
    if path.stat().st_mode & 0o222:
        raise SystemExit(f"published materialization path is writable: {path}")
with open(os.environ["MACSCOPE_QUALIFICATION_TEST_LOG"], "a", encoding="utf-8") as stream:
    stream.write("verify-machokit\n")
''',
        )
        self._write_executable(
            "Scripts/bootstrap.sh",
            r'''#!/bin/bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd -P)"
test -f "$MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT/GhosttySurface/macos/.macscope-ghostty-surface-manifest"
test -f "$MACSCOPE_SLEIGH_SOURCE_BUILD_WORK_ROOT/SleighNativeSource/materialization/MATERIALIZATION.json"
test "$MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT" = "$MACSCOPE_SLEIGH_SOURCE_BUILD_WORK_ROOT/SleighNativeSource"
test "$MACSCOPE_SLEIGH_MATERIALIZATION_ROOT" = "$MACSCOPE_SLEIGH_SOURCE_BUILD_WORK_ROOT/SleighNativeSource/materialization"
test -f "$MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT/MATERIALIZATION.json"
ln -s "$MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT" "$repo/MacScope/LocalPackages"
cat > "$repo/MacScope/DependencyRoots.local.xcconfig" <<EOF
// Generated by Scripts/bootstrap.sh. Untracked and machine-local — do not commit.
// Regenerate by re-running bootstrap; edit DependencyRoots.xcconfig for anything
// that should be shared.
MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT = $MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT
MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR = $MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR
MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT = $MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT
MACSCOPE_GHOSTTY_SURFACE_FRAMEWORK = $MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT/macos-arm64/libghostty-internal.a
MACSCOPE_GHOSTTY_SURFACE_ENABLED = MACSCOPE_FULL_GHOSTTY_SURFACE
MACSCOPE_SLEIGH_COMPONENT_ROOT = $repo/ThirdParty/SleighNative
MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT = $MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT
MACSCOPE_SLEIGH_MATERIALIZATION_ROOT = $MACSCOPE_SLEIGH_MATERIALIZATION_ROOT
MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT = $MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT
MACSCOPE_PARSER_ENGINE_CACHE_ROOT = $MACSCOPE_DEPENDENCY_CACHE_ROOT
EOF
project="$repo/MacScope/MacScope.xcodeproj"
mkdir -p \
  "$project/project.xcworkspace/xcshareddata/swiftpm/configuration" \
  "$project/xcshareddata/xcschemes"
for relative in \
  .macscope-project-generation.sha256 \
  project.xcproj \
  project.xcworkspace/contents.xcworkspacedata \
  xcshareddata/xcschemes/MacScopeApp.xcscheme \
  xcshareddata/xcschemes/CoreTests.xcscheme \
  xcshareddata/xcschemes/Phase2Tests.xcscheme \
  xcshareddata/xcschemes/MacScopeInstalledAppUITests.xcscheme
do
  printf '// generated %s\n' "$relative" > "$project/$relative"
done
printf '// generated project.xcproj WorkspaceDatabase.swift AnalysisEngine.swift\n' \
  > "$project/project.xcproj"
/usr/bin/python3 -B -c 'import importlib.util, sys; from pathlib import Path
spec = importlib.util.spec_from_file_location("f", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.record_generated_project_freshness(Path(sys.argv[2]))' "$repo/Scripts/project_freshness.py" "$repo/MacScope/project.yml"
echo bootstrap >> "$MACSCOPE_QUALIFICATION_TEST_LOG"
''',
        )

        self._write("ThirdParty/GhosttyVT/Source/fixture.txt", "vendored VT\n")
        self._write("ThirdParty/GhosttySurface/Source/fixture.txt", "vendored surface\n")
        self._write("ThirdParty/GhosttySurface/zig-pkg/fixture.txt", "closed packages\n")
        self._write("ThirdParty/SleighNative/Source/MATERIALIZATION.json", '{"fixture":"source"}\n')
        self._write_executable("ThirdParty/Zig/zig-0.16.0/zig", "#!/bin/sh\necho 0.16.0\n")
        self._machokit(self.root / "ThirdParty/MachOKit/materialization", "repository")
        self._machokit(self.external_machokit, "diagnostic-override")
        self._freeze_machokit(self.external_machokit)
        self._write("MacScope/project.yml", "name: Fixture\n")
        # Remaining project-generation freshness inputs (Scripts/check_local_signing_policy.py).
        self._write("MacScope/DependencyRoots.xcconfig", "// fixture dependency roots\n")
        self._write("MacScope/SigningIdentity.xcconfig", "// fixture signing identity\n")
        self._write("ThirdParty/SleighNative/PATCHED_RESOURCES.json", '{"fixture": "sleigh overlay"}\n')
        self._write(
            "THIRD_PARTY_COMPONENTS.yml",
            json.dumps(
                {
                    "components": [
                        {"id": "fixture", "pin": {"revision": "fixture-revision"}}
                    ]
                },
                sort_keys=True,
            )
            + "\n",
        )
        self._write("THIRD_PARTY_NOTICES.md", "# Fixture notices\n")

        self._git("init", "-b", "main")
        self._git("config", "user.email", "qualification@example.invalid")
        self._git("config", "user.name", "Qualification Fixture")
        self._git("remote", "add", "origin", "https://github.com/example/MacScope.git")
        self._git("remote", "add", "gitfox-local", str(root.parent / "MacScope.git"))
        self._git("add", ".")
        self._git("commit", "-m", "fixture")
        self._git("update-ref", self.integration_ref, self._git("rev-parse", "HEAD", output=True))

    def _write(self, relative: str, contents: str | bytes) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(contents, bytes):
            path.write_bytes(contents)
        else:
            path.write_text(contents, encoding="utf-8")

    def _write_executable(self, relative: str, contents: str) -> None:
        self._write(relative, contents)
        (self.root / relative).chmod(0o755)

    @staticmethod
    def _machokit(root: Path, identity: str) -> None:
        (root / "MachOKit").mkdir(parents=True)
        (root / "MachOKit/Package.swift").write_text("// fixture\n", encoding="utf-8")
        (root / "MATERIALIZATION.json").write_text(
            json.dumps({"fixture": identity}, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    @staticmethod
    def _freeze_machokit(root: Path) -> None:
        for path in root.rglob("*"):
            if path.is_file():
                path.chmod(path.stat().st_mode & ~0o222)
        for path in sorted(
            [root, *(path for path in root.rglob("*") if path.is_dir())],
            key=lambda item: len(item.parts),
            reverse=True,
        ):
            path.chmod(path.stat().st_mode & ~0o222)

    def _git(self, *arguments: str, output: bool = False) -> str:
        result = subprocess.run(
            ["/usr/bin/git", *arguments],
            cwd=self.root,
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise AssertionError(result.stderr)
        return result.stdout.strip() if output else ""

    def qualify(
        self,
        work_root: Path,
        *,
        integration_ref: str | None = integration_ref,
        integration_commit: str | None = None,
        mode: str = "prepare",
        materialize_dependencies: bool = False,
        resume_run: Path | None = None,
        machokit_override: Path | None = None,
        dependency_cache_root: Path | None = None,
        extra_environment: dict[str, str] | None = None,
        source_root: Path | None = None,
        xcode_output: str | None = None,
        qualifier_path: Path | None = None,
        extra_arguments: tuple[str, ...] = (),
        inherited_nice: int | None = None,
    ) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        for name in tuple(environment):
            if name.startswith("MACSCOPE_GHOSTTY_") or name.startswith("MACSCOPE_SLEIGH_"):
                environment.pop(name)
        environment.pop("MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT", None)
        environment["MACSCOPE_QUALIFICATION_TEST_LOG"] = str(self.log)
        if machokit_override is not None:
            environment["MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT"] = str(machokit_override)
        if extra_environment:
            environment.update(extra_environment)
        command = [
            "/bin/bash",
            str(qualifier_path or QUALIFIER),
            "--source-root",
            str(source_root or self.root),
            "--work-root",
            str(work_root),
            "--mode",
            mode,
        ]
        if integration_ref is not None:
            command.extend(["--integration-ref", integration_ref])
        if integration_commit is not None:
            command.extend(["--integration-commit", integration_commit])
        if dependency_cache_root is not None:
            command.extend(["--dependency-cache-root", str(dependency_cache_root)])
        if materialize_dependencies:
            command.append("--materialize-dependencies")
        if resume_run is not None:
            command.extend(["--resume-run", str(resume_run)])
        if xcode_output is not None:
            command.extend(["--xcode-output", xcode_output])
        command.extend(extra_arguments)
        if inherited_nice is not None:
            adjustment = max(0, inherited_nice - os.getpriority(os.PRIO_PROCESS, 0))
            command = ["/usr/bin/nice", "-n", str(adjustment), *command]
        return subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )


class LocalPrivateBuildQualificationTests(unittest.TestCase):
    def test_fixture_external_identity_never_reads_host_toolchain(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary).resolve() / "source"
            source.mkdir()
            QualificationFixture(source)
            requested = source / "nonexistent-toolchain"
            result = subprocess.run(
                ["/usr/bin/python3", "-B",
                 str(source / "Scripts/qualification/dependency_cache.py"),
                 "external-identity", "--external-file", f"clang={requested}"],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertRegex(result.stdout.strip(), r"^[0-9a-f]{64}$")
            self.assertFalse(requested.exists())

    def test_reverification_flag_is_refused_and_ci_never_passes_it(self) -> None:
        script = QUALIFIER.read_text(encoding="utf-8")
        workflow = (REPOSITORY_ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
        self.assertNotIn("--no-verification-reuse", workflow)
        self.assertNotIn("VERIFICATION_REUSE=0", script)
        self.assertNotIn("MACSCOPE_OWNER_APPROVED_REVERIFICATION", script)
        result = subprocess.run(["/bin/bash", str(QUALIFIER), "--no-verification-reuse"],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("never re-verified", result.stderr)

    def test_gate_lock_wait_is_bounded_by_default(self) -> None:
        script = QUALIFIER.read_text(encoding="utf-8")
        self.assertIn("\nGATE_LOCK_TIMEOUT=1800\n", script)

    # D1 (2026-10-12): Git identity replaces full source verification.

    def test_git_identity_admission_stages_clean_head_without_reverification(self) -> None:
        script = QUALIFIER.read_text(encoding="utf-8")
        for removed in ("full-verify", "verify --source-root", "reuse-export", "clone-export",
                        "TRUSTED_SOURCE_TOOL", "--incremental-verification", "--clone-stage"):
            self.assertNotIn(removed, script)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            work = root / "qualification"
            result = fixture.qualify(work)
            self.assertEqual(result.returncode, 0, result.stderr)
            identity = self._receipt(work)["source_identity"]
            self.assertEqual(identity["git_head_commit"], fixture._git("rev-parse", "HEAD", output=True))
            self.assertEqual(identity["git_head_tree"], fixture._git("rev-parse", "HEAD^{tree}", output=True))
            self.assertEqual(self._stage_names(work)[:2], ["source.git-identity", "source.identity-check"])
            run = next((work / "runs").glob("run.*"))
            self.assertFalse((run / "source/.git").exists())
            self.assertFalse((work / "source-export").exists())

    def test_persistent_run_keeps_only_derived_data_warm(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            work = root / "qualification"
            options = ("--persistent-run", "nightly", "--nice", "10")
            inherited = max(15, os.getpriority(os.PRIO_PROCESS, 0))
            first = fixture.qualify(work, extra_arguments=options, inherited_nice=15)
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertIn(f"requested=10 inherited={inherited} effective={inherited}", first.stderr)
            run = work / "runs/run.nightly"
            sentinel = run / "DerivedData/Build/warm.txt"
            sentinel.parent.mkdir(parents=True, exist_ok=True)
            sentinel.write_text("warm\\n")
            (run / "stale.txt").write_text("stale\\n")
            second = fixture.qualify(work, extra_arguments=options, inherited_nice=15)
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertIn(f"requested=10 inherited={inherited} effective={inherited}", second.stderr)
            self.assertEqual(sentinel.read_text(), "warm\\n")
            self.assertFalse((run / "stale.txt").exists())
            self.assertTrue((run / "source/SOURCE_PROVENANCE.json").is_file())
            self.assertEqual([path.name for path in (work / "runs").iterdir()], ["run.nightly"])
            rejected = fixture.qualify(work, extra_arguments=("--persistent-run", "../x"))
            self.assertEqual(rejected.returncode, 2)

    def test_nice_only_lowers_priority_and_rejects_invalid_requests(self) -> None:
        script = QUALIFIER.read_text(encoding="utf-8")
        start = script.index('if [[ -n "${PROCESS_NICE}" ]]; then')
        block = script[start:script.index('if [[ ! "${GATE_LOCK_TIMEOUT}"', start)]
        inherited = max(15, os.getpriority(os.PRIO_PROCESS, 0))
        adjustment = max(0, 15 - os.getpriority(os.PRIO_PROCESS, 0))
        for requested in (10, 15, 19, 21):
            with self.subTest(requested=requested):
                result = subprocess.run(
                    ["/usr/bin/nice", "-n", str(adjustment), "/bin/bash", "-eu", "-c", block],
                    env=dict(os.environ, PROCESS_NICE=str(requested)),
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, 2 if requested == 21 else 0, result.stderr)
                if requested == 21:
                    self.assertIn("integer from 0 to 20", result.stderr)
                else:
                    self.assertIn(
                        f"requested={requested} inherited={inherited} effective={max(inherited, requested)}",
                        result.stderr,
                    )

    def test_typed_persistent_run_preserves_native_view_inode_and_readonly_mode(self) -> None:
        script = QUALIFIER.read_text(encoding="utf-8")
        start = script.index('  if [[ -n "${PERSISTENT_RUN}" ]]; then', script.index('else\n  if [[ -n "${PERSISTENT_RUN}"'))
        end = script.index('  else\n    RUN_ROOT="$(/usr/bin/mktemp', start)
        block = script[start:end] + "\n  fi\n"
        with tempfile.TemporaryDirectory() as temporary:
            runs = Path(temporary).resolve() / "runs"
            run = runs / "run.main-release"
            native = run / "dependencies/sleigh-native-source/SleighNativeSource/materialization/native.txt"
            native.parent.mkdir(parents=True)
            native.write_text("accepted native copy")
            native.chmod(0o444)
            before = native.stat()
            compiled = run / "DerivedData/Build/warm.txt"
            compiled.parent.mkdir(parents=True)
            compiled.write_text("compiled")
            stale = run / "stale.txt"
            stale.write_text("replace")
            environment = dict(os.environ, RUNS_ROOT=str(runs), PERSISTENT_RUN="main-release",
                               RETAINED_RELEASE_QUALIFICATION_INPUTS="/accepted/QUALIFICATION_INPUTS.json",
                               NATIVE_RELEASE_ADMISSION="")
            result = subprocess.run(["/bin/bash", "-c", "set -euo pipefail\n" + block],
                                    env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(native.read_text(), "accepted native copy")
            self.assertEqual(native.stat().st_ino, before.st_ino)
            self.assertEqual(native.stat().st_mtime_ns, before.st_mtime_ns)
            self.assertEqual(stat.S_IMODE(native.stat().st_mode), 0o444)
            self.assertEqual(compiled.read_text(), "compiled")
            self.assertFalse(stale.exists())
            self.assertEqual([p.name for p in runs.iterdir()], ["run.main-release"])

    def test_shared_gate_slot_never_takes_the_exclusive_lock(self) -> None:
        script = QUALIFIER.read_text(encoding="utf-8")
        acquire = script[script.index("acquire_heavy_gate_lock() {"):]
        acquire = acquire[: acquire.index("\n}\n")]
        self.assertIn('shared_arguments=(--shared --slot-fds 4,5,6)', acquire)
        self.assertIn('${shared_arguments[@]+"${shared_arguments[@]}"}', acquire)

    def test_dirty_worktree_is_rejected_before_run_staging(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            (source / "untracked.txt").write_text("dirty source")
            work = root / "qualification"
            rejected = fixture.qualify(work)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("requires a clean Git worktree", rejected.stderr)
            self.assertEqual(list((work / "runs").glob("run.*/source")), [])
            self.assertFalse(fixture.log.exists())

    def test_head_must_equal_the_integration_commit(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            work = root / "qualification"
            rejected = fixture.qualify(work, integration_commit="0" * 40)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("expected integration commit", rejected.stderr)
            self.assertFalse(fixture.log.exists())

    def test_source_sha256_is_computed_once_per_blob_and_trusted_by_key(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            work = root / "qualification"
            self.assertEqual(fixture.qualify(work).returncode, 0)
            memo = work / "dependencies/verification.noindex/source-records/git-blob-sha256.v1.json"
            blobs = json.loads(memo.read_bytes())["blobs"]
            first_run = next((work / "runs").glob("run.*"))
            records = json.loads((first_run / "source/SOURCE_FILES.json").read_bytes())["files"]
            self.assertEqual({record["blob_oid"] for record in records}, set(blobs))
            # A later run trusts the memo by blob ID: a planted digest is used
            # verbatim, proving no file is re-hashed.
            planted = records[0]["blob_oid"]
            blobs[planted] = ["f" * 64, blobs[planted][1]]
            memo.write_text(json.dumps({"blobs": blobs, "schema_version": 1}))
            self.assertEqual(fixture.qualify(work).returncode, 0)
            second_run = next(run for run in (work / "runs").glob("run.*") if run != first_run)
            second = json.loads((second_run / "source/SOURCE_FILES.json").read_bytes())["files"]
            self.assertEqual(second[0]["sha256"], "f" * 64)

    def test_xcode_output_mode_is_closed_before_work_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            quiet = fixture.qualify(root / "quiet-work", xcode_output="quiet")
            self.assertEqual(quiet.returncode, 0, quiet.stderr)
            self.assertIn("MACSCOPE_QUALIFICATION_RECEIPT=", quiet.stdout)
            mirror = fixture.qualify(root / "mirror-work", xcode_output="mirror")
            self.assertEqual(mirror.returncode, 0, mirror.stderr)
            for mode in ("log-only", "QUIET", ""):
                with self.subTest(mode=mode):
                    work = root / ("invalid-" + (mode or "empty"))
                    rejected = fixture.qualify(work, xcode_output=mode)
                    self.assertEqual(rejected.returncode, 2)
                    self.assertIn("--xcode-output", rejected.stderr)
                    self.assertFalse(work.exists())

    def test_release_candidate_option_is_closed_before_work_mutation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            accepted = fixture.qualify(root / "auto-work", extra_arguments=("--release-candidate", "auto"))
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            # CI passes one expression for every mode; modes that never build
            # Release accept build/skip as no-ops.
            for value in ("build", "skip"):
                with self.subTest(mode="prepare", value=value):
                    noop = fixture.qualify(root / f"prepare-{value}", mode="prepare",
                                           extra_arguments=("--release-candidate", value))
                    self.assertEqual(noop.returncode, 0, noop.stderr)
            for mode, value, message in (
                ("release", "skip", "--release-candidate skip is not valid for release"),
                ("full-test", "never", "--release-candidate must be auto, build or skip"),
            ):
                with self.subTest(mode=mode, value=value):
                    work = root / f"invalid-{mode}-{value}"
                    rejected = fixture.qualify(
                        work, mode=mode, extra_arguments=("--release-candidate", value)
                    )
                    self.assertEqual(rejected.returncode, 2)
                    self.assertIn(message, rejected.stderr)
                    self.assertFalse(work.exists())

    def test_release_candidate_skip_omits_release_build_and_installed_preparation(self) -> None:
        script = QUALIFIER.read_text(encoding="utf-8")
        full_test = script[script.index("  full-test)") : script.index("  release)")]
        skip = full_test.index('if [[ "${RELEASE_CANDIDATE}" == skip ]]; then')
        build = full_test.index("timed_xcode_stage xcode.release-build")
        self.assertLess(skip, build)
        self.assertEqual(full_test.count("timed_xcode_stage xcode.release-build"), 1)
        self.assertIn('"${RUN_ROOT}/RELEASE_CANDIDATE.json"', full_test[skip:build])
        release = script[script.index("  release)\n") : script.index("\nesac\n", script.index("  release)\n"))]
        self.assertNotIn("RELEASE_CANDIDATE", release)
        self.assertIn("timed_xcode_stage xcode.release-build", release)
        publish = script.index('if [[ "${RELEASE_CANDIDATE}" == skip ]]; then\n'
                               '  PUBLISH_INSTALLED_ACCEPTANCE_AUTHORITY=0\nfi\n')
        self.assertLess(script.index("PUBLISH_INSTALLED_ACCEPTANCE_AUTHORITY=1"), publish)
        self.assertLess(publish, script.index('if [[ "${PUBLISH_INSTALLED_ACCEPTANCE_AUTHORITY}" == 1 ]]; then\n'
                                              '  publish_installed_acceptance_preparation'))
        self.assertIn('--expected-configuration "${QUALIFICATION_CONFIGURATION}" \\\n'
                      '    --app-bundle "${QUALIFICATION_APP_BUNDLE}"', script)
        start = script.index("QUALIFICATION_CONFIGURATION=Debug\n")
        selection = script[start : script.index("\nfi\n", start) + 4]
        for mode, candidate, expected in (
            ("full-test", "auto", "Release"), ("full-test", "build", "Release"),
            ("full-test", "skip", "Debug"), ("release", "auto", "Release"),
            ("focused-test", "auto", "Debug"), ("smoke", "auto", "Debug"),
        ):
            with self.subTest(mode=mode, candidate=candidate):
                completed = subprocess.run(
                    ["/bin/bash", "-eu", "-c", selection + 'printf %s "${QUALIFICATION_CONFIGURATION}"'],
                    env={"MODE": mode, "RELEASE_CANDIDATE": candidate, "PATH": "/usr/bin:/bin"},
                    capture_output=True, text=True, check=True,
                )
                self.assertEqual(completed.stdout, expected)

    def test_xcode_quiet_preserves_generated_diagnostics_logs_and_exit(self) -> None:
        # Execute the real shared argv construction and timed-Xcode function;
        # replace only the external Xcode executable, never the log producer.
        script = QUALIFIER.read_text(encoding="utf-8")
        default_start = script.index("XCODE_OUTPUT=")
        default_output = script[default_start : script.index("\n", default_start)]
        array = script[script.index("XCODEBUILD=(") : script.index('\ncase "${MODE}" in', script.index("XCODEBUILD=("))]
        timed = script[script.index("timed_xcode_stage() {") : script.index('\nif [[ "${IS_RESUME}"', script.index("timed_xcode_stage() {"))]
        marker_start = script.index("emit_qualification_outputs() {")
        markers = script[marker_start : script.index("\n}\n", marker_start) + 3]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fake = root / "xcodebuild"
            fake.write_text("#!/bin/bash\nquiet=0\nfor arg in \"$@\"; do [[ $arg != -quiet ]] || quiet=1; done\n"
                "printf '%s\\n' --invocation-- \"$@\" >>\"$SYNTHETIC_XCODE_ARGV\"\n"
                "[[ $quiet == 1 ]] || printf 'command/environment chatter\\n'\n"
                "printf 'warning: synthetic warning\\n'\nprintf 'error: synthetic diagnostic\\n' >&2\n"
                "exit \"${SYNTHETIC_XCODE_EXIT:-0}\"\n", encoding="utf-8")
            fake.chmod(0o755)
            stages = (("xcode.installed-ui-build-for-testing", "MacScopeInstalledAppUITests", "Debug", "build-for-testing"),
                      ("xcode.core-tests-build-for-testing", "MacScopeApp", "Debug", "build-for-testing"),
                      ("xcode.core-tests", "MacScopeApp", "Debug", "test-without-building"),
                      ("xcode.release-build", "MacScopeApp", "Release", "build"))
            for mode in (None, "mirror", "quiet"):
                for exit_code in (0, 7):
                    with self.subTest(mode=mode, exit_code=exit_code):
                        run = root / ((mode or "default") + str(exit_code))
                        run.mkdir()
                        receipt = run / "STAGE_TIMINGS.json"
                        receipt.write_text(json.dumps({"clock": "time.monotonic_ns", "mode": "full-test",
                            "run_root": str(run), "schema_version": 1, "source": {"commit": "a" * 40,
                            "tree": "b" * 40}, "stages": []}, sort_keys=True, separators=(",", ":")) + "\n")
                        env = os.environ.copy()
                        for name in ("BUILD_SOURCE_ROOT", "DERIVED_DATA_ROOT", "GHOSTTY_SURFACE_WORK_ROOT",
                                     "GHOSTTY_SURFACE_SOURCE_DIR", "GHOSTTY_SURFACE_ARTIFACT_ROOT",
                                     "GHOSTTY_SURFACE_MANIFEST", "SLEIGH_SOURCE_BUILD_WORK_ROOT",
                                     "SLEIGH_SOURCE_BUILD_ROOT", "SLEIGH_ROOT", "PRIVATE_MACHOKIT_ROOT",
                                     "GHOSTTY_VT_WORK_ROOT", "GHOSTTY_VT_STAGING_DESCRIPTOR",
                                     "GHOSTTY_VT_STAGING_SHA256"):
                            env[name] = str(run)
                        env.update(XCODE_JOBS="2", SIGNING="development", STAGE_TIMING_RECEIPT=str(receipt),
                                   SYNTHETIC_XCODE_EXIT=str(exit_code), SYNTHETIC_XCODE_ARGV=str(run / "argv"),
                                   RETAINED_RELEASE_QUALIFICATION_INPUTS="", NATIVE_RELEASE_ADMISSION="")
                        for name in re.findall(r"\$\{([A-Z0-9_]+)\}", markers):
                            env.setdefault(name, str(run / name))
                        env["PUBLISH_INSTALLED_ACCEPTANCE_AUTHORITY"] = "0"
                        if mode is not None:
                            env["XCODE_OUTPUT"] = mode
                        else:
                            env.pop("XCODE_OUTPUT", None)
                        setup = 'STAGE_TIMING_TOOL=(/usr/bin/python3 -B "' + str(STAGE_TIMING_TOOL) + '")\n' + default_output + "\n"
                        if mode is not None:
                            setup += 'XCODE_OUTPUT="$1"\n'
                        calls = "\n".join('timed_xcode_stage "' + name + '" "' + str(run / (name + ".log"))
                            + '" "${XCODEBUILD[@]}" -scheme ' + scheme + ' -configuration ' + config + ' ' + action
                            for name, scheme, config, action in stages)
                        completed = subprocess.run(["/bin/bash", "-eu", "-c", setup + timed + "\n" + markers + "\n"
                            + array.replace("/usr/bin/xcodebuild", str(fake)) + "\n" + calls + "\nemit_qualification_outputs",
                            "synthetic-xcode-boundary", mode or ""],
                            env=env, capture_output=True, text=True)
                        self.assertEqual(completed.returncode, exit_code, completed.stderr)
                        expected = ("" if mode == "quiet" else "command/environment chatter\n") + "warning: synthetic warning\nerror: synthetic diagnostic\n"
                        count = 4 if exit_code == 0 else 1
                        diagnostics = completed.stdout.split("MACSCOPE_QUALIFICATION_RUN_ROOT=", 1)[0]
                        self.assertEqual(diagnostics, expected * count)
                        final_marker = "MACSCOPE_QUALIFICATION_RECEIPT=" + env["RECEIPT"]
                        if exit_code == 0:
                            self.assertEqual(completed.stdout.splitlines()[-1], final_marker)
                            self.assertEqual(completed.stdout.count(final_marker), 1)
                        else:
                            self.assertNotIn("MACSCOPE_QUALIFICATION_RECEIPT=", completed.stdout)
                        argv = (run / "argv").read_text().splitlines()
                        self.assertEqual(argv.count("--invocation--"), count)
                        self.assertEqual(argv.count("-quiet"), count if mode == "quiet" else 0)
                        self.assertEqual(argv.count("-showBuildTimingSummary"), count)
                        self.assertEqual(argv.count("-scheme"), count)
                        observed = json.loads(receipt.read_bytes())["stages"]
                        self.assertEqual([s["name"] for s in observed], [s[0] for s in stages[:count]])
                        self.assertEqual([s["exit_code"] for s in observed], [exit_code] * count)
                        for stage in observed:
                            self.assertEqual(Path(stage["log"]).read_text(), expected)

    @staticmethod
    def _install_generated_scaffold(run: Path) -> tuple[Path, Path, Path]:
        source = run / "source"
        macscope = source / "MacScope"
        machokit = run / "private-machokit-input"
        local_packages = macscope / "LocalPackages"
        local_packages.symlink_to(machokit, target_is_directory=True)
        xcconfig = macscope / "DependencyRoots.local.xcconfig"
        surface_work = run / "dependencies/ghostty-surface"
        surface_source = surface_work / "GhosttySurface"
        surface_artifact = surface_source / "macos/GhosttyKit.xcframework"
        surface_framework = surface_artifact / "macos-arm64/libghostty-internal.a"
        sleigh_source = run / "dependencies/sleigh-native-source/SleighNativeSource"
        sleigh_materialization = sleigh_source / "materialization"
        xcconfig.write_text(
            "// Generated by Scripts/bootstrap.sh. Untracked and machine-local — do not commit.\n"
            "// Regenerate by re-running bootstrap; edit DependencyRoots.xcconfig for anything\n"
            "// that should be shared.\n"
            f"MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT = {surface_work}\n"
            f"MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR = {surface_source}\n"
            f"MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT = {surface_artifact}\n"
            f"MACSCOPE_GHOSTTY_SURFACE_FRAMEWORK = {surface_framework}\n"
            "MACSCOPE_GHOSTTY_SURFACE_ENABLED = MACSCOPE_FULL_GHOSTTY_SURFACE\n"
            f"MACSCOPE_SLEIGH_COMPONENT_ROOT = {source / 'ThirdParty/SleighNative'}\n"
            f"MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT = {sleigh_source}\n"
            f"MACSCOPE_SLEIGH_MATERIALIZATION_ROOT = {sleigh_materialization}\n"
            f"MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT = {machokit}\n"
            f"MACSCOPE_PARSER_ENGINE_CACHE_ROOT = {run.parent.parent / 'dependencies'}\n",
            encoding="utf-8",
        )
        xcconfig.chmod(0o600)
        project = macscope / "MacScope.xcodeproj"
        for relative in (
            "project.xcworkspace",
            "project.xcworkspace/xcshareddata",
            "project.xcworkspace/xcshareddata/swiftpm",
            "project.xcworkspace/xcshareddata/swiftpm/configuration",
            "xcshareddata",
            "xcshareddata/xcschemes",
        ):
            (project / relative).mkdir(parents=True, exist_ok=True)
        for relative in (
            ".macscope-project-generation.sha256",
            "project.xcproj",
            "project.xcworkspace/contents.xcworkspacedata",
            "xcshareddata/xcschemes/MacScopeApp.xcscheme",
            "xcshareddata/xcschemes/MacScopeInstalledAppUITests.xcscheme",
        ):
            path = project / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"// generated {relative}\n", encoding="utf-8")
        return local_packages, xcconfig, project

    def test_fresh_run_uses_clonefile_source_staging(self) -> None:
        script = QUALIFIER.read_text(encoding="utf-8")
        self.assertIn("git-stage \\\n", script)
        self.assertIn('/bin/cp -c -pR "${SOURCE_ROOT}" "${BUILD_SOURCE_ROOT}"', script)
        self.assertNotIn("/bin/cp -pR", script)

    def test_restore_tool_is_frozen_and_binds_project_around_xcode(self) -> None:
        script = QUALIFIER.read_text(encoding="utf-8")
        self.assertIn('TRUSTED_RESTORE_TOOL="${SCRIPT_DIR}/qualification/restore_build_source.py"', script)
        self.assertIn('exec 8<"${TRUSTED_RESTORE_TOOL}"', script)
        self.assertIn("os.pread(", script)
        resume_cleanup = script.index(
            "run_trusted_restore_tool --operation restore"
        )
        initial_verify = script.index(
            'if [[ "${BUILD_SOURCE_IDENTITY_JSON}" != "${SOURCE_EXPORT_IDENTITY_JSON}" ]]', resume_cleanup
        )
        stage_timing_init = script.index('"${STAGE_TIMING_TOOL[@]}" init', initial_verify)
        bootstrap = script.index("timed_stage project.bootstrap", stage_timing_init)
        project_binding = script.index(
            'GENERATED_PROJECT_IDENTITY="$(run_trusted_restore_tool --operation identity',
            bootstrap,
        )
        xcode_array = script.index("XCODEBUILD=(", project_binding)
        final_cleanup = script.index(
            "--expected-project-identity \"${GENERATED_PROJECT_IDENTITY}\"",
            xcode_array,
        )
        preparation = script.index("publish_installed_acceptance_preparation()")
        self.assertLess(resume_cleanup, initial_verify)
        self.assertLess(initial_verify, stage_timing_init)
        self.assertLess(bootstrap, project_binding)
        self.assertLess(project_binding, xcode_array)
        self.assertLess(xcode_array, final_cleanup)
        self.assertLess(final_cleanup, preparation)
        capture = script.index('"${BUILD_SOURCE_ROOT}/Scripts/qualification/generated_project_evidence.py"', xcode_array)
        cleanup_call = script.index("run_trusted_restore_tool --operation restore", capture)
        self.assertLess(xcode_array, capture)
        self.assertLess(capture, cleanup_call)
        self.assertLess(cleanup_call, preparation)
        prepare = script.index('if [[ "${MODE}" == "prepare" ]]; then')
        prepare_exit = script.index("exit 0", prepare)
        self.assertLess(prepare_exit, bootstrap)
        self.assertLess(prepare_exit, capture)

    def test_resume_restores_valid_generated_scaffold_before_source_admission(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            work = root / "qualification"
            first = fixture.qualify(work)
            self.assertEqual(first.returncode, 0, first.stderr)
            run = next((work / "runs").glob("run.*"))
            local_packages, xcconfig, project = self._install_generated_scaffold(run)

            resumed = fixture.qualify(work, resume_run=run)

            self.assertEqual(resumed.returncode, 0, resumed.stderr)
            self.assertFalse(local_packages.exists())
            self.assertFalse(local_packages.is_symlink())
            self.assertFalse(xcconfig.exists())
            self.assertFalse(project.exists())

    def test_prepare_and_resume_preserve_gitless_local_submodule_package(self) -> None:
        from Scripts.tests.test_source_export_provenance import SourceRepository

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            dependency = SourceRepository(root / "lumen-seed")
            dependency.write("Package.swift", "// pinned local package\n")
            dependency.git("add", ".")
            dependency.git("commit", "-m", "local package")
            fixture._git("-c", "protocol.file.allow=always", "submodule", "add",
                         str(dependency.root), "ThirdParty/Lumen")
            fixture._git("config", "-f", ".gitmodules", "submodule.ThirdParty/Lumen.url",
                         "https://github.com/jdotc1/Lumen.git")
            fixture._git("add", ".")
            fixture._git("commit", "-m", "pin local package")
            fixture._git("update-ref", fixture.integration_ref, "HEAD")
            work = root / "qualification"
            first = fixture.qualify(work)
            self.assertEqual(first.returncode, 0, first.stderr)
            run = next((work / "runs").glob("run.*"))
            package = run / "source/ThirdParty/Lumen/Package.swift"
            self.assertEqual(package.read_text(), "// pinned local package\n")
            self.assertFalse((package.parent / ".git").exists())
            self._install_generated_scaffold(run)
            resumed = fixture.qualify(work, resume_run=run)
            self.assertEqual(resumed.returncode, 0, resumed.stderr)
            self.assertEqual(package.read_text(), "// pinned local package\n")

    def test_resume_rejects_wrong_generated_scaffold_without_erasing_it(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            work = root / "qualification"
            first = fixture.qualify(work)
            self.assertEqual(first.returncode, 0, first.stderr)
            run = next((work / "runs").glob("run.*"))
            local_packages, xcconfig, project = self._install_generated_scaffold(run)
            xcconfig.write_bytes(xcconfig.read_bytes().replace(b"ghostty-surface", b"other-surface", 1))
            timing_before = (run / "STAGE_TIMINGS.json").read_bytes()
            log_before = fixture.log.read_bytes()

            rejected = fixture.qualify(work, resume_run=run)

            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("differs from canonical run roots", rejected.stderr)
            self.assertTrue(local_packages.is_symlink())
            self.assertTrue(xcconfig.is_file())
            self.assertTrue(project.is_dir())
            self.assertEqual((run / "STAGE_TIMINGS.json").read_bytes(), timing_before)
            self.assertEqual(fixture.log.read_bytes(), log_before)

    def test_resume_rejects_wrong_local_packages_target_without_erasing_scaffold(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            work = root / "qualification"
            first = fixture.qualify(work)
            self.assertEqual(first.returncode, 0, first.stderr)
            run = next((work / "runs").glob("run.*"))
            local_packages, xcconfig, project = self._install_generated_scaffold(run)
            wrong = root / "wrong-machokit"
            wrong.mkdir()
            local_packages.unlink()
            local_packages.symlink_to(wrong, target_is_directory=True)
            timing_before = (run / "STAGE_TIMINGS.json").read_bytes()
            log_before = fixture.log.read_bytes()

            rejected = fixture.qualify(work, resume_run=run)

            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("does not target the run-owned MachOKit root", rejected.stderr)
            self.assertTrue(local_packages.is_symlink())
            self.assertTrue(xcconfig.is_file())
            self.assertTrue(project.is_dir())
            self.assertEqual((run / "STAGE_TIMINGS.json").read_bytes(), timing_before)
            self.assertEqual(fixture.log.read_bytes(), log_before)

    def test_resume_rejects_unsafe_generated_project_root_without_erasing_scaffold(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            work = root / "qualification"
            first = fixture.qualify(work)
            self.assertEqual(first.returncode, 0, first.stderr)
            run = next((work / "runs").glob("run.*"))
            local_packages, xcconfig, project = self._install_generated_scaffold(run)
            replacement = root / "replacement-project"
            project.rename(replacement)
            project.symlink_to(replacement, target_is_directory=True)
            timing_before = (run / "STAGE_TIMINGS.json").read_bytes()
            log_before = fixture.log.read_bytes()

            rejected = fixture.qualify(work, resume_run=run)

            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("generated Xcode project must be an ordinary directory", rejected.stderr)
            self.assertTrue(local_packages.is_symlink())
            self.assertTrue(xcconfig.is_file())
            self.assertTrue(project.is_symlink())
            self.assertEqual((run / "STAGE_TIMINGS.json").read_bytes(), timing_before)
            self.assertEqual(fixture.log.read_bytes(), log_before)

    def test_resume_rejects_unexpected_generated_project_file_without_erasing_scaffold(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            work = root / "qualification"
            first = fixture.qualify(work)
            self.assertEqual(first.returncode, 0, first.stderr)
            run = next((work / "runs").glob("run.*"))
            local_packages, xcconfig, project = self._install_generated_scaffold(run)
            (project / "Unexpected.txt").write_text("unexpected\n", encoding="utf-8")
            timing_before = (run / "STAGE_TIMINGS.json").read_bytes()
            log_before = fixture.log.read_bytes()

            rejected = fixture.qualify(work, resume_run=run)

            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("contains an unexpected file", rejected.stderr)
            self.assertTrue(local_packages.is_symlink())
            self.assertTrue(xcconfig.is_file())
            self.assertTrue(project.is_dir())
            self.assertEqual((run / "STAGE_TIMINGS.json").read_bytes(), timing_before)
            self.assertEqual(fixture.log.read_bytes(), log_before)

    def test_prepare_is_self_contained_offline_and_requires_local_remote_ref(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)

            missing = fixture.qualify(root / "missing-ref", integration_ref=None)
            self.assertEqual(missing.returncode, 2)
            self.assertIn("--integration-ref is required", missing.stderr)

            unqualified = fixture.qualify(
                root / "unqualified-ref", integration_ref="refs/heads/main"
            )
            self.assertEqual(unqualified.returncode, 2)
            self.assertIn("fully qualified refs/remotes", unqualified.stderr)

            expression = fixture.qualify(
                root / "ref-expression",
                integration_ref=(
                    "refs/remotes/gitfox-local/feature/qualification-fixture~0"
                ),
            )
            self.assertEqual(expression.returncode, 2)
            self.assertIn("canonical Git ref name", expression.stderr)

            result = fixture.qualify(root / "offline")
            self.assertEqual(result.returncode, 0, result.stderr)
            receipt = self._receipt(root / "offline")
            self.assertFalse(receipt["dependency_network_allowed"])
            self.assertFalse(receipt["dependency_network_used"])
            run = next((root / "offline/runs").glob("run.*"))
            cache_events = json.loads(
                (run / "DEPENDENCY_CACHE_EVENTS.json").read_text(encoding="utf-8")
            )
            self.assertEqual(
                [event["status"] for event in cache_events["events"]],
                ["published-miss", "published-miss", "published-miss"],
            )
            timings = json.loads((run / "STAGE_TIMINGS.json").read_text(encoding="utf-8"))
            self.assertEqual(timings["source"]["commit"], fixture._git("rev-parse", "HEAD", output=True))
            self.assertTrue(all(stage["duration_ns"] >= 0 for stage in timings["stages"]))
            self.assertEqual(
                fixture.log.read_text(encoding="utf-8").splitlines().count(
                    "build-sleigh-source"
                ),
                1,
            )

    def test_prepare_seals_repository_inputs_and_run_owned_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            work = root / "qualification"

            result = fixture.qualify(work)

            self.assertEqual(result.returncode, 0, result.stderr)
            receipt_path = next((work / "runs").glob("run.*/QUALIFICATION_INPUTS.json"))
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            run = receipt_path.parent
            self.assertEqual(
                result.stdout.splitlines()[-1],
                f"MACSCOPE_QUALIFICATION_RECEIPT={receipt_path}",
            )
            self.assertEqual(set(receipt), QUALIFICATION_V4_FIELDS)
            self.assertEqual(receipt["schema_version"], 4)
            self.assertEqual(
                Path(receipt["ghostty_source_dir"]),
                run / "dependencies/ghostty-vt-qualification",
            )
            self.assertTrue((run / "source/ThirdParty/GhosttyVT/Source").is_dir())
            self.assertEqual(
                Path(receipt["zig_executable"]),
                run / "source/ThirdParty/Zig/zig-0.16.0/zig",
            )
            expected_sleigh = (
                run
                / "dependencies/sleigh-native-source/SleighNativeSource/materialization"
            )
            self.assertEqual(Path(receipt["sleigh_materialization_root"]), expected_sleigh)
            self.assertTrue(
                (run / "dependencies/ghostty-vt/artifacts/lib/.macscope-ghostty-vt-manifest").is_file()
            )
            expected_surface_source = run / "dependencies/ghostty-surface/GhosttySurface"
            self.assertEqual(
                Path(receipt["ghostty_surface_source_dir"]), expected_surface_source
            )
            self.assertEqual(
                Path(receipt["ghostty_surface_artifact_root"]),
                expected_surface_source / "macos/GhosttyKit.xcframework",
            )
            surface_manifest = (
                expected_surface_source / "macos/.macscope-ghostty-surface-manifest"
            )
            self.assertEqual(
                receipt["ghostty_surface_manifest_sha256"],
                hashlib.sha256(surface_manifest.read_bytes()).hexdigest(),
            )
            self.assertTrue(
                (
                    run
                    / "dependencies/ghostty-vt-qualification/zig-out/lib/libghostty-vt.dylib"
                ).is_file()
            )
            self.assertTrue(
                (
                    run
                    / "dependencies/ghostty-surface/GhosttySurface/macos/.macscope-ghostty-surface-manifest"
                ).is_file()
            )
            self.assertEqual(
                (run / "private-machokit-input/MATERIALIZATION.json").read_bytes(),
                (source / "ThirdParty/MachOKit/materialization/MATERIALIZATION.json").read_bytes(),
            )
            for path in [
                run / "private-machokit-input",
                *(run / "private-machokit-input").rglob("*"),
            ]:
                self.assertEqual(path.stat().st_mode & 0o222, 0, path)
            self.assertIn(
                f"MACSCOPE_SLEIGH_MATERIALIZATION_ROOT={expected_sleigh}", result.stdout
            )
            self.assertTrue((run / "DerivedData").is_dir())
            expected_commit = fixture._git("rev-parse", "HEAD", output=True)
            expected_tree = fixture._git("rev-parse", "HEAD^{tree}", output=True)
            for output in (
                f"MACSCOPE_QUALIFICATION_RUN_ROOT={run}",
                f"MACSCOPE_QUALIFICATION_DERIVED_DATA_ROOT={run / 'DerivedData'}",
                f"MACSCOPE_QUALIFICATION_SOURCE_COMMIT={expected_commit}",
                f"MACSCOPE_QUALIFICATION_SOURCE_TREE={expected_tree}",
            ):
                self.assertIn(output, result.stdout)

    def test_source_and_planned_run_trees_cannot_hide_inside_dependency_cache(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            cache = root / "dependency-cache"
            source = cache / "source"
            source.mkdir(parents=True)
            fixture = QualificationFixture(source)
            work = root / "qualification"

            source_nested = fixture.qualify(
                work,
                dependency_cache_root=cache,
            )

            self.assertEqual(source_nested.returncode, 2)
            self.assertIn("must not overlap", source_nested.stderr)
            self.assertFalse((work / "source-export").exists())

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            work = root / "qualification"

            run_nested = fixture.qualify(
                work,
                dependency_cache_root=work,
            )

            self.assertEqual(run_nested.returncode, 2)
            self.assertIn("must not overlap", run_nested.stderr)
            self.assertFalse((work / "source-export").exists())

    def test_gitless_export_requires_independent_commit_authority(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            trusted_commit = fixture._git("rev-parse", "HEAD", output=True)

            (source / "MacScope/project.yml").write_text(
                "name: ForgedCandidate\n",
                encoding="utf-8",
            )
            fixture._git("add", "MacScope/project.yml")
            fixture._git("commit", "-m", "forged candidate")
            forged_commit = fixture._git("rev-parse", "HEAD", output=True)
            fixture._git("update-ref", fixture.integration_ref, forged_commit)
            forged_export = root / "forged-export"
            exported = subprocess.run(
                [
                    "/usr/bin/python3",
                    "-B",
                    str(SOURCE_EXPORT),
                    "create",
                    "--repository-root",
                    str(source),
                    "--destination",
                    str(forged_export),
                    "--integration-ref",
                    fixture.integration_ref,
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(exported.returncode, 0, exported.stderr)

            unanchored = fixture.qualify(
                root / "unanchored",
                source_root=forged_export,
            )
            self.assertNotEqual(unanchored.returncode, 0)
            self.assertIn("requires --integration-commit", unanchored.stderr)

            rejected = fixture.qualify(
                root / "trusted-authority",
                source_root=forged_export,
                integration_commit=trusted_commit,
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("expected integration commit authority", rejected.stderr)

            accepted = fixture.qualify(
                root / "forged-authority",
                source_root=forged_export,
                integration_commit=forged_commit,
            )
            self.assertEqual(accepted.returncode, 0, accepted.stderr)

    def test_legacy_network_permission_is_recorded_but_never_used(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)

            result = fixture.qualify(
                root / "qualification", materialize_dependencies=True
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            receipt = self._receipt(root / "qualification")
            self.assertTrue(receipt["dependency_network_allowed"])
            self.assertFalse(receipt["dependency_network_used"])
            script = QUALIFIER.read_text(encoding="utf-8")
            self.assertNotIn("materialize_ghostty_vt.sh", script)
            self.assertNotIn("materialize_sleigh_native_dcp03b4.sh", script)
            self.assertNotIn("MACSCOPE_GHOSTTY_ZIG_PACKAGE_STORE_SOURCE", script)

    def test_explicit_machokit_override_is_verified_and_privately_sealed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)

            result = fixture.qualify(
                root / "qualification", machokit_override=fixture.external_machokit
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            receipt_path = next(
                (root / "qualification/runs").glob("run.*/QUALIFICATION_INPUTS.json")
            )
            private = receipt_path.parent / "private-machokit-input/MATERIALIZATION.json"
            self.assertEqual(
                json.loads(private.read_text(encoding="utf-8"))["fixture"],
                "diagnostic-override",
            )
            self.assertNotIn("machokit_materialization_root", self._receipt(root / "qualification"))

    def test_resume_reuses_verified_outputs_and_preserves_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            work = root / "qualification"
            first = fixture.qualify(work)
            self.assertEqual(first.returncode, 0, first.stderr)
            run = next((work / "runs").glob("run.*"))
            receipt_before = (run / "QUALIFICATION_INPUTS.json").read_bytes()

            resumed = fixture.qualify(work, resume_run=run)

            self.assertEqual(resumed.returncode, 0, resumed.stderr)
            self.assertEqual((run / "QUALIFICATION_INPUTS.json").read_bytes(), receipt_before)
            self.assertEqual(len(list((work / "runs").glob("run.*"))), 1)
            lines = fixture.log.read_text(encoding="utf-8").splitlines()
            self.assertEqual(lines.count("build-ghostty-vt"), 1)
            self.assertEqual(lines.count("verify-ghostty-vt"), 3)
            self.assertEqual(lines.count("build-ghostty-surface"), 1)
            self.assertEqual(lines.count("verify-ghostty-surface"), 3)
            self.assertEqual(lines.count("build-sleigh-source"), 1)
            self.assertEqual(lines.count("reuse-sleigh-source-build"), 3)

    def test_fresh_runs_share_only_verified_content_addressed_dependencies(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            cache = root / "shared-cache"

            first = fixture.qualify(
                root / "qualification-one", dependency_cache_root=cache
            )
            second = fixture.qualify(
                root / "qualification-two", dependency_cache_root=cache
            )

            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(second.returncode, 0, second.stderr)
            lines = fixture.log.read_text(encoding="utf-8").splitlines()
            self.assertEqual(lines.count("build-ghostty-vt"), 1)
            self.assertEqual(lines.count("build-ghostty-surface"), 1)
            self.assertEqual(lines.count("build-sleigh-source"), 1)
            second_run = next((root / "qualification-two/runs").glob("run.*"))
            events = json.loads(
                (second_run / "DEPENDENCY_CACHE_EVENTS.json").read_text(encoding="utf-8")
            )["events"]
            # D1: the second run trusts the receipts the first run published.
            self.assertEqual(
                [event["status"] for event in events],
                ["receipt-reused-hit", "receipt-reused-hit", "receipt-reused-hit"],
            )
            for event in events:
                self.assertEqual(Path(event["run_view"]).stat().st_mode & 0o222, 0)

    def test_resume_rejects_tampered_source_built_native_materialization(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            work = root / "qualification"
            first = fixture.qualify(work)
            self.assertEqual(first.returncode, 0, first.stderr)
            run = next((work / "runs").glob("run.*"))
            manifest = (
                run
                / "dependencies/sleigh-native-source/SleighNativeSource/materialization/MATERIALIZATION.json"
            )
            self.assertEqual(manifest.stat().st_mode & 0o222, 0)
            manifest.chmod(0o600)
            manifest.write_text('{"fixture":"tampered"}\n', encoding="utf-8")

            resumed = fixture.qualify(work, resume_run=run)

            self.assertNotEqual(resumed.returncode, 0)
            self.assertIn("SLEIGH materialization manifest differs", resumed.stderr)
            self.assertEqual(len(list((work / "runs").glob("run.*"))), 1)

    def test_resume_rejects_indirect_receipts_before_dependency_use(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            work = root / "qualification"
            first = fixture.qualify(work)
            self.assertEqual(first.returncode, 0, first.stderr)
            run = next((work / "runs").glob("run.*"))
            receipt = run / "QUALIFICATION_INPUTS.json"
            target = root / "preserved-receipt.json"
            receipt.replace(target)
            receipt.symlink_to(target)
            log_before = fixture.log.read_bytes()

            symlinked = fixture.qualify(work, resume_run=run)

            self.assertNotEqual(symlinked.returncode, 0)
            self.assertIn("cannot safely open qualification receipt", symlinked.stderr)
            self.assertEqual(fixture.log.read_bytes(), log_before)

            receipt.unlink()
            os.link(target, receipt)
            hardlinked = fixture.qualify(work, resume_run=run)

            self.assertNotEqual(hardlinked.returncode, 0)
            self.assertIn("single-link file", hardlinked.stderr)
            self.assertEqual(fixture.log.read_bytes(), log_before)

    def test_unexpected_native_producer_output_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)

            result = fixture.qualify(
                root / "qualification",
                extra_environment={"MACSCOPE_QUALIFICATION_FIXTURE_BAD_SLEIGH_OUTPUT": "1"},
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unexpected output contract", result.stderr)
            self.assertEqual(
                list((root / "qualification/runs").glob("run.*/QUALIFICATION_INPUTS.json")),
                [],
            )

    def test_unexpected_ghostty_surface_producer_output_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)

            result = fixture.qualify(
                root / "qualification",
                extra_environment={"MACSCOPE_QUALIFICATION_FIXTURE_BAD_SURFACE_OUTPUT": "1"},
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("surface producer returned an unexpected output contract", result.stderr)
            self.assertEqual(
                list((root / "qualification/runs").glob("run.*/QUALIFICATION_INPUTS.json")),
                [],
            )

    def test_resume_rejects_receipt_identity_drift_before_dependency_use(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            work = root / "qualification"
            first = fixture.qualify(work)
            self.assertEqual(first.returncode, 0, first.stderr)
            run = next((work / "runs").glob("run.*"))
            receipt_path = run / "QUALIFICATION_INPUTS.json"
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            receipt["mode"] = "release"
            receipt_path.write_text(
                json.dumps(receipt, sort_keys=True, separators=(",", ":")) + "\n",
                encoding="utf-8",
            )
            log_before = fixture.log.read_bytes()

            resumed = fixture.qualify(work, resume_run=run)

            self.assertNotEqual(resumed.returncode, 0)
            self.assertIn("resumed qualification input mismatch: mode", resumed.stderr)
            self.assertEqual(fixture.log.read_bytes(), log_before)

    def test_resume_rejects_every_consumed_path_and_network_drift_before_dependency_use(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            work = root / "qualification"
            first = fixture.qualify(work)
            self.assertEqual(first.returncode, 0, first.stderr)
            run = next((work / "runs").glob("run.*"))
            receipt_path = run / "QUALIFICATION_INPUTS.json"
            original = json.loads(receipt_path.read_text(encoding="utf-8"))
            log_before = fixture.log.read_bytes()
            mutations: dict[str, object] = {
                "ghostty_source_dir": str(root / "substituted-vt"),
                "ghostty_surface_source_dir": str(root / "substituted-surface"),
                "ghostty_surface_artifact_root": str(root / "substituted-artifact"),
                "sleigh_materialization_root": str(root / "substituted-sleigh"),
                "zig_executable": str(root / "substituted-zig"),
                "dependency_network_used": True,
            }
            for field, value in mutations.items():
                with self.subTest(field=field):
                    mutated = dict(original)
                    mutated[field] = value
                    receipt_path.write_text(
                        json.dumps(mutated, sort_keys=True, separators=(",", ":")) + "\n",
                        encoding="utf-8",
                    )

                    result = fixture.qualify(work, resume_run=run)

                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("resumed qualification input mismatch", result.stderr)
                    self.assertEqual(fixture.log.read_bytes(), log_before)
            receipt_path.write_text(
                json.dumps(original, sort_keys=True, separators=(",", ":")) + "\n",
                encoding="utf-8",
            )

    def test_xcode_contract_forwards_all_prepared_roots_without_running_xcode(self) -> None:
        script = QUALIFIER.read_text(encoding="utf-8")
        self.assertEqual(script.count('--value "payload-layout='), 3)
        self.assertIn('--external-file "rsync=/usr/bin/rsync"', script)
        array_start = script.index("XCODEBUILD=(")
        array_end = script.index("\n)", array_start)
        xcodebuild = script[array_start:array_end]
        self.assertNotIn("MACSCOPE_GHOSTTY_SOURCE_DIR", xcodebuild)
        for setting in (
            "MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT",
            "MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR",
            "MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT",
            "MACSCOPE_GHOSTTY_SURFACE_MANIFEST",
            "MACSCOPE_SLEIGH_SOURCE_BUILD_WORK_ROOT",
            "MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT",
            "MACSCOPE_SLEIGH_MATERIALIZATION_ROOT",
            "MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT",
        ):
            self.assertIn(setting, xcodebuild)
        self.assertEqual(xcodebuild.count("COMPILER_INDEX_STORE_ENABLE=NO"), 1)
        self.assertIn("-parallelizeTargets", xcodebuild)
        self.assertIn('-jobs "${XCODE_JOBS}"', xcodebuild)
        self.assertIn('-derivedDataPath "${DERIVED_DATA_ROOT}"', xcodebuild)
        self.assertIn("-showBuildTimingSummary", xcodebuild)
        self.assertIn('"${QUALIFICATION_VALIDATOR[@]}" validate-inputs', script)
        self.assertIn('"${QUALIFICATION_VALIDATOR[@]}" validate-build', script)
        self.assertIn('--app-bundle "${QUALIFICATION_APP_BUNDLE}"', script)

    def test_path_independent_cache_alias_never_reaches_test_actions(self) -> None:
        # The run-root alias becomes #filePath in compiled code; test bundles
        # read real source paths through #filePath, so only smoke may use it.
        script = QUALIFIER.read_text(encoding="utf-8")
        start = script.index('PATH_INDEPENDENT_CACHE_EXCLUDED_REASON=""\n')
        end = script.index("\nfi\n", script.index('case "${MODE}" in', start)) + len("\nfi\n")
        self.assertLess(end, script.index('COMPILATION_CACHE_ALIAS_ROOT="${DEPENDENCY_CACHE_ROOT}/build-alias.noindex"'))
        self.assertLess(end, script.index('COMPILATION_CACHE_PREFIX_MAPPINGS=("${RUN_ROOT}=${COMPILATION_CACHE_ALIAS}")'))
        block = script[start:end]
        for mode, expected in (("smoke", "1"), ("focused-test", "0"), ("full-test", "0")):
            result = subprocess.run(
                ["/bin/bash", "-c",
                 f'set -euo pipefail\nMODE={mode}\nPATH_INDEPENDENT_CACHE=1\n{block}\n'
                 'printf "%s|%s" "${PATH_INDEPENDENT_CACHE}" "${PATH_INDEPENDENT_CACHE_EXCLUDED_REASON}"'],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            applied, reason = result.stdout.split("|", 1)
            self.assertEqual(applied, expected, mode)
            if expected == "0":
                self.assertIn("#filePath", reason)
                self.assertIn("path-independent compilation cache not applied", result.stderr)
            else:
                self.assertEqual(reason, "")
        self.assertIn('"path_independent": enabled == "1" and path_independent == "1"', script)

    def test_offline_full_test_publishes_both_exact_preparation_receipts(self) -> None:
        script = QUALIFIER.read_text(encoding="utf-8")
        self.assertIn(
            'if [[ "${MODE}" == full-test && "${DEPENDENCY_NETWORK_ALLOWED}" == false ]]; then',
            script,
        )
        self.assertIn(
            'CANDIDATE_ARTIFACT_ROOT="${RUN_ROOT}/candidate-artifacts"', script
        )
        self.assertIn(
            'NATIVE_PREPARATION_RECEIPT="${CANDIDATE_ARTIFACT_ROOT}/NativeLivePreparation.receipt.json"',
            script,
        )
        self.assertIn(
            'INSTALLED_UI_PREPARATION_RECEIPT="${CANDIDATE_ARTIFACT_ROOT}/InstalledUIPreparation.receipt.json"',
            script,
        )
        publisher = script[
            script.index("publish_installed_acceptance_preparation() {") :
            script.index('\n}\n\nif [[ "${PUBLISH_INSTALLED_ACCEPTANCE_AUTHORITY}" == 1 ]]')
        ]
        self.assertEqual(publisher.count('"${preparation_producer}" create'), 2)
        self.assertIn("--preparation-mode installed-ui-matrix", publisher)
        self.assertIn('--repository-root "${SOURCE_ROOT}"', publisher)
        self.assertIn(
            '--repository-label "${INTEGRATION_REPOSITORY_LABEL}"', publisher
        )
        self.assertIn(
            'INTEGRATION_REPOSITORY_LABEL="${INTEGRATION_REMOTE}:MacScope"', script
        )
        self.assertNotIn("gitfox-local:MacScope", publisher)
        self.assertIn(
            '--products-root "${products_root}" --scheme MacScopeApp --sdk-version "${QUALIFICATION_SDK_VERSION}"',
            publisher,
        )
        self.assertIn(
            '--products-root "${products_root}" --scheme MacScopeInstalledAppUITests --sdk-version "${QUALIFICATION_SDK_VERSION}"',
            publisher,
        )
        self.assertIn('candidate_app="${products_root}/Release/MacScope.app"', publisher)
        self.assertNotIn("--allow-missing", publisher)
        self.assertNotIn("macosx27.0-arm64.xctestrun", script)
        self.assertIn('/usr/bin/xcrun --sdk macosx --show-sdk-version', script)
        self.assertIn(
            'ui_runner="${products_root}/Debug/MacScopeInstalledAppUITests-Runner.app"',
            publisher,
        )
        self.assertIn(
            'ui_test_bundle="${ui_runner}/Contents/PlugIns/MacScopeInstalledAppUITests.xctest"',
            publisher,
        )
        self.assertIn('document.get("schema_version") != 2', publisher)
        self.assertIn(
            'document.get("receipt_kind") != "native-live-xpc-preparation"',
            publisher,
        )
        self.assertIn(
            'document.get("source", {}).get("commit") != expected_commit', publisher
        )
        self.assertIn(
            'document.get("source", {}).get("tree") != expected_tree', publisher
        )

    def test_installed_ui_preparation_reuses_complete_products_and_rejects_partial_state(
        self,
    ) -> None:
        script = QUALIFIER.read_text(encoding="utf-8")
        full_test = script[script.index("  full-test)") : script.index("  release)")]
        self.assertEqual(full_test.count('"${XCODEBUILD[@]}" -scheme MacScopeInstalledAppUITests'), 1)
        self.assertEqual(full_test.count(" YES build-for-testing"), 1)
        self.assertEqual(full_test.count("-enableCodeCoverage YES"), 3)
        self.assertIn("xcode.core-tests-build-for-testing", full_test)
        self.assertIn("-only-testing:CoreTests -only-testing:Phase2Tests build-for-testing", full_test)
        self.assertIn("xcode.core-tests-serial", full_test)
        self.assertIn('"${TEST_SELECTION_ARGUMENTS[@]}" test-without-building', full_test)
        self.assertIn('if [[ "${INSTALLED_PRODUCT_COUNT}" == 0 ]]; then', full_test)
        self.assertIn('elif [[ "${INSTALLED_PRODUCT_COUNT}" != 4 ]]; then', full_test)
        self.assertIn("refusing a repairing build", full_test)
        self.assertLess(
            full_test.index("-scheme MacScopeInstalledAppUITests"),
            full_test.index("-only-testing:CoreTests -only-testing:Phase2Tests build-for-testing"),
        )

    def test_core_tests_partition_invocations_are_pinned(self) -> None:
        script = QUALIFIER.read_text(encoding="utf-8")
        serial_list = (REPOSITORY_ROOT / "Scripts/qualification/serial_core_tests.txt").read_text(encoding="utf-8")
        active_serial_classes = [line.strip() for line in serial_list.splitlines()
                                 if line.strip() and not line.lstrip().startswith("#")]
        self.assertNotIn("CallArgumentABIOracleTests", active_serial_classes)
        helpers = script[script.index("XCRESULTTOOL=(") : script.index("\nif [[ \"${IS_RESUME}\"", script.index("XCRESULTTOOL=("))]
        self.assertIn('local list="${BUILD_SOURCE_ROOT}/Scripts/qualification/serial_core_tests.txt"', helpers)
        self.assertIn('CORE_TEST_WORKERS="${MACSCOPE_CORE_TEST_WORKERS:-4}"', helpers)
        self.assertIn('skip+=("-skip-testing:CoreTests/${serial}")', helpers)
        self.assertIn('only+=("-only-testing:CoreTests/${serial}")', helpers)
        self.assertIn('-parallel-testing-enabled YES -parallel-testing-worker-count "${CORE_TEST_WORKERS}" \\\n'
                      '      "${bundles[@]}" ${skip[@]+"${skip[@]}"} "${parallel_action}"', helpers)
        self.assertIn('-parallel-testing-enabled NO "${only[@]}" "${serial_action}"', helpers)
        self.assertIn('"${XCRESULTTOOL[@]}" merge "${parallel_bundle}" "${serial_bundle}" \\\n'
                      '      --output-path "${final_bundle}"', helpers)
        self.assertIn('/bin/mv "${parallel_bundle}" "${final_bundle}"', helpers)
        self.assertIn("==> CoreTests partition: parallel (${CORE_TEST_WORKERS} workers, skipping: ", helpers)
        focused = script[script.index("  focused-test)\n    record_test_selection\n    RESULT_BUNDLE=") : script.index("  full-test)\n    record_test_selection\n    RESULT_BUNDLE=")]
        self.assertIn("refusing to overwrite evidence", focused)
        self.assertIn('run_core_tests_partition "${RESULT_BUNDLE}" \\\n'
                      '        xcode.focused-test "${RUN_ROOT}/xcode-focused-test.log" test \\\n'
                      '        xcode.focused-test-serial "${RUN_ROOT}/xcode-focused-test-serial.log" test-without-building \\\n'
                      '        -- -scheme MacScopeApp -configuration Debug', focused)
        full_test = script[script.index("  full-test)") : script.index("  release)")]
        self.assertIn('    CORE_TESTS_OPTIONS=(-scheme MacScopeApp -configuration Debug -enableCodeCoverage YES\n'
                      '      ${NONWINDOW_TEST_ARGUMENTS[@]+"${NONWINDOW_TEST_ARGUMENTS[@]}"})\n', full_test)
        partition = full_test.index('run_core_tests_partition "${RESULT_BUNDLE}" \\\n'
                                    '        xcode.core-tests "${RUN_ROOT}/xcode-core-tests.log" test-without-building \\\n'
                                    '        xcode.core-tests-serial "${RUN_ROOT}/xcode-core-tests-serial.log" test-without-building \\\n'
                                    '        "${CORE_TESTS_PREFIX[@]}" \\\n'
                                    '        -- "${CORE_TESTS_OPTIONS[@]}"\n')
        self.assertLess(full_test.index("    load_serial_core_tests\n"), partition)
        self.assertLess(partition, full_test.index("/usr/bin/xcrun xccov view --report --json"))
        self.assertNotIn("-only-testing:CoreTests test-without-building", full_test)

    def _run_focused_block(self, root: Path, selector: str, serial_list: str,
                           failing_action: str = "") -> tuple[subprocess.CompletedProcess[str], list[list[str]], Path]:
        # Execute the real helpers and focused-test block; replace only the
        # external xcodebuild and xcresulttool executables.
        script = QUALIFIER.read_text(encoding="utf-8")
        timed_start = script.index("timed_xcode_stage() {")
        timed = script[timed_start : script.index("\n}\n", timed_start) + 3]
        helpers = script[script.index("XCRESULTTOOL=(") : script.index("\nif [[ \"${IS_RESUME}\"", script.index("XCRESULTTOOL=("))]
        start = script.index("  focused-test)\n    record_test_selection\n    RESULT_BUNDLE=") + len("  focused-test)\n")
        focused = script[start : script.index("\n    ;;\n  full-test)")]
        selection = script[script.index("TEST_SELECTION_ARGUMENTS=()") : script.index('XCODE_JOBS="')]
        record_start = script.index("record_test_selection() {")
        record = script[record_start : script.index("\n}\n", record_start) + 3]
        run = root / "run"
        source = root / "sealed-source"
        (source / "Scripts/qualification").mkdir(parents=True)
        (source / "Scripts/qualification/serial_core_tests.txt").write_text(serial_list, encoding="utf-8")
        run.mkdir()
        receipt = run / "STAGE_TIMINGS.json"
        receipt.write_text(json.dumps({"clock": "time.monotonic_ns", "mode": "focused-test",
            "run_root": str(run), "schema_version": 1, "source": {"commit": "a" * 40, "tree": "b" * 40},
            "stages": []}, sort_keys=True, separators=(",", ":")) + "\n")
        argv_log = root / "argv"
        fake = root / "xcodebuild"
        fake.write_text("#!/bin/bash\nprintf '%s\\n' --invocation-- \"$@\" >>\"$SYNTHETIC_XCODE_ARGV\"\n"
            "previous=\nfor arg in \"$@\"; do\n  [[ $previous != -resultBundlePath ]] || /bin/mkdir -p \"$arg\"\n"
            "  previous=$arg\ndone\nlast=\"${!#}\"\n"
            "[[ -z $SYNTHETIC_FAIL_ACTION || $last != \"$SYNTHETIC_FAIL_ACTION\" ]] || exit 9\nexit 0\n", encoding="utf-8")
        fake.chmod(0o755)
        merge = root / "xcresulttool"
        merge.write_text("#!/bin/bash\nprintf '%s\\n' --invocation-- xcresulttool \"$@\" >>\"$SYNTHETIC_XCODE_ARGV\"\n"
            "/bin/mkdir -p \"${!#}\"\n", encoding="utf-8")
        merge.chmod(0o755)
        env = os.environ.copy()
        env.update(BUILD_SOURCE_ROOT=str(source), RUN_ROOT=str(run), ONLY_TESTING=selector,
                   STAGE_TIMING_RECEIPT=str(receipt), SYNTHETIC_XCODE_ARGV=str(argv_log),
                   SYNTHETIC_FAIL_ACTION=failing_action)
        env.pop("MACSCOPE_CORE_TEST_WORKERS", None)
        program = ('STAGE_TIMING_TOOL=(/usr/bin/python3 -B "' + str(STAGE_TIMING_TOOL) + '")\n'
                   + 'XCODEBUILD=("' + str(fake) + '")\n' + timed + helpers
                   + '\nXCRESULTTOOL=("' + str(merge) + '")\n'
                   + 'MODE=focused-test\nONLY_TESTING=("${ONLY_TESTING}")\n' + selection + record
                   + focused + "\n")
        completed = subprocess.run(["/bin/bash", "-euo", "pipefail", "-c", program],
                                   env=env, capture_output=True, text=True)
        invocations: list[list[str]] = []
        if argv_log.exists():
            for line in argv_log.read_text().splitlines():
                if line == "--invocation--":
                    invocations.append([])
                else:
                    invocations[-1].append(line)
        return completed, invocations, run

    def test_focused_core_tests_partition_reads_serial_list_from_sealed_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            completed, calls, run = self._run_focused_block(
                Path(temporary).resolve(), "CoreTests",
                "# sealed copy, not the checkout\nSealedOnlySuite  # comment\n\nOtherSerialSuite\n")
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("==> CoreTests partition: parallel (4 workers, skipping: SealedOnlySuite OtherSerialSuite)"
                          " + serial (SealedOnlySuite OtherSerialSuite)", completed.stderr)
            self.assertEqual(len(calls), 3)
            common = ["-scheme", "MacScopeApp", "-configuration", "Debug"]
            self.assertEqual(calls[0], common + [
                "-resultBundlePath", str(run / "FocusedTestResults.parallel.xcresult"),
                "-parallel-testing-enabled", "YES", "-parallel-testing-worker-count", "4",
                "-only-testing:CoreTests", "-skip-testing:CoreTests/SealedOnlySuite",
                "-skip-testing:CoreTests/OtherSerialSuite", "test"])
            self.assertEqual(calls[1], common + [
                "-resultBundlePath", str(run / "FocusedTestResults.serial.xcresult"),
                "-parallel-testing-enabled", "NO", "-only-testing:CoreTests/SealedOnlySuite",
                "-only-testing:CoreTests/OtherSerialSuite", "test-without-building"])
            self.assertNotIn("CallArgumentABIOracleTests", "\n".join(sum(calls, [])))
            self.assertEqual(calls[2], ["xcresulttool", "merge",
                str(run / "FocusedTestResults.parallel.xcresult"), str(run / "FocusedTestResults.serial.xcresult"),
                "--output-path", str(run / "FocusedTestResults.xcresult")])
            self.assertTrue((run / "FocusedTestResults.xcresult").is_dir())
            stages = [stage["name"] for stage in json.loads((run / "STAGE_TIMINGS.json").read_text())["stages"]]
            self.assertEqual(stages, ["xcode.focused-test", "xcode.focused-test-serial"])
            self.assertTrue((run / "xcode-focused-test.log").exists())
            self.assertTrue((run / "xcode-focused-test-serial.log").exists())

    def test_focused_partition_runs_serial_pass_after_parallel_failure_and_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            completed, calls, run = self._run_focused_block(
                Path(temporary).resolve(), "CoreTests", "CallArgumentABIOracleTests\n", failing_action="test")
            self.assertEqual(completed.returncode, 9, completed.stderr)
            self.assertIn("parallel CoreTests pass failed", completed.stderr)
            self.assertEqual([call[-1] for call in calls],
                             ["test", "test-without-building", str(run / "FocusedTestResults.xcresult")])
            self.assertEqual(calls[2][:2], ["xcresulttool", "merge"])

    def test_focused_non_core_tests_selector_gets_single_parallel_pass(self) -> None:
        for selector in ("CoreTests/FastSuite/testCase", "MacScopeAppTests"):
            with self.subTest(selector=selector), tempfile.TemporaryDirectory() as temporary:
                completed, calls, run = self._run_focused_block(
                    Path(temporary).resolve(), selector, "CallArgumentABIOracleTests\n")
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertNotIn("CoreTests partition", completed.stderr)
                self.assertEqual(calls, [["-scheme", "MacScopeApp", "-configuration", "Debug",
                    "-resultBundlePath", str(run / "FocusedTestResults.xcresult"),
                    "-parallel-testing-enabled", "YES", "-parallel-testing-worker-count", "4",
                    "-only-testing:" + selector, "test"]])
                stages = [stage["name"] for stage in json.loads((run / "STAGE_TIMINGS.json").read_text())["stages"]]
                self.assertEqual(stages, ["xcode.focused-test"])

    def test_focused_serial_class_selector_gets_single_serial_pass(self) -> None:
        for selector in ("CoreTests/CallArgumentABIOracleTests", "CoreTests/CallArgumentABIOracleTests/testCase"):
            with self.subTest(selector=selector), tempfile.TemporaryDirectory() as temporary:
                completed, calls, run = self._run_focused_block(
                    Path(temporary).resolve(), selector, "CallArgumentABIOracleTests\n")
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertEqual(calls, [["-scheme", "MacScopeApp", "-configuration", "Debug",
                    "-resultBundlePath", str(run / "FocusedTestResults.xcresult"),
                    "-parallel-testing-enabled", "NO", "-only-testing:" + selector, "test"]])
                stages = [stage["name"] for stage in json.loads((run / "STAGE_TIMINGS.json").read_text())["stages"]]
                self.assertEqual(stages, ["xcode.focused-test-serial"])

    def test_missing_sealed_serial_list_is_rejected(self) -> None:
        script = QUALIFIER.read_text(encoding="utf-8")
        helpers = script[script.index("XCRESULTTOOL=(") : script.index("\nif [[ \"${IS_RESUME}\"", script.index("XCRESULTTOOL=("))]
        with tempfile.TemporaryDirectory() as temporary:
            env = os.environ.copy()
            env["BUILD_SOURCE_ROOT"] = temporary
            completed = subprocess.run(["/bin/bash", "-eu", "-c", helpers + "\nload_serial_core_tests\n"],
                                       env=env, capture_output=True, text=True)
            self.assertEqual(completed.returncode, 1)
            self.assertIn("sealed serial CoreTests list is missing", completed.stderr)

    def test_repeated_test_selection_preserves_full_test_release_envelope(self) -> None:
        script = QUALIFIER.read_text(encoding="utf-8")
        selection = script[script.index("TEST_SELECTION_ARGUMENTS=()") : script.index('XCODE_JOBS="')]
        for mode, selectors, expected in (
            ("focused-test", ["CoreTests/A/first", "CoreTests/B/second"],
             ["-only-testing:CoreTests/A/first", "-only-testing:CoreTests/B/second"]),
            ("full-test", ["CoreTests/A/first", "CoreTests/B/second"],
             ["-only-testing:CoreTests/A/first", "-only-testing:CoreTests/B/second"]),
            ("full-test", [], ["-only-testing:CoreTests", "-only-testing:Phase2Tests"]),
        ):
            result = subprocess.run(
                ["/bin/bash", "-c", 'MODE="$1"; shift; ONLY_TESTING=("$@");\n' + selection
                 + 'printf "%s\\n" "${TEST_SELECTION_ARGUMENTS[@]}"', "selection", mode, *selectors],
                capture_output=True, text=True, check=True,
            )
            self.assertEqual(result.stdout.splitlines(), expected)
        self.assertIn('ONLY_TESTING+=("${2:?missing value for --only-testing}")', script)
        full_test = script[script.index("  full-test)") : script.index("  release)")]
        self.assertIn("xcode.release-build", full_test)
        self.assertIn("-configuration Release", full_test)
        self.assertIn("TEST_SELECTION.txt", script)

    def test_installed_preparation_is_verified_before_qualification_success(self) -> None:
        script = QUALIFIER.read_text(encoding="utf-8")
        publication = script.index("  publish_installed_acceptance_preparation")
        final_validation = script.index(
            '"${QUALIFICATION_VALIDATOR[@]}" validate-build \\', publication
        )
        final_success = script.index("emit_qualification_outputs", final_validation)
        self.assertLess(publication, final_validation)
        self.assertLess(final_validation, final_success)
        self.assertIn(
            'echo "MACSCOPE_INSTALLED_UI_PREPARATION_RECEIPT=${INSTALLED_UI_PREPARATION_RECEIPT}"',
            script,
        )
        self.assertIn(
            'if [[ "${NATIVE_RECEIPT_PRESENT}" != "${INSTALLED_RECEIPT_PRESENT}" ]]; then',
            script,
        )
        self.assertIn("receipt set is partial", script)

    def test_receipt_success_token_is_emitted_only_after_the_selected_gate(self) -> None:
        script = QUALIFIER.read_text(encoding="utf-8")
        calls = [
            offset
            for offset, line in enumerate(script.splitlines())
            if line.strip() == "emit_qualification_outputs"
        ]
        self.assertEqual(len(calls), 2)
        prepare_line = next(
            offset
            for offset, line in enumerate(script.splitlines())
            if line.strip() == 'if [[ "${MODE}" == "prepare" ]]; then'
        )
        final_validation_line = next(
            offset
            for offset, line in enumerate(script.splitlines())
            if line.strip() == '"${QUALIFICATION_VALIDATOR[@]}" validate-build \\'
        )
        self.assertGreater(calls[0], prepare_line)
        self.assertGreater(calls[1], final_validation_line)
        function_body = script[
            script.index("emit_qualification_outputs() {") : script.index(
                "\n}\n", script.index("emit_qualification_outputs() {")
            )
        ]
        output_lines = [
            line.strip()
            for line in function_body.splitlines()
            if line.strip().startswith("echo ")
        ]
        self.assertEqual(
            output_lines[-1],
            'echo "MACSCOPE_QUALIFICATION_RECEIPT=${RECEIPT}"',
        )

    def test_resumed_full_test_preserves_primary_and_numbered_evidence_names(self) -> None:
        script = QUALIFIER.read_text(encoding="utf-8")
        full_test = script[script.index("  full-test)") : script.index("  release)")]
        self.assertIn('RESULT_BUNDLE="${RUN_ROOT}/TestResults.xcresult"', full_test)
        self.assertIn('COVERAGE_JSON="${RUN_ROOT}/COVERAGE.json"', full_test)
        self.assertIn("TestResults.resume-${RESULT_INDEX}.xcresult", full_test)
        self.assertIn("COVERAGE.resume-${RESULT_INDEX}.json", full_test)

    @staticmethod
    def _receipt(work: Path) -> dict[str, object]:
        path = next((work / "runs").glob("run.*/QUALIFICATION_INPUTS.json"))
        return json.loads(path.read_text(encoding="utf-8"))

    @staticmethod
    def _stage_names(work: Path) -> list[str]:
        path = next((work / "runs").glob("run.*/STAGE_TIMINGS.json"))
        return [stage["name"] for stage in json.loads(path.read_bytes())["stages"]]


class VerificationReceiptReuseTests(unittest.TestCase):
    """D1: dependency views verified once are trusted by key on later commits."""

    def _setup(self, root: Path) -> tuple[QualificationFixture, Path]:
        source = root / "source"
        source.mkdir()
        return QualificationFixture(source), root / "shared-cache"

    def _qualify(self, fixture, cache, work, **options):
        before = fixture.log.read_text() if fixture.log.exists() else ""
        result = fixture.qualify(work, dependency_cache_root=cache, **options)
        after = fixture.log.read_text() if fixture.log.exists() else ""
        return result, after[len(before):].splitlines()

    def test_dependency_receipts_are_reused_across_commits(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, cache = self._setup(root)
            first, first_log = self._qualify(fixture, cache, root / "work-1")
            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertIn("verify-ghostty-vt", first_log)
            self.assertIn("verify-ghostty-surface", first_log)
            # A new commit outside every component's source closure keeps each
            # dependency key, so its once-verified view is trusted by key.
            fixture._write("docs/new-file.md", "changes the tree only\n")
            fixture._git("add", ".")
            fixture._git("commit", "-m", "tree change")
            fixture._git(
                "update-ref", fixture.integration_ref, fixture._git("rev-parse", "HEAD", output=True)
            )
            second, second_log = self._qualify(fixture, cache, root / "work-2")
            self.assertEqual(second.returncode, 0, second.stderr)
            for component in ("ghostty-vt", "ghostty-surface", "sleigh-native-source"):
                self.assertRegex(
                    second.stderr, rf"reusing verified dependency {component} [0-9a-f]{{64}} \(receipt"
                )
            self.assertNotIn("verify-ghostty-vt", second_log)
            self.assertNotIn("verify-ghostty-surface", second_log)
            stages = LocalPrivateBuildQualificationTests._stage_names(root / "work-2")
            self.assertEqual(stages[:2], ["source.git-identity", "source.identity-check"])
            self.assertIn("dependency.ghostty-surface.reuse", stages)
            self.assertNotIn("dependency.ghostty-surface.verify", stages)
            self.assertNotEqual(
                LocalPrivateBuildQualificationTests._receipt(root / "work-1")["source_identity"],
                LocalPrivateBuildQualificationTests._receipt(root / "work-2")["source_identity"],
            )

    def test_restored_dependency_entry_metadata_reuses_content_key_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, cache = self._setup(root)
            first, _log = self._qualify(fixture, cache, root / "work-1")
            self.assertEqual(first.returncode, 0, first.stderr)
            (entry,) = list((cache / "artifacts/v1/ghostty-surface").iterdir())
            leaf = next(path for path in (entry / "payload").rglob("*") if path.is_file())
            directory = leaf.parent
            directory.chmod(0o755)
            leaf.chmod(0o644)
            leaf.chmod(0o444)
            directory.chmod(0o555)
            second, second_log = self._qualify(fixture, cache, root / "work-2")
            self.assertEqual(second.returncode, 0, second.stderr)
            self.assertIn(
                "reusing verified dependency ghostty-surface",
                second.stderr,
            )
            self.assertNotIn("verify-ghostty-surface", second_log)
            stages = LocalPrivateBuildQualificationTests._stage_names(root / "work-2")
            self.assertIn("dependency.ghostty-surface.reuse", stages)
            self.assertNotIn("dependency.ghostty-surface.verify", stages)
            self.assertIn("reusing verified dependency ghostty-vt", second.stderr)

    def test_opt_out_is_refused_without_reading_or_publishing_receipts(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, cache = self._setup(root)
            rejected = fixture.qualify(root / "work-1", dependency_cache_root=cache,
                                       extra_arguments=("--no-verification-reuse",))
            self.assertEqual(rejected.returncode, 2)
            self.assertIn("never re-verified", rejected.stderr)
            self.assertFalse((cache / "verification").exists())
            self.assertFalse((cache / "verification.noindex").exists())

    def test_concurrent_same_tree_gates_share_one_published_entry(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture, cache = self._setup(root)
            environment = os.environ.copy()
            environment["MACSCOPE_QUALIFICATION_TEST_LOG"] = str(fixture.log)
            processes = [
                subprocess.Popen(
                    ["/bin/bash", str(QUALIFIER), "--source-root", str(fixture.root),
                     "--work-root", str(root / f"work-{index}"), "--mode", "prepare",
                     "--integration-ref", fixture.integration_ref,
                     "--dependency-cache-root", str(cache)],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment,
                )
                for index in range(3)
            ]
            results = [process.communicate(timeout=300) + (process.returncode,) for process in processes]
            for _stdout, stderr, code in results:
                self.assertEqual(code, 0, stderr)
            for component in ("ghostty-vt", "ghostty-surface", "sleigh-native-source"):
                self.assertEqual(len(list((cache / "artifacts/v1" / component).iterdir())), 1)
            identities = {
                json.dumps(LocalPrivateBuildQualificationTests._receipt(root / f"work-{index}")["source_identity"], sort_keys=True)
                for index in range(3)
            }
            self.assertEqual(len(identities), 1)


class HeavyGateLockTests(unittest.TestCase):
    """Machine-wide heavy-gate lock: blocking, crash release and prepare exemption."""

    def _run_exit_traps(self, signal_name: str, exit_status: int) -> None:
        """Exercise production traps with a real temporary flock, without Xcode."""
        import fcntl

        source = QUALIFIER.read_text(encoding="utf-8")
        start = source.index("HEAVY_GATE_LOCK_HELD=0\n")
        end = source.index("\nrelease_cache_lock() {", start)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            lock = root / "heavy.lock"
            cache_temp = root / "cache-temp"
            cache_temp.mkdir()
            cache_lock = root / "cache-lock"
            cache_lock.mkdir()
            (cache_lock / "owner").write_text("fixture")
            # The foreground child signals only its waiting parent. Bash defers
            # the trap, so the lock must remain held until this child finishes.
            stage = root / "stage.py"
            stage.write_text(
                "import fcntl, os, pathlib, signal, sys\n"
                "os.close(7)\n"
                "if sys.argv[2]:\n"
                "    os.kill(os.getppid(), getattr(signal, sys.argv[2]))\n"
                "with open(sys.argv[1], 'a') as probe:\n"
                "    try:\n"
                "        fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
                "    except BlockingIOError:\n"
                "        pass\n"
                "    else:\n"
                "        raise AssertionError('foreground stage lost its lock')\n"
                "pathlib.Path(sys.argv[3]).write_text('finished while locked')\n"
            )
            setup = (
                'BUILD_SOURCE_ROOT="$1"\nGATE_LOCK_PATH="$2"\n'
                'ACTIVE_CACHE_TEMP="$3"\nACTIVE_CACHE_LOCK="$4"\n'
            )
            body = (
                '\nexec 7>>"$GATE_LOCK_PATH"\n'
                '/usr/bin/python3 -B "$BUILD_SOURCE_ROOT/Scripts/qualification/heavy_gate_lock.py" '
                'acquire --fd 7 --lock "$GATE_LOCK_PATH" --pid $$ '
                '--work-root "$3" --integration-ref fixture --mode smoke --run-root "$3"\n'
                'HEAVY_GATE_LOCK_HELD=1\n'
                '/usr/bin/python3 -B "$5" "$GATE_LOCK_PATH" "$6" "$7"\n'
                'echo "later stage: lock=$HEAVY_GATE_LOCK_HELD"\n'
                'exit "$8"\n'
            )
            result = subprocess.run(
                ["/bin/bash", "-eu", "-c", setup + source[start:end] + body,
                 "trap-fixture", str(REPOSITORY_ROOT), str(lock), str(cache_temp),
                 str(cache_lock), str(stage), signal_name, str(root / "finished"),
                 str(exit_status)],
                capture_output=True, text=True, timeout=15,
            )
            expected = {"SIGINT": 130, "SIGTERM": 143}.get(signal_name, exit_status)
            self.assertEqual(result.returncode, expected, result.stderr)
            self.assertEqual((root / "finished").read_text(), "finished while locked")
            if signal_name:
                self.assertNotIn("later stage", result.stdout)
            else:
                self.assertIn("later stage: lock=1", result.stdout)
            self.assertFalse(cache_temp.exists())
            self.assertFalse(cache_lock.exists())
            self.assertFalse(lock.with_name("heavy.lock.json").exists())
            with lock.open("a") as probe:
                fcntl.flock(probe, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_signals_exit_without_running_later_stages(self) -> None:
        for signal_name in ("SIGINT", "SIGTERM"):
            with self.subTest(signal=signal_name):
                self._run_exit_traps(signal_name, 0)

    def test_exit_cleanup_preserves_success_and_failure_status(self) -> None:
        for status in (0, 19):
            with self.subTest(status=status):
                self._run_exit_traps("", status)

    @staticmethod
    def _holder(lock: Path, ready: Path) -> subprocess.Popen:
        script = (
            'exec 7>>"$1"\n'
            '/usr/bin/python3 -B "$2" acquire --fd 7 --lock "$1" --pid $$ '
            '--work-root /holder --integration-ref refs/remotes/x/holder --mode full-test '
            '--run-root /holder/run\n'
            'touch "$3"\n'
            'exec /bin/sleep 120\n'
        )
        return subprocess.Popen(
            ["/bin/bash", "-c", script, "holder", str(lock), str(HEAVY_GATE_LOCK_TOOL), str(ready)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

    @staticmethod
    def _wait_for(path: Path) -> None:
        import time

        deadline = time.monotonic() + 30
        while not path.exists():
            if time.monotonic() > deadline:
                raise AssertionError(f"timed out waiting for {path}")
            time.sleep(0.05)

    def _qualifier_lock_fragment(self) -> str:
        script = QUALIFIER.read_text(encoding="utf-8")
        start = script.index("HEAVY_GATE_LOCK_HELD=0\n")
        end = script.index("cleanup_cache_operation() {", start)
        clock_start = script.index("stage_clock() {")
        clock = script[clock_start : script.index("\n}\n", clock_start) + 3]
        return clock + script[start:end]

    def _run_fragment(self, root: Path, lock: Path, timeout: int) -> subprocess.CompletedProcess[str]:
        run = root / f"run-{timeout}-{len(list(root.iterdir()))}"
        (run / "source/Scripts/qualification").mkdir(parents=True)
        (run / "source/Scripts/qualification/heavy_gate_lock.py").write_bytes(
            HEAVY_GATE_LOCK_TOOL.read_bytes()
        )
        receipt = run / "STAGE_TIMINGS.json"
        receipt.write_text(json.dumps({"clock": "time.monotonic_ns", "mode": "smoke",
            "run_root": str(run), "schema_version": 1, "source": {"commit": "a" * 40,
            "tree": "b" * 40}, "stages": []}, sort_keys=True, separators=(",", ":")) + "\n")
        setup = (
            'STAGE_TIMING_TOOL=(/usr/bin/python3 -B "' + str(STAGE_TIMING_TOOL) + '")\n'
            f'GATE_LOCK_ENABLED=1\nGATE_LOCK_PATH="{lock}"\nGATE_LOCK_TIMEOUT={timeout}\n'
            f'BUILD_SOURCE_ROOT="{run / "source"}"\nSTAGE_TIMING_RECEIPT="{receipt}"\n'
            f'WORK_ROOT="{root}"\nINTEGRATION_REF=refs/remotes/x/waiter\nMODE=smoke\nRUN_ROOT="{run}"\n'
        )
        body = (
            "acquire_heavy_gate_lock\n"
            'test "${HEAVY_GATE_LOCK_HELD}" = 1\n'
            "release_heavy_gate_lock\n"
            f'/usr/bin/python3 -c \'import json,sys; print(json.load(open(sys.argv[1]))["stages"][-1]["name"])\' "{receipt}"\n'
        )
        return subprocess.run(
            ["/bin/bash", "-eu", "-c", setup + self._qualifier_lock_fragment() + body],
            capture_output=True, text=True, timeout=120,
        )

    def test_second_gate_blocks_until_holder_is_killed(self) -> None:
        import signal

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            lock = root / "locks/heavy.lock"
            lock.parent.mkdir()
            ready = root / "ready"
            holder = self._holder(lock, ready)
            try:
                self._wait_for(ready)
                metadata = json.loads(lock.with_name("heavy.lock.json").read_text())
                self.assertEqual(metadata["pid"], holder.pid)
                blocked = self._run_fragment(root, lock, timeout=2)
                self.assertNotEqual(blocked.returncode, 0)
                self.assertIn(f"waiting for heavy-gate lock held by pid={holder.pid}", blocked.stderr)
                self.assertIn("heavy-gate lock was not acquired", blocked.stderr)
                holder.send_signal(signal.SIGKILL)
                holder.wait(timeout=30)
                acquired = self._run_fragment(root, lock, timeout=30)
                self.assertEqual(acquired.returncode, 0, acquired.stderr)
                self.assertEqual(acquired.stdout.strip(), "gate.heavy-lock.wait")
                # The releasing qualifier removes only its own metadata.
                self.assertFalse(lock.with_name("heavy.lock.json").exists())
            finally:
                if holder.poll() is None:
                    holder.kill()
                    holder.wait()

    def test_prepare_never_takes_the_heavy_gate_lock(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            source = root / "source"
            source.mkdir()
            fixture = QualificationFixture(source)
            lock = root / "locks/heavy.lock"
            lock.parent.mkdir()
            ready = root / "ready"
            holder = self._holder(lock, ready)
            try:
                self._wait_for(ready)
                result = fixture.qualify(
                    root / "work", extra_arguments=("--gate-lock", str(lock), "--gate-lock-timeout", "1")
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("heavy-gate lock", result.stderr)
                stages = LocalPrivateBuildQualificationTests._stage_names(root / "work")
                self.assertNotIn("gate.heavy-lock.wait", stages)
                self.assertEqual(
                    json.loads(lock.with_name("heavy.lock.json").read_text())["pid"], holder.pid
                )
            finally:
                holder.kill()
                holder.wait()

    def test_lock_is_taken_only_around_xcode_actions(self) -> None:
        script = QUALIFIER.read_text(encoding="utf-8")
        acquire = script.index("\nacquire_heavy_gate_lock\n")
        release = script.index("\nrelease_heavy_gate_lock\n", acquire)
        self.assertLess(script.index("timed_stage project.bootstrap"), acquire)
        self.assertLess(script.index('if [[ "${MODE}" == "prepare" ]]; then'), acquire)
        heavy = script[acquire:release]
        self.assertIn('case "${MODE}" in', heavy)
        self.assertEqual(script.count("timed_xcode_stage xcode."), heavy.count("timed_xcode_stage xcode."))
        self.assertIn("run_trusted_restore_tool --operation restore", script[release:])


class BootstrapReuseTests(unittest.TestCase):
    """Tree-keyed replay of a verified project.bootstrap result.

    Each gate runs in smoke mode while a test-held heavy-gate lock makes the
    qualifier stop right after bootstrap and the project identity binding,
    before any Xcode action.
    """

    def setUp(self) -> None:
        self._temporary = tempfile.TemporaryDirectory()
        self.root = Path(self._temporary.name).resolve()
        source = self.root / "source"
        source.mkdir()
        self.fixture = QualificationFixture(source)
        self.cache = self.root / "shared-cache"
        self.lock = self.root / "gate.lock"
        ready = self.root / "holder.ready"
        self.holder = HeavyGateLockTests._holder(self.lock, ready)
        HeavyGateLockTests._wait_for(ready)

    def tearDown(self) -> None:
        self.holder.kill()
        self.holder.wait()
        for path in self.cache.rglob("*"):
            if not path.is_symlink():
                path.chmod(0o700 if path.is_dir() else 0o600)
        self._temporary.cleanup()

    def _gate(self, name: str, *arguments: str, environment=None):
        before = self.fixture.log.read_text() if self.fixture.log.exists() else ""
        result = self.fixture.qualify(
            self.root / name,
            mode="smoke",
            dependency_cache_root=self.cache,
            extra_environment=environment,
            extra_arguments=("--gate-lock", str(self.lock), "--gate-lock-timeout", "1", *arguments),
        )
        after = self.fixture.log.read_text() if self.fixture.log.exists() else ""
        # The held lock is the intended stop: bootstrap and binding completed.
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("heavy-gate lock", result.stderr)
        run = next((self.root / name / "runs").glob("run.*"))
        self.assertTrue((run / "source/MacScope/MacScope.xcodeproj/project.xcproj").is_file(), result.stderr)
        stages = [stage["name"] for stage in json.loads((run / "STAGE_TIMINGS.json").read_bytes())["stages"]]
        return result, after[len(before):].splitlines(), stages, run

    def _entries(self) -> list[Path]:
        root = self.cache / "verification.noindex/bootstraps/v1/entries"
        return sorted(root.iterdir()) if root.exists() else []

    def _commit(self, relative: str, contents: str) -> None:
        self.fixture._write(relative, contents)
        self.fixture._git("add", ".")
        self.fixture._git("commit", "-m", f"change {relative}")
        self.fixture._git(
            "update-ref", self.fixture.integration_ref,
            self.fixture._git("rev-parse", "HEAD", output=True),
        )

    @staticmethod
    def _project_bytes(run: Path) -> dict[str, bytes]:
        project = run / "source/MacScope/MacScope.xcodeproj"
        return {
            path.relative_to(project).as_posix(): path.read_bytes()
            for path in project.rglob("*") if path.is_file()
        }

    def test_exact_match_replays_byte_identical_validated_outputs(self) -> None:
        first, first_log, first_stages, first_run = self._gate("work-1")
        self.assertIn("full bootstrap: no verified bootstrap for this key", first.stderr)
        self.assertIn("published bootstrap verification receipt", first.stderr)
        self.assertIn("bootstrap", first_log)
        self.assertIn("project.bootstrap", first_stages)
        self.assertEqual(len(self._entries()), 1)

        second, second_log, second_stages, second_run = self._gate("work-2")
        key = self._entries()[0].name
        self.assertRegex(second.stderr, rf"reusing verified bootstrap {key} \(receipt [0-9a-f]{{64}}\)")
        self.assertNotIn("bootstrap", second_log)
        self.assertIn("project.bootstrap.reuse", second_stages)
        self.assertNotIn("project.bootstrap", second_stages)
        self.assertEqual(self._project_bytes(first_run), self._project_bytes(second_run))
        source = second_run / "source/MacScope"
        xcconfig = source / "DependencyRoots.local.xcconfig"
        metadata = xcconfig.lstat()
        self.assertEqual((stat.S_IMODE(metadata.st_mode), metadata.st_nlink), (0o600, 1))
        self.assertIn(str(second_run), xcconfig.read_text())
        self.assertNotIn(str(first_run), xcconfig.read_text())
        self.assertEqual(os.readlink(source / "LocalPackages"), str(second_run / "private-machokit-input"))
        for path in (second_run / "source/MacScope/MacScope.xcodeproj").rglob("*"):
            first_path = first_run / path.relative_to(second_run)
            self.assertEqual(stat.S_IMODE(path.lstat().st_mode), stat.S_IMODE(first_path.lstat().st_mode))
            self.assertEqual(path.lstat().st_nlink if path.is_file() else 1, 1)
        # The trusted restore validator accepts the replayed scaffold exactly.
        restore = subprocess.run(
            ["/usr/bin/python3", "-B", str(BUILD_SOURCE_RESTORE_TOOL), "--operation", "restore",
             "--build-source-root", str(second_run / "source"),
             "--machokit-root", str(second_run / "private-machokit-input"),
             "--dependency-cache-root", str(self.cache)],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(restore.returncode, 0, restore.stderr)

    def test_changed_generator_script_tree_or_environment_misses(self) -> None:
        first, _log, _stages, _run = self._gate("work-1")
        self.assertIn("published bootstrap verification receipt", first.stderr)

        environment, environment_log, _stages, _run = self._gate(
            "work-environment", environment={"MACSCOPE_BOOTSTRAP_FIXTURE_VARIANT": "1"}
        )
        self.assertIn("full bootstrap: no verified bootstrap for this key", environment.stderr)
        self.assertIn("bootstrap", environment_log)

        self._commit("Scripts/generate_xcode_json_project.py", "# generator variant\n")
        generator, generator_log, generator_stages, _run = self._gate("work-generator")
        self.assertIn("full bootstrap: no verified bootstrap for this key", generator.stderr)
        self.assertNotIn("reusing verified bootstrap", generator.stderr)
        self.assertIn("bootstrap", generator_log)
        self.assertIn("project.bootstrap", generator_stages)

        self._commit("docs/new-file.md", "changes the tree only\n")
        tree, tree_log, _stages, _run = self._gate("work-tree")
        self.assertIn("full bootstrap: no verified bootstrap for this key", tree.stderr)
        self.assertIn("bootstrap", tree_log)
        self.assertEqual(len(self._entries()), 4)
        inputs = [json.loads((entry / "RECEIPT.json").read_bytes())["key_inputs"] for entry in self._entries()]
        self.assertTrue(any(
            "script-generate_xcode_json_project.py" in value["files"]
            and "sha256" in value["files"]["script-generate_xcode_json_project.py"]
            for value in inputs
        ))

    def test_tampered_cached_project_is_rejected_quarantined_and_republished(self) -> None:
        first, _log, _stages, first_run = self._gate("work-1")
        (entry,) = self._entries()
        target = entry / "project/project.xcproj"
        original = target.read_bytes()
        target.chmod(0o644)
        target.write_bytes(original[:-2] + b"X\n")
        target.chmod(0o444)
        second, second_log, second_stages, second_run = self._gate("work-2")
        self.assertIn("stored bootstrap project bytes differ from its receipt", second.stderr)
        self.assertIn("full bootstrap:", second.stderr)
        self.assertNotIn("reusing verified bootstrap", second.stderr)
        self.assertIn("bootstrap", second_log)
        self.assertIn("project.bootstrap", second_stages)
        quarantine = list((self.cache / "verification.noindex/bootstraps/v1/quarantine").iterdir())
        self.assertEqual(len(quarantine), 1)
        (republished,) = self._entries()
        self.assertEqual((republished / "project/project.xcproj").read_bytes(), original)
        self.assertEqual(self._project_bytes(first_run), self._project_bytes(second_run))


if __name__ == "__main__":
    unittest.main()
