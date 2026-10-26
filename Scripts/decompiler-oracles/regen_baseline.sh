#!/usr/bin/env bash
# Regenerate the decompiler corpus baseline sweep from a MacScope build.
#
# The baseline is DERIVED DATA (per-function pseudocode + fallback/goto/__unknown enrichment
# for the 4-binary corpus) — ~11 MB, regenerable, so it is NEVER committed. Track this script;
# regenerate the data on demand. A driver runs this on the pristine pre-merge tree to get the
# "before" side of an additivity/structuring differential.
#
# Usage:
#   regen_baseline.sh <out-dir> [--binary <prebuilt MacScope exe>] [--derived <dir>] [corpus...]
#
#   --binary   use an already-built MacScope executable (skips xcodebuild — fast path for a driver
#              that just built the candidate). Point at .../MacScope.app/Contents/MacOS/MacScope.
#   --derived  derivedDataPath for the xcodebuild fallback (default: a temp dir).
#   corpus     override the default 4 binaries (/bin/ls /usr/bin/grep /usr/bin/ssh /bin/zsh).
#
# Prints the aggregate __unknown / fallback totals so a human can eyeball drift vs the last run.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

OUT= BIN= DERIVED= ; CORPUS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --binary)  BIN=${2:?}; shift 2;;
    --derived) DERIVED=${2:?}; shift 2;;
    -h|--help) sed -n '2,20p' "$0"; exit 0;;
    -*)        echo "unknown flag: $1" >&2; exit 2;;
    *)         if [ -z "$OUT" ]; then OUT="$1"; else CORPUS+=("$1"); fi; shift;;
  esac
done
[ -n "$OUT" ] || { echo "usage: regen_baseline.sh <out-dir> [--binary EXE] [--derived DIR] [corpus...]" >&2; exit 2; }
mkdir -p "$OUT"

if [ -z "$BIN" ]; then
  DERIVED="${DERIVED:-$(mktemp -d)/dd}"
  echo "regen_baseline: building MacScope (derivedData=$DERIVED) ..." >&2
  /usr/bin/python3 -B "$REPO/Scripts/generate_xcode_json_project.py" --source "$REPO/MacScope"
  xcodebuild -project "$REPO/MacScope/MacScope.xcodeproj" -scheme MacScopeApp \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" build >/dev/null
  BIN="$DERIVED/Build/Products/Debug/MacScope.app/Contents/MacOS/MacScope"
fi
[ -x "$BIN" ] || { echo "MacScope executable not found/executable: $BIN" >&2; exit 1; }

echo "regen_baseline: sweeping with $BIN" >&2
# macOS ships bash 3.2, where `"${CORPUS[@]}"` on an EMPTY array is an unbound-variable error
# under `set -u` — i.e. the default no-corpus-override path aborted after the (slow) build.
# Expand only when non-empty; sweep.py falls back to its own 4-binary default corpus.
if [ ${#CORPUS[@]} -gt 0 ]; then
  python3 "$HERE/sweep.py" "$BIN" "$OUT" "${CORPUS[@]}"
else
  python3 "$HERE/sweep.py" "$BIN" "$OUT"
fi

# Eyeball totals + REFUSE degenerate data (the "silent degenerate baseline" failure class):
# if every function's fallback is empty, the RegionTree diagnostics were not captured — the
# binary is stale/lacks instrumentation, or the env var didn't take. A structuring differential
# against such a baseline would silently pass everything. Fail loudly instead.
python3 - "$OUT" <<'PY'
import json, os, sys, glob
out = sys.argv[1]
tot_unk = tot_fn = 0
fb = {}
for f in sorted(glob.glob(os.path.join(out, "*.json"))):
    if os.path.basename(f).startswith("_"):
        continue
    for r in json.load(open(f)):
        tot_fn += 1
        tot_unk += r.get("unknowns", 0)
        fb[r.get("fallback", "?") or "<empty>"] = fb.get(r.get("fallback", "?") or "<empty>", 0) + 1
print(f"baseline: {tot_fn} functions, {tot_unk} __unknown sites, fallback={fb}")
if tot_fn == 0:
    sys.exit("FATAL: swept 0 functions — build/run failed")
real = sum(v for k, v in fb.items() if k not in ("<empty>", "?"))
if real == 0:
    sys.exit("FATAL: every function has empty fallback — RegionTree diagnostics NOT captured "
             "(binary predates the instrumentation, or MACSCOPE_REGIONTREE_DIAGNOSTICS did not "
             "take). This baseline is degenerate; do NOT use it for a differential.")
PY
echo "regen_baseline: wrote $OUT (data is gitignored/ephemeral by design)"
