#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
: "${PORTABLE_BUILD_PATH:=$here/.build}"
export SWIFTCI_USE_LOCAL_DEPS=1
export SWIFT_MODULECACHE_PATH="$PORTABLE_BUILD_PATH/module-cache"
export CLANG_MODULE_CACHE_PATH="$PORTABLE_BUILD_PATH/clang-cache"
mkdir -p "$SWIFT_MODULECACHE_PATH" "$CLANG_MODULE_CACHE_PATH" "$PORTABLE_BUILD_PATH/cache" "$PORTABLE_BUILD_PATH/config" "$PORTABLE_BUILD_PATH/security"
repo=${PORTABLE_REPO:-$(cd "$here/../.." && pwd)}
receipt_dir=${PORTABLE_RECEIPT_DIR:-$PORTABLE_BUILD_PATH/receipts}
mkdir -p "$receipt_dir"
receipt_tag=$(python3 -c 'import uuid; print(uuid.uuid4().hex)')
python3 "$here/prepare.py" --repo "$repo" --receipt "$receipt_dir/sources-$receipt_tag.json"
"${SWIFT:-swift}" build --package-path "$here" --scratch-path "$PORTABLE_BUILD_PATH" --cache-path "$PORTABLE_BUILD_PATH/cache" --config-path "$PORTABLE_BUILD_PATH/config" --security-path "$PORTABLE_BUILD_PATH/security" -j "${PORTABLE_JOBS:-4}" "$@"

python3 "$here/stage_resources.py" --repo "$repo" --executable "$PORTABLE_BUILD_PATH/debug/render-all" --receipt "$receipt_dir/resources-$receipt_tag.json"
