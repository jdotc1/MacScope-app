#!/usr/bin/env bash
# bootstrap.sh — Reproducible Xcode project generation for MacScope
#
# Usage: ./Scripts/bootstrap.sh
#
# Verifies XcodeGen satisfies the minimum declared by project.yml, regenerates the
# gitignored MacScope/MacScope.xcodeproj from MacScope/project.yml, then
# performs lightweight sanity checks to confirm the project is well-formed.
# Run this after every fresh checkout and before any xcodebuild invocation.

set -euo pipefail

# Governance and signing tests import repository-local Python modules.  Never
# leave interpreter caches in source directories: Release provenance treats
# every selected build input as an exact HEAD blob and must reject generated
# bytecode rather than accidentally sealing it.
export PYTHONDONTWRITEBYTECODE=1

# ── Locate repo root (this script lives in Scripts/ at the repo root) ─────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/work_root.sh
source "${SCRIPT_DIR}/lib/work_root.sh"
MACSCOPE_DIR="${REPO_ROOT}/MacScope"
PROJECT_FILE="${MACSCOPE_DIR}/MacScope.xcodeproj/project.xcproj"
PROJECT_FRESHNESS_STAMP="${MACSCOPE_DIR}/MacScope.xcodeproj/.macscope-project-generation.sha256"
GHOSTTY_SOURCE_DIR="${REPO_ROOT}/ThirdParty/GhosttyVT/Source"
SLEIGH_COMPONENT_ROOT="${MACSCOPE_SLEIGH_COMPONENT_ROOT:-${REPO_ROOT}/ThirdParty/SleighNative}"
SLEIGH_ROOT="${MACSCOPE_SLEIGH_MATERIALIZATION_ROOT:-}"
SLEIGH_SOURCE_BUILD_ROOT="${MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT:-}"
# Set only by the successful in-process cache resolver below, never by an
# environment override. Its pinned VIEW.json already records domain verification.
SLEIGH_CACHE_ADMITTED=0
MACHOKIT_ROOT="${MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT:-}"
MACHOKIT_SOURCE_ROOT="${REPO_ROOT}/ThirdParty/MachOKit/materialization"
# The read-only MachOKit view backs the MacScope/LocalPackages symlink, so its
# default work root must survive a restart ($TMPDIR does not): it lives under
# the owner-controlled, Spotlight-excluded dev-loop root. Qualifier and CI runs
# pass MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT (a run-owned copy) and never use it.
MACHOKIT_WORK_ROOT="${MACSCOPE_MACHOKIT_MATERIALIZATION_WORK_ROOT:-${MACSCOPE_DEV_LOOP_ROOT:-$(macscope_work_root)/MacScopeDevLoop.noindex}/MachOKit}"

# MacScope accepts any Xcode 27 build, but no other Xcode/SDK major line.
source "${SCRIPT_DIR}/xcode27_env.sh"

echo "==> MacScope bootstrap"
echo "    Repo root: ${REPO_ROOT}"

# Explicit Release inheritance is admitted by source records and the exact
# qualifier/cache receipts. An environment variable alone never authorizes it.
BOOTSTRAP_RETAINED=0
BOOTSTRAP_POLICY_INHERITED=0
BOOTSTRAP_INVENTORY_INHERITED=0
if [[ -n "${MACSCOPE_RETAINED_RELEASE_QUALIFICATION_INPUTS:-}" ]]; then
  BOOTSTRAP_ADMISSION="$(/usr/bin/python3 -B - "${REPO_ROOT}" <<'PYADMIT'
import os, sys
from pathlib import Path
sys.path.insert(0, str(Path(sys.argv[1]) / 'Scripts/qualification'))
from qualification_manifest_inheritance import admit_bootstrap
value = admit_bootstrap(Path(sys.argv[1]), os.environ['MACSCOPE_QUALIFICATION_INPUTS_RECEIPT'],
                        os.environ['MACSCOPE_RETAINED_RELEASE_QUALIFICATION_INPUTS'], os.environ)
