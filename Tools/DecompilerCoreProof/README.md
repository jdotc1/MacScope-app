# DCP-03 native SLEIGH data-flow proof

This directory retains the accepted historical dependency-bearing decompiler proof. It is
**developer-only, non-shipping, shadow-only, and a partial implementation of
DCP-03**. The proof uses the native SLEIGH binding and bundled AArch64 processor
specifications in pinned `pypcode` 4.0.0, then derives MacScope-owned low-level
data-flow and register-semantics contracts from raw p-code and the machine CFG.

The implementation is intentionally incremental:

- DCP-03A froze the validated byte, instruction, raw p-code, CFG, call,
  source-map, process-supervision, and canonical-serialization seam.
- DCP-03B0 added deterministic exact-storage SSA, per-operand heritage,
  conservative single-partition MemorySSA, and independent semantic
  rederivation.
- DCP-03B1 adds a separate AArch64 GPR semantic layer that canonicalizes
  `xN`/`wN` and `sp`/`wsp`, models 32-bit writes as zero-extension, derives
  canonical 64-bit GPR SSA, and publishes explicit base Darwin call-input and
  clobber slices.
- DCP-03B2 adds an authority-preserving effective-memory view that applies a
  frozen AArch64 Mach-O relocation subset and normalized dyld chained-pointer
  fixups before decode/lift while retaining raw bytes and exact patch evidence.

None of these MacScope-owned layers are represented as native Ghidra decompiler
heritage.

## Available capabilities

The successful result contract reports these capabilities as available:

- strict, duplicate-key-rejecting request validation;
- immutable image identity and preferred-address context;
- caller-supplied raw bytes from the `LoadedBinary` authority boundary;
- immutable raw and effective memory views with exact region hashes;
- a bounded fail-closed AArch64 Mach-O relocation subset for unsigned pointers,
  B/BL branch26, ADRP page21, and supported ADD/load/store pageoff12 forms;
- normalized 64-bit dyld rebase/bind and authenticated rebase/bind targets with
  retained authentication evidence;
- deterministic per-patch provenance, per-region ownership, unmapped metadata
  evidence, and independent supervisor rederivation from the original request;
- AArch64 instruction decoding from the effective function bytes;
- raw SLEIGH p-code operations and varnodes;
- conservative machine basic-block and CFG-edge recovery;
- direct and indirect call records with caller-supplied symbol evidence;
- image-qualified instruction and operation source ranges;
- deterministic exact-storage SSA using the tuple
  `space/offset/size/instruction-scope` as storage identity;
- backward-liveness, multi-input phi placement, including entry-loop paths;
- one exact-storage SSA binding per p-code operation and one heritage record per
  raw p-code operand;
- conservative MemorySSA over one `unknown` memory partition;
- memory reads, writes, call clobbers, unknown clobbers, and memory phis;
- pinned-SLEIGH AArch64 GPR view validation for `x0`-`x30`, `w0`-`w30`, `sp`,
  and `wsp`;
- one canonical 64-bit SSA family for every observed `xN`/`wN` pair and for
  `sp`/`wsp`;
- zero-extension semantics for 32-bit GPR writes;
- edge-qualified GPR phis and deterministic post-call GPR definitions;
- Darwin AAPCS64 call-effect records covering 19 conservative unknown-prototype
  input slices and 56 post-call slices: unknown `x0`-`x18` and `x30`, volatile
  SIMD slices, and undefined N/Z/C/V state;
- call-input reads before synthetic post-call clobbers, including indirect-call
  target registers;
- independent semantic rederivation of exact-storage SSA, heritage, MemorySSA,
  canonical GPR SSA, and every call-effect slice before publication;
- deterministic canonical JSON and complete content hashes;
- cancellation, internal budgets, an external supervisor timeout, output caps,
  malformed-input rejection, and process isolation from the app; and
- explicit capability and semantic truth tables for every unavailable layer.

## Deliberate limitations

The proof does **not** provide or claim:

- native Ghidra decompiler heritage;
- complete AArch64 register SSA;
- SIMD/vector register SSA;
- condition-flag SSA;
- subregister semantics beyond the modeled GPR aliases;
- stack/global/TLS/heap memory partitions or points-to analysis;
- recovered variables, signatures, or generic types;
- complete Mach-O relocation coverage, chained-fixup decoding, PAC validation,
  image-slide inference, or a second binary loader;
- high-level control-flow structuring;
- C, Objective-C, or Swift pseudocode or source tokens;
- a production `LoadedBinary` adapter;
- MacIR2 import;
- app or signed-XPC integration; or
- a replacement for MacScope's current decompiler.

