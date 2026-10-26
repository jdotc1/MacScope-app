#!/usr/bin/env bash
# Build stations (decision D12, docs: BUILD-STATIONS.md): warm worktrees that
# lanes claim for builds and focused test runs instead of creating new
# worktrees with cold DerivedData.
#
# usage: Scripts/station.sh claim STATION [--owner NAME] [--branch BRANCH]
#        Scripts/station.sh release STATION [--owner NAME] [--force]
#        Scripts/station.sh sync [STATION]
#        Scripts/station.sh list
#        Scripts/station.sh pre-pr [STATION]   (refuse a stray ThirdParty/* gitlink change)
#
# STATION is a configured name (default: S1) or a station path. A claim is the file
# <station>/.station-claim (owner, branch, time, pid), written under
# flock(LOCK_EX) so two claimants never both win; release removes it.
# Claiming does not switch branches: after a claim, run
#   git -C <station> switch <branch> && <station>/Scripts/dev_loop.sh ...
# sync (also run by claim, and by dev_loop.sh before every build) aligns
# ThirdParty/Lumen with the checked-out gitlink, because `git switch` never
# moves a submodule. Aligned: two rev-parses. Stale or uninitialised: the
# offline first-party materializer moves/fills it from the local Lumen seed
# (Xcode's .swiftpm/.build state is regenerable); real local changes are kept
# and reported. Prints one line; never fails the caller. Default STATION: the
# worktree this script is in.
# No manual Scripts/bootstrap.sh is needed after a merge that adds, removes or
# renames source files: dev_loop.sh's generated-project freshness contract
# binds the folder-source path list and regenerates the project itself.
#
# Environment:
#   MACSCOPE_STATIONS     space-separated NAME=PATH list overriding the pool.
#   MACSCOPE_LUMEN_SEED   local Lumen seed repository (default: Lumen beside the work root)
#   MACSCOPE_LUMEN_SYNC=0 skip the Lumen sync (e.g. a deliberate local Lumen).
# Exit status: 0 ok, 3 already claimed by someone else, 2 usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/work_root.sh
source "${SCRIPT_DIR}/lib/work_root.sh"
WORK_ROOT_DIR="$(macscope_work_root)"

if [[ -z "${MACSCOPE_STATIONS:-}" && "${WORK_ROOT_DIR}" =~ [[:space:]] ]]; then
  echo "ERROR: station work root must not contain whitespace for the default pool" >&2
  exit 2
fi

DEFAULT_STATIONS="S1=$(cd "${SCRIPT_DIR}/.." && pwd -P)"
STATIONS="${MACSCOPE_STATIONS:-${DEFAULT_STATIONS}}"

# The pool is a whitespace-separated NAME=PATH format, not a shell expression.
# Refuse detached path fragments before either reader can select a wrong root.
/usr/bin/python3 -B - "${STATIONS}" <<'PYPOOL'
import sys
items = sys.argv[1].split()
if not items or any("=" not in item or not all(item.split("=", 1))
                    for item in items):
    print("ERROR: station pool requires whitespace-separated NAME=PATH entries; paths cannot contain whitespace", file=sys.stderr)
    raise SystemExit(2)
PYPOOL

usage() {
  /usr/bin/sed -n '2,29p' "${BASH_SOURCE[0]}" | /usr/bin/sed 's/^# \{0,1\}//'
}

station_path() {
  local item
  for item in ${STATIONS}; do
    if [[ "${item%%=*}" == "$1" ]]; then
      printf '%s\n' "${item#*=}"
      return
    fi
  done
  printf '%s\n' "$1"
}

sync_lumen() {
  local root="$1" seed="${MACSCOPE_LUMEN_SEED:-$(dirname "${WORK_ROOT_DIR}")/Lumen}" pin current="" output
  if [[ "${MACSCOPE_LUMEN_SYNC:-1}" == 0 ]]; then
    echo "lumen: sync skipped (MACSCOPE_LUMEN_SYNC=0)"
    return 0
  fi
  if ! pin="$(/usr/bin/git -C "${root}" rev-parse -q --verify 'HEAD:ThirdParty/Lumen' 2>/dev/null)"; then
    echo "lumen: no ThirdParty/Lumen gitlink at ${root} HEAD; nothing to sync"
    return 0
  fi
  # Without its own .git, rev-parse inside ThirdParty/Lumen would answer for
  # the superproject; treat that as uninitialised.
  if [[ -e "${root}/ThirdParty/Lumen/.git" ]]; then
    current="$(/usr/bin/git -C "${root}/ThirdParty/Lumen" rev-parse -q --verify HEAD 2>/dev/null || true)"
  fi
  if [[ "${current}" == "${pin}" ]]; then
    echo "lumen: ThirdParty/Lumen already at gitlink ${pin:0:7}"
    return 0
  fi
  local from="${current:0:7}" removed=""
  [[ -n "${current}" ]] || from="uninitialised"
  if output="$(/usr/bin/python3 -B "${SCRIPT_DIR}/dependencies/materialize_lumen_submodule.py" \
      --source-root "${root}" --seed-repository "${seed}" 2>&1)"; then
    [[ "${output}" != *'"removed_regenerable"'* ]] || removed=", removed Xcode .swiftpm/.build state"
    echo "lumen: ThirdParty/Lumen ${from} -> gitlink ${pin:0:7} (offline from ${seed}${removed})"
  else
    echo "lumen: WARNING ThirdParty/Lumen is ${from} but the gitlink is ${pin:0:7}; left as is: ${output##*ERROR: }" >&2
  fi
  return 0
}

