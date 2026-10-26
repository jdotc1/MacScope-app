#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p "${OUT:-build}"
xcrun clang -O2 -target arm64-apple-macos15.0 -c \
  Tools/ValueWitnessOracle/ProcessIsolation.c -o "${OUT:-build}/ProcessIsolation.o"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos15.0 \
  -import-objc-header Tools/ValueWitnessOracle/ProcessIsolation.h \
  "${OUT:-build}/ProcessIsolation.o" \
  -o "${OUT:-build}/vwo" Tools/ValueWitnessOracle/*.swift
