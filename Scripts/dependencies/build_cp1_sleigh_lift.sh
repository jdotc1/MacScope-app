#!/bin/bash
# Build the CP1 SME checkpoint test frontend against the governed SLEIGH package.
# Test tooling only; no library rebuild, network access or repository output.
#
# build_cp1_sleigh_lift.sh [--out /absolute/external/cache]
#
# Reuse binds committed frontend/build inputs, the existing dependency receipt
# and the selected frontend compiler/SDK. It never rehashes the library.
# A cache miss compiles once and records RECEIPT.json beside the executable.
# Prints only the executable path, for export as CP1_SLEIGH_LIFT.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec /usr/bin/python3 -B "${script_dir}/cp1_frontend_cache.py" "$@"