print(int(value['policy']))
print(int(value['inventory']))
print(value['xcodegen_version'])
PYADMIT
)"
  BOOTSTRAP_POLICY_INHERITED="${BOOTSTRAP_ADMISSION%%$'\n'*}"
  BOOTSTRAP_ADMISSION="${BOOTSTRAP_ADMISSION#*$'\n'}"
  BOOTSTRAP_INVENTORY_INHERITED="${BOOTSTRAP_ADMISSION%%$'\n'*}"
  INHERITED_XCODEGEN_VERSION="${BOOTSTRAP_ADMISSION#*$'\n'}"
  BOOTSTRAP_RETAINED=1
  SLEIGH_CACHE_ADMITTED=1
fi

# ── 1. Enforce dependency governance before any build tooling runs ────────────
echo "==> Verifying dependency governance and offline build surface ..."
if [[ "${BOOTSTRAP_POLICY_INHERITED}" == 1 ]]; then
  echo "    Reusing unchanged policy consistency evidence"
else
  /usr/bin/python3 "${SCRIPT_DIR}/dependencies/validate_policy_consistency.py" >/dev/null
fi
if [[ "${BOOTSTRAP_INVENTORY_INHERITED}" == 1 ]]; then
  echo "    Reusing unchanged third-party inventory evidence"
else
  /usr/bin/python3 "${SCRIPT_DIR}/dependencies/validate_third_party_components.py" >/dev/null
fi
/usr/bin/python3 "${SCRIPT_DIR}/dependencies/validate_offline_build_surface.py" >/dev/null
echo "    Policy, inventory, licenses/notices, pins, and offline surface — OK"

# ── 2. Verify exact repository XcodeGen (with explicit verified override) ─────
XCODEGEN="${MACSCOPE_XCODEGEN:-${REPO_ROOT}/ThirdParty/XcodeGen/bin/xcodegen}"
if [[ "${BOOTSTRAP_RETAINED}" == 1 ]]; then
  echo "    Reusing exact admitted XcodeGen source/tool identity"
else
  /usr/bin/python3 -B "${SCRIPT_DIR}/dependencies/materialize_xcodegen.py" \
    verify-tool --binary "${XCODEGEN}" >/dev/null || {
    echo "ERROR: XcodeGen is not the exact governed repository tool: ${XCODEGEN}" >&2
    exit 1
  }
fi

# ── 3. Check the project-declared XcodeGen minimum ────────────────────────────
MINIMUM_XCODEGEN_VERSION="$(awk '$1 == "minimumXcodeGenVersion:" { print $2; exit }' "${MACSCOPE_DIR}/project.yml")"
if [[ "${BOOTSTRAP_RETAINED}" == 1 ]]; then
  FOUND_VERSION="${INHERITED_XCODEGEN_VERSION}"
else
  FOUND_VERSION="$("${XCODEGEN}" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
fi
if [[ -z "${MINIMUM_XCODEGEN_VERSION}" || -z "${FOUND_VERSION}" ]]; then
  echo "ERROR: Could not determine the declared minimum or installed XcodeGen version."
  echo "       Declared minimum: ${MINIMUM_XCODEGEN_VERSION:-missing}"
  echo "       Installed:       ${FOUND_VERSION:-missing}"
  exit 1
fi
if ! /usr/bin/python3 - "${FOUND_VERSION}" "${MINIMUM_XCODEGEN_VERSION}" <<'PY'
import sys

def version(value: str) -> tuple[int, int, int]:
    parts = value.split(".")
    if len(parts) != 3 or any(not part.isdigit() for part in parts):
        raise ValueError(value)
    return tuple(int(part) for part in parts)

try:
    installed = version(sys.argv[1])
    minimum = version(sys.argv[2])
except ValueError as error:
    print(f"ERROR: Invalid XcodeGen version: {error.args[0]}", file=sys.stderr)
    raise SystemExit(1)
