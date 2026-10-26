# compiler-rt function-signature generator

This directory contains the offline, standard-library-only generator for the
MacScope WS-11 arm64 library-signature corpus. The parser consumes the active
Xcode toolchain's universal `libclang_rt.osx.a`, selects the exact
`CPU_TYPE_ARM64` / normalized `CPU_SUBTYPE_ARM64_ALL` slice, and generates
versioned Swift predicates plus source-oracle fixtures and provenance artifacts.

The source archive is part of LLVM's compiler-rt runtime. Upstream compiler-rt
is distributed under the Apache License 2.0 with LLVM Exceptions, with legacy
notices and terms retained in its license file. A verbatim copy of the canonical
`llvm-project/compiler-rt/LICENSE.TXT` is committed here as
`LICENSE.compiler-rt.txt` (16,708 bytes; SHA-256
`1a8f1058753f1ba890de984e48f0242a3a5c29a6a8f2ed9fd813f36985387e8d`).

The Xcode archive is input evidence only: neither it nor extracted object files
may be committed. `compiler_rt_source_fixtures.json` retains the complete bytes
of every emitted function atom for deterministic oracle testing.
`FunctionSignatureCorpus.swift` retains only the bounded prefix, checksum,
collision-tail, imported-reference, symbol, and length evidence required by the
runtime matcher. `compiler_rt_signatures_manifest.json` pins the input archive
and selected arm64 slice SHA-256 hashes together with the selected raw CPU type,
raw and normalized CPU subtype, slice offset, and slice size.
`compiler_rt_signature_rejections.json` is the canonical stable-sorted ledger
of every dropped atom and its conservative reason. For the pinned archive it
records 34 drops: four `same-address-alias`, thirteen `unstable-checksum`,
fifteen `weak-evidence`, and two `predicate-collision` records.

The checked-in manifest identifies the exact Xcode-supplied binary used to
generate this corpus, but Apple does not publish a source-to-binary attestation
for that specific toolchain build here. The upstream license copy therefore
documents compiler-rt's governing terms and legacy notices without claiming
that the archived Xcode binary is byte-derived from the current upstream `main`
branch.

## Smoke gate

The smoke suite uses only synthetic containers and never opens Xcode's archive:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover \
  -s Scripts/function-signatures/tests -p 'test_*.py' -v
```

The current smoke suite contains 42 tests covering fat32/fat64 selection, BSD
ar and ranlib parsing, Mach-O object and symbol boundaries, conservative
relocation handling, frozen signature evidence, ambiguity rejection,
static-twin witness collisions, deterministic artifacts, checkpoint/resume, and
read-only artifact checking.

## Witness collisions

Records come only from exported, ranlib-listed atoms, but every symbol-delimited
`__text` range in the archive, static functions included, is also a collision
witness. A record whose byte predicate (imported-reference checks ignored)
matches a differently named range is dropped as `witness-collision`, because
once linked it would name that function wrongly. H18 measured this defect on
public libraries. The checked-in
artifacts predate the rule: a `--check` run against the pinned Xcode archive
reports drift exactly when the shipped corpus contains such a twin, and
`--refresh` then removes it.

## Full check and refresh

Full runs require the expected whole-archive SHA-256. `--check` never writes
generated outputs; `--refresh` is the only mode that writes those four tracked
artifacts. An explicitly requested checkpoint is a separate untracked progress
artifact and may be written atomically during a checkpoint/resume check run. The
optional Apple-tool gate independently cross-checks the direct parser with
Xcode-bundled `lipo`, `nm`, `otool`, and `llvm-objdump`.

```sh
python3 Scripts/function-signatures/generate_compiler_rt_signatures.py \
  --archive /path/to/libclang_rt.osx.a \
  --expected-sha256 EXPECTED_SHA256 \
  --check \
  --cross-check-apple-tools
```

For an injected bounded stop, use `--checkpoint /tmp/ws11-checkpoint.json`
with `--stop-after-members N`. Continue only with
`--resume /tmp/ws11-checkpoint.json`. Checkpoints are canonical JSON outside
the repository; resume reparses the SHA-pinned input and validates normalized
progress rather than trusting serialized archive bytes.
