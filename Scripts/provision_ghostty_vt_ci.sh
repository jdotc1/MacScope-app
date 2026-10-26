#!/usr/bin/env bash
# Compatibility shim. Explicit dependency acquisition lives under Scripts/dependencies/.
# Callers export MACSCOPE_GHOSTTY_ZIG_PACKAGE_STORE_SOURCE for a cache-miss
# materialization; exec preserves that independently verified seed unchanged.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/dependencies/materialize_ghostty_vt.sh" "$@"