raise SystemExit(0 if installed >= minimum else 1)
PY
then
  echo "ERROR: XcodeGen ${MINIMUM_XCODEGEN_VERSION} or later is required; found ${FOUND_VERSION}."
  exit 1
fi
echo "    xcodegen ${FOUND_VERSION} satisfies minimum ${MINIMUM_XCODEGEN_VERSION} — OK"

# ── 5. Refuse signing-identity regressions before generating/building ─────────
echo "==> Verifying persistent local signing policy ..."
/usr/bin/python3 "${SCRIPT_DIR}/check_local_signing_policy.py"
echo "    Signing-policy source + isolated-CI override — OK"

# ── 6. Produce/reuse strict offline dependency inputs before Xcode links them ─
# Developer bootstraps consume the qualifier's shared, content-addressed and
# verified dependency cache (same keys, same builders, same verifiers) through
# read-only views, so a new worktree or a purged $TMPDIR never rebuilds SLEIGH
# or the Ghostty surface from scratch. A miss builds once and publishes for every
# lane, CI and the qualifier. Status 3 (disabled, no cache, or governed inputs
# that differ from HEAD) keeps the original local producers below. The
# qualifier passes its own verified roots, so this path never runs there.
DEV_DEPENDENCY_CACHE="${SCRIPT_DIR}/qualification/dev_dependency_cache.py"
# Prints the value of NAME from a dev_dependency_cache.py contract on stdin.
dev_dependency_value() {
  local name="$1" line found=""
  while IFS= read -r line; do
    if [[ "${line}" == "${name}="* ]]; then
      [[ -z "${found}" ]] || return 1
      found="${line#"${name}="}"
    fi
  done
  [[ -n "${found}" ]] || return 1
  printf '%s\n' "${found}"
}
dev_dependency_resolve() {
  /usr/bin/python3 -B "${DEV_DEPENDENCY_CACHE}" resolve \
    --component "$1" --repository-root "${REPO_ROOT}"
}
if [[ -z "${SLEIGH_ROOT}" && -z "${SLEIGH_SOURCE_BUILD_ROOT}" ]]; then
  echo "==> Resolving native SLEIGH materialization from the shared verified dependency cache ..."
  DEV_DEPENDENCY_STATUS=0
  SLEIGH_PREPARATION="$(dev_dependency_resolve sleigh-native-source)" || DEV_DEPENDENCY_STATUS=$?
  if [[ "${DEV_DEPENDENCY_STATUS}" == 0 ]]; then
    SLEIGH_SOURCE_BUILD_ROOT="$(dev_dependency_value MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT <<<"${SLEIGH_PREPARATION}")" &&
      SLEIGH_ROOT="$(dev_dependency_value MACSCOPE_SLEIGH_MATERIALIZATION_ROOT <<<"${SLEIGH_PREPARATION}")" || {
        echo "ERROR: shared dependency cache returned an invalid SLEIGH contract." >&2
        exit 1
      }
    if [[ "${SLEIGH_ROOT}" != "${SLEIGH_SOURCE_BUILD_ROOT}/materialization" ]]; then
      echo "ERROR: shared dependency cache returned incoherent SLEIGH roots." >&2
      exit 1
    fi
    SLEIGH_CACHE_ADMITTED=1
    echo "    Native SLEIGH (verified cache view): ${SLEIGH_ROOT}"
  elif [[ "${DEV_DEPENDENCY_STATUS}" != 3 ]]; then
    echo "ERROR: shared dependency cache rejected native SLEIGH." >&2
    exit 1
  fi
