#!/bin/sh
# Reproducible build recipe for original-arm64, the reconstruction F target
# (profile arm64-c-u32-saturating-increment-v1). It mirrors the production compile
# argv in Services/Reconstruction/ReconstructionProductionSourceCutResolver.swift
# (compileArguments): candidate.c is ReconstructionSourceOriginalSession.originalSourceUTF8 and
# harness.c is ReconstructionSourceBehaviorHarness.saturatingIncrementV1().sourceUTF8.
# The checked-in binary (33,656 B, sha256 e4aaf1e8...3ff0) was built by the production
# original-preparation path on 2026-10-08 (Xcode 27.2, macOS SDK 27.2); a different toolchain
# may produce different bytes. Even with the same toolchain a rebuild differs by 48 bytes (LC_UUID
# from the driver's random temporary object names, plus the signature's page-0 hash); see README.md.
# The checked-in binary is canonical. The output is named candidate, as in production, so the
# linker signature identifier matches.
set -eu
cd "$(dirname "$0")"
outdir="${1:-./rebuilt}"
mkdir -p "$outdir"
out="$outdir/candidate"
clang -std=c11 -O0 -Wall -Wextra -Werror -target arm64-apple-macos27.0 \
  -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -ffreestanding -fno-builtin -ferror-limit=8 \
  candidate.c harness.c -o "$out"
shasum -a 256 "$out"
cmp -l original-arm64 "$out" | wc -l | sed "s/^ */differing bytes vs original-arm64: /"
