# Darwin arm64 C record-layout oracle

`layouts.json.gz` backs `CLayoutABIOracleTests`. It holds 4,644 C records with Clang's layout: size, alignment, and every field's byte offset, absolute bit offset and bit width. Each record carries its declaration; the common preamble and dependencies are stored once.

## Provenance

- **Source:** reference data recorded on 2026-10-13.
  - Source schema: `macscope-darwin-arm64-layout-abi-oracle-1`.
  - Only the layouts are sliced here. The 304 call vectors belong to the debugger/binder owner.
- **Reference:** official LLVM apt Clang 19.1.7 (LLVM commit cd708029e0b2869e80abe31ddb175f7c35361f90), with `-target arm64-apple-macos14`, gnu11, freestanding, -O0 and no SDK.
- **Independent checks:** 4,188 records were also checked by independent layout arithmetic; all agree. The rest are compiler observations.
- **Product baseline:** jdotc1/MacScope-app `5a1c0acdb2f8a98cd2e17c99be67876892cdb01d`.

## Integrity

| File | SHA-256 |
|---|---|
| `vectors.json` (as delivered; matches the `SHA256SUMS.json`) | `2cad3ac0bb9070b776f03b1890c9d820ca25e8612359d9acb19e72f792544d89` |
| `layout-inputs.json` (as delivered) | `cfe8d7c57b705d0e4ecd4691b66c12e597d053cf877ce9dafa998fa543938ff7` |
| `layouts.json.gz` (this slice, `gzip -9 -n`, 56,550 bytes) | `1f498a778a48f2800757773c58249e76aceb300736f200c55291917b5a5a659e` |

The hashes are recorded once, here. The test does not re-hash.

## Gates

- **`baseline-pass.txt`:** 2,425 records that match Clang at the first Mac run on 2026-10-13.
  - Each record is imported on its own with the preamble and dependencies.
  - Size, alignment and named member byte offsets are compared.
  - MacScope's layout is byte-only, so a bitfield must have Clang's exact bit span inside its MacScope storage unit.
- **`baseline-roundtrip.txt`:** 2,232 records that keep size, alignment and offsets through `CTypeHeaderRenderer` export and re-import.
- **`REPORT-20261013.md`:** that run's counts by family, and every failing record with its declaration.

Re-record with `TEST_RUNNER_MACSCOPE_LAYOUT_ORACLE_RECORD_BASELINE=1`. The run records only when no record in the old baselines regressed.
