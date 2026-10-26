# Darwin arm64 call-binding oracle

`call-vectors.json.gz` backs `DarwinARM64CallBindingOracleTests` (§4.99b). It holds 304 C call
signatures (0–12 arguments) and 25 return probes for `arm64-apple-macos14`. Each call parameter
carries its ABI locations (register name and byte size, or a stack offset relative to call-time
sp and size; multi-register chunks in increasing memory order). `fixed_count` separates the
named formals from anonymous variadic actuals.

## Provenance

- Specification-derived reference data recorded on 2026-10-13.
- Schema `macscope-darwin-arm64-layout-abi-oracle-1`; the `fixture_contract` block inside the file
  is the authority for how locations are expressed.
- Expected locations: independently predicted from AAPCS64 plus Apple's arm64 deviations (compact
  stack slots for narrow named scalars, binary64 `long double`, odd-pair starts for 16-byte
  integers, anonymous variadics on the stack after default promotions), then corroborated by a
  bounded interpreter tracing the caller assembly emitted by the compiler below up to each `bl`.
  All 1,941 parameter-byte checks and 25 return probes matched. No Darwin binary was executed.
- Compiler: official LLVM apt Clang 19.1.7, package build
  `1:19.1.7~++20250114103228+cd708029e0b2-1~exp1~20250114103334.78`, LLVM commit
  `cd708029e0b2869e80abe31ddb175f7c35361f90`; target `arm64-apple-macos14`, gnu11, freestanding,
  `-O0`, no SDK.
- Product baseline the oracle was written against: jdotc1/MacScope-app `5a1c0acdb2f8a98cd2e17c99be67876892cdb01d`.

## Derivation and integrity

`call-vectors.json` is a subset of the delivery, built with Python's `json` module (no oracle
script was run): from `vectors.json` the keys `schema`, `counts`, `defaults`, `fixture_contract`,
`calls`, `return_probes` and `discrepancies.calls`, verbatim; from `call-inputs.json` the `types`
table (C spelling, size, alignment, kind, HFA base/count). The 4,644 record layouts are omitted.
Serialized with `json.dumps(indent=1)` plus a trailing newline, then `gzip -9 -n`.

| File | Bytes | SHA-256 |
|---|---:|---|
| delivery `vectors.json` (matches the delivery's `SHA256SUMS.json`) | 10,828,202 | `2cad3ac0bb9070b776f03b1890c9d820ca25e8612359d9acb19e72f792544d89` |
| delivery `call-inputs.json` (matches `SHA256SUMS.json`) | 558,861 | `06f3a151295382e32cf55a2c1b46d32846ad34f9bd65a7c21f0833073661611b` |
| `call-vectors.json` (derived subset) | 1,644,623 | `d309b10485b713e0628d8000cbf54b83827464e5a02f03b9590fb217393cabcb` |
| `call-vectors.json.gz` (`gzip -9 -n`) | 76,664 | `2e69cc04d274c2c5b8465fa3496f0c1817904d4767652123e88e61d35f4959d8` |

All 51 entries of the delivery's `SHA256SUMS.json` were checked once with `shasum -a 256` on
2026-10-13 before import. The hashes are recorded once, here. The test does not re-hash the file.

## How the test uses it

- Named formals only: the first `fixed_count` types, spelled with the `types[*].c` C spelling
  (`signed char`, `short`, `int`, `long`, `float`, `double`, `long double`, `__int128`, and the
  typedef names `V2`/`V4`/`H1`…`Mix` for vectors and records), go to
  `DarwinARM64ParameterBinder.bind(parameterTypes:isVariadic:)`. Anonymous actuals are outside
  that API and are never fed in.
- Comparison: binder `gpr(i, 32|64)` renders `w<i>`/`x<i>`, `simd(i, 32|64)` renders
  `s<i>`/`d<i>`, `entryStack(off, size, _)` renders `stack+off/size`; the oracle's locations
  render the same way. Register value sizes inside a carrier are not compared (the binder does not
  expose them); stack slot sizes are.
- UNSUPPORTED is the binder's documented limit (aggregates incl. HFA/HVA, short vectors,
  `__int128`, and later formals marked dependent on them). An abstention on any other type is a
  FAIL. Formals bound before the first abstention are still compared.
- Return probes are NOT-MODELLED: the binder has no return-location API.
- `baseline-pass.txt` lists the PASS case ids from the recording run; the test fails when a listed
  case stops passing or the PASS count drops. Re-record with
  `TEST_RUNNER_MACSCOPE_ABI_CALL_ORACLE_RECORD_BASELINE=1` when cases turn green.
- `REPORT-20261013.md` is the report from the recording run.

## Scope (from the oracle's coverage notes)

Not covered: C++ non-trivial objects, scalable vectors/predicates, SME state, arm64e pointer
authentication, Objective-C dispatch, unprototyped calls, empty/GNU aggregate corner cases,
runtime `va_list` traversal, other optimisation levels.