fi
if [[ -z "${SLEIGH_ROOT}" ]]; then
  SLEIGH_SOURCE_WORK_ROOT="${MACSCOPE_SLEIGH_SOURCE_BUILD_WORK_ROOT:-${MACSCOPE_SLEIGH_MATERIALIZATION_WORK_ROOT:-${TMPDIR:-/tmp}/MacScope/SleighNative}}"
  echo "==> Building or reusing strict source-built native SLEIGH materialization ..."
  if ! SLEIGH_PREPARATION="$(
    "${SCRIPT_DIR}/dependencies/build_vendored_sleigh_native_source.sh" \
      --work-root "${SLEIGH_SOURCE_WORK_ROOT}"
  )"
  then
    echo "ERROR: repository SLEIGH source-build preparation failed." >&2
    exit 1
  fi
  if [[ "${SLEIGH_PREPARATION}" != *$'\n'* ]]; then
    echo "ERROR: repository SLEIGH source producer omitted its two-line contract." >&2
    exit 1
  fi
  SLEIGH_SOURCE_LINE="${SLEIGH_PREPARATION%%$'\n'*}"
  SLEIGH_ROOT_LINE="${SLEIGH_PREPARATION#*$'\n'}"
  if [[ "${SLEIGH_SOURCE_LINE}" != MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT=* ]] || \
     [[ "${SLEIGH_ROOT_LINE}" != MACSCOPE_SLEIGH_MATERIALIZATION_ROOT=* ]] || \
     [[ "${SLEIGH_ROOT_LINE}" == *$'\n'* ]]; then
    echo "ERROR: repository SLEIGH source producer returned an invalid contract." >&2
    exit 1
  fi
  SLEIGH_SOURCE_BUILD_ROOT="${SLEIGH_SOURCE_LINE#MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT=}"
  SLEIGH_ROOT="${SLEIGH_ROOT_LINE#MACSCOPE_SLEIGH_MATERIALIZATION_ROOT=}"
  if [[ -z "${SLEIGH_SOURCE_BUILD_ROOT}" || \
        "${SLEIGH_ROOT}" != "${SLEIGH_SOURCE_BUILD_ROOT}/materialization" ]]; then
    echo "ERROR: repository SLEIGH source producer returned incoherent roots." >&2
    exit 1
  fi
  # The legacy prepare_repository_sleigh_materialization.py path remains an
  # explicit schema-1 rollback seam; ordinary bootstrap does not invoke it.
  echo "    Native SLEIGH source build: ${SLEIGH_SOURCE_BUILD_ROOT}"
  echo "    Native SLEIGH: ${SLEIGH_ROOT}"
fi

# Produce/reuse the offline full-surface artifact before Xcode links it. The VT
# fallback is built directly from repository-owned source by the Xcode phase.
canonical_external_ghostty_root() {
  local label="$1"
  local requested="$2"
  /usr/bin/python3 -B - "${label}" "${requested}" "${REPO_ROOT}" <<'PY'
from pathlib import Path
import sys

label, requested, repository_value = sys.argv[1:]
candidate = Path(requested)
if not candidate.is_absolute():
    raise SystemExit(f"ERROR: {label} must be an absolute external path.")
resolved = candidate.resolve(strict=False)
repository = Path(repository_value).resolve(strict=True)
if resolved in (Path("/"), Path.home().resolve(), repository) or repository in resolved.parents:
    raise SystemExit(f"ERROR: {label} must be a dedicated path outside the repository.")
print(resolved)
PY
}

GHOSTTY_SURFACE_WORK_ROOT="${MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT:-${TMPDIR:-/tmp}/MacScope}"
GHOSTTY_SURFACE_WORK_ROOT="$(canonical_external_ghostty_root \
  MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT "${GHOSTTY_SURFACE_WORK_ROOT}")"
