#!/usr/bin/env bash
# Build the golden-differential CORPUS binaries from committed sources into the fixtures tree.
#
# The corpus extends the MacScope-vs-oracle differential beyond /bin/ls to MODERN-binary shapes
# (Swift metadata + mangled symbols; ObjC classes/categories/msgSend) that /bin/ls does not have.
# The SOURCES (GoldenFixtures/corpus/*.{swift,m}) are committed and reproducible; the built BINARIES
# and the captured oracle JSONs are git-ignored (clean-room — see GoldenFixtures/README.md).
#
# Build these binaries, then supply stored reference output for each:
#     Scripts/build_golden_corpus.sh
# Then `GoldenDifferentialTests` picks the binaries + references up automatically (skips if absent).
#
# Env: GOLDEN_CORPUS_ARCH  target arch (default: arm64e — matches MacScope's slice choice and
#                          exercises the PAC prologue / authenticated-call shapes).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MACSCOPE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$MACSCOPE_DIR/Tests/CoreTests/GoldenFixtures"
SRC="$FIXTURES/corpus"
TARGET="${GOLDEN_CORPUS_ARCH:-arm64e}-apple-macos13"

mkdir -p "$FIXTURES/swift_corpus" "$FIXTURES/objc_corpus"

echo "Building swift_corpus ($TARGET) ..."
xcrun swiftc -emit-library -O -target "$TARGET" -module-name swift_corpus \
    "$SRC/swift_corpus.swift" -o "$FIXTURES/swift_corpus/swift_corpus"

echo "Building objc_corpus ($TARGET) ..."
xcrun clang -dynamiclib -O2 -target "$TARGET" -framework Foundation \
    "$SRC/objc_corpus.m" -o "$FIXTURES/objc_corpus/objc_corpus"

echo "Built:"
for b in swift_corpus objc_corpus; do
    printf '  %-14s %s  ' "$b" "$(lipo -archs "$FIXTURES/$b/$b")"
    echo "$FIXTURES/$b/$b"
done
echo "Next: supply stored reference output, then run GoldenDifferentialTests."
