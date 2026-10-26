#!/usr/bin/env bash
set -euo pipefail
if [[ $# != 3 ]]; then echo 'Usage: measure.sh <repo-dir> <dump-path> <out-dir>' >&2; exit 2; fi
repo=$(cd "$1" && pwd)
baseline=$(realpath "$2")
if [[ -e "$3" ]] && [[ ! -d "$3" || -n "$(find "$3" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "Refuse to overwrite retained measurement evidence: $3" >&2
    exit 2
fi
mkdir -p "$3"
out=$(cd "$3" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
export PORTABLE_REPO="$repo"
export PORTABLE_RECEIPT_DIR="$out/receipts"
: "${PORTABLE_PIN:?Set PORTABLE_PIN to the admitted source-tree revision}"
: "${PORTABLE_METRIC:?Set PORTABLE_METRIC to this calibration metric name}"
: "${PORTABLE_BINARY:?Set PORTABLE_BINARY to the witness binary}"
mkdir -p "$out/rerender" "$out/receipts"
"$here/build.sh" 2>&1 | tee "$out/receipts/build.txt"
"$here/render-all" "$PORTABLE_BINARY" "$out/rerender/pseudocode-all.txt" 2>&1 | tee "$out/receipts/render.txt"
python3 "$here/compare.py" "$baseline" "$out/rerender/pseudocode-all.txt" "$out" --pin "$PORTABLE_PIN" --metric "$PORTABLE_METRIC"