if [[ -z "${MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR:-}${MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR_SHA256:-}" ]]; then
  echo "==> Resolving Ghostty full surface from the shared verified dependency cache ..."
  DEV_DEPENDENCY_STATUS=0
  GHOSTTY_SURFACE_PREPARATION="$(dev_dependency_resolve ghostty-surface)" || DEV_DEPENDENCY_STATUS=$?
  if [[ "${DEV_DEPENDENCY_STATUS}" == 0 ]]; then
    # The view was fully hashed against its immutable entry and accepted by the
    # surface producer's own verifier; bootstrap admits it like a qualification view.
    GHOSTTY_SURFACE_WORK_ROOT="$(dev_dependency_value MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT <<<"${GHOSTTY_SURFACE_PREPARATION}")" &&
      MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR="$(dev_dependency_value MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR <<<"${GHOSTTY_SURFACE_PREPARATION}")" &&
      MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR_SHA256="$(dev_dependency_value MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR_SHA256 <<<"${GHOSTTY_SURFACE_PREPARATION}")" || {
        echo "ERROR: shared dependency cache returned an invalid Ghostty surface contract." >&2
        exit 1
      }
    GHOSTTY_SURFACE_WORK_ROOT="$(canonical_external_ghostty_root \
      MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT "${GHOSTTY_SURFACE_WORK_ROOT}")"
  elif [[ "${DEV_DEPENDENCY_STATUS}" != 3 ]]; then
    echo "ERROR: shared dependency cache rejected the Ghostty surface." >&2
    exit 1
  fi
fi
GHOSTTY_SURFACE_SOURCE_DIR="${GHOSTTY_SURFACE_WORK_ROOT}/GhosttySurface"
GHOSTTY_SURFACE_ARTIFACT_ROOT="${GHOSTTY_SURFACE_SOURCE_DIR}/macos/GhosttyKit.xcframework"
GHOSTTY_SURFACE_FRAMEWORK="${GHOSTTY_SURFACE_ARTIFACT_ROOT}/macos-arm64/libghostty-internal.a"

if [[ -n "${MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR:-}${MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR_SHA256:-}" ]]; then
  echo "==> Admitting qualification-verified Ghostty surface inputs ..."
  /usr/bin/python3 -B "${SCRIPT_DIR}/dependencies/verified_ghostty_surface_admission.py" \
    --source-root "${GHOSTTY_SURFACE_SOURCE_DIR}" \
    --descriptor "${MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR:?}" \
    --descriptor-sha256 "${MACSCOPE_GHOSTTY_SURFACE_VERIFIED_DESCRIPTOR_SHA256:?}"
else
echo "==> Producing or reusing offline Ghostty full-surface artifacts ..."
if ! (
  unset MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR \
    MACSCOPE_ZIG_ROOT MACSCOPE_ZIG MACSCOPE_ZIG_RECEIPT \
    MACSCOPE_GIT MACSCOPE_LIPO MACSCOPE_NM MACSCOPE_PLIST_BUDDY MACSCOPE_PYTHON
  "${SCRIPT_DIR}/dependencies/build_vendored_ghostty_surface.sh" \
    --work-root "${GHOSTTY_SURFACE_WORK_ROOT}"
); then
  echo "ERROR: offline Ghostty full-surface production failed." >&2
  exit 1
fi
fi
echo "    Ghostty surface: ${GHOSTTY_SURFACE_ARTIFACT_ROOT}"

if [[ "${SLEIGH_CACHE_ADMITTED}" == 1 ]]; then
  echo "==> Reusing native SLEIGH verification from the admitted cache-view receipt ..."
else
  echo "==> Verifying native SLEIGH package materialization ..."
  /usr/bin/python3 -B \
    "${SCRIPT_DIR}/native-decompiler-direct/verify_sleigh_package.py" \
    verify --materialization-root "${SLEIGH_ROOT}" >/dev/null
fi
echo "    Native SLEIGH package — OK"

echo "==> Verifying MachOKit direct-source materialization ..."
if [[ -z "${MACHOKIT_ROOT}" ]]; then
  if ! MACHOKIT_PREPARATION="$(
    /usr/bin/python3 -B "${SCRIPT_DIR}/machokit_source_identity.py" \
      publish-read-only \
      --source-root "${MACHOKIT_SOURCE_ROOT}" \
      --work-root "${MACHOKIT_WORK_ROOT}" \
      --quiet
  )"
  then
    echo "ERROR: repository MachOKit read-only view publication failed." >&2
    exit 1
  fi
  case "${MACHOKIT_PREPARATION}" in
    MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT=*)
      MACHOKIT_ROOT="${MACHOKIT_PREPARATION#MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT=}"
      ;;
    *)
      echo "ERROR: repository MachOKit publisher returned an invalid result." >&2
      exit 1
      ;;
  esac
