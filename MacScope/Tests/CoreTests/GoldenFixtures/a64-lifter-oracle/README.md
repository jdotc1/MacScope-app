# A64 lifter state-transition oracle

`vectors.json.gz` backs `A64LifterOracleTests`. It holds 9,368 single-instruction fixtures over
1,197 operand forms (4,679 distinct words). Each fixture is an A64 instruction word, its seeded
architectural input state (GPRs, SP, NZCV, FPCR, FPSR, V registers, memory) and the expected
output state. Every fixture was executed once under QEMU and matched its expected state.

## Provenance

- Specification-derived reference data recorded on 2026-10-13.
- Schema `macscope-a64-lifter-oracle-1`; the `defaults` and `fixture_contract` blocks inside the
  file are the authority for how state is seeded and compared.
- Expected values: exact integer arithmetic and `fractions.Fraction`-based IEEE arithmetic
  following the pinned Arm pseudocode. Execution never rewrote expectations.
- Execution: QEMU aarch64 user-mode 11.1.2 (Debian 1:11.1.2+ds-3), CPU max, one GDB
  single-step per fixture.
- Assembly: LLVM MC 19.1.7 (Debian 1:19.1.7-3+b1).
- Encodings checked against Arm XML 2025-03, mirror commit
  `836d4cab97342d7eb22d51648757ae51608a5572`.
- Product baseline the oracle was written against: jdotc1/MacScope-app `5a1c0acdb2f8a98cd2e17c99be67876892cdb01d`.

## Integrity

| File | Bytes | SHA-256 |
|---|---:|---|
| `vectors.json` (as delivered; matches the `file-manifest.json`) | 9,560,665 | `f8eebde48695d3b50a83132137b8e377913f9f02b9702d3f64380b260fddc648` |
| `vectors.json.gz` (`gzip -9 -n`) | 216,861 | `7041fbadf3a1de6bd37548c98aa26acfca9702cf88544a190483de6eca865bb7` |

The hashes are recorded once, here. The test does not re-hash the file on each run.

## Scope (from the oracle's coverage notes)

- EL0, little-endian, PSTATE.SM=0, FP traps disabled. FPCR options are zero except an
  explicit RMode.
- Excluded: PAuth signing/authentication, exception returns, alternate FP profiles, fault
  ordering, exclusives and atomics.
- Selection fixtures consume an NZCV value directly, with no preceding compare. The harness
  pairs them with a synthesized `cmp` that produces that exact NZCV, because MacIR has no flag
  state of its own.

## Baseline and report

- `baseline-pass.txt` lists the fixture IDs that PASS today: 3,142 of 9,368 at the first run on 2026-10-13. `A64LifterOracleTests` fails if any of them stops passing.
- `REPORT-20261013.md` is that first run's report: FAIL classes, §4.78 width/signedness counts, and UNLIFTED and UNSUPPORTED breakdowns.

## Regenerating

Do not edit the JSON by hand. A new oracle delivery replaces `vectors.json.gz`, and this README
gets the new hashes and versions. After that, re-record `baseline-pass.txt` from one run of
`A64LifterOracleTests` with `TEST_RUNNER_MACSCOPE_A64_ORACLE_RECORD_BASELINE=1`.
