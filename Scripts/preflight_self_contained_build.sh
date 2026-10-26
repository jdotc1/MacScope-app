#!/usr/bin/env bash
# Run the single build-free, offline gate before any Xcode command.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="${DEFAULT_REPO_ROOT}"
WORK_ROOT="${TMPDIR:-/tmp}/MacScope/self-contained-preflight"

usage() {
  cat >&2 <<'EOF'
usage: preflight_self_contained_build.sh [--repo-root ABSOLUTE_PATH] --work-root ABSOLUTE_PATH

Runs the repository's build-free dependency, governance, source, package, and
project contracts exactly once. All logs are written below --work-root.
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)
      [[ $# -ge 2 ]] || usage
      REPO_ROOT="$2"
      shift 2
      ;;
    --work-root)
      [[ $# -ge 2 ]] || usage
      WORK_ROOT="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *) usage ;;
  esac
done

ROOTS="$(/usr/bin/python3 -B - "$REPO_ROOT" "$WORK_ROOT" <<'PY'
from pathlib import Path
import sys

repo = Path(sys.argv[1])
work = Path(sys.argv[2])
if not repo.is_absolute() or not work.is_absolute():
    raise SystemExit("repository and work roots must be absolute paths")
repo = repo.resolve(strict=True)
work_resolved = work.resolve(strict=False)
if work_resolved in (Path("/"), repo) or repo in work_resolved.parents:
    raise SystemExit("preflight work root must remain outside the repository")
if work.exists() and work.is_symlink():
    raise SystemExit("preflight work root must not be a symbolic link")
print(f"{repo}\n{work_resolved}")
PY
)"
REPO_ROOT="$(sed -n '1p' <<<"${ROOTS}")"
WORK_ROOT="$(sed -n '2p' <<<"${ROOTS}")"
/bin/mkdir -p "${WORK_ROOT}"
LOG_FILE="${WORK_ROOT}/preflight.log"
: >"${LOG_FILE}"

run_stage() {
  local name="$1"
  shift
  echo "[preflight] ${name}"
  {
    echo "=== ${name} ==="
    echo "command: $*"
    "$@"
  } >>"${LOG_FILE}" 2>&1 || {
    echo "ERROR: preflight stage failed: ${name}" >&2
    echo "       See ${LOG_FILE}" >&2
    exit 1
  }
}

PYTHON=(/usr/bin/python3 -B)
SCRIPTS="${REPO_ROOT}/Scripts"

run_stage dependency-policy \
  "${PYTHON[@]}" "${SCRIPTS}/dependencies/validate_policy_consistency.py" \
  --repo-root "${REPO_ROOT}"
run_stage third-party-inventory \
  "${PYTHON[@]}" "${SCRIPTS}/dependencies/validate_third_party_components.py" \
  --repo-root "${REPO_ROOT}"
run_stage offline-build-surface \
  "${PYTHON[@]}" "${SCRIPTS}/dependencies/validate_offline_build_surface.py" \
  --repo-root "${REPO_ROOT}"
run_stage signing-and-project-policy \
  "${PYTHON[@]}" "${SCRIPTS}/check_local_signing_policy.py" \
  --project-yml "${REPO_ROOT}/MacScope/project.yml" \
  --ci-yml "${REPO_ROOT}/.github/workflows/ci.yml" \
  --signing-identity-xcconfig "${REPO_ROOT}/MacScope/SigningIdentity.xcconfig" \
  --dependency-roots-xcconfig "${REPO_ROOT}/MacScope/DependencyRoots.xcconfig"
run_stage ghostty-vt-source-and-package \
  /bin/bash "${REPO_ROOT}/Scripts/build_ghostty_vt.sh" \
  --work-root "${WORK_ROOT}/GhosttyVT" --verify-inputs-only
run_stage ghostty-surface-source-and-package \
  /bin/bash "${SCRIPTS}/dependencies/build_vendored_ghostty_surface.sh" \
  --work-root "${WORK_ROOT}/GhosttySurface" --verify-inputs-only
run_stage sleigh-source-and-package \
  "${PYTHON[@]}" "${SCRIPTS}/native-decompiler-xpc/prepare_repository_sleigh_materialization.py" \
  --component-root "${REPO_ROOT}/ThirdParty/SleighNative" \
  --work-root "${WORK_ROOT}/SleighNative"
run_stage machokit-source-and-package \
  "${PYTHON[@]}" "${SCRIPTS}/machokit_source_identity.py" publish-read-only \
  --source-root "${REPO_ROOT}/ThirdParty/MachOKit/materialization" \
  --work-root "${WORK_ROOT}/MachOKit" --quiet
run_stage ghostty-project-contract \
  "${PYTHON[@]}" -m unittest -q Scripts.tests.test_ghostty_surface_project_contract

echo "[preflight] PASS (9 stages); log: ${LOG_FILE}"
