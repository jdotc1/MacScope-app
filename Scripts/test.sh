#!/usr/bin/env bash
# test.sh — Build and run MacScope CoreTests
#
# Usage:
#   ./Scripts/test.sh                          # run all CoreTests
#   ./Scripts/test.sh CoreTests/MyTest/myCase  # run a specific test
#
# Always regenerates the Xcode project via bootstrap.sh first so the test run
# never depends on a stale or manually-generated project.xcproj.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
XCODEPROJ="${REPO_ROOT}/MacScope/MacScope.xcodeproj"

source "${SCRIPT_DIR}/xcode27_env.sh"

# Optional first argument: an -only-testing: filter (e.g. CoreTests/SomeClass)
# Defaults to the entire CoreTests bundle.
ONLY_TESTING="${1:-CoreTests}"

# Keep the focused-test driver out of Xcode’s shared DerivedData. Both
# drivers write task signatures into one build.db per root; alternating drivers
# against that database causes otherwise warm builds to relink and re-sign every
# target. Give every worktree one stable external root so different selectors
# reuse compiled products without colliding with Xcode or another worktree.
REPO_ROOT_REAL="$(cd "${REPO_ROOT}" && pwd -P)"
if [[ -n "${MACSCOPE_TEST_DERIVED_DATA:-}" ]]; then
  TEST_DERIVED_DATA="${MACSCOPE_TEST_DERIVED_DATA}"
else
  WORKTREE_ID="$(
    python3 -c \
      'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:16])' \
      "${REPO_ROOT_REAL}"
  )"
  TEST_DERIVED_DATA="${HOME:-/private/tmp}/Library/Developer/Xcode/DerivedData/MacScopeFocusedTests-${WORKTREE_ID}"
fi