fi
# link admits the exact pinned read-only root, reusing publication's receipt.
# An explicit qualification root without a receipt is verified once there.
/usr/bin/python3 -B "${SCRIPT_DIR}/machokit_source_identity.py" \
  link \
  --materialization-root "${MACHOKIT_ROOT}" \
  --macscope-directory "${MACSCOPE_DIR}" \
  --quiet
echo "    MachOKit direct-source materialization and local package link — OK"

# ── 7. Run xcodegen generate from inside MacScope/ ───────────────────────────
# Publish this machine's verified roots as build settings before generating, so
# that the Xcode UI, the headless Xcode MCP server and `xcodebuild` all resolve
# them identically. Scheme environment variables cannot serve this purpose: they
# apply to the Run and Test actions only and are invisible to build script phases.
LOCAL_DEPENDENCY_ROOTS="${MACSCOPE_DIR}/DependencyRoots.local.xcconfig"
# Parser engines (RX-03, R11) link prebuilt archives from the shared verified dependency cache.
PARSER_ENGINE_CACHE_ROOT="${MACSCOPE_DEPENDENCY_CACHE_ROOT:-$(macscope_work_root)/MacScopeQualificationCache-20260920}"
# Reuse the receipt-owned staged pattern archive through the same machine-local
# dependency configuration. Its producer is separate from Xcode/bootstrap.
PATTERN_ADAPTER_ROOT="${MACSCOPE_PATTERN_ADAPTER_ROOT:-}"
echo "==> Recording machine-local dependency roots ..."
for _root_value in \
  "${GHOSTTY_SOURCE_DIR}" \
  "${GHOSTTY_SURFACE_WORK_ROOT}" \
  "${GHOSTTY_SURFACE_SOURCE_DIR}" \
  "${GHOSTTY_SURFACE_ARTIFACT_ROOT}" \
  "${GHOSTTY_SURFACE_FRAMEWORK}" \
  "${SLEIGH_COMPONENT_ROOT}" \
  "${SLEIGH_SOURCE_BUILD_ROOT}" \
  "${SLEIGH_ROOT}" \
  "${MACHOKIT_ROOT}" \
  "${PARSER_ENGINE_CACHE_ROOT}" \
  "${PATTERN_ADAPTER_ROOT}"
do
  case "${_root_value}" in
    *'"'*|*'$'*|*'//'*)
      echo "ERROR: dependency root is not representable in an xcconfig: ${_root_value}" >&2
      exit 1
      ;;
  esac
done
/usr/bin/python3 -B "${SCRIPT_DIR}/generate_xcode_json_project.py" \
  --publish-file "${LOCAL_DEPENDENCY_ROOTS}" --publish-mode 0600 <<XCCONFIG
// Generated by Scripts/bootstrap.sh. Untracked and machine-local — do not commit.
// Regenerate by re-running bootstrap; edit DependencyRoots.xcconfig for anything
// that should be shared.
MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT = ${GHOSTTY_SURFACE_WORK_ROOT}
MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR = ${GHOSTTY_SURFACE_SOURCE_DIR}
MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT = ${GHOSTTY_SURFACE_ARTIFACT_ROOT}
MACSCOPE_GHOSTTY_SURFACE_FRAMEWORK = ${GHOSTTY_SURFACE_FRAMEWORK}
MACSCOPE_GHOSTTY_SURFACE_ENABLED = MACSCOPE_FULL_GHOSTTY_SURFACE
MACSCOPE_SLEIGH_COMPONENT_ROOT = ${SLEIGH_COMPONENT_ROOT}
MACSCOPE_SLEIGH_SOURCE_BUILD_ROOT = ${SLEIGH_SOURCE_BUILD_ROOT}
MACSCOPE_SLEIGH_MATERIALIZATION_ROOT = ${SLEIGH_ROOT}
MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT = ${MACHOKIT_ROOT}
MACSCOPE_PARSER_ENGINE_CACHE_ROOT = ${PARSER_ENGINE_CACHE_ROOT}
MACSCOPE_PATTERN_ADAPTER_ROOT = ${PATTERN_ADAPTER_ROOT}
XCCONFIG
echo "    ${LOCAL_DEPENDENCY_ROOTS} — OK"