These limitations describe this proof artifact, not the later provider. DCP-03B5
subsequently qualified the direct native structured provider, and DCP-04 now
hosts that provider in a dedicated signed shadow XPC service. Neither tranche
promoted native output to the default decompiler or persisted product truth.

The distinction among the available layers is binding:

- `exactStorageSSA` versions exact SLEIGH storage tuples independently;
- `aarch64GprSSA` overlays only the canonical 64-bit GPR families;
- generic `registerSSA` remains unavailable because SIMD/vector slices,
  condition flags, system registers, and the complete architecture register
  model are not versioned.

The call-effect overlay enumerates ABI-defined call inputs and volatility even
when the proof has no corresponding SIMD or flag SSA version. Conservative
inputs are `x0`-`x8`, `x30`, `sp`, and `v0`-`v7`; only the GPR inputs carry
reaching SSA versions. Only GPR clobber slices receive synthetic post-call
versions. `x18` is recorded as Apple platform-reserved rather than ordinary
caller-saved state. `x30` binds to the pre-call link write and receives a
distinct unknown post-call version.

The effective-image layer is also deliberately bounded. Every mapped metadata
record must match one of the frozen relocation/fixup kinds and a supported
instruction or pointer encoding. Unsupported mapped records, ambiguous target
evidence, partial region overlaps, boundary crossings, and overlapping patches
fail closed. Records entirely outside caller-supplied memory remain visible as
unmapped evidence. The supervisor reconstructs the complete effective view from
the validated request before publishing output.

`pypcode` is not imported by normal MacScope bootstrap, build, or product-test
paths. Native integration tests run only when the current Python environment
already contains exactly the pinned dependency. Otherwise, dependency-free
protocol, schema, semantic-verifier, data-flow, register-analysis, governance,
and supervisor tests remain active.

## Explicit materialization

On a supported macOS arm64 or Linux x86_64 CPython 3.13 host:

```sh
./Scripts/dependencies/materialize_pypcode_dcp03.sh
```

The command downloads exactly one predeclared wheel, verifies its SHA-256,
creates the ignored `pypcode-dcp03/` environment, installs with `--no-index`
and `--no-deps`, validates the selected Apple-Silicon SLEIGH resource, and runs
an AArch64 self-test. It is never called implicitly by bootstrap, build, test,
Xcode generation, or application execution.

## Run the supervised fixture

```sh
MACSCOPE_DCP03_PYTHON="$PWD/pypcode-dcp03/bin/python3" \
  ./Scripts/decompiler-proof/run_dcp03_proof.sh \
  --input Tools/DecompilerCoreProof/fixtures/conditional-call.request.json \
  --output /tmp/macscope-dcp03-result.json
```

The supervisor validates the request before native dependency import, launches
the worker in a child process with bounded resources, validates request and
engine identity, independently reconstructs the effective memory view,
rederives all low-level and GPR data-flow contracts, verifies the canonical
content hash, and atomically publishes the result. The app and existing
decompiler are not touched.

## Test

Dependency-free protocol, effective-image, data-flow, register-semantics,
and supervisor tests:

```sh
PYTHONPATH=Tools/DecompilerCoreProof \
  python3 -m unittest -v \
  Scripts.tests.test_decompiler_core_proof \
  Scripts.tests.test_decompiler_load_image \
  Scripts.tests.test_decompiler_dataflow \
  Scripts.tests.test_decompiler_register_dataflow
```

Full proof tests in the explicitly materialized environment:

```sh
PYTHONPATH=Tools/DecompilerCoreProof \
  pypcode-dcp03/bin/python3 -m unittest -v \
  Scripts.tests.test_decompiler_core_proof \
  Scripts.tests.test_decompiler_load_image \
  Scripts.tests.test_decompiler_dataflow \
  Scripts.tests.test_decompiler_register_dataflow
```

The result schema is Draft 2020-12 and is intentionally closed. The standard-
library semantic verifier remains authoritative even when `jsonschema` is not
installed because it enforces cross-record properties that JSON Schema cannot
express.

## Promotion path

DCP-03B2 is a prerequisite seam, not completion of DCP-03B. The next backend
increment must integrate the approved native Ghidra decompiler through a custom
MacScope `LoadImage`/symbol/type adapter, consume the exact effective bytes
specified here, and export its structured heritage, complete register-aware
SSA, memory effects, variables, type candidates, regions, calls, tokens, and
source ranges directly. Rendered C must never be reparsed to infer semantics.

Only after that backend is deterministic, source-faithful, malformed-input
hardened, resource bounded, and differentially qualified may DCP-04 package it
inside a signed `DecompilerCoreXPCService`. The current Swift decompiler remains
the sole default until the repository's promotion gates explicitly authorize a
change.