if [[ "${TEST_DERIVED_DATA}" != /* ]]; then
  echo "ERROR: MACSCOPE_TEST_DERIVED_DATA must be an absolute path outside the repository." >&2
  exit 1
fi

case "${TEST_DERIVED_DATA}/" in
  "${REPO_ROOT}/"* | "${REPO_ROOT_REAL}/"*)
    echo "ERROR: test DerivedData must remain outside the repository: ${TEST_DERIVED_DATA}" >&2
    exit 1
    ;;
esac

# Resolve existing symlinks before creating the destination. This closes the
# less-obvious case where an apparently external override traverses a symlink
# back into the repository and would otherwise create build output there before
# the containment check ran.
TEST_DERIVED_DATA="$(
  python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "${TEST_DERIVED_DATA}"
)"
case "${TEST_DERIVED_DATA}/" in
  "${REPO_ROOT_REAL}/"*)
    echo "ERROR: test DerivedData must remain outside the repository: ${TEST_DERIVED_DATA}" >&2
    exit 1
    ;;
esac
mkdir -p "${TEST_DERIVED_DATA}"
TEST_DERIVED_DATA="$(cd "${TEST_DERIVED_DATA}" && pwd -P)"

GHOSTTY_SURFACE_WORK_ROOT="${MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT:-${TEST_DERIVED_DATA}/Dependencies/GhosttySurface}"
if [[ "${GHOSTTY_SURFACE_WORK_ROOT}" != /* ]]; then
  echo "ERROR: MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT must be an absolute external path." >&2
  exit 1
fi
GHOSTTY_SURFACE_WORK_ROOT="$(
  /usr/bin/python3 -B -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' \
    "${GHOSTTY_SURFACE_WORK_ROOT}"
)"
export MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT="${GHOSTTY_SURFACE_WORK_ROOT}"

# The repository SLEIGH component also carries licenses, provenance, and an
# independently governed AArch64 record. Publish only its strict runtime closure
# to an external root unless the caller supplied an explicit diagnostic
# materialization override.
if [[ -z "${MACSCOPE_SLEIGH_MATERIALIZATION_ROOT:-}" ]]; then
  SLEIGH_COMPONENT_ROOT="${MACSCOPE_SLEIGH_COMPONENT_ROOT:-${REPO_ROOT}/ThirdParty/SleighNative}"
  SLEIGH_WORK_ROOT="${MACSCOPE_SLEIGH_MATERIALIZATION_WORK_ROOT:-${TEST_DERIVED_DATA}/Dependencies/SleighNative}"
  SLEIGH_PREPARATION="$(
    /usr/bin/python3 -B \
      "${SCRIPT_DIR}/native-decompiler-xpc/prepare_repository_sleigh_materialization.py" \
      --component-root "${SLEIGH_COMPONENT_ROOT}" \
      --work-root "${SLEIGH_WORK_ROOT}"
  )"
  case "${SLEIGH_PREPARATION}" in
    MACSCOPE_SLEIGH_MATERIALIZATION_ROOT=*)
      MACSCOPE_SLEIGH_MATERIALIZATION_ROOT="${SLEIGH_PREPARATION#MACSCOPE_SLEIGH_MATERIALIZATION_ROOT=}"
      ;;
    *)
      echo "ERROR: SLEIGH repository materialization producer returned an invalid result." >&2
      exit 1
      ;;
  esac
fi
if [[ "${MACSCOPE_SLEIGH_MATERIALIZATION_ROOT}" != /* ]]; then
  echo "ERROR: MACSCOPE_SLEIGH_MATERIALIZATION_ROOT must be an absolute path." >&2
  exit 1
fi
export MACSCOPE_SLEIGH_MATERIALIZATION_ROOT

# Publish the tracked MachOKit closure into the same external dependency area.
# The repository tree is an immutable source authority; only the strictly
# verified read-only view may become SwiftPM's local-package input.
if [[ -z "${MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT:-}" ]]; then
  MACHOKIT_WORK_ROOT="${MACSCOPE_MACHOKIT_MATERIALIZATION_WORK_ROOT:-${TEST_DERIVED_DATA}/Dependencies/MachOKit}"
  if ! MACHOKIT_PREPARATION="$(
    /usr/bin/python3 -B "${SCRIPT_DIR}/machokit_source_identity.py" \
      publish-read-only \
      --source-root "${REPO_ROOT}/ThirdParty/MachOKit/materialization" \
      --work-root "${MACHOKIT_WORK_ROOT}" \
      --quiet
  )"
  then
    echo "ERROR: repository MachOKit read-only view publication failed." >&2
    exit 1
  fi
  case "${MACHOKIT_PREPARATION}" in
    MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT=*)
      MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT="${MACHOKIT_PREPARATION#MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT=}"
      ;;
    *)
      echo "ERROR: repository MachOKit publisher returned an invalid result." >&2
      exit 1
      ;;
  esac
fi
if [[ "${MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT}" != /* ]]; then
  echo "ERROR: MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT must be an absolute path." >&2
  exit 1
fi
export MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT

# Command-line settings keep generated native outputs and explicit diagnostic
# overrides authoritative across the bootstrap/Xcode boundary.
XCODEBUILD_INPUT_SETTINGS=()
XCODEBUILD_INPUT_SETTINGS+=("MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT=${MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT}")
XCODEBUILD_INPUT_SETTINGS+=("MACSCOPE_SLEIGH_MATERIALIZATION_ROOT=${MACSCOPE_SLEIGH_MATERIALIZATION_ROOT}")
XCODEBUILD_INPUT_SETTINGS+=("MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT=${MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT}")

# ── Step 1: Always bootstrap (regenerate the Xcode project) ──────────────────
echo "==> Running bootstrap ..."
"${SCRIPT_DIR}/bootstrap.sh"

# ── Step 2: Run xcodebuild test ───────────────────────────────────────────────
echo ""
echo "==> Running tests: -only-testing:${ONLY_TESTING}"
echo "    DerivedData: ${TEST_DERIVED_DATA} (isolated from Xcode)"
xcodebuild \
  -project "${XCODEPROJ}" \
  -scheme MacScopeApp \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "${TEST_DERIVED_DATA}" \
  -only-testing:"${ONLY_TESTING}" \
  "${XCODEBUILD_INPUT_SETTINGS[@]}" \
  COMPILER_INDEX_STORE_ENABLE=NO \
  test

echo ""
echo "==> Tests complete."