COMMAND="${1:-}"
[[ $# -gt 0 ]] && shift
STATION=""
if [[ "${COMMAND}" == claim || "${COMMAND}" == release ]]; then
  STATION="${1:-}"
  [[ $# -gt 0 ]] && shift
  if [[ -z "${STATION}" ]]; then
    usage >&2
    exit 2
  fi
elif [[ ( "${COMMAND}" == sync || "${COMMAND}" == pre-pr ) && $# -gt 0 && "$1" != -* ]]; then
  STATION="$1"
  shift
fi
OWNER="${USER:-unknown}"
BRANCH=""
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner) OWNER="${2:?missing value for --owner}"; shift 2 ;;
    --branch) BRANCH="${2:?missing value for --branch}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
case "${COMMAND}" in
  claim|release|list) ;;
  sync)
    SYNC_ROOT="$(station_path "${STATION:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}")"
    if [[ ! -e "${SYNC_ROOT}/.git" ]]; then
      echo "ERROR: ${SYNC_ROOT} is not a Git worktree station" >&2
      exit 2
    fi
    sync_lumen "${SYNC_ROOT}"
    exit 0
    ;;
  pre-pr)
    PR_ROOT="$(station_path "${STATION:-$(cd "${SCRIPT_DIR}/.." && pwd -P)}")"
    exec /usr/bin/python3 -B "${SCRIPT_DIR}/check_pin_changes.py" --repo "${PR_ROOT}"
    ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

STATUS=0
/usr/bin/python3 -B - "${COMMAND}" "${STATION}" "${OWNER}" "${BRANCH}" "${FORCE}" "${STATIONS}" "${PPID}" \
    <<'PY' || STATUS=$?
from __future__ import annotations

import datetime
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys

command, station, owner, branch, force, pool_text, claimant = sys.argv[1:]
pool = {}
for item in pool_text.split():
    name, _, path = item.partition("=")
    if name and path:
        pool[name] = Path(path)


def resolve(value: str) -> tuple[str, Path]:
    if value in pool:
        return value, pool[value]
    path = Path(value).expanduser().resolve()
    name = next((key for key, known in pool.items() if known.resolve() == path), path.name)
    return name, path


def current_branch(path: Path) -> str:
    result = subprocess.run(["/usr/bin/git", "-C", str(path), "branch", "--show-current"],
                            capture_output=True, text=True, check=False)
    return result.stdout.strip() if result.returncode == 0 else "?"


def read_claim(path: Path) -> dict | None:
    try:
        text = (path / ".station-claim").read_text(encoding="utf-8")
    except FileNotFoundError:
        return None
    try:
        value = json.loads(text) if text.strip() else None
    except ValueError:
        return {"owner": "?", "note": "unreadable claim"}
    return value if isinstance(value, dict) else None


def locked_claim_file(path: Path):
    descriptor = os.open(path / ".station-claim", os.O_RDWR | os.O_CREAT, 0o644)
    fcntl.flock(descriptor, fcntl.LOCK_EX)
    return descriptor


if command == "list":
    for name, path in pool.items():
        if not path.is_dir():
            print(f"{name:4} {path}  (missing)")
            continue
        claim = read_claim(path)
        state = "free" if claim is None else (
            f"claimed by {claim.get('owner')} for {claim.get('branch') or '-'} since {claim.get('time')}")
        print(f"{name:4} {path}  [{current_branch(path)}]  {state}")
    raise SystemExit(0)

name, path = resolve(station)
if not (path / ".git").exists():
    print(f"ERROR: {path} is not a Git worktree station", file=sys.stderr)
    raise SystemExit(2)
descriptor = locked_claim_file(path)
try:
    raw = os.read(descriptor, 65536).decode("utf-8", errors="replace")
    try:
        existing = json.loads(raw) if raw.strip() else None
    except ValueError:
        existing = {"owner": "?"}
    if command == "claim":
        if existing is not None and existing.get("owner") != owner:
            print(f"station {name} is claimed by {existing.get('owner')} for "
                  f"{existing.get('branch') or '-'} since {existing.get('time')}", file=sys.stderr)
            raise SystemExit(3)
        record = {"owner": owner, "branch": branch or current_branch(path),
                  "time": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
                  "pid": int(claimant), "station": name}
        os.ftruncate(descriptor, 0)
        os.pwrite(descriptor, (json.dumps(record, sort_keys=True) + "\n").encode(), 0)
        print(f"claimed {name} {path}")
        print(f"next: git -C {path} switch <branch> && {path}/Scripts/dev_loop.sh <selectors>")
    else:
        if existing is not None and existing.get("owner") != owner and force != "1":
            print(f"station {name} is claimed by {existing.get('owner')}; use --force to release it",
                  file=sys.stderr)
            raise SystemExit(3)
        (path / ".station-claim").unlink()
        print(f"released {name} {path}")
finally:
    os.close(descriptor)
PY
if [[ "${COMMAND}" == claim && "${STATUS}" == 0 ]]; then
  # A station keeps whatever Lumen checkout its last lane built; align it now.
  sync_lumen "$(station_path "${STATION}")"
fi
exit "${STATUS}"
