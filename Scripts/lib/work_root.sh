# Shared helper: resolve the MacScope work root.
#
# The work root is the folder that holds MacScope caches, lanes and evidence
# (dev-loop output, qualification caches, heavy-gate lock, lane checkouts).
# Resolution order:
#   1. MACSCOPE_WORK_ROOT in the environment.
#   2. MACSCOPE_WORK_ROOT=... in a gitignored .env.local at the repository root.
#   3. The parent directory of the main checkout (same answer from every worktree).
#
# Usage:  source "<repo>/Scripts/lib/work_root.sh"; WORK_ROOT="$(macscope_work_root)"
# zsh callers (no BASH_SOURCE) pass the repository root: macscope_work_root "$REPO_ROOT"

macscope_work_root() {
  local value="" here repo env_file common main_checkout
  if [ -n "${MACSCOPE_WORK_ROOT:-}" ]; then
    value="${MACSCOPE_WORK_ROOT}"
  else
    if [ -n "${1:-}" ]; then
      repo="$(cd "$1" && pwd -P)" || return 1
    else
      here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)" || return 1
      repo="$(cd "${here}/../.." && pwd -P)" || return 1
    fi
    env_file="${repo}/.env.local"
    if [ -f "${env_file}" ]; then
      value="$(sed -n 's/^[[:space:]]*MACSCOPE_WORK_ROOT=//p' "${env_file}" | tail -n 1)"
      value="${value%\"}"; value="${value#\"}"
      value="${value%\'}"; value="${value#\'}"
    fi
    if [ -z "${value}" ]; then
      common="$(git -C "${repo}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""
      if [ -n "${common}" ]; then
        main_checkout="$(dirname "${common}")"
        value="$(dirname "${main_checkout}")"
      fi
    fi
  fi
  if [ -z "${value}" ]; then
    echo "macscope_work_root: cannot resolve the work root; set MACSCOPE_WORK_ROOT" >&2
    return 1
  fi
  while [ "${#value}" -gt 1 ] && [ "${value%/}" != "${value}" ]; do value="${value%/}"; done
  printf '%s\n' "${value}"
}