echo "==> Generating Xcode project (xcodegen generate) ..."
/bin/rm -f "${PROJECT_FRESHNESS_STAMP}"
# Captured before generation: a file added mid-generation must not be stamped as present.
PRE_GENERATION_SOURCE_PATHS_DIGEST="$(/usr/bin/python3 "${SCRIPT_DIR}/check_local_signing_policy.py" \
  --project-yml "${MACSCOPE_DIR}/project.yml" --print-source-paths-digest)"
(
  cd "${MACSCOPE_DIR}"
  /usr/bin/python3 -B "${SCRIPT_DIR}/generate_xcode_json_project.py" --source "${MACSCOPE_DIR}" --xcodegen "${XCODEGEN}"
) || {
  echo "ERROR: xcodegen generate failed."
  exit 1
}
echo "    Project generated: ${PROJECT_FILE}"

echo "==> Verifying resolved MacScope signing settings ..."
/usr/bin/python3 "${SCRIPT_DIR}/check_local_signing_policy.py" \
  --xcodeproj "${MACSCOPE_DIR}/MacScope.xcodeproj"
echo "    Resolved Debug/Release certificate signing — OK"

# ── 8. Verify expected source files are referenced in the generated project ───
echo "==> Verifying source inclusion ..."

MISSING=0
for SOURCE_FILE in "WorkspaceDatabase.swift" "AnalysisEngine.swift"; do
  if grep -q "${SOURCE_FILE}" "${PROJECT_FILE}"; then
    echo "    [OK] ${SOURCE_FILE} referenced in project"
  else
    echo "ERROR: ${SOURCE_FILE} NOT found in generated project.xcproj"
    MISSING=1
  fi
done

if [[ "${MISSING}" -ne 0 ]]; then
  echo "ERROR: One or more expected source files are missing from the generated project."
  echo "       Check MacScope/project.yml source globs."
  exit 1
fi

# ── 9. Verify scheme/test discoverability (lightweight, no build) ─────────────
echo "==> Verifying scheme discoverability ..."
XCODEPROJ="${MACSCOPE_DIR}/MacScope.xcodeproj"

xcodebuild \
  -project "${XCODEPROJ}" \
  -scheme MacScopeApp \
  -showBuildSettings \
  MACSCOPE_SLEIGH_MATERIALIZATION_ROOT="${SLEIGH_ROOT}" \
  MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT="${MACHOKIT_ROOT}" \
  >/dev/null 2>&1 || {
  echo "ERROR: xcodebuild -showBuildSettings failed for scheme 'MacScopeApp'."
  echo "       The generated project may be malformed. Check xcodegen output above."
  exit 1
}
echo "    Scheme 'MacScopeApp' is discoverable — OK"

/usr/bin/python3 "${SCRIPT_DIR}/check_local_signing_policy.py" \
  --project-yml "${MACSCOPE_DIR}/project.yml" \
  --record-generated-project-freshness \
  --expected-source-paths-digest "${PRE_GENERATION_SOURCE_PATHS_DIGEST}" || {
  echo "ERROR: source files changed while the project was generated; rerun bootstrap (or the dev loop)."
  exit 1
}
echo "    Project-generation freshness stamp — OK"

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "==> Bootstrap complete. Project is ready to build."
echo "    Run ./Scripts/test.sh to build and run the CoreTests suite."
