#!/usr/bin/env bash
# Measure one cold and one immediate null Debug build without changing build policy.

set -euo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORK_ROOT=""
OUTPUT="${REPOSITORY_ROOT}/docs/perf/BUILD_ECONOMICS.json"

usage() {
  echo "usage: measure_build_economics.sh --work-root PATH [--output PATH]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --work-root) WORK_ROOT="${2:?missing --work-root value}"; shift 2 ;;
    --output) OUTPUT="${2:?missing --output value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "${WORK_ROOT}" ]]; then
  echo "ERROR: --work-root is required" >&2
  exit 2
fi
if [[ "${WORK_ROOT}" != /* ]]; then
  echo "ERROR: --work-root must be an absolute path outside the repository" >&2
  exit 2
fi
REPOSITORY_ROOT_REAL="$(cd "${REPOSITORY_ROOT}" && /bin/pwd -P)"
WORK_ROOT_REAL="$(/usr/bin/python3 - "${WORK_ROOT}" "${REPOSITORY_ROOT_REAL}" <<'PY'
from pathlib import Path
import sys

candidate = Path(sys.argv[1]).resolve(strict=False)
repository = Path(sys.argv[2]).resolve(strict=True)
if candidate == repository or repository in candidate.parents:
    raise SystemExit("ERROR: --work-root must remain outside the repository")
print(candidate)
PY
)"
if [[ "${WORK_ROOT_REAL}" == "${REPOSITORY_ROOT_REAL}"/* ]]; then
  echo "ERROR: --work-root must remain outside the repository" >&2
  exit 2
fi
canonical_dependency_root() {
  local variable_name="$1"
  local variable_value="${!variable_name:-}"
  if [[ -z "${variable_value}" || ! -d "${variable_value}" ]]; then
    echo "ERROR: ${variable_name} must name an existing verified dependency root" >&2
    exit 2
  fi
  if [[ "${variable_value}" != /* ]]; then
    echo "ERROR: ${variable_name} must be an absolute path" >&2
    exit 2
  fi
  (cd "${variable_value}" && /bin/pwd -P)
}

GHOSTTY_SURFACE_WORK_ROOT="$(canonical_dependency_root MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT)"
SLEIGH_MATERIALIZATION_ROOT="$(canonical_dependency_root MACSCOPE_SLEIGH_MATERIALIZATION_ROOT)"
MACHOKIT_MATERIALIZATION_ROOT="$(canonical_dependency_root MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT)"
GHOSTTY_SURFACE_SOURCE_DIR="${GHOSTTY_SURFACE_WORK_ROOT}/GhosttySurface"
GHOSTTY_SURFACE_ARTIFACT_ROOT="${GHOSTTY_SURFACE_SOURCE_DIR}/macos/GhosttyKit.xcframework"
GHOSTTY_SURFACE_FRAMEWORK="${GHOSTTY_SURFACE_ARTIFACT_ROOT}/macos-arm64/libghostty-internal.a"
for required_path in \
  "${GHOSTTY_SURFACE_SOURCE_DIR}" \
  "${GHOSTTY_SURFACE_ARTIFACT_ROOT}" \
  "${GHOSTTY_SURFACE_ARTIFACT_ROOT}/macos-arm64/Headers/ghostty.h" \
  "${GHOSTTY_SURFACE_ARTIFACT_ROOT}/macos-arm64/Headers/module.modulemap" \
  "${GHOSTTY_SURFACE_FRAMEWORK}" \
  "${SLEIGH_MATERIALIZATION_ROOT}/MATERIALIZATION.json" \
  "${MACHOKIT_MATERIALIZATION_ROOT}/MATERIALIZATION.json"
do
  if [[ ! -e "${required_path}" ]]; then
    echo "ERROR: validated dependency input is missing: ${required_path}" >&2
    exit 2
  fi
done
if [[ ! -d "${REPOSITORY_ROOT}/MacScope/MacScope.xcodeproj" ]]; then
  echo "ERROR: bootstrap the project with ./Scripts/bootstrap.sh before measuring" >&2
  exit 2
fi

/bin/mkdir -p "${WORK_ROOT_REAL}"
RUN_ROOT="$(/usr/bin/mktemp -d "${WORK_ROOT_REAL%/}/run.XXXXXX")"
DERIVED_DATA="${RUN_ROOT}/DerivedData"
COLD_LOG="${RUN_ROOT}/cold-build.log"
NULL_LOG="${RUN_ROOT}/null-build.log"

XCODEBUILD=(
  /usr/bin/xcodebuild
  -project "${REPOSITORY_ROOT}/MacScope/MacScope.xcodeproj"
  -scheme MacScopeApp
  -configuration Debug
  -destination 'platform=macOS,arch=arm64'
  -derivedDataPath "${DERIVED_DATA}"
  -disableAutomaticPackageResolution
  -showBuildTimingSummary
  "MACSCOPE_GHOSTTY_SURFACE_WORK_ROOT=${GHOSTTY_SURFACE_WORK_ROOT}"
  "MACSCOPE_GHOSTTY_SURFACE_SOURCE_DIR=${GHOSTTY_SURFACE_SOURCE_DIR}"
  "MACSCOPE_GHOSTTY_SURFACE_ARTIFACT_ROOT=${GHOSTTY_SURFACE_ARTIFACT_ROOT}"
  "MACSCOPE_GHOSTTY_SURFACE_FRAMEWORK=${GHOSTTY_SURFACE_FRAMEWORK}"
  "MACSCOPE_SLEIGH_MATERIALIZATION_ROOT=${SLEIGH_MATERIALIZATION_ROOT}"
  "MACSCOPE_MACHOKIT_MATERIALIZATION_ROOT=${MACHOKIT_MATERIALIZATION_ROOT}"
  COMPILER_INDEX_STORE_ENABLE=NO
  build
)

measure() {
  local log_path="$1"
  local start_ns end_ns status
  start_ns="$(/usr/bin/python3 -c 'import time; print(time.time_ns())')"
  set +e
  "${XCODEBUILD[@]}" 2>&1 | /usr/bin/tee "${log_path}" >&2
  status="${PIPESTATUS[0]}"
  set -e
  end_ns="$(/usr/bin/python3 -c 'import time; print(time.time_ns())')"
  if [[ "${status}" -ne 0 ]]; then
    echo "ERROR: measured xcodebuild failed with status ${status}; log: ${log_path}" >&2
    exit "${status}"
  fi
  /usr/bin/python3 - "${start_ns}" "${end_ns}" <<'PY'
import sys
print(f"{(int(sys.argv[2]) - int(sys.argv[1])) / 1_000_000_000:.3f}")
PY
}

COLD_SECONDS="$(measure "${COLD_LOG}")"
NULL_SECONDS="$(measure "${NULL_LOG}")"
MEASURED_AT_UTC="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"

/usr/bin/python3 -B "${SCRIPT_DIR}/build_economics.py" \
  --repository-root "${REPOSITORY_ROOT}" \
  --project-yml "${REPOSITORY_ROOT}/MacScope/project.yml" \
  --cold-log "${COLD_LOG}" \
  --null-log "${NULL_LOG}" \
  --cold-seconds "${COLD_SECONDS}" \
  --null-seconds "${NULL_SECONDS}" \
  --measured-at-utc "${MEASURED_AT_UTC}" \
  --output "${OUTPUT}"

echo "MACSCOPE_BUILD_ECONOMICS_RECEIPT=${OUTPUT}"
echo "MACSCOPE_BUILD_ECONOMICS_RUN_ROOT=${RUN_ROOT}"
