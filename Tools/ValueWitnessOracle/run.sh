#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
exec "${OUT:-$root/build}/vwo" "$@"
